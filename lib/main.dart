import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

// Global navigator key for provider-driven navigation
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  // Lock to landscape (kiosk-like)
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]).then((_) {
    runApp(const PillPalApp());
  });
}

class PillPalApp extends StatelessWidget {
  const PillPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTextStyle = GoogleFonts.montserrat(
      textStyle: const TextStyle(color: Colors.white),
    );

    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'PillPal',
        theme: ThemeData(
          scaffoldBackgroundColor: Colors.black,
          textTheme: TextTheme(
            bodyLarge: baseTextStyle.copyWith(fontSize: 18),
            headlineLarge: baseTextStyle.copyWith(
              fontSize: 48,
              fontWeight: FontWeight.bold,
            ),
            headlineMedium: baseTextStyle.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.w600,
            ),
          ),
          colorScheme: const ColorScheme.dark(),
        ),
        initialRoute: '/',
        routes: {
          '/': (_) => const TitleScreen(),
          '/refill': (_) => const RefillPage(),
          '/instructions': (_) => const AppInstructionsPage(),
          '/clock': (_) => const ClockScreen(),
          '/alarm': (_) => const AlarmScreen(),
        },
      ),
    );
  }
}

// -------------------- Models --------------------
class Medication {
  String name;
  Medication({required this.name});
  factory Medication.fromJson(Map<String, dynamic> j) =>
      Medication(name: j['name'] ?? '');
  Map<String, dynamic> toJson() => {'name': name};
}

class AlarmModel {
  int hour;
  int minute;
  bool isActive;
  List<Medication> meds;

  AlarmModel({
    required this.hour,
    required this.minute,
    required this.isActive,
    required this.meds,
  });

  factory AlarmModel.fromJson(Map<String, dynamic> j) {
    var medsJson = j['meds'] as List? ?? [];
    return AlarmModel(
      hour: j['hour'] ?? 0,
      minute: j['minute'] ?? 0,
      isActive: j['isActive'] ?? true,
      meds: medsJson.map((m) => Medication.fromJson(m)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'hour': hour,
    'minute': minute,
    'isActive': isActive,
    'meds': meds.map((e) => e.toJson()).toList(),
  };
}

class Patient {
  String name;
  int age;
  int slotNumber;
  List<AlarmModel> alarms;

  Patient({
    required this.name,
    required this.age,
    required this.slotNumber,
    required this.alarms,
  });

  factory Patient.fromJson(Map<String, dynamic> j) {
    var alarmsJson = j['alarms'] as List? ?? [];
    return Patient(
      name: j['name'] ?? '',
      age: j['age'] ?? 0,
      slotNumber: j['slotNumber'] ?? 0,
      alarms: alarmsJson.map((a) => AlarmModel.fromJson(a)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'age': age,
    'slotNumber': slotNumber,
    'alarms': alarms.map((a) => a.toJson()).toList(),
  };
}

// -------------------- App State & MQTT --------------------
class AppState extends ChangeNotifier {
  List<Patient> patients = [];
  bool isAlarmActive = false;
  String mqttStatus = 'disconnected';
  DateTime now = DateTime.now();

  // Active alarm references
  Patient? activePatient;
  AlarmModel? activeAlarm;

  // MQTT config (per spec)
  final String _host = 'b18466311acb443e9753aae2266143d3.s1.eu.hivemq.cloud';
  final int _port = 8883;
  final String _username = 'pillpal_device';
  final String _password = 'SecurePass123!';
  final String _clientId = 'PillPal_Flutter_001';
  final String _topicSync = 'pillpal/device001/sync';
  final String _topicCmd = 'pillpal/device001/cmd';
  final String _topicStatus = 'pillpal/device001/status';
  final String _topicAlarm = 'pillpal/device001/alarm';

  late MqttServerClient _client;
  Timer? _clockTimer;

  AppState() {
    // start internal clock and alarm checker
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      notifyListeners();
      _checkAlarms();
    });

    // Start MQTT connection
    Future.microtask(() => _connectMqtt());
  }

  int get patientCount => patients.length;

  Future<void> _connectMqtt() async {
    _client = MqttServerClient.withPort(_host, _clientId, _port);
    _client.logging(on: false);
    _client.keepAlivePeriod = 20;
    _client.secure = true;
    _client.onDisconnected = _onDisconnected;
    _client.onConnected = _onConnected;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _client.connectionMessage = connMess;

    try {
      mqttStatus = 'connecting';
      notifyListeners();
      await _client.connect(_username, _password);
    } catch (e) {
      _client.disconnect();
    }

    if (_client.connectionStatus?.state == MqttConnectionState.connected) {
      // subscribe
      _client.subscribe(_topicSync, MqttQos.atLeastOnce);
      _client.subscribe(_topicCmd, MqttQos.atLeastOnce);
      _client.updates!.listen(_onMessage);
      _publishStatus('connected');
    } else {
      mqttStatus = 'disconnected';
      notifyListeners();
    }
  }

  void _onConnected() {
    mqttStatus = 'connected';
    notifyListeners();
  }

  void _onDisconnected() {
    mqttStatus = 'disconnected';
    notifyListeners();
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final rec in messages) {
      final topic = rec.topic;
      final payload = (rec.payload as MqttPublishMessage).payload;
      final message = MqttPublishPayload.bytesToStringAsString(payload.message);

      if (topic == _topicSync) {
        _handleSync(message);
      } else if (topic == _topicCmd) {
        // handle simple commands if any (e.g., remote triggers)
        try {
          final cmd = jsonDecode(message);
          if (cmd['action'] == 'trigger_alarm') {
            // find patient/slot and trigger
            final slot = cmd['slot'];
            final patient = patients.firstWhere(
              (p) => p.slotNumber == slot,
              orElse: () =>
                  Patient(name: '', age: 0, slotNumber: -1, alarms: []),
            );
            if (patient.slotNumber != -1 && patient.alarms.isNotEmpty) {
              _triggerAlarm(patient, patient.alarms.first);
            }
          }
        } catch (_) {
          // ignore malformed or plain commands
        }
      }
    }
  }

  void _handleSync(String payload) {
    try {
      final parsed = jsonDecode(payload);
      List<Patient> newPatients = [];
      if (parsed is Map && parsed['patients'] != null) {
        newPatients = (parsed['patients'] as List)
            .map((p) => Patient.fromJson(p))
            .toList();
      } else if (parsed is List) {
        newPatients = parsed.map((p) => Patient.fromJson(p)).toList();
      }

      patients = newPatients;
      mqttStatus = 'synced';
      notifyListeners();
    } catch (e) {
      // ignore parse errors
    }
  }

  void _publishStatus(String status) {
    final msg = jsonEncode({
      'status': status,
      'time': DateTime.now().toIso8601String(),
    });
    final builder = MqttClientPayloadBuilder();
    builder.addString(msg);
    _client.publishMessage(_topicStatus, MqttQos.atLeastOnce, builder.payload!);
  }

  void _publishAlarmEvent(String event, {Patient? patient}) {
    final msg = jsonEncode({
      'event': event,
      'patient': patient?.name ?? '',
      'time': DateTime.now().toIso8601String(),
    });
    final builder = MqttClientPayloadBuilder();
    builder.addString(msg);
    _client.publishMessage(_topicAlarm, MqttQos.atLeastOnce, builder.payload!);
  }

  // Check every second for matching alarms
  void _checkAlarms() {
    if (isAlarmActive) return; // one at a time
    for (final p in patients) {
      for (final a in p.alarms) {
        if (!a.isActive) continue;
        if (a.hour == now.hour && a.minute == now.minute) {
          _triggerAlarm(p, a);
          return;
        }
      }
    }
  }

  void _triggerAlarm(Patient p, AlarmModel a) {
    activePatient = p;
    activeAlarm = a;
    isAlarmActive = true;
    notifyListeners();

    // Bring Alarm screen to front
    navigatorKey.currentState?.pushNamed('/alarm');
  }

  // Dispense action: publish and clear alarm
  void dispenseMedicine() {
    if (activePatient == null || activeAlarm == null) return;
    _publishAlarmEvent('medicine_dispensed', patient: activePatient);
    // Clear the active alarm
    activeAlarm!.isActive = false;
    isAlarmActive = false;
    // Clear references
    activePatient = null;
    activeAlarm = null;
    notifyListeners();

    // Ensure UI returns to clock
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/clock', (r) => false);
  }

  // Stop alarm (no action)
  void stopAlarm() {
    isAlarmActive = false;
    activePatient = null;
    activeAlarm = null;
    notifyListeners();
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/clock', (r) => false);
  }

  // Simulated reboot from UI
  void rebootDevice() {
    _publishStatus('reboot');
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    try {
      _client.disconnect();
    } catch (_) {}
    super.dispose();
  }
}

// -------------------- UI Screens --------------------
class TitleScreen extends StatelessWidget {
  const TitleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Container(
          color: Colors.black,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Text(
                'PillPal',
                style: textTheme.headlineLarge?.copyWith(fontSize: 72),
              ),
              const SizedBox(height: 12),
              Text('SMART MEDICINE DISPENSER', style: textTheme.headlineMedium),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white24,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                    ),
                    onPressed: () => Navigator.pushNamed(context, '/refill'),
                    child: const Text('Refill Instructions'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white24,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                    ),
                    onPressed: () =>
                        Navigator.pushNamed(context, '/instructions'),
                    child: const Text('App Instructions'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                ),
                onPressed: () => Navigator.pushNamed(context, '/clock'),
                child: const Text('ENTER'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RefillPage extends StatelessWidget {
  const RefillPage({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Refill Instructions'),
        backgroundColor: Colors.black87,
      ),
      body: Container(
        padding: const EdgeInsets.all(24),
        color: Colors.black,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '1. Loosen screws on the top panel.',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '2. Open the hopper and refill medication slots.',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '3. Re-tighten screws and ensure hopper is secure.',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '4. Verify device reports updated status via MQTT.',
              style: textTheme.bodyLarge,
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('BACK'),
            ),
          ],
        ),
      ),
    );
  }
}

class AppInstructionsPage extends StatelessWidget {
  const AppInstructionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Instructions'),
        backgroundColor: Colors.black87,
      ),
      body: Container(
        padding: const EdgeInsets.all(24),
        color: Colors.black,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '1. Connect the device to the network.',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '2. Ensure MQTT broker credentials are configured.',
              style: textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '3. Use the Clock Dashboard for monitoring.',
              style: textTheme.bodyLarge,
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('BACK'),
            ),
          ],
        ),
      ),
    );
  }
}

class ClockScreen extends StatelessWidget {
  const ClockScreen({super.key});

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  String _formatDate(DateTime dt) =>
      '${_monthName(dt.month)} ${dt.day}, ${dt.year}';

  static String _monthName(int m) {
    const names = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return names[m - 1];
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Scaffold(
          body: SafeArea(
            child: Container(
              color: Colors.black,
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(state.now),
                          style: Theme.of(
                            context,
                          ).textTheme.headlineLarge?.copyWith(fontSize: 96),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _formatDate(state.now),
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 24,
                    bottom: 24,
                    child: Text(
                      'Patients: ${state.patientCount}',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  Positioned(
                    right: 24,
                    bottom: 24,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                      ),
                      onPressed: () {
                        state.rebootDevice();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Simulated reboot...')),
                        );
                      },
                      child: const Text('REBOOT'),
                    ),
                  ),
                  Positioned(
                    left: 24,
                    top: 24,
                    child: Row(
                      children: [
                        ElevatedButton(
                          onPressed: () => Navigator.pushNamed(context, '/'),
                          child: const Text('TITLE'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: () =>
                              Navigator.pushNamed(context, '/refill'),
                          child: const Text('REFILL'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class AlarmScreen extends StatelessWidget {
  const AlarmScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final p = state.activePatient;
        final a = state.activeAlarm;
        return Scaffold(
          body: Container(
            color: Colors.black,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 24),
                Text(
                  'MEDICATION DUE',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    color: Colors.red,
                    fontSize: 56,
                  ),
                ),
                const SizedBox(height: 24),
                if (p != null)
                  Text(
                    'Patient: ${p.name}',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                if (p != null)
                  Text(
                    'Slot #: ${p.slotNumber}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                const SizedBox(height: 12),
                if (a != null)
                  Text(
                    'Due at ${a.hour.toString().padLeft(2, '0')}:${a.minute.toString().padLeft(2, '0')}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: Colors.redAccent),
                  ),
                const SizedBox(height: 16),
                if (a != null)
                  Column(
                    children: a.meds
                        .map(
                          (m) => Text(
                            '- ${m.name}',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        )
                        .toList(),
                  ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                      onPressed: () {
                        state.dispenseMedicine();
                      },
                      child: const Text('DISPENSE'),
                    ),
                    const SizedBox(width: 24),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white24,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                      onPressed: () => state.stopAlarm(),
                      child: const Text('STOP ALARM'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }
}
