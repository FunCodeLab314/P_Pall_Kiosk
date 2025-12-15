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
// 🚀 CHANGED: Import Cloud Firestore instead of Realtime Database
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

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

// -------------------- Updated Models for Firestore --------------------
class Medication {
  String name;
  Medication({required this.name});

  factory Medication.fromFirestore(Map<String, dynamic> data) {
    return Medication(name: data['name'] ?? 'Unknown Med');
  }
}

class AlarmModel {
  String id;
  int hour;
  int minute;
  bool isActive;
  List<Medication> meds;

  AlarmModel({
    required this.id,
    required this.hour,
    required this.minute,
    required this.isActive,
    required this.meds,
  });

  // 🚀 Parses the "HH:MM" string from Mobile App into hour/minute ints
  factory AlarmModel.fromFirestore(
    String id,
    Map<String, dynamic> data,
    List<Medication> meds,
  ) {
    final timeString = data['timeOfDay'] as String? ?? "00:00";
    final parts = timeString.split(':');
    final h = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    return AlarmModel(
      id: id,
      hour: h,
      minute: m,
      isActive: data['isActive'] ?? true,
      meds: meds,
    );
  }
}

class Patient {
  String id;
  String name;
  int age;
  int slotNumber;
  List<AlarmModel> alarms;

  Patient({
    required this.id,
    required this.name,
    required this.age,
    required this.slotNumber,
    required this.alarms,
  });

  factory Patient.fromFirestore(
    String id,
    Map<String, dynamic> data,
    List<AlarmModel> alarms,
  ) {
    // Mobile app saves slotNumber as String, Kiosk needs int
    int slot = 0;
    if (data['slotNumber'] is int) {
      slot = data['slotNumber'];
    } else if (data['slotNumber'] is String) {
      slot = int.tryParse(data['slotNumber']) ?? 0;
    }

    return Patient(
      id: id,
      name: data['name'] ?? 'Unknown',
      age: data['age'] ?? 0,
      slotNumber: slot,
      alarms: alarms,
    );
  }
}

// -------------------- App State & Logic --------------------
class AppState extends ChangeNotifier {
  List<Patient> patients = [];
  bool isAlarmActive = false;
  String mqttStatus = 'disconnected';
  DateTime now = DateTime.now();

  Patient? activePatient;
  AlarmModel? activeAlarm;

  // 🚀 CHANGED: Use Firestore instance
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // MQTT Variables
  final String _host = 'b18466311acb443e9753aae2266143d3.s1.eu.hivemq.cloud';
  final int _port = 8883;
  final String _username = 'pillpal_device';
  final String _password = 'SecurePass123!';
  final String _clientId = 'PillPal_Flutter_Kiosk';
  final String _topicCmd = 'pillpal/device001/cmd';
  final String _topicStatus = 'pillpal/device001/status';

  late MqttServerClient _client;
  Timer? _clockTimer;
  StreamSubscription? _patientSubscription;

  AppState() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      notifyListeners();
      _checkAlarms();
    });

    Future.microtask(() {
      _connectMqtt();
      _listenToFirestore(); // 🚀 Changed from _listenToFirebase
    });
  }

  int get patientCount => patients.length;

  // 🚀 NEW: Listen to Firestore Collection 'patients'
  void _listenToFirestore() {
    print("Starting Firestore Listener...");
    _patientSubscription = _firestore
        .collection('patients')
        .snapshots()
        .listen(
          (snapshot) async {
            print("Firestore Update: Found ${snapshot.docs.length} patients.");
            List<Patient> newPatients = [];

            for (var doc in snapshot.docs) {
              final pData = doc.data();

              // Fetch Alarms (Subcollection)
              final alarmSnapshot = await doc.reference
                  .collection('alarms')
                  .get();
              List<AlarmModel> pAlarms = [];

              for (var alarmDoc in alarmSnapshot.docs) {
                final aData = alarmDoc.data();

                // Fetch Medications (Subcollection inside Alarm)
                final medSnapshot = await alarmDoc.reference
                    .collection('medications')
                    .get();
                List<Medication> pMeds = medSnapshot.docs
                    .map((mDoc) => Medication.fromFirestore(mDoc.data()))
                    .toList();

                pAlarms.add(
                  AlarmModel.fromFirestore(alarmDoc.id, aData, pMeds),
                );
              }

              newPatients.add(Patient.fromFirestore(doc.id, pData, pAlarms));
            }

            patients = newPatients;
            notifyListeners();
            print(
              "Sync Complete: Loaded ${patients.length} patients with full details.",
            );
          },
          onError: (e) {
            print("Firestore Error: $e");
          },
        );
  }

  // --- MQTT CONNECTION (Unchanged) ---
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

  // --- ALARM LOGIC (Unchanged) ---
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

  void dispenseMedicine() {
    if (activePatient == null || activeAlarm == null) return;

    final msg = jsonEncode({
      'command': 'DISPENSE',
      'slot': activePatient!.slotNumber,
    });

    final builder = MqttClientPayloadBuilder();
    builder.addString(msg);
    _client.publishMessage(_topicCmd, MqttQos.atLeastOnce, builder.payload!);

    // Note: To truly update the 'isActive' state permanently,
    // you should write back to Firestore here.
    activeAlarm!.isActive = false;
    isAlarmActive = false;
    activePatient = null;
    activeAlarm = null;
    notifyListeners();

    navigatorKey.currentState?.popUntil(
      (route) => route.settings.name == '/clock',
    );
  }

  void stopAlarm() {
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

  void rebootDevice() {}

  @override
  void dispose() {
    _clockTimer?.cancel();
    _patientSubscription?.cancel();
    super.dispose();
  }
}

// -------------------- UI Screens (Unchanged) --------------------

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
