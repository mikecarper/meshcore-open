import '../connector/meshcore_connector.dart';
import '../models/contact.dart';
import 'firmware_controls.dart';

List<Contact> loggedInFilterRepeaters(MeshCoreConnector connector) =>
    connector.isConnected
    ? connector.repeaterAdminSessions.repeaters(
        connector.contacts,
        connector.selfPublicKeyHex,
      )
    : [];

class RepeaterFilterCheck {
  const RepeaterFilterCheck(this.target, this.ready, this.message);
  final Contact target;
  final bool ready;
  final String message;
}

class RepeaterFilterResult {
  const RepeaterFilterResult(this.target, this.applied, this.message);
  final Contact target;
  final bool applied;
  final String message;
}

/// Runs one insert per selected node, sequentially, with no automatic retries.
/// A lost reply is explicitly unconfirmed, not evidence of a failed write.
class RepeaterFilterBatch {
  RepeaterFilterBatch(this.connector)
    : _identity = connector.selfPublicKeyHex,
      _generation = connector.repeaterAdminSessions.generation;
  final MeshCoreConnector connector;
  final String _identity;
  final int _generation;
  bool _stopped = false;
  final Map<String, RepeaterFilterCheck> _checked = {};
  FirmwareControlEndpoint? _active;

  void stopAfterCurrent() => _stopped = true;

  Contact _resolve(Contact selected) {
    if (_stopped) throw StateError('Stopped before writing.');
    if (!connector.isConnected ||
        connector.selfPublicKeyHex != _identity ||
        connector.repeaterAdminSessions.generation != _generation) {
      throw StateError('Companion changed or disconnected. Check again.');
    }
    final matches = loggedInFilterRepeaters(
      connector,
    ).where((c) => c.publicKeyHex == selected.publicKeyHex);
    if (matches.length != 1) {
      throw StateError('Admin login is no longer available. Log in again.');
    }
    return matches.single;
  }

  Future<RepeaterFilterCheck> check(Contact selected) async {
    _checked.remove(selected.publicKeyHex);
    FirmwareControlEndpoint? endpoint;
    try {
      final current = _resolve(selected);
      endpoint = _active = FirmwareControlEndpoint(connector, target: current);
      final summary = await endpoint.read('get fr');
      final slot = RegExp(r'\b(\d+)=').firstMatch(summary)?[1];
      if (slot == null) {
        throw const FormatException(
          'No saved compact row to confirm FPF7 support. Inspect this node first.',
        );
      }
      final row = ForwardingRule.parse(await endpoint.read('get fr.$slot'));
      row.command(remote: true);
      _resolve(selected);
      final check = RepeaterFilterCheck(
        selected,
        true,
        'Ready - compact filters supported',
      );
      _checked[selected.publicKeyHex] = check;
      return check;
    } catch (error) {
      return RepeaterFilterCheck(selected, false, error.toString());
    } finally {
      endpoint?.dispose();
      _active = null;
    }
  }

  Future<List<RepeaterFilterResult>> apply(
    List<RepeaterFilterCheck> checks,
    String command, {
    void Function(Contact target)? onSending,
    void Function(RepeaterFilterResult result)? onResult,
  }) async {
    final match = RegExp(r'^set fr (.+)$').firstMatch(command);
    if (match == null) {
      throw const FormatException(
        'Bulk filters must add a rule, not replace a slot.',
      );
    }
    final rule = ForwardingRule.parse('set fr.1 ${match[1]}')..slot = null;
    final insert = rule.command(remote: true);
    if (checks.isEmpty ||
        checks.any(
          (check) =>
              !check.ready ||
              !identical(_checked[check.target.publicKeyHex], check),
        )) {
      throw StateError('Check every selected repeater before applying.');
    }
    if (checks.map((c) => c.target.publicKeyHex).toSet().length !=
        checks.length) {
      throw StateError('A repeater was selected more than once.');
    }
    final results = <RepeaterFilterResult>[];
    // A completed or unconfirmed attempt always needs a fresh preflight.
    _checked.clear();
    for (final check in checks) {
      FirmwareControlEndpoint? endpoint;
      RepeaterFilterResult result;
      var started = false;
      try {
        final current = _resolve(check.target);
        onSending?.call(current);
        endpoint = _active = FirmwareControlEndpoint(
          connector,
          target: current,
        );
        await endpoint.apply(
          [insert],
          guard: () {
            _resolve(check.target);
            started = true;
          },
        );
        result = RepeaterFilterResult(
          check.target,
          true,
          'Applied - node acknowledged',
        );
      } catch (error) {
        result = RepeaterFilterResult(
          check.target,
          false,
          started
              ? 'Not confirmed. It may have applied; inspect before retrying. $error'
              : 'Not sent. $error',
        );
      } finally {
        endpoint?.dispose();
        _active = null;
      }
      results.add(result);
      onResult?.call(result);
    }
    return results;
  }

  void dispose() {
    _stopped = true;
    _active?.dispose();
  }
}
