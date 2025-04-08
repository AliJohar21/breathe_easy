import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import '/flutter_flow/flutter_flow_icon_button.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'scanning_model.dart';
export 'scanning_model.dart';
import 'package:breathe_easy/csvConvertion.dart';

/// Singleton BLE service that manages scanning, connection, and data reception.
class BleService {
  static final BleService instance = BleService._internal();
  BleService._internal();

  final FlutterReactiveBle _ble = FlutterReactiveBle();

  // UUIDs (must match your Arduino code)
  final Uuid smartBandServiceUuid =
      Uuid.parse("12345678-1234-5678-1234-56789abcdef0");
  final Uuid sensorDataCharacteristicUuid =
      Uuid.parse("abcdefab-1234-5678-1234-56789abcdef0");
  final Uuid controlCharacteristicUuid = Uuid.parse(
      "abcdefab-1234-5678-1234-56789abcdef1"); // New control characteristic

  // Lists for discovered and connected devices.
  final List<DiscoveredDevice> discoveredDevices = [];
  final List<DiscoveredDevice> connectedDevices = [];

  // ValueNotifiers for UI updates.
  final ValueNotifier<List<DiscoveredDevice>> discoveredNotifier =
      ValueNotifier([]);
  final ValueNotifier<List<DiscoveredDevice>> connectedNotifier =
      ValueNotifier([]);
  final ValueNotifier<String> sensorDataNotifier = ValueNotifier("");

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  final Map<String, StreamSubscription> _connectionSubscriptions = {};
  StreamSubscription<List<int>>? _sensorDataSubscription;

  // CSV helper instance
  final CsvHelper csvHelper = CsvHelper();

  /// Start scanning for devices advertising the smart band service.
  void startScan() {
    if (_scanSubscription != null) return;
    discoveredDevices.clear();
    discoveredNotifier.value = [];
    _scanSubscription = _ble
        .scanForDevices(withServices: [smartBandServiceUuid]).listen((device) {
      if (!discoveredDevices.any((d) => d.id == device.id)) {
        discoveredDevices.add(device);
        discoveredNotifier.value = List.from(discoveredDevices);
        debugPrint("Discovered device: ${device.name} (${device.id})");
      }
    }, onError: (error) {
      debugPrint("Scan error: $error");
    });
  }

  /// Stop scanning.
  void stopScan() {
    _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  /// Connect to a device and subscribe to sensor data.
  void connectToDevice(DiscoveredDevice device) {
    final subscription =
        _ble.connectToDevice(id: device.id).listen((connectionState) {
      debugPrint(
          "Connection state for ${device.name}: ${connectionState.connectionState}");
      if (connectionState.connectionState == DeviceConnectionState.connected) {
        if (!connectedDevices.any((d) => d.id == device.id)) {
          connectedDevices.add(device);
          connectedNotifier.value = List.from(connectedDevices);
          final characteristic = QualifiedCharacteristic(
            serviceId: smartBandServiceUuid,
            characteristicId: sensorDataCharacteristicUuid,
            deviceId: device.id,
          );
          Future.delayed(const Duration(milliseconds: 1000), () {
            _ble.readCharacteristic(characteristic).then((data) {
              debugPrint("Initial read data: $data, length: ${data.length}");
              if (data.length >= 4) {
                final int sensorValue =
                    ByteData.sublistView(Uint8List.fromList(data))
                        .getUint32(0, Endian.little);
                sensorDataNotifier.value = sensorValue.toString();
                debugPrint("Initial sensor data read: $sensorValue");
              } else {
                debugPrint("Initial read: Data too short: $data");
              }
            }).catchError((error) {
              debugPrint("Error reading initial sensor data: $error");
            });
          });
          subscribeToSensorData(device);
        }
      } else if (connectionState.connectionState ==
          DeviceConnectionState.disconnected) {
        debugPrint("Device ${device.name} disconnected");
        connectedDevices.removeWhere((d) => d.id == device.id);
        connectedNotifier.value = List.from(connectedDevices);
        _sensorDataSubscription?.cancel();
        _sensorDataSubscription = null;
        _connectionSubscriptions.remove(device.id);
      }
    }, onError: (error) {
      debugPrint("Connection error for ${device.name}: $error");
    });
    _connectionSubscriptions[device.id] = subscription;
  }

  /// Subscribe to sensor data notifications from the connected device.
  void subscribeToSensorData(DiscoveredDevice device) {
    final characteristic = QualifiedCharacteristic(
      serviceId: smartBandServiceUuid,
      characteristicId: sensorDataCharacteristicUuid,
      deviceId: device.id,
    );
    _ble.subscribeToCharacteristic(characteristic).listen((data) async {
      debugPrint("Raw sensor data received: $data, length: ${data.length}");
      if (data.length >= 4) {
        try {
          final ByteData byteData =
              ByteData.sublistView(Uint8List.fromList(data));
          final floatValue = byteData.getFloat32(0, Endian.little);
          sensorDataNotifier.value = floatValue.toStringAsFixed(2);

          // Automatically log and, if necessary, save the sensor reading.
          await csvHelper.addRow(DateTime.now(), floatValue);

          debugPrint("Converted sensor data: $floatValue");
        } catch (e) {
          debugPrint("Error parsing float: $e");
        }
      } else {
        debugPrint("Received sensor data is too short: $data");
      }
    }, onError: (error) {
      debugPrint("Sensor data error: $error");
    });
  }

  /// Sends the start command (a value of 1) to the connected device.
  Future<void> sendStartCommand(DiscoveredDevice device) async {
    final characteristic = QualifiedCharacteristic(
      serviceId: smartBandServiceUuid,
      characteristicId: controlCharacteristicUuid,
      deviceId: device.id,
    );
    try {
      await _ble.writeCharacteristicWithoutResponse(characteristic, value: [1]);
      debugPrint("Sent start command to device ${device.name}");
    } catch (error) {
      debugPrint("Error sending start command: $error");
    }
  }

  /// Sends the stop command (a value of 0) to the connected device.
  Future<void> sendStopCommand(DiscoveredDevice device) async {
    final characteristic = QualifiedCharacteristic(
      serviceId: smartBandServiceUuid,
      characteristicId:
          controlCharacteristicUuid, // Must match Arduino's write characteristic
      deviceId: device.id,
    );

    try {
      await _ble.writeCharacteristicWithoutResponse(
        characteristic,
        value: [0], // Sending byte 0 (STOP command)
      );
      debugPrint("Sent stop command to device ${device.name}");
    } catch (error) {
      debugPrint("Error sending stop command: $error");
      rethrow; // Optional: propagate error to UI
    }
  }

  /// Disconnect a specific device.
  void disconnectDevice(DiscoveredDevice device) {
    _connectionSubscriptions[device.id]?.cancel();
    _connectionSubscriptions.remove(device.id);
    connectedDevices.removeWhere((d) => d.id == device.id);
    connectedNotifier.value = List.from(connectedDevices);
    _sensorDataSubscription?.cancel();
    _sensorDataSubscription = null;
  }

  /// Disconnect all connected devices.
  void disconnectAll() {
    for (var subscription in _connectionSubscriptions.values) {
      subscription.cancel();
    }
    _connectionSubscriptions.clear();
    connectedDevices.clear();
    connectedNotifier.value = List.from(connectedDevices);
    _sensorDataSubscription?.cancel();
    _sensorDataSubscription = null;
  }
}

class ScanningWidget extends StatefulWidget {
  const ScanningWidget({super.key});

  @override
  State<ScanningWidget> createState() => _ScanningWidgetState();
}

class _ScanningWidgetState extends State<ScanningWidget> {
  late ScanningModel _model;
  final scaffoldKey = GlobalKey<ScaffoldState>();

  final BleService _bleService = BleService.instance;
  CsvHelper csvHelper = CsvHelper(); // CSV helper instance

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => ScanningModel());
    _bleService.startScan();
  }

  @override
  void dispose() {
    _model.dispose();
    // Optionally stop scanning.
    // _bleService.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).secondaryBackground,
        appBar: AppBar(
          backgroundColor: FlutterFlowTheme.of(context).secondaryBackground,
          automaticallyImplyLeading: false,
          leading: FlutterFlowIconButton(
            borderColor: Colors.transparent,
            borderRadius: 30.0,
            borderWidth: 1.0,
            buttonSize: 60.0,
            icon: Icon(
              Icons.arrow_back_rounded,
              color: FlutterFlowTheme.of(context).primaryText,
              size: 30.0,
            ),
            onPressed: () async {
              context.pop();
            },
          ),
          title: Text(
            'Connect your Device',
            style: FlutterFlowTheme.of(context).headlineMedium.override(
                  fontFamily: 'Inter Tight',
                  color: FlutterFlowTheme.of(context).primaryText,
                  fontSize: 22.0,
                  letterSpacing: 0.0,
                ),
          ),
          actions: const [],
          centerTitle: false,
        ),
        body: SingleChildScrollView(
          child: Column(
            children: [
              // Top Section: Instructions
              SizedBox(
                width: MediaQuery.sizeOf(context).width,
                height: 170.0,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                      24.0, 24.0, 24.0, 24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connect to Devices',
                        style: FlutterFlowTheme.of(context)
                            .headlineLarge
                            .override(
                              fontFamily: 'Inter Tight',
                              color: FlutterFlowTheme.of(context).primaryText,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      Text(
                        'Turn on Bluetooth and scan the static QR code on your device to initiate a connection.',
                        style: FlutterFlowTheme.of(context).bodyMedium.override(
                              fontFamily: 'Inter',
                              color: FlutterFlowTheme.of(context).primaryText,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              // Connection Status Section
              Align(
                alignment: AlignmentDirectional.center,
                child: Material(
                  elevation: 2.0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16.0)),
                  child: Container(
                    width: MediaQuery.sizeOf(context).width * 0.9,
                    padding: const EdgeInsets.all(20.0),
                    decoration: BoxDecoration(
                      color: FlutterFlowTheme.of(context).primaryBackground,
                      borderRadius: BorderRadius.circular(16.0),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Connection Status',
                          style: FlutterFlowTheme.of(context)
                              .headlineSmall
                              .override(
                                fontFamily: 'Inter Tight',
                                color: FlutterFlowTheme.of(context).primaryText,
                              ),
                        ),
                        ValueListenableBuilder<List<DiscoveredDevice>>(
                          valueListenable: _bleService.connectedNotifier,
                          builder: (context, connectedDevices, child) {
                            if (connectedDevices.isEmpty) {
                              return const Text("No connected devices");
                            }
                            return Column(
                              children: connectedDevices.map((device) {
                                return ListTile(
                                  title: Text(device.name),
                                  subtitle: Text(device.id),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      _bleService.disconnectDevice(device);
                                    },
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Discovered Devices Section
              Align(
                alignment: AlignmentDirectional.center,
                child: Material(
                  elevation: 2.0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16.0)),
                  child: Container(
                    width: MediaQuery.sizeOf(context).width * 0.9,
                    padding: const EdgeInsets.all(20.0),
                    decoration: BoxDecoration(
                      color: FlutterFlowTheme.of(context).primaryBackground,
                      borderRadius: BorderRadius.circular(16.0),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Discovered Devices',
                          style: FlutterFlowTheme.of(context)
                              .headlineSmall
                              .override(
                                fontFamily: 'Inter Tight',
                                color: FlutterFlowTheme.of(context).primaryText,
                              ),
                        ),
                        ValueListenableBuilder<List<DiscoveredDevice>>(
                          valueListenable: _bleService.discoveredNotifier,
                          builder: (context, discoveredDevices, child) {
                            if (discoveredDevices.isEmpty) {
                              return const Text("No devices found");
                            }
                            return Column(
                              children: discoveredDevices.map((device) {
                                return ListTile(
                                  title: Text(device.name),
                                  subtitle: Text(device.id),
                                  onTap: () =>
                                      _bleService.connectToDevice(device),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Troubleshooting Tips Section
              Align(
                alignment: AlignmentDirectional.center,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 10.0),
                  child: Container(
                    width: MediaQuery.sizeOf(context).width * 0.9,
                    padding: const EdgeInsets.all(20.0),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(16.0),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.info_outline,
                                color: Color(0xFFEF6C00), size: 24.0),
                            const SizedBox(width: 12.0),
                            Text(
                              'Troubleshooting Tips',
                              style: FlutterFlowTheme.of(context)
                                  .bodyLarge
                                  .override(
                                    fontFamily: 'Inter',
                                    color: const Color(0xFFEF6C00),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8.0),
                        Text(
                          '1. Ensure the smart band is powered on.',
                          style: FlutterFlowTheme.of(context)
                              .bodyMedium
                              .override(
                                fontFamily: 'Inter',
                                color:
                                    FlutterFlowTheme.of(context).secondaryText,
                              ),
                        ),
                        const SizedBox(height: 8.0),
                        Text(
                          '2. Turn on Bluetooth on your phone.',
                          style: FlutterFlowTheme.of(context)
                              .bodyMedium
                              .override(
                                fontFamily: 'Inter',
                                color:
                                    FlutterFlowTheme.of(context).secondaryText,
                              ),
                        ),
                        const SizedBox(height: 8.0),
                        Text(
                          '3. Rescan the QR code if necessary.',
                          style: FlutterFlowTheme.of(context)
                              .bodyMedium
                              .override(
                                fontFamily: 'Inter',
                                color:
                                    FlutterFlowTheme.of(context).secondaryText,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Container to display received sensor data.
              Align(
                alignment: Alignment.center,
                child: ValueListenableBuilder<String>(
                  valueListenable: _bleService.sensorDataNotifier,
                  builder: (context, sensorData, child) {
                    return Container(
                      width: MediaQuery.sizeOf(context).width * 0.9,
                      padding: const EdgeInsets.all(20.0),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16.0),
                        border: Border.all(color: Colors.grey),
                      ),
                      child: Text(
                        "Received Data: $sensorData",
                        style: FlutterFlowTheme.of(context).bodyMedium,
                      ),
                    );
                  },
                ),
              ),
            ].divide(const SizedBox(height: 20.0)),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            // Launch the QR scanner.
            final scannedCode = await Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const QRScannerScreen()),
            );
            if (scannedCode != null) {
              if (scannedCode == "12345678-1234-5678-1234-56789abcdef0") {
                _bleService.startScan();
                if (_bleService.discoveredDevices.isNotEmpty) {
                  _bleService
                      .connectToDevice(_bleService.discoveredDevices.first);
                }
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Scanned QR code is invalid.")),
                );
              }
            }
          },
          child: const Icon(Icons.qr_code_scanner),
        ),
      ),
    );
  }
}

/// A QR scanner screen using ReaderWidget from flutter_zxing.
class QRScannerScreen extends StatelessWidget {
  const QRScannerScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan QR Code")),
      body: ReaderWidget(
        onScan: (Code result) async {
          if (result.isValid) {
            debugPrint("Scanned QR Code: ${result.text}");
            Navigator.pop(context, result.text);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Invalid scan. Please try again.")),
            );
          }
        },
      ),
    );
  }
}
