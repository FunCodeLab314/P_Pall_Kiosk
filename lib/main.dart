import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import 'firebase_options.dart';
import 'services.dart';
import 'auth_screens.dart';
import 'dashboard.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const PillPalApp());
}

class PillPalApp extends StatelessWidget {
  const PillPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => KioskState(),
      child: MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'PillPal Kiosk',
        theme: ThemeData(
          scaffoldBackgroundColor: Colors.white,
          primaryColor: const Color(0xFF1565C0),
          textTheme: GoogleFonts.poppinsTextTheme(),
          colorScheme: ColorScheme.fromSwatch().copyWith(
            primary: const Color(0xFF1565C0),
            secondary: const Color(0xFF64B5F6),
          ),
        ),
        // Auth Flow Logic
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return const DashboardScreen();
            }
            return const AuthScreen();
          },
        ),
        routes: {
          '/kiosk': (_) => const KioskModeScreen(),
          '/alarm': (_) => const AlarmPopup(),
        },
      ),
    );
  }
}

// ================== KIOSK STATE & MQTT ==================

class KioskState extends ChangeNotifier {
  final FirestoreService _db = FirestoreService();
  List<Patient> patients = [];

  // MQTT Config
  late MqttServerClient _client;
  String mqttStatus = "Disconnected";
  final String _topicCmd = 'pillpal/device001/cmd';

  // Alarm Logic
  DateTime now = DateTime.now();
  int _lastTriggeredMinute = -1;
  bool isAlarmActive = false;
  Patient? activePatient;
  AlarmModel? activeAlarm;

  KioskState() {
    // 1. Listen to Database
    _db.getPatients().listen((data) {
      patients = data;
      notifyListeners();
    });

    // 2. Start Clock
    Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      _checkAlarms();
      notifyListeners();
    });

    // 3. Connect MQTT
    _connectMqtt();
  }

  void _checkAlarms() {
    if (isAlarmActive || now.minute == _lastTriggeredMinute) return;

    for (var p in patients) {
      for (var a in p.alarms) {
        if (!a.isActive) continue;
        if (a.hour == now.hour && a.minute == now.minute) {
          _lastTriggeredMinute = now.minute;
          _trigger(p, a);
          return;
        }
      }
    }
  }

  void _trigger(Patient p, AlarmModel a) {
    activePatient = p;
    activeAlarm = a;
    isAlarmActive = true;
    notifyListeners();
    navigatorKey.currentState?.pushNamed('/alarm');
  }

  void dispense() {
    if (activePatient != null) {
      // Send MQTT Command
      final msg = jsonEncode({
        'command': 'DISPENSE',
        'slot': activePatient!.slotNumber,
      });
      final builder = MqttClientPayloadBuilder();
      builder.addString(msg);
      _client.publishMessage(_topicCmd, MqttQos.atLeastOnce, builder.payload!);
    }
    _close();
  }

  void skip() {
    // 🚀 Update DB Status to Skipped
    if (activePatient != null && activeAlarm != null) {
      _db.markSkipped(
        activePatient!.id!,
        activeAlarm!.id!,
        activeAlarm!.medications,
      );
    }
    _close();
  }

  void _close() {
    isAlarmActive = false;
    activePatient = null;
    activeAlarm = null;
    notifyListeners();
    navigatorKey.currentState?.pop();
  }

  Future<void> _connectMqtt() async {
    _client = MqttServerClient.withPort(
      'b18466311acb443e9753aae2266143d3.s1.eu.hivemq.cloud',
      'PillPal_Kiosk',
      8883,
    );
    _client.secure = true;
    _client.securityContext = SecurityContext.defaultContext;
    _client.logging(on: false);
    _client.keepAlivePeriod = 20;

    try {
      mqttStatus = "Connecting...";
      notifyListeners();
      await _client.connect('pillpal_device', 'SecurePass123!');
      mqttStatus = "Connected";
    } catch (e) {
      mqttStatus = "Error: $e";
      _client.disconnect();
    }
    notifyListeners();
  }
}

// ================== SCREEN: KIOSK MODE ==================

class KioskModeScreen extends StatelessWidget {
  const KioskModeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<KioskState>(
      builder: (context, state, _) {
        return Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFF1565C0)),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  DateFormat('HH:mm').format(state.now),
                  style: GoogleFonts.poppins(
                    fontSize: 96,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1565C0),
                  ),
                ),
                Text(
                  DateFormat('MMM dd, yyyy').format(state.now),
                  style: const TextStyle(
                    fontSize: 24,
                    color: Color(0xFF64B5F6),
                  ),
                ),
                const SizedBox(height: 40),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.wifi,
                        color: state.mqttStatus == "Connected"
                            ? Colors.green
                            : Colors.red,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        "MQTT: ${state.mqttStatus}",
                        style: const TextStyle(
                          color: Color(0xFF1565C0),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  "Active Patients: ${state.patients.length}",
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ================== SCREEN: ALARM POPUP ==================

class AlarmPopup extends StatelessWidget {
  const AlarmPopup({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<KioskState>(
      builder: (context, state, _) {
        final p = state.activePatient;
        final a = state.activeAlarm;
        if (p == null || a == null) return const Scaffold();

        return Scaffold(
          backgroundColor: const Color(0xFF1565C0),
          body: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.notifications_active_rounded,
                      size: 80,
                      color: Color(0xFF1565C0),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      "MEDICATION DUE",
                      style: GoogleFonts.poppins(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1565C0),
                      ),
                    ),
                    const Divider(height: 40),
                    Text(
                      p.name,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "Tray Slot: ${p.slotNumber}",
                      style: const TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                    const SizedBox(height: 20),
                    ...a.medications.map(
                      (m) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          "• ${m.name}",
                          style: const TextStyle(fontSize: 20),
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => state.dispense(),
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text("DISPENSE NOW"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1565C0),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        OutlinedButton.icon(
                          onPressed: () =>
                              state.skip(), // UPDATES DB STATUS TO SKIPPED
                          icon: const Icon(Icons.close),
                          label: const Text("SKIP DOSE"),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.grey,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
