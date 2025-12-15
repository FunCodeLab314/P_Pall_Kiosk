import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

// --- IMPORT THE FILE YOU JUST GENERATED ---
import 'firebase_options.dart';

// Global navigator key for provider-driven navigation
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase using the credentials you just generated
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Lock to landscape (kiosk-like)
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
        debugShowCheckedModeBanner: false,
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
  factory Medication.fromJson(Map<dynamic, dynamic> j) =>
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

  factory AlarmModel.fromJson(Map<dynamic, dynamic> j) {
    var medsJson = j['meds'] as List? ?? [];
    return AlarmModel(
      hour: int.tryParse(j['hour'].toString()) ?? 0,
      minute: int.tryParse(j['minute'].toString()) ?? 0,
      isActive: j['isActive'] ?? true,
      meds: medsJson.map((m) => Medication.fromJson(m)).toList(),
    );
  }
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

  factory Patient.fromJson(Map<dynamic, dynamic> j) {
    var alarmsJson = j['alarms'] as List? ?? [];
    return Patient(
      name: j['name'] ?? '',
      age: int.tryParse(j['age'].toString()) ?? 0,
      slotNumber: int.tryParse(j['slotNumber'].toString()) ?? 0,
      alarms: alarmsJson.map((a) => AlarmModel.fromJson(a)).toList(),
    );
  }
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

  // Firebase Database Reference
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  // MQTT config (Your HiveMQ Credentials)
  final String _host = 'b18466311acb443e9753aae2266143d3.s1.eu.hivemq.cloud';
  final int _port = 8883;
  final String _username = 'pillpal_device';
  final String _password = 'SecurePass123!';
  final String _clientId = 'PillPal_Flutter_Kiosk';

  // Topics
  final String _topicCmd = 'pillpal/device001/cmd';
  final String _topicStatus = 'pillpal/device001/status';

  late MqttServerClient _client;
  Timer? _clockTimer;

  AppState() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      notifyListeners();
      _checkAlarms();
    });

    Future.microtask(() {
      _connectMqtt();
      _listenToFirebase();
    });
  }

  int get patientCount => patients.length;

  // --- FIREBASE LISTENER ---
  void _listenToFirebase() {
    _dbRef.child('patients').onValue.listen((event) {
      try {
        final data = event.snapshot.value;
        List<Patient> newPatients = [];

        if (data is List) {
          for (var item in data) {
            if (item != null) newPatients.add(Patient.fromJson(item));
          }
        } else if (data is Map) {
          data.forEach((key, value) {
            newPatients.add(Patient.fromJson(value));
          });
        }

        patients = newPatients;
        notifyListeners();
        print("Firebase: Synced ${patients.length} patients.");
      } catch (e) {
        print("Firebase Sync Error: $e");
      }
    });
  }

  // --- MQTT CONNECTION ---
  Future<void> _connectMqtt() async {
    _client = MqttServerClient.withPort(_host, _clientId, _port);
    _client.logging(on: false);
    _client.keepAlivePeriod = 20;
    _client.secure = true;
    _client.securityContext = SecurityContext.defaultContext;
    _client.onDisconnected = _onDisconnected;
    _client.onConnected = _onConnected;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(_clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    _client.connectionMessage = connMess;

    try {
      mqttStatus = 'connecting...';
      notifyListeners();
      await _client.connect(_username, _password);
    } catch (e) {
      print('MQTT Error: $e');
      _client.disconnect();
    }
  }

  void _onConnected() {
    mqttStatus = 'connected';
    _client.subscribe(_topicStatus, MqttQos.atLeastOnce);
    notifyListeners();
  }

  void _onDisconnected() {
    mqttStatus = 'disconnected';
    notifyListeners();
  }

  // --- ALARM LOGIC ---
  void _checkAlarms() {
    if (isAlarmActive) return;

    for (final p in patients) {
      for (final a in p.alarms) {
        if (!a.isActive) continue;

        // Trigger if times match (and seconds is 0 to avoid multi-trigger)
        if (a.hour == now.hour && a.minute == now.minute && now.second == 0) {
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
    navigatorKey.currentState?.pushNamed('/alarm');
  }

  // --- DISPENSE ACTION ---
  void dispenseMedicine() {
    if (activePatient == null || activeAlarm == null) return;

    // Send JSON Command to ESP32
    final msg = jsonEncode({
      'command': 'DISPENSE',
      'slot': activePatient!.slotNumber,
    });

    final builder = MqttClientPayloadBuilder();
    builder.addString(msg);
    _client.publishMessage(_topicCmd, MqttQos.atLeastOnce, builder.payload!);

    // Clear Alarm State
    activeAlarm!.isActive = false;
    isAlarmActive = false;
    activePatient = null;
    activeAlarm = null;
    notifyListeners();

    // Go back to clock
    navigatorKey.currentState?.popUntil(
      (route) => route.settings.name == '/clock',
    );
  }

  void stopAlarm() {
    // Optional: Send STOP to ESP32
    final msg = jsonEncode({'command': 'STOP'});
    final builder = MqttClientPayloadBuilder();
    builder.addString(msg);
    _client.publishMessage(_topicCmd, MqttQos.atLeastOnce, builder.payload!);

    isAlarmActive = false;
    activePatient = null;
    activeAlarm = null;
    notifyListeners();
    navigatorKey.currentState?.popUntil(
      (route) => route.settings.name == '/clock',
    );
  }

  void rebootDevice() {
    // Only used for simulation in App
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
                      padding: const EdgeInsets.all(16),
                    ),
                    onPressed: () => Navigator.pushNamed(context, '/refill'),
                    child: const Text('Refill Instructions'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white24,
                      padding: const EdgeInsets.all(16),
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
                child: const Text('ENTER KIOSK MODE'),
              ),
            ],
          ),
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
  static String _monthName(int m) => [
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
  ][m - 1];

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Patients Synced: ${state.patientCount}',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        Text(
                          'MQTT: ${state.mqttStatus}',
                          style: TextStyle(
                            color: state.mqttStatus == 'connected'
                                ? Colors.green
                                : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 24,
                    top: 24,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('EXIT'),
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
          backgroundColor: Colors.black,
          body: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.redAccent, width: 4),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.red,
                  size: 80,
                ),
                const SizedBox(height: 16),
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
                    'Slot #${p.slotNumber}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                const SizedBox(height: 16),
                if (a != null)
                  ...a.meds.map(
                    (m) => Text(
                      '- ${m.name}',
                      style: const TextStyle(fontSize: 24, color: Colors.white),
                    ),
                  ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 20,
                        ),
                      ),
                      onPressed: () => state.dispenseMedicine(),
                      child: const Text(
                        'DISPENSE',
                        style: TextStyle(fontSize: 24),
                      ),
                    ),
                    const SizedBox(width: 40),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 40,
                          vertical: 20,
                        ),
                      ),
                      onPressed: () => state.stopAlarm(),
                      child: const Text(
                        'SKIP / STOP',
                        style: TextStyle(fontSize: 24),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class RefillPage extends StatelessWidget {
  const RefillPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("Refill")),
    body: const Center(child: Text("Refill Instructions Placeholder")),
  );
}

class AppInstructionsPage extends StatelessWidget {
  const AppInstructionsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("Instructions")),
    body: const Center(child: Text("App Instructions Placeholder")),
  );
}
