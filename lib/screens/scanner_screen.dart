import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/platform_info.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../services/linux_ble_error_classifier.dart';
import '../services/nrf_dfu_recovery_store.dart';
import '../theme/mesh_theme.dart';
import '../services/notification_service.dart';
import '../utils/app_logger.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/device_tile.dart';
import '../widgets/empty_state.dart';
import '../widgets/mesh_ui.dart';
import '../helpers/snack_bar_builder.dart';
import 'channels_screen.dart';
import 'tcp_screen.dart';
import 'usb_screen.dart';
import 'packet_tools_screen.dart';
import 'companion_update_screen.dart';

/// Screen for scanning and connecting to MeshCore devices
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, this.recoveryStore, this.recoveryBuilder});

  final NrfDfuRecoveryStore? recoveryStore;
  final WidgetBuilder? recoveryBuilder;

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  bool _changedNavigation = false;
  String? _connectingDeviceId;
  late final MeshCoreConnector _connector;
  late final VoidCallback _connectionListener;
  BluetoothAdapterState _bluetoothState = BluetoothAdapterState.unknown;
  late StreamSubscription<BluetoothAdapterState> _bluetoothStateSubscription;
  late final NrfDfuRecoveryStore _recoveryStore;
  late final bool _recoverySupported;
  bool _recoveryOpen = false;
  bool _recoveryAvailable = false;
  bool _checkingRecovery = false;

  @override
  void initState() {
    super.initState();
    _connector = Provider.of<MeshCoreConnector>(context, listen: false);
    _recoveryStore = widget.recoveryStore ?? NrfDfuRecoveryStore();
    _recoverySupported = PlatformInfo.isAndroid || widget.recoveryStore != null;
    _checkingRecovery = _recoverySupported;

    _connectionListener = () {
      final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
      if (_connector.state == MeshCoreConnectionState.disconnected) {
        _changedNavigation = false;
      } else if (_connector.state == MeshCoreConnectionState.connected &&
          _connector.activeTransport == MeshCoreTransportType.bluetooth &&
          isCurrentRoute &&
          !_recoveryOpen &&
          !_checkingRecovery &&
          !_changedNavigation) {
        _changedNavigation = true;
        // Prompt for notification permission on first
        // connect so notifications work out of the box
        // on Android 13+.
        NotificationService().requestPermissions();
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const ChannelsScreen()),
          );
        }
      }
    };

    _connector.addListener(_connectionListener);

    // If the app was killed (swipe-away) and relaunched, try to reconnect
    // to the last known device so the user doesn't have to scan again.
    if (_recoverySupported) {
      unawaited(_refreshRecovery(tryAutoReconnect: true));
    } else if (_connector.state == MeshCoreConnectionState.disconnected) {
      unawaited(_tryReconnect());
    }

    _bluetoothStateSubscription = FlutterBluePlus.adapterState.listen(
      (state) {
        if (mounted) {
          setState(() {
            _bluetoothState = state;
          });
          // Cancel scan if Bluetooth turns off while scanning
          if (state != BluetoothAdapterState.on) {
            unawaited(_connector.stopScan());
          }
        }
      },
      onError: (Object e) {
        appLogger.warn('Adapter state stream error: $e', tag: 'ScannerScreen');
      },
    );
  }

  Future<void> _tryReconnect() async {
    try {
      await _connector.tryAutoReconnect();
    } catch (_) {
      appLogger.warn(
        'Automatic reconnect did not finish.',
        tag: 'ScannerScreen',
        noNotify: true,
      );
    }
  }

  Future<void> _refreshRecovery({bool tryAutoReconnect = false}) async {
    if (!_recoverySupported) return;
    try {
      final nativePending = await _recoveryStore.hasUnconfirmedNativeTransfer();
      final record = await _recoveryStore.load();
      if (!mounted) return;
      setState(() {
        _recoveryAvailable = nativePending || record != null;
        _checkingRecovery = false;
      });
      if (tryAutoReconnect &&
          !_recoveryAvailable &&
          !_recoveryOpen &&
          _connector.state == MeshCoreConnectionState.disconnected) {
        await _tryReconnect();
      }
    } catch (_) {
      // No arbitrary filesystem errors/paths are exported, and an unavailable
      // durable lifetime guard is not permission to auto-connect a DFU radio.
      appLogger.warn(
        'Bluetooth recovery availability could not be checked.',
        tag: 'ScannerScreen',
        noNotify: true,
      );
      if (mounted) setState(() => _checkingRecovery = false);
    }
  }

  Future<void> _openRecovery() async {
    if (_recoveryOpen || !_recoveryAvailable) return;
    final previousPreserve = _connector.preserveUpdateScreenOnDisconnect;
    setState(() => _recoveryOpen = true);
    _connector.setPreserveUpdateScreenOnDisconnect(true);
    try {
      await _connector.stopScan();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder:
              widget.recoveryBuilder ??
              (_) => CompanionUpdateScreen(recoveryStore: _recoveryStore),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open Bluetooth recovery. No firmware was sent.',
            ),
          ),
        );
      }
    } finally {
      _connector.setPreserveUpdateScreenOnDisconnect(previousPreserve);
      if (mounted) {
        setState(() => _recoveryOpen = false);
        await _refreshRecovery();
      }
    }
  }

  @override
  void dispose() {
    _connector.removeListener(_connectionListener);
    unawaited(_bluetoothStateSubscription.cancel());
    if (!_changedNavigation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_connector.disconnect(manual: true));
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        leading: canPop
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  appLogger.info('Back button pressed', tag: 'ScannerScreen');
                  Navigator.of(context).maybePop();
                },
              )
            : null,
        title: AdaptiveAppBarTitle(context.l10n.scanner_title),
        centerTitle: true,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.analytics_outlined),
            tooltip: 'Packet tools',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const PacketToolsScreen(),
              ),
            ),
          ),
          if (PlatformInfo.supportsUsbSerial)
            IconButton(
              icon: const Icon(Icons.usb),
              tooltip: context.l10n.connectionChoiceUsbLabel,
              onPressed: () {
                appLogger.info(
                  'USB selected, opening UsbScreen',
                  tag: 'ScannerScreen',
                );
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const UsbScreen()));
              },
            ),
          if (!PlatformInfo.isWeb)
            IconButton(
              icon: const Icon(Icons.lan),
              tooltip: context.l10n.connectionChoiceTcpLabel,
              onPressed: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const TcpScreen()));
              },
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Consumer<MeshCoreConnector>(
          builder: (context, connector, child) {
            return Column(
              children: [
                // Bluetooth off warning — slides in/out with AnimatedSize
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: _bluetoothState == BluetoothAdapterState.off
                      ? _BluetoothOffBanner(
                          onEnable: PlatformInfo.isAndroid
                              ? () => FlutterBluePlus.turnOn()
                              : null,
                        )
                      : const SizedBox.shrink(),
                ),

                // Connection status header
                _ConnectionStatusHeader(connector: connector),

                if (_recoveryAvailable)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: OutlinedButton.icon(
                      key: const ValueKey('scanner_dfu_recovery'),
                      onPressed: _recoveryOpen ? null : _openRecovery,
                      icon: const Icon(Icons.settings_backup_restore, size: 20),
                      label: const Text('Recover Bluetooth update'),
                    ),
                  ),

                // Device list
                Expanded(child: _buildDeviceList(context, connector)),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: Consumer<MeshCoreConnector>(
        builder: (context, connector, child) {
          final isScanning =
              connector.state == MeshCoreConnectionState.scanning;
          final isBluetoothOff = _bluetoothState == BluetoothAdapterState.off;
          final isConnecting =
              connector.state == MeshCoreConnectionState.connecting;
          final isDisconnecting =
              connector.state == MeshCoreConnectionState.disconnecting;

          return SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FilledButton.icon(
              key: const ValueKey('scanner_scan_action'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
              ),
              onPressed: isBluetoothOff || isConnecting || isDisconnecting
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      _toggleScan(connector);
                    },
              icon: Icon(isScanning ? Icons.stop : Icons.bluetooth_searching),
              label: Text(
                isConnecting
                    ? context.l10n.scanner_connecting
                    : isDisconnecting
                    ? context.l10n.scanner_disconnecting
                    : isScanning
                    ? context.l10n.scanner_stop
                    : context.l10n.scanner_scan,
              ),
            ),
          );
        },
      ),
    );
  }

  void _toggleScan(MeshCoreConnector connector) {
    if (PlatformInfo.isWeb) {
      // flutter_blue_plus has no web backend, so a BLE scan silently no-ops in
      // the browser. Tell the user instead of leaving them staring at a button.
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.scanner_bluetoothWebUnsupported),
      );
      return;
    }
    if (connector.state == MeshCoreConnectionState.scanning) {
      connector.stopScan();
    } else {
      unawaited(
        connector.startScan().catchError((e) {
          appLogger.warn('startScan error: $e', tag: 'ScannerScreen');
          if (mounted) {
            showDismissibleSnackBar(context, content: Text('$e'));
          }
        }),
      );
    }
  }

  Widget _buildDeviceList(BuildContext context, MeshCoreConnector connector) {
    if (connector.scanResults.isEmpty) {
      final isBluetoothOff = _bluetoothState == BluetoothAdapterState.off;
      final isScanning = connector.state == MeshCoreConnectionState.scanning;
      return EmptyState(
        icon: isBluetoothOff ? Icons.bluetooth_disabled : Icons.bluetooth,
        title: isBluetoothOff
            ? context.l10n.scanner_bluetoothOff
            : isScanning
            ? context.l10n.scanner_searchingDevices
            : context.l10n.scanner_tapToScan,
        subtitle: isBluetoothOff
            ? context.l10n.scanner_bluetoothOffMessage
            : null,
      );
    }

    final isConnecting = connector.state == MeshCoreConnectionState.connecting;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: connector.scanResults.length,
      itemBuilder: (context, index) {
        final result = connector.scanResults[index];
        final deviceId = result.device.remoteId.toString();
        return ListEntrance(
          index: index,
          child: DeviceTile(
            scanResult: result,
            isConnecting: isConnecting && _connectingDeviceId == deviceId,
            onTap: isConnecting
                ? null
                : () => _connectToDevice(context, connector, result),
          ),
        );
      },
    );
  }

  Future<void> _connectToDevice(
    BuildContext context,
    MeshCoreConnector connector,
    ScanResult result,
  ) async {
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;
    setState(() {
      _connectingDeviceId = result.device.remoteId.toString();
    });
    try {
      await connector.connect(
        result.device,
        displayName: name,
        linuxPairingPinProvider: PlatformInfo.isLinux
            ? () async {
                if (!context.mounted) return null;
                return _promptLinuxPairingPin(context, name);
              }
            : null,
      );
    } catch (e) {
      final errorText = e.toString();
      final suppressTransientLinuxConnectError =
          PlatformInfo.isLinux &&
          connector.isAutoReconnectScheduled &&
          isLinuxBleConnectFailureText(errorText);
      if (suppressTransientLinuxConnectError) {
        appLogger.info(
          'Suppressing transient Linux connect error while auto-reconnect is active: $e',
          tag: 'ScannerScreen',
        );
        return;
      }
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.scanner_connectionFailed(e.toString())),
          backgroundColor: Theme.of(context).colorScheme.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceId = null;
        });
      }
    }
  }

  Future<String?> _promptLinuxPairingPin(
    BuildContext context,
    String deviceName,
  ) async {
    final l10n = context.l10n;
    var pinValue = '';
    var obscure = true;
    appLogger.info(
      'Showing Linux BLE pairing PIN prompt for $deviceName',
      tag: 'ScannerScreen',
    );
    final pin = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(l10n.scanner_linuxPairingPinTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.scanner_linuxPairingPinPrompt(deviceName)),
                    const SizedBox(height: 12),
                    TextField(
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      obscureText: obscure,
                      enableSuggestions: false,
                      autocorrect: false,
                      onChanged: (value) {
                        pinValue = value.trim();
                      },
                      onSubmitted: (value) {
                        Navigator.of(dialogContext).pop(value.trim());
                      },
                      decoration: InputDecoration(
                        suffixIcon: IconButton(
                          onPressed: () {
                            setDialogState(() {
                              obscure = !obscure;
                            });
                          },
                          icon: Icon(
                            obscure ? Icons.visibility : Icons.visibility_off,
                          ),
                          tooltip: obscure
                              ? l10n.scanner_linuxPairingShowPin
                              : l10n.scanner_linuxPairingHidePin,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(null),
                  child: Text(l10n.common_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(pinValue),
                  child: Text(l10n.common_connect),
                ),
              ],
            );
          },
        );
      },
    );
    if (pin == null) {
      appLogger.info(
        'Linux BLE pairing PIN prompt cancelled for $deviceName',
        tag: 'ScannerScreen',
      );
      return null;
    }
    appLogger.info(
      'Linux BLE pairing PIN prompt completed for $deviceName',
      tag: 'ScannerScreen',
    );
    return pin;
  }
}

// ── Private sub-widgets ────────────────────────────────────────────────────

/// Bluetooth-off warning banner — styled as an alert MeshCard.
class _BluetoothOffBanner extends StatelessWidget {
  final VoidCallback? onEnable;

  const _BluetoothOffBanner({this.onEnable});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MeshCard(
      color: scheme.error.withValues(alpha: 0.08),
      borderColor: scheme.error.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled, size: 20, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.scanner_bluetoothOff,
                  style: TextStyle(
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.l10n.scanner_bluetoothOffMessage,
                  style: TextStyle(
                    color: scheme.error.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
                if (onEnable != null)
                  TextButton(
                    onPressed: onEnable,
                    child: Text(context.l10n.scanner_enableBluetooth),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Connection status header with AnimatedSwitcher between states.
class _ConnectionStatusHeader extends StatelessWidget {
  final MeshCoreConnector connector;

  const _ConnectionStatusHeader({required this.connector});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;

    final (String label, Color color, bool pulse) = switch (connector.state) {
      MeshCoreConnectionState.scanning => (
        l10n.scanner_scanning,
        MeshPalette.blue,
        true,
      ),
      MeshCoreConnectionState.connecting => (
        l10n.scanner_connecting,
        MeshPalette.warn,
        true,
      ),
      MeshCoreConnectionState.connected => (
        l10n.scanner_connectedTo(connector.deviceDisplayName),
        MeshPalette.signal,
        false,
      ),
      MeshCoreConnectionState.disconnecting => (
        l10n.scanner_disconnecting,
        MeshPalette.warn,
        true,
      ),
      MeshCoreConnectionState.disconnected => (
        l10n.scanner_notConnected,
        scheme.onSurfaceVariant,
        false,
      ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Align(
          key: ValueKey(connector.state),
          alignment: Alignment.centerLeft,
          child: StatusChip(label: label, color: color, pulse: pulse),
        ),
      ),
    );
  }
}
