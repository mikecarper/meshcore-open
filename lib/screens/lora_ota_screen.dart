import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import '../models/path_selection.dart';
import '../services/ble_mota_catalog.dart';
import '../services/lora_ota_route_planner.dart';
import '../services/repeater_command_service.dart';
import '../services/storage_service.dart';
import '../theme/mesh_theme.dart';
import '../widgets/mesh_ui.dart';
import '../widgets/path_editor_sheet.dart';

class LoRaOtaScreen extends StatefulWidget {
  final Contact repeater;
  final RepeaterCommandService? commandService;

  const LoRaOtaScreen({super.key, required this.repeater, this.commandService});

  @override
  State<LoRaOtaScreen> createState() => _LoRaOtaScreenState();
}

class _LoRaOtaScreenState extends State<LoRaOtaScreen> {
  static const _bandwidths = <double>[
    7.8,
    10.4,
    15.6,
    20.8,
    31.25,
    41.7,
    62.5,
    125,
    250,
    500,
  ];

  final TextEditingController _frequencyController = TextEditingController(
    text: '909.950',
  );
  final TextEditingController _minutesController = TextEditingController(
    text: '120',
  );
  final List<String> _events = <String>[];
  final StorageService _storage = StorageService();
  final List<_ControlledHopPlan> _controlledHops = <_ControlledHopPlan>[];
  final Set<String> _switchedControlledKeys = <String>{};

  late final MeshCoreConnector _connector;
  late final RepeaterCommandService _commandService;
  late final bool _ownsCommandService;
  StreamSubscription<Uint8List>? _frameSubscription;
  Timer? _statusTimer;
  Timer? _liveProgressTimer;
  Timer? _bleSourceResumeTimer;
  late MeshCoreConnectionState _lastConnectorState;

  BleMotaCatalog? _catalog;
  BleMotaFile? _selectedFile;
  BleMotaSourceStatus? _sourceStatus;
  late Uint8List _normalTargetPath;
  late Uint8List _temporaryTargetPath;
  double _bandwidth = 250;
  int _spreadingFactor = 5;
  int _codingRate = 5;
  bool _busy = false;
  bool _sessionActive = false;
  bool _resumeSourceAfterReconnect = false;
  bool _sourceResumeActive = false;
  bool _restoringSession = false;
  bool _autoCheck = true;
  bool _readyToInstall = false;
  int? _downloadPercent;
  int? _confirmedBlocks;
  int? _confirmedTotalBlocks;
  String? _validationStatus;

  @override
  void initState() {
    super.initState();
    _connector = context.read<MeshCoreConnector>();
    _lastConnectorState = _connector.state;
    _connector.addListener(_handleConnectorChanged);
    _ownsCommandService = widget.commandService == null;
    _commandService =
        widget.commandService ?? RepeaterCommandService(_connector);
    _catalog = _connector.bleMotaCatalog;
    final current = _currentRepeater();
    _normalTargetPath = _bestKnownPath(current);
    _temporaryTargetPath = Uint8List.fromList(_normalTargetPath);
    _frameSubscription = _connector.receivedFrames.listen(_handleFrame);
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _liveProgressTimer?.cancel();
    _bleSourceResumeTimer?.cancel();
    _connector.removeListener(_handleConnectorChanged);
    _frameSubscription?.cancel();
    if (_ownsCommandService) _commandService.dispose();
    for (final plan in _controlledHops) {
      plan.dispose();
    }
    _frequencyController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  void _handleConnectorChanged() {
    final state = _connector.state;
    final previous = _lastConnectorState;
    _lastConnectorState = state;
    if (!_sessionActive || _restoringSession) return;

    if (state != MeshCoreConnectionState.connected) {
      if (previous == MeshCoreConnectionState.connected) {
        _resumeSourceAfterReconnect = true;
        _bleSourceResumeTimer?.cancel();
        scheduleMicrotask(() {
          if (!mounted || !_sessionActive || _restoringSession) return;
          _addEvent(
            'Bluetooth disconnected. The repeater keeps its staged blocks; '
            'the source will reattach after the Companion reconnects.',
          );
        });
      }
      return;
    }

    // A transport reconnect can be reported before service discovery and the
    // protected mOTA notifications are ready. Start the retry loop on the
    // transport transition itself instead of depending on another connector
    // notification for the channel-ready transition.
    if (_resumeSourceAfterReconnect) {
      _scheduleBleSourceResume();
    }
  }

  void _scheduleBleSourceResume({
    Duration delay = const Duration(milliseconds: 250),
  }) {
    if (!_sessionActive || _restoringSession) return;
    _bleSourceResumeTimer?.cancel();
    _bleSourceResumeTimer = Timer(delay, () {
      if (mounted) unawaited(_resumeBleSourceAfterReconnect());
    });
  }

  Future<void> _resumeBleSourceAfterReconnect() async {
    if (_sourceResumeActive || !_sessionActive || _restoringSession) return;
    if (!_resumeSourceAfterReconnect || !_connector.isConnected) return;
    if (!_connector.isBleMotaChannelReady) {
      _scheduleBleSourceResume(delay: const Duration(seconds: 2));
      return;
    }

    final catalog = _catalog;
    if (catalog == null || catalog.files.isEmpty) {
      _addEvent(
        'Cannot resume Bluetooth source: the verified catalog is gone.',
      );
      return;
    }

    _sourceResumeActive = true;
    var retryDelay = const Duration(milliseconds: 500);
    try {
      // Automatic BLE reconnect preserves the in-memory verified files, but
      // firmware deliberately detaches the old GATT-backed source when that
      // encrypted link disappears. Renew the local TempRadio window and
      // explicitly attach a fresh source session; the destination's persisted
      // block bitmap then asks only for what is still missing.
      _connector.setBleMotaCatalog(catalog);
      final radioReply = await _connector.executeLocalOtaControl(
        _tempRadioCommand(),
      );
      _addEvent('Companion reconnect: $radioReply');
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      if (!_connector.isConnected || !_sessionActive || _restoringSession) {
        return;
      }

      final status = await _connector.controlBleMotaSource(bleMotaActionStart);
      if (!status.channelReady || !status.attached) {
        throw StateError(_sourceStatusText(status));
      }
      if (status.offered != catalog.files.length ||
          status.advertised != catalog.files.length) {
        throw StateError(
          'Companion resumed ${status.advertised}/${status.offered} files; '
          '${catalog.files.length} are selected.',
        );
      }

      _resumeSourceAfterReconnect = false;
      if (mounted) setState(() => _sourceStatus = status);
      _addEvent(
        'Bluetooth source reattached. The repeater can resume its existing '
        'download without discarding confirmed blocks.',
      );
      _startLiveProgressTimer();
      if (_selectedFile != null && !_readyToInstall) _startStatusTimer();

      try {
        final targetStatus = await _sendTargetCommand('ota status');
        _addEvent('${widget.repeater.name}: $targetStatus');
        _applyDownloadStatus(targetStatus);
      } catch (error) {
        _addEvent('Source resumed; target status will retry: $error');
      }
    } catch (error) {
      _addEvent('Bluetooth source resume failed: $error');
      retryDelay = const Duration(seconds: 5);
    } finally {
      _sourceResumeActive = false;
      if (_resumeSourceAfterReconnect &&
          _sessionActive &&
          !_restoringSession &&
          _connector.isConnected &&
          _connector.isBleMotaChannelReady) {
        _scheduleBleSourceResume(delay: retryDelay);
      }
    }
  }

  void _handleFrame(Uint8List frame) {
    if (frame.isEmpty ||
        (frame[0] != respCodeContactMsgRecv &&
            frame[0] != respCodeContactMsgRecvV3)) {
      return;
    }
    final parsed = parseContactMessageText(frame);
    if (parsed == null) return;
    final contact = _contactForPrefix(parsed.senderPrefix);
    if (contact != null) {
      _commandService.handleResponse(contact, parsed.text);
    }
  }

  Contact? _contactForPrefix(Uint8List prefix) {
    final candidates = <Contact>[
      _currentRepeater(),
      ..._controlledHops.map((plan) => plan.contact),
    ];
    for (final contact in candidates) {
      if (_matchesPrefix(contact, prefix)) return contact;
    }
    return null;
  }

  bool _matchesPrefix(Contact contact, Uint8List prefix) {
    final publicKey = contact.publicKey;
    if (publicKey.length < 6 || prefix.length < 6) return false;
    for (var index = 0; index < 6; index++) {
      if (publicKey[index] != prefix[index]) return false;
    }
    return true;
  }

  Contact _currentRepeater() {
    return _connector.contacts.cast<Contact?>().firstWhere(
          (contact) => contact?.publicKeyHex == widget.repeater.publicKeyHex,
          orElse: () => null,
        ) ??
        widget.repeater;
  }

  Future<void> _pickFirmware() async {
    if (_busy || _sessionActive) return;
    const type = XTypeGroup(
      label: 'MeshCore mOTA firmware',
      extensions: <String>['mota'],
      mimeTypes: <String>['application/octet-stream'],
      uniformTypeIdentifiers: <String>['public.data'],
      webWildCards: <String>['.mota'],
    );
    final sources = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[type],
    );
    if (sources.isEmpty || !mounted) return;

    setState(() {
      _busy = true;
      _validationStatus = 'Validating 0/${sources.length}';
    });
    try {
      final catalog = await BleMotaCatalog.load(
        sources,
        onProgress: (completed, total) {
          if (!mounted) return;
          setState(() => _validationStatus = 'Validating $completed/$total');
        },
      );
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _validationStatus = '${catalog.files.length} verified file(s)';
      });
      _addEvent('Verified ${catalog.files.length} mOTA file(s).');
    } catch (error) {
      if (!mounted) return;
      setState(() => _validationStatus = 'Validation failed');
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _tempRadioCommand() {
    final frequencyText = _frequencyController.text.trim();
    final frequency = double.tryParse(frequencyText);
    final minutes = int.tryParse(_minutesController.text.trim());
    if (frequency == null || frequency < 150 || frequency > 2500) {
      throw const FormatException('Frequency must be 150-2500 MHz.');
    }
    if (minutes == null || minutes < 1 || minutes > 10080) {
      throw const FormatException('Duration must be 1-10080 minutes.');
    }
    final bandwidth = _numberText(_bandwidth);
    return 'tempradio $frequencyText,$bandwidth,$_spreadingFactor,'
        '$_codingRate,$minutes';
  }

  ({Future<void> dispatched, Future<String> response}) _beginRemoteCommand(
    Contact contact,
    String command,
    PathSelection path,
  ) {
    final dispatched = Completer<void>();
    final response = _commandService.sendCommand(
      contact,
      command,
      retries: 1,
      pathSelection: path,
      onPacketSent: () {
        if (!dispatched.isCompleted) dispatched.complete();
      },
    );
    response.then<void>(
      (_) {
        // A reply proves that the packet was sent even if older firmware did
        // not provide the local RESP_CODE_SENT notification.
        if (!dispatched.isCompleted) dispatched.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!dispatched.isCompleted) {
          dispatched.completeError(error, stackTrace);
        }
      },
    );
    return (dispatched: dispatched.future, response: response);
  }

  Future<String> _sendRemoteCommand(
    Contact contact,
    String command,
    PathSelection path,
  ) {
    return _commandService.sendCommand(
      contact,
      command,
      retries: 1,
      pathSelection: path,
    );
  }

  PathSelection _pathSelection(Uint8List bytes) {
    final width = _connector.pathHashByteWidth;
    if (width < 1 || width > 4 || bytes.length % width != 0) {
      throw StateError('Route bytes do not match the active path-hash width.');
    }
    if (bytes.length > maxPathSize || bytes.length ~/ width > 0x3F) {
      throw StateError('Route exceeds the Companion path limit.');
    }
    return PathSelection(
      pathBytes: bytes,
      hopCount: bytes.length ~/ width,
      useFlood: false,
    );
  }

  PathSelection get _normalTargetSelection => _pathSelection(_normalTargetPath);
  PathSelection get _temporaryTargetSelection =>
      _pathSelection(_temporaryTargetPath);

  Future<String> _sendTargetCommand(String command) {
    return _sendRemoteCommand(
      _currentRepeater(),
      command,
      _temporaryTargetSelection,
    );
  }

  Future<String> _awaitRadioCommand(
    Contact contact,
    ({Future<void> dispatched, Future<String> response}) operation,
  ) async {
    // A response proves end-to-end delivery and is sent before firmware
    // changes radio parameters. Merely seeing the source packet leave the
    // Companion is not enough for a multi-hop handoff: a nearer relay must not
    // switch until the farther node has received and accepted its command.
    await operation.dispatched;
    final response = await operation.response;
    _addEvent('${contact.name}: $response');
    if (!response.trimLeft().toLowerCase().startsWith('ok')) {
      throw StateError('${contact.name} rejected the radio command: $response');
    }
    return response;
  }

  Future<void> _editTargetPath({required bool temporary}) async {
    final initial = temporary ? _temporaryTargetPath : _normalTargetPath;
    final result = await PathEditorSheet.show(
      context,
      availableContacts: _connector.allContactsUnfiltered
          .where(
            (contact) => contact.publicKeyHex != widget.repeater.publicKeyHex,
          )
          .toList(),
      initialPath: initial,
      pathHashByteWidth: _connector.pathHashByteWidth,
    );
    if (result == null || !mounted) return;
    setState(() {
      if (temporary) {
        _temporaryTargetPath = result;
      } else {
        _normalTargetPath = result;
      }
    });
  }

  Future<void> _addControlledHop() async {
    final existing = _controlledHops
        .map((plan) => plan.contact.publicKeyHex)
        .toSet();
    final candidates =
        _connector.allContactsUnfiltered
            .where(
              (contact) =>
                  (contact.type == advTypeRepeater ||
                      contact.type == advTypeRoom) &&
                  contact.publicKey.length == pubKeySize &&
                  contact.publicKeyHex != widget.repeater.publicKeyHex &&
                  !existing.contains(contact.publicKeyHex),
            )
            .toList()
          ..sort(
            (left, right) =>
                left.name.toLowerCase().compareTo(right.name.toLowerCase()),
          );
    if (candidates.isEmpty) {
      _showError(StateError('No additional repeater contacts are available.'));
      return;
    }

    final selected = await showDialog<Contact>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add controlled intermediate'),
        content: SizedBox(
          width: 420,
          height: 360,
          child: ListView.builder(
            itemCount: candidates.length,
            itemBuilder: (context, index) {
              final contact = candidates[index];
              return ListTile(
                leading: const Icon(Icons.cell_tower),
                title: Text(contact.name),
                subtitle: Text(contact.publicKeyHex.substring(0, 12)),
                onTap: () => Navigator.pop(dialogContext, contact),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;

    final normal =
        _prefixBeforeContact(_normalTargetPath, selected) ??
        _bestKnownPath(selected);
    final temporary =
        _prefixBeforeContact(_temporaryTargetPath, selected) ??
        Uint8List.fromList(normal);
    final plan = _ControlledHopPlan(
      contact: selected,
      normalPath: normal,
      temporaryPath: temporary,
    );
    setState(() => _controlledHops.add(plan));

    try {
      final saved = await _storage.getRepeaterPassword(selected.publicKeyHex);
      if (saved != null && mounted && _controlledHops.contains(plan)) {
        setState(() {
          plan.passwordController.text = saved;
          plan.savePassword = true;
        });
      }
    } catch (_) {
      // Password entry remains available even if local storage is unavailable.
    }
  }

  Uint8List _bestKnownPath(Contact contact) {
    final displayed = contact.pathBytesForDisplay;
    if (displayed.isNotEmpty) return Uint8List.fromList(displayed);
    if (contact.pathLength > 0 && contact.path.isNotEmpty) {
      return Uint8List.fromList(contact.path);
    }
    return Uint8List(0);
  }

  Uint8List? _prefixBeforeContact(Uint8List route, Contact contact) {
    final width = _connector.pathHashByteWidth;
    if (width <= 0 ||
        route.length % width != 0 ||
        contact.publicKey.length < width) {
      return null;
    }
    for (var offset = 0; offset < route.length; offset += width) {
      var matches = true;
      for (var index = 0; index < width; index++) {
        if (route[offset + index] != contact.publicKey[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return Uint8List.fromList(route.sublist(0, offset));
    }
    return null;
  }

  Future<void> _editControlledPath(
    _ControlledHopPlan plan, {
    required bool temporary,
  }) async {
    final initial = temporary ? plan.temporaryPath : plan.normalPath;
    final result = await PathEditorSheet.show(
      context,
      availableContacts: _connector.allContactsUnfiltered
          .where((contact) => contact.publicKeyHex != plan.contact.publicKeyHex)
          .toList(),
      initialPath: initial,
      pathHashByteWidth: _connector.pathHashByteWidth,
    );
    if (result == null || !mounted) return;
    setState(() {
      if (temporary) {
        plan.temporaryPath = result;
      } else {
        plan.normalPath = result;
      }
    });
  }

  void _removeControlledHop(_ControlledHopPlan plan) {
    setState(() => _controlledHops.remove(plan));
    _switchedControlledKeys.remove(plan.contact.publicKeyHex);
    plan.dispose();
  }

  List<_ControlledHopPlan> _farthestFirst({required bool temporary}) {
    return loraOtaDependencyFirst(
      _controlledHops,
      routeBytes: (plan) => temporary ? plan.temporaryPath : plan.normalPath,
      destinationPublicKey: (plan) => plan.contact.publicKey,
      pathHashByteWidth: _connector.pathHashByteWidth,
    );
  }

  void _validateRoutePlan() {
    final target = _currentRepeater();
    if (target.publicKey.length != pubKeySize) {
      throw StateError('${target.name} has an invalid public key.');
    }
    _normalTargetSelection;
    _temporaryTargetSelection;
    if (_prefixBeforeContact(_normalTargetPath, target) != null ||
        _prefixBeforeContact(_temporaryTargetPath, target) != null) {
      throw StateError('The target cannot appear as a hop in its own route.');
    }
    for (final plan in _controlledHops) {
      if (plan.contact.publicKey.length != pubKeySize) {
        throw StateError('${plan.contact.name} has an invalid public key.');
      }
      _pathSelection(plan.normalPath);
      _pathSelection(plan.temporaryPath);
      if (_prefixBeforeContact(plan.normalPath, target) != null ||
          _prefixBeforeContact(plan.temporaryPath, target) != null) {
        throw StateError(
          '${target.name} cannot relay a controlled intermediate path. '
          'The OTA target reboots before those relays are restored.',
        );
      }
      if (utf8.encode(plan.passwordController.text).length >
          maxFrameSize - pubKeySize - 2) {
        throw StateError('${plan.contact.name} admin password is too long.');
      }
    }
    // Resolve both dependency graphs before changing any radio. This catches
    // hash collisions, self-routes, and cycles while recovery is still on the
    // normal channel.
    _farthestFirst(temporary: false);
    _farthestFirst(temporary: true);
  }

  Future<void> _loginControlledHops() async {
    for (final plan in _farthestFirst(temporary: false)) {
      await _loginControlledHop(plan);
    }
  }

  Future<void> _loginControlledHop(_ControlledHopPlan plan) async {
    final contact = plan.contact;
    final selection = _pathSelection(plan.normalPath);
    await _connector.preparePathForContactSend(
      contact,
      explicitSelection: selection,
    );
    final loginFrame = buildSendLoginFrame(
      contact.publicKey,
      plan.passwordController.text,
    );
    final responseBytes = loginFrame.length > maxFrameSize
        ? loginFrame.length
        : maxFrameSize;
    final timeoutMs = _connector.calculateTimeout(
      pathLength: selection.hopCount,
      messageBytes: responseBytes,
    );

    final completer = Completer<bool>();
    late final StreamSubscription<Uint8List> subscription;
    subscription = _connector.receivedFrames.listen((frame) {
      if (frame.length < 8 ||
          (frame[0] != pushCodeLoginSuccess && frame[0] != pushCodeLoginFail)) {
        return;
      }
      for (var index = 0; index < 6; index++) {
        if (frame[index + 2] != contact.publicKey[index]) return;
      }
      if (!completer.isCompleted) {
        completer.complete(frame[0] == pushCodeLoginSuccess && frame[1] == 1);
      }
    });
    try {
      await _connector.sendFrame(loginFrame);
      final admin = await completer.future.timeout(
        Duration(milliseconds: timeoutMs + 2000),
      );
      if (!admin) {
        throw StateError('${contact.name} did not grant admin access.');
      }
      _addEvent('Admin login confirmed for ${contact.name}.');
      if (plan.savePassword) {
        await _storage.saveRepeaterPassword(
          contact.publicKeyHex,
          plan.passwordController.text,
        );
      }
    } finally {
      // This private listener no longer owns useful work once the login result
      // is known. Do not let a transport-specific cancellation future stall
      // the next dependency in a multi-hop handoff.
      unawaited(subscription.cancel());
    }
  }

  Future<void> _startSession() async {
    await _runBusy('Starting LoRa OTA', () async {
      final catalog = _catalog;
      if (catalog == null || catalog.files.isEmpty) {
        throw StateError('Choose and validate at least one .mota file first.');
      }
      if (!_connector.isBleMotaChannelReady) {
        throw StateError(
          _connector.bleMotaChannelError ??
              'Use a paired nRF52 Full Companion with protocol-v14 Bluetooth mOTA.',
        );
      }

      final tempRadio = _tempRadioCommand();
      _validateRoutePlan();
      await _loginControlledHops();
      catalog.resetTransferMetrics();
      _connector.setBleMotaCatalog(catalog);
      _switchedControlledKeys.clear();
      var targetMayBeTemporary = false;
      var localMayBeTemporary = false;
      try {
        _addEvent('Sending TempRadio to ${widget.repeater.name}.');
        // Arm recovery before the first byte can leave. If a local sent
        // notification or the remote reply is lost, the command may still
        // have reached the target and scheduled its handoff.
        targetMayBeTemporary = true;
        final targetOperation = _beginRemoteCommand(
          _currentRepeater(),
          tempRadio,
          _normalTargetSelection,
        );
        await _awaitRadioCommand(_currentRepeater(), targetOperation);
        _addEvent('Target TempRadio handoff confirmed.');

        for (final plan in _farthestFirst(temporary: false)) {
          // Treat every attempted controlled handoff as possibly applied so a
          // lost acknowledgement cannot remove that node from recovery.
          _switchedControlledKeys.add(plan.contact.publicKeyHex);
          final operation = _beginRemoteCommand(
            plan.contact,
            tempRadio,
            _pathSelection(plan.normalPath),
          );
          await _awaitRadioCommand(plan.contact, operation);
          _addEvent('${plan.contact.name} TempRadio handoff confirmed.');
        }

        // Every controlled remote is confirmed farthest-to-nearest before
        // the local timer starts. A nearer hop can therefore switch without
        // cutting off a command still destined for a node behind it.
        localMayBeTemporary = true;
        final localReply = await _connector.executeLocalOtaControl(tempRadio);
        _addEvent('Companion: $localReply');

        await Future<void>.delayed(const Duration(milliseconds: 2500));
        final status = await _connector.controlBleMotaSource(
          bleMotaActionStart,
        );
        if (!status.channelReady || !status.attached) {
          throw StateError(_sourceStatusText(status));
        }
        if (status.offered != catalog.files.length ||
            status.advertised != catalog.files.length) {
          throw StateError(
            'Companion accepted ${status.advertised}/${status.offered} files; '
            '${catalog.files.length} were selected.',
          );
        }
        if (!mounted) return;
        setState(() {
          _sourceStatus = status;
          _sessionActive = true;
          _resumeSourceAfterReconnect = false;
          _readyToInstall = false;
          _downloadPercent = null;
          _confirmedBlocks = null;
          _confirmedTotalBlocks = null;
          _selectedFile = null;
        });
        _addEvent(_sourceStatusText(status));
        _startLiveProgressTimer();

        try {
          final discovery = await _sendTargetCommand('ota ls');
          _addEvent('${widget.repeater.name}: $discovery');
        } catch (error) {
          _addEvent(
            'The source is running, but initial discovery failed: $error. '
            'Use Refresh updates to retry.',
          );
        }
      } catch (_) {
        if (targetMayBeTemporary ||
            localMayBeTemporary ||
            _switchedControlledKeys.isNotEmpty) {
          if (!localMayBeTemporary) {
            try {
              final reply = await _connector.executeLocalOtaControl(tempRadio);
              localMayBeTemporary = true;
              _addEvent('Companion recovery handoff: $reply');
              await Future<void>.delayed(const Duration(milliseconds: 2500));
            } catch (error) {
              _addEvent(
                'Could not join the temporary channel for cleanup: $error',
              );
            }
          }
          _addEvent(
            'Start failed; restoring controlled radios and detaching source.',
          );
          await _restoreSessionState(restoreTarget: targetMayBeTemporary);
        } else {
          _connector.setBleMotaCatalog(null);
        }
        rethrow;
      }
    });
  }

  Future<void> _refreshUpdates() async {
    await _runBusy('Refreshing updates', () async {
      _requireActiveSession();
      final first = await _sendTargetCommand('ota ls');
      _addEvent('${widget.repeater.name}: $first');
      await Future<void>.delayed(const Duration(seconds: 5));
      final second = await _sendTargetCommand('ota ls');
      _addEvent('${widget.repeater.name}: $second');
    });
  }

  Future<void> _pull(BleMotaFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Download ${file.manifestId}?'),
        content: Text(
          'The repeater will stage ${file.name} (${file.versionLabel}) in its '
          'OTA flash. This does not install it yet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Start download'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBusy('Starting download', () async {
      _requireActiveSession();
      final response = await _sendTargetCommand(
        'ota pull ${file.manifestId} flash',
      );
      _addEvent('${widget.repeater.name}: $response');
      if (response.toLowerCase().startsWith('err')) {
        throw StateError(response);
      }
      if (!mounted) return;
      setState(() {
        _readyToInstall = false;
        _downloadPercent = 0;
        _confirmedBlocks = 0;
        _confirmedTotalBlocks = file.blockCount;
        _selectedFile = file;
      });
      _startStatusTimer();
    });
  }

  Future<void> _checkStatus() async {
    await _runBusy('Checking download', _checkStatusBody);
  }

  Future<void> _checkStatusBody() async {
    _requireActiveSession();
    final response = await _sendTargetCommand('ota status');
    _addEvent('${widget.repeater.name}: $response');
    _applyDownloadStatus(response);
    await _refreshSourceStatusQuietly();
  }

  void _applyDownloadStatus(String response) {
    final blocksMatch = RegExp(
      r'(\d+)\/(\d+)(?:\s+\((\d{1,3})%\))?',
    ).firstMatch(response);
    final have = int.tryParse(blocksMatch?.group(1) ?? '');
    final total = int.tryParse(blocksMatch?.group(2) ?? '');
    final reportedPercent = int.tryParse(blocksMatch?.group(3) ?? '');
    final percent =
        reportedPercent ??
        (have != null && total != null && total > 0
            ? (have * 100 ~/ total)
            : null);
    final lower = response.toLowerCase();
    final ready = lower.contains('ready to install');
    if (!mounted) return;
    setState(() {
      if (percent != null) _downloadPercent = percent.clamp(0, 100);
      if (have != null) _confirmedBlocks = have;
      if (total != null && total > 0) _confirmedTotalBlocks = total;
      _readyToInstall = ready;
    });
    if (ready || lower.contains('download: failed')) {
      _statusTimer?.cancel();
      _statusTimer = null;
    }
  }

  void _startStatusTimer() {
    _statusTimer?.cancel();
    if (!_autoCheck) return;
    _statusTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_busy && _sessionActive && mounted) {
        unawaited(_runBusy('Checking download', _checkStatusBody, quiet: true));
      }
    });
  }

  void _startLiveProgressTimer() {
    _liveProgressTimer?.cancel();
    var ticks = 0;
    _liveProgressTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || !_sessionActive) return;
      setState(() {});
      ticks++;
      if (ticks % 3 == 0 && !_busy) {
        unawaited(_refreshSourceStatusQuietly());
      }
    });
  }

  bool _sourceStatusPollActive = false;
  Future<void> _refreshSourceStatusQuietly() async {
    if (_sourceStatusPollActive || !_sessionActive) return;
    _sourceStatusPollActive = true;
    try {
      final status = await _connector.controlBleMotaSource(bleMotaActionStatus);
      if (mounted) setState(() => _sourceStatus = status);
      if (_sessionActive && !status.attached && !_restoringSession) {
        _resumeSourceAfterReconnect = true;
        _scheduleBleSourceResume();
      }
    } catch (_) {
      // The next scheduled poll or explicit status action retries.
    } finally {
      _sourceStatusPollActive = false;
    }
  }

  Future<void> _install() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Install staged firmware?'),
        content: Text(
          '${widget.repeater.name} will verify the package, approve it, and '
          'reboot. Do not remove power during the bootloader update.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Install and reboot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBusy('Installing firmware', () async {
      _requireActiveSession();
      if (!_readyToInstall) {
        throw StateError('The download is not reported ready to install.');
      }
      final operation = _beginRemoteCommand(
        _currentRepeater(),
        'ota install',
        _temporaryTargetSelection,
      );
      await operation.dispatched.timeout(const Duration(seconds: 30));
      _addEvent('Install command left the Companion.');
      try {
        final response = await operation.response.timeout(
          const Duration(seconds: 20),
        );
        _addEvent('${widget.repeater.name}: $response');
        if (response.toLowerCase().startsWith('err')) {
          throw StateError(response);
        }
      } on StateError {
        rethrow;
      } catch (error) {
        _addEvent(
          'The repeater stopped replying ($error), which is expected during reboot.',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      await _restoreSessionState(restoreTarget: false);
    });
  }

  Future<void> _stopAndRestore({bool restoreTarget = true}) async {
    await _runBusy('Stopping LoRa OTA', () async {
      await _restoreSessionState(restoreTarget: restoreTarget);
    });
  }

  Future<void> _restoreSessionState({required bool restoreTarget}) async {
    if (_restoringSession) return;
    _restoringSession = true;
    _resumeSourceAfterReconnect = false;
    _bleSourceResumeTimer?.cancel();
    try {
      await _restoreSessionStateBody(restoreTarget: restoreTarget);
    } finally {
      _restoringSession = false;
    }
  }

  Future<void> _restoreSessionStateBody({required bool restoreTarget}) async {
    _statusTimer?.cancel();
    _statusTimer = null;
    _liveProgressTimer?.cancel();
    _liveProgressTimer = null;
    final pollDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (_sourceStatusPollActive && DateTime.now().isBefore(pollDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    try {
      final status = await _connector.controlBleMotaSource(bleMotaActionStop);
      _addEvent(_sourceStatusText(status));
      if (mounted) setState(() => _sourceStatus = status);
    } catch (error) {
      _addEvent('Could not detach source cleanly: $error');
    }

    if (restoreTarget) {
      final operation = _beginRemoteCommand(
        _currentRepeater(),
        'normalradio',
        _temporaryTargetSelection,
      );
      try {
        await _awaitRadioCommand(_currentRepeater(), operation);
        _addEvent('Target normal-radio restore confirmed.');
      } catch (error) {
        _addEvent('Could not send target normal-radio command: $error');
      }
    }

    for (final plan in _farthestFirst(temporary: true)) {
      if (!_switchedControlledKeys.contains(plan.contact.publicKeyHex)) {
        continue;
      }
      final operation = _beginRemoteCommand(
        plan.contact,
        'normalradio',
        _pathSelection(plan.temporaryPath),
      );
      try {
        await _awaitRadioCommand(plan.contact, operation);
        _addEvent('${plan.contact.name} normal-radio restore confirmed.');
      } catch (error) {
        _addEvent('Could not restore ${plan.contact.name}: $error');
      }
    }

    try {
      final local = await _connector.executeLocalOtaControl('normalradio');
      _addEvent('Companion: $local');
    } catch (error) {
      _addEvent('Could not restore Companion radio: $error');
    }

    // Put the Companion's contact table back on the normal-route paths after
    // all temporary-channel commands have been confirmed or exhausted.
    try {
      await _connector.preparePathForContactSend(
        _currentRepeater(),
        explicitSelection: _normalTargetSelection,
      );
      for (final plan in _controlledHops) {
        await _connector.preparePathForContactSend(
          plan.contact,
          explicitSelection: _pathSelection(plan.normalPath),
        );
      }
    } catch (error) {
      _addEvent('Could not restore cached normal routes: $error');
    }

    _switchedControlledKeys.clear();
    _connector.setBleMotaCatalog(null);
    if (mounted) {
      setState(() {
        _sessionActive = false;
        _resumeSourceAfterReconnect = false;
        _readyToInstall = false;
        _downloadPercent = null;
      });
    }
  }

  Future<void> _readSourceStatus() async {
    await _runBusy('Reading source status', () async {
      final status = await _connector.controlBleMotaSource(bleMotaActionStatus);
      if (!mounted) return;
      setState(() {
        _sourceStatus = status;
        _sessionActive = status.attached;
      });
      if (status.attached) _startLiveProgressTimer();
      _addEvent(_sourceStatusText(status));
    });
  }

  Future<void> _runBusy(
    String label,
    Future<void> Function() operation, {
    bool quiet = false,
  }) async {
    if (_busy) return;
    if (mounted) setState(() => _busy = true);
    try {
      final pollDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (_sourceStatusPollActive && DateTime.now().isBefore(pollDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      if (_sourceStatusPollActive) {
        throw StateError('A Companion source-status request is still pending.');
      }
      await operation();
    } catch (error) {
      _addEvent('$label failed: $error');
      if (!quiet) _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _requireActiveSession() {
    if (!_sessionActive) {
      throw StateError('Start the Bluetooth LoRa OTA source first.');
    }
  }

  void _addEvent(String message) {
    if (!mounted) return;
    final timestamp = TimeOfDay.now().format(context);
    setState(() {
      _events.add('$timestamp  $message');
      if (_events.length > 100) _events.removeAt(0);
    });
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  String _sourceStatusText(BleMotaSourceStatus status) {
    final states = <String>[
      status.channelReady ? 'channel ready' : 'channel unavailable',
      status.attached ? 'source attached' : 'source detached',
    ];
    if (status.anotherLinkActive) states.add('another source owns the slot');
    final packets = status.packetsSent == null
        ? ''
        : '; ${status.packetsSent} LoRa packet(s) sent';
    return '${states.join(', ')}; advertising '
        '${status.advertised}/${status.offered} file(s)$packets';
  }

  Future<void> _leaveActiveSession() async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop the LoRa OTA session?'),
        content: const Text(
          'The phone must keep serving firmware while the repeater downloads. '
          'Leaving now will detach the catalog and restore every controlled '
          'radio.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep serving'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Stop and leave'),
          ),
        ],
      ),
    );
    if (stop != true || !mounted) return;
    await _stopAndRestore();
    if (mounted && !_sessionActive) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final catalog = _catalog;
    final channelReady = connector.isBleMotaChannelReady;
    final sourceLabel = _sourceStatus == null
        ? 'Not checked'
        : _sourceStatusText(_sourceStatus!);
    final transferFile = _selectedFile;
    final sentBlocks = transferFile?.payloadBlocksServed ?? 0;
    final sentTotal = transferFile?.blockCount ?? 0;
    final confirmedBlocks = _confirmedBlocks ?? 0;
    final confirmedTotal = _confirmedTotalBlocks ?? sentTotal;

    return PopScope(
      canPop: !_sessionActive && !_busy,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _sessionActive && !_busy) {
          unawaited(_leaveActiveSession());
        } else if (!didPop && _busy) {
          _showError(
            StateError('Wait for the current LoRa OTA operation to finish.'),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('LoRa OTA'),
          centerTitle: true,
          leading: _sessionActive
              ? IconButton(
                  onPressed: _busy ? null : _leaveActiveSession,
                  tooltip: 'Stop session and go back',
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              SectionHeader('Connection'),
              MeshCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusRow(
                      label: 'Companion transport',
                      value:
                          connector.activeTransport ==
                              MeshCoreTransportType.bluetooth
                          ? 'Bluetooth'
                          : connector.activeTransport.name.toUpperCase(),
                      good:
                          connector.activeTransport ==
                          MeshCoreTransportType.bluetooth,
                    ),
                    const SizedBox(height: 8),
                    _StatusRow(
                      label: 'Encrypted mOTA channel',
                      value: channelReady
                          ? 'Ready'
                          : connector.bleMotaChannelError ?? 'Not available',
                      good: channelReady,
                    ),
                    const SizedBox(height: 8),
                    _StatusRow(
                      label: 'Remote repeater',
                      value: widget.repeater.name,
                      good: connector.isConnected,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Keep this app in the foreground for the entire download. '
                      'The route plan below can switch relays you administer; '
                      'owner-prepared passive relays stay on their existing '
                      'temporary radio.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              SectionHeader('Firmware catalog'),
              MeshCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy || _sessionActive ? null : _pickFirmware,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose .mota files'),
                    ),
                    if (_validationStatus != null) ...[
                      const SizedBox(height: 8),
                      Text(_validationStatus!),
                    ],
                    if (catalog != null) ...[
                      const SizedBox(height: 12),
                      ...catalog.files.map(_buildFirmwareTile),
                    ],
                  ],
                ),
              ),
              SectionHeader('Route plan'),
              MeshCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Normal paths carry setup commands before the handoff. '
                      'Temporary paths carry OTA and recovery commands after '
                      'the handoff, so the two paths may be different.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    _buildRouteRow(
                      title: 'Target normal control path',
                      path: _normalTargetPath,
                      onEdit: () => _editTargetPath(temporary: false),
                    ),
                    const Divider(),
                    _buildRouteRow(
                      title: 'Target temporary OTA path',
                      path: _temporaryTargetPath,
                      onEdit: () => _editTargetPath(temporary: true),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Controlled intermediate repeaters',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Add only nodes whose admin password you have. Passive '
                      'hops need no entry here; include their hashes in the '
                      'temporary paths that traverse them.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_controlledHops.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ..._controlledHops.map(_buildControlledHopCard),
                    ],
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy || _sessionActive
                          ? null
                          : _addControlledHop,
                      icon: const Icon(Icons.add),
                      label: const Text('Add controlled intermediate'),
                    ),
                  ],
                ),
              ),
              SectionHeader('Temporary radio'),
              MeshCard(
                child: Column(
                  children: [
                    TextField(
                      controller: _frequencyController,
                      enabled: !_sessionActive && !_busy,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Frequency (MHz)',
                        helperText: 'Use a legal frequency for your region.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<double>(
                      initialValue: _bandwidth,
                      decoration: const InputDecoration(
                        labelText: 'Bandwidth (kHz)',
                      ),
                      items: _bandwidths
                          .map(
                            (value) => DropdownMenuItem<double>(
                              value: value,
                              child: Text(_numberText(value)),
                            ),
                          )
                          .toList(),
                      onChanged: _sessionActive || _busy
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _bandwidth = value);
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: _spreadingFactor,
                            decoration: const InputDecoration(labelText: 'SF'),
                            items: <int>[5, 6, 7, 8, 9, 10, 11, 12]
                                .map(
                                  (value) => DropdownMenuItem<int>(
                                    value: value,
                                    child: Text('$value'),
                                  ),
                                )
                                .toList(),
                            onChanged: _sessionActive || _busy
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() => _spreadingFactor = value);
                                    }
                                  },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: _codingRate,
                            decoration: const InputDecoration(labelText: 'CR'),
                            items: <int>[5, 6, 7, 8]
                                .map(
                                  (value) => DropdownMenuItem<int>(
                                    value: value,
                                    child: Text('$value'),
                                  ),
                                )
                                .toList(),
                            onChanged: _sessionActive || _busy
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() => _codingRate = value);
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _minutesController,
                      enabled: !_sessionActive && !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Duration (minutes)',
                      ),
                    ),
                  ],
                ),
              ),
              SectionHeader('OTA session'),
              MeshCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(sourceLabel),
                    if (transferFile != null) ...[
                      const SizedBox(height: 12),
                      _TransferProgress(
                        label: 'Sent / queued by source',
                        value: sentTotal == 0 ? 0 : sentBlocks / sentTotal,
                        detail: '$sentBlocks / $sentTotal blocks',
                      ),
                      const SizedBox(height: 12),
                      _TransferProgress(
                        label: 'Confirmed by target',
                        value: confirmedTotal == 0
                            ? 0
                            : confirmedBlocks / confirmedTotal,
                        detail:
                            '$confirmedBlocks / $confirmedTotal verified blocks',
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text(
                            _sourceStatus?.packetsSent == null
                                ? 'LoRa packets: unavailable on legacy Companion firmware'
                                : 'LoRa source packets: ${_sourceStatus!.packetsSent}',
                          ),
                          Text(
                            'Phone source reads: ${transferFile.readRequests} '
                            '(${_formatBytes(transferFile.bytesServed)})',
                          ),
                          if (transferFile.payloadBytesPerSecond != null)
                            Text(
                              '${_formatRate(transferFile.payloadBytesPerSecond!)} from phone',
                            ),
                        ],
                      ),
                    ],
                    if (_readyToInstall) ...[
                      const SizedBox(height: 8),
                      const StatusChip(
                        label: 'READY TO INSTALL',
                        color: MeshPalette.signal,
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (!_sessionActive)
                      FilledButton.icon(
                        onPressed: _busy || !channelReady || catalog == null
                            ? null
                            : _startSession,
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('Prepare radios and start source'),
                      )
                    else ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: _busy ? null : _refreshUpdates,
                            child: const Text('Refresh updates'),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : _checkStatus,
                            child: const Text('Check download'),
                          ),
                          FilledButton(
                            onPressed: _busy || !_readyToInstall
                                ? null
                                : _install,
                            child: const Text('Install and reboot'),
                          ),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Auto-check every 60 seconds'),
                        value: _autoCheck,
                        onChanged: _busy
                            ? null
                            : (value) {
                                setState(() => _autoCheck = value);
                                if (value && _downloadPercent != null) {
                                  _startStatusTimer();
                                } else {
                                  _statusTimer?.cancel();
                                  _statusTimer = null;
                                }
                              },
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _stopAndRestore,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Stop and restore controlled radios'),
                      ),
                    ],
                    TextButton(
                      onPressed: _busy ? null : _readSourceStatus,
                      child: const Text('Read source status'),
                    ),
                  ],
                ),
              ),
              if (_events.isNotEmpty) ...[
                SectionHeader('Session log'),
                MeshCard(
                  child: SelectableText(
                    _events.reversed.join('\n'),
                    style: MeshTheme.mono(fontSize: 11.5),
                  ),
                ),
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFirmwareTile(BleMotaFile file) {
    final subtitle = <String>[
      'MID ${file.manifestId}',
      'v${file.versionLabel}',
      file.hardwareId.isEmpty ? 'hardware unknown' : file.hardwareId,
      file.codecLabel,
      _formatBytes(file.size),
    ].join(' | ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(file.isBootloader ? Icons.memory : Icons.system_update),
      title: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle),
      trailing: _sessionActive
          ? FilledButton.tonal(
              onPressed: _busy ? null : () => _pull(file),
              child: const Text('Pull'),
            )
          : null,
    );
  }

  Widget _buildRouteRow({
    required String title,
    required Uint8List path,
    required VoidCallback onEdit,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(_routeLabel(path)),
      trailing: OutlinedButton(
        onPressed: _busy || _sessionActive ? null : onEdit,
        child: const Text('Edit'),
      ),
    );
  }

  Widget _buildControlledHopCard(_ControlledHopPlan plan) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.cell_tower, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    plan.contact.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: _busy || _sessionActive
                      ? null
                      : () => _removeControlledHop(plan),
                  tooltip: 'Remove controlled intermediate',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            TextField(
              controller: plan.passwordController,
              enabled: !_busy && !_sessionActive,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Admin password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Save password on this device'),
              value: plan.savePassword,
              onChanged: _busy || _sessionActive
                  ? null
                  : (value) {
                      setState(() => plan.savePassword = value ?? false);
                    },
            ),
            _buildRouteRow(
              title: 'Normal setup path',
              path: plan.normalPath,
              onEdit: () => _editControlledPath(plan, temporary: false),
            ),
            _buildRouteRow(
              title: 'Temporary restore path',
              path: plan.temporaryPath,
              onEdit: () => _editControlledPath(plan, temporary: true),
            ),
          ],
        ),
      ),
    );
  }

  String _routeLabel(Uint8List path) {
    if (path.isEmpty) return 'Direct (zero hops)';
    final width = _connector.pathHashByteWidth;
    if (width <= 0 || path.length % width != 0) {
      return 'Invalid for current path-hash width';
    }
    final hops = <String>[];
    for (var offset = 0; offset < path.length; offset += width) {
      hops.add(
        path
            .sublist(offset, offset + width)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase(),
      );
    }
    return '${hops.length} hop${hops.length == 1 ? '' : 's'}: '
        '${hops.join(' -> ')}';
  }
}

class _ControlledHopPlan {
  final Contact contact;
  final TextEditingController passwordController = TextEditingController();
  Uint8List normalPath;
  Uint8List temporaryPath;
  bool savePassword = false;

  _ControlledHopPlan({
    required this.contact,
    required this.normalPath,
    required this.temporaryPath,
  });

  void dispose() => passwordController.dispose();
}

class _TransferProgress extends StatelessWidget {
  final String label;
  final double value;
  final String detail;

  const _TransferProgress({
    required this.label,
    required this.value,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final safeValue = value.clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text('${(safeValue * 100).floor()}%'),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: safeValue),
        const SizedBox(height: 3),
        Text(detail, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final bool good;

  const _StatusRow({
    required this.label,
    required this.value,
    required this.good,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          good ? Icons.check_circle : Icons.info_outline,
          size: 18,
          color: good ? MeshPalette.signal : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(text: value),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _numberText(double value) {
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

String _formatRate(double bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${bytesPerSecond.toStringAsFixed(0)} B/s';
}
