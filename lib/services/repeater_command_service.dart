import 'dart:async';
import '../models/contact.dart';
import '../models/path_selection.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';

/// Companion firmware (MeshCore commit 4a869163, 2025-12-30) replaces the CLI
/// frame timestamp with the companion node's RTC for TXT_TYPE_CLI_DATA, so a
/// plain "clock sync" sets the repeater clock to the node clock. The official
/// meshcore-cli translates it to an explicit `time <epoch>` command instead;
/// do the same so the repeater always gets the phone's time.
String normalizeRepeaterClockSyncCommand(String command, {int? nowSeconds}) {
  final epoch = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return command.trim().toLowerCase() == 'clock sync' ? 'time $epoch' : command;
}

class RepeaterCommandService {
  final MeshCoreConnector _connector;
  final Map<String, Completer<String>> _pendingCommands = {};
  final Map<String, Timer> _commandTimeouts = {};
  final Map<String, String> _commandPrefixes = {};
  final Map<String, String> _pendingByPrefix = {};
  int _prefixCounter = 0;

  static const int maxRetries = 5;
  static final RegExp _prefixPattern = RegExp(r'^[0-9A-Fa-f]{2}\|');

  RepeaterCommandService(this._connector);

  /// Send a CLI command to a repeater with automatic retries
  /// Returns a future that completes when a response is received or after max retries.
  /// With [raw], the command is sent verbatim without the `XX|` reply prefix.
  Future<String> sendCommand(
    Contact repeater,
    String command, {
    Function(String)? onResponse,
    Function(int)? onAttempt,
    void Function()? onPacketSent,
    PathSelection? pathSelection,
    int retries = maxRetries,
    int minimumTimeoutMs = 0,
    bool raw = false,
  }) async {
    if (!raw) command = normalizeRepeaterClockSyncCommand(command);
    final attemptCount = retries < 1 ? 1 : retries;
    // A management page may hold a Contact from before the user changed its
    // route. Resolve the live contact so a stale page cannot silently reset a
    // manually selected direct path on the Companion.
    final currentRepeater =
        _connector.getContactByPubKeyHex(repeater.publicKeyHex) ?? repeater;
    final selection = await _connector.preparePathForContactSend(
      currentRepeater,
      explicitSelection: pathSelection,
    );

    for (int attempt = 0; attempt < attemptCount; attempt++) {
      onAttempt?.call(attempt + 1);
      try {
        final response = await _sendCommandAttempt(
          currentRepeater,
          command,
          selection,
          attempt,
          onPacketSent,
          raw,
          minimumTimeoutMs,
        );
        onResponse?.call(response);
        return response;
      } catch (e) {
        if (attempt == attemptCount - 1) rethrow;
      }
    }

    throw Exception('Command failed after $attemptCount attempts');
  }

  Future<String> _sendCommandAttempt(
    Contact repeater,
    String command,
    PathSelection selection,
    int attempt,
    void Function()? onPacketSent,
    bool raw,
    int minimumTimeoutMs,
  ) async {
    final repeaterKey = repeater.publicKeyHex;
    final prefix = _nextPrefixToken();
    final commandId = '${repeaterKey}_$prefix';
    final completer = Completer<String>();
    _pendingCommands[commandId] = completer;
    _commandPrefixes[commandId] = prefix;
    _pendingByPrefix[prefix] = commandId;

    try {
      final framedCommand = raw ? command : '$prefix$command';
      final pathLengthValue = selection.useFlood ? -1 : selection.hopCount;
      final timestampSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _connector.trackRepeaterAck(
        contact: repeater,
        selection: selection,
        text: framedCommand,
        timestampSeconds: timestampSeconds,
        attempt: attempt,
        onPacketSent: onPacketSent,
      );
      final frame = buildSendCliCommandFrame(
        repeater.publicKey,
        framedCommand,
        attempt: attempt,
        timestampSeconds: timestampSeconds,
      );
      final responseBytes = frame.length > maxFrameSize
          ? frame.length
          : maxFrameSize;
      final estimatedTimeoutMs = _connector.calculateTimeout(
        pathLength: pathLengthValue,
        messageBytes: responseBytes,
      );
      final timeoutMs = estimatedTimeoutMs > minimumTimeoutMs
          ? estimatedTimeoutMs
          : minimumTimeoutMs;
      final timeoutSeconds = (timeoutMs / 1000).ceil();
      await _connector.sendFrame(frame);
      _commandTimeouts[commandId]?.cancel();
      _commandTimeouts[commandId] = Timer(
        Duration(milliseconds: timeoutMs),
        () {
          final completer = _pendingCommands[commandId];
          if (completer != null && !completer.isCompleted) {
            completer.completeError(
              'Command timeout after $timeoutSeconds seconds',
            );
            _cleanup(commandId);
          }
        },
      );
    } catch (e) {
      _cleanup(commandId);
      throw Exception('Failed to send command: $e');
    }

    try {
      return await completer.future;
    } finally {
      _cleanup(commandId);
    }
  }

  /// Send [line] verbatim and don't wait for a reply. While `region load` is
  /// active the firmware consumes each line before prefix stripping and
  /// sends nothing back (simple_repeater/MyMesh.cpp handleCommand).
  Future<void> sendUnansweredLine(Contact repeater, String line) {
    return _connector.sendFrame(
      buildSendCliCommandFrame(repeater.publicKey, line),
    );
  }

  /// Call this when a text message response is received from a repeater
  void handleResponse(Contact repeater, String responseText) {
    // Find pending command for this repeater and complete it
    final repeaterKey = repeater.publicKeyHex;

    String? commandId;
    String responsePayload = responseText;
    if (_prefixPattern.hasMatch(responseText)) {
      final prefix = responseText.substring(0, 3).toUpperCase();
      final correlatedCommandId = _pendingByPrefix[prefix];
      final expectedCommandId = '${repeaterKey}_$prefix';

      // The short prefix disambiguates concurrent/retried commands, but it is
      // not an identity. Bind it to the contact whose authenticated direct
      // message carried the reply. Otherwise another logged-in contact could
      // guess a live prefix and complete a different repeater's operation.
      // Unknown prefixes are rejected as well, rather than falling through to
      // the legacy same-contact path and turning a delayed reply into an ACK
      // for the contact's next command.
      if (correlatedCommandId != expectedCommandId) return;
      commandId = correlatedCommandId;
      responsePayload = responseText.substring(3).trimLeft();
    }

    commandId ??= _pendingCommands.keys.firstWhere(
      (id) => id.startsWith('${repeaterKey}_'),
      orElse: () => '',
    );

    if (commandId.isEmpty) return;

    final completer = _pendingCommands[commandId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(responsePayload);
      _cleanup(commandId);
    }
  }

  void _cleanup(String commandId) {
    _commandTimeouts[commandId]?.cancel();
    _commandTimeouts.remove(commandId);
    _pendingCommands.remove(commandId);
    final prefix = _commandPrefixes.remove(commandId);
    if (prefix != null) {
      _pendingByPrefix.remove(prefix);
    }
  }

  void dispose() {
    for (final timer in _commandTimeouts.values) {
      timer.cancel();
    }
    _commandTimeouts.clear();
    _pendingCommands.clear();
    _commandPrefixes.clear();
    _pendingByPrefix.clear();
  }

  String _nextPrefixToken() {
    for (var i = 0; i < 256; i++) {
      final value = _prefixCounter++ & 0xFF;
      final token = '${value.toRadixString(16).padLeft(2, '0').toUpperCase()}|';
      if (!_pendingByPrefix.containsKey(token)) {
        return token;
      }
    }
    // Prefixes correlate replies which have already passed the Mesh
    // transport's sender authentication and replay checks; they are not
    // security nonces. Reuse after a completed command is intentional, but
    // two live commands must never share a token. Fail before inserting or
    // sending when all 256 values are occupied instead of overwriting the
    // owner of 00| and misrouting one of the replies.
    throw StateError('All repeater command correlation prefixes are in use');
  }
}
