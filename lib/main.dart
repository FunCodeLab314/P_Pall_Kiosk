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
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'firebase_options.dart';
import 'services.dart';
import 'auth_screens.dart';
import 'dashboard.dart';
import 'welcome_screen.dart';
import 'history_screen.dart';
import 'notifications_screen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// --- NOTIFICATIONS SETUP ---
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize Notifications
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

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
        title: 'PillPal',
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF5F9FF),
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
          textTheme: GoogleFonts.poppinsTextTheme(),
        ),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }
            if (snapshot.hasData) {
              return const DashboardScreen();
            }
            return const WelcomeScreen();
          },
        ),
        routes: {
          '/kiosk': (_) => const KioskModeScreen(),
          '/alarm': (_) => const AlarmPopup(),
          '/history': (_) => const HistoryScreen(),
          '/notifications': (_) => const NotificationsScreen(),
        },
      ),
    );
  }
}

class KioskState extends ChangeNotifier {
  final FirestoreService _db = FirestoreService();
  List<Patient> patients = [];

  late MqttServerClient _client;
  String mqttStatus = "Disconnected";
  final String _topicCmd = 'pillpal/device001/cmd';

  DateTime now = DateTime.now();
  int _lastTriggeredMinute = -1;
  bool isAlarmActive = false;

  List<Map<String, dynamic>> _alarmQueue = [];

  Patient? activePatient;
  AlarmModel? activeAlarm;

  final AudioPlayer _audioPlayer = AudioPlayer();

  KioskState() {
    _db.getPatients().listen((data) {
      patients = data;
      _checkLowStock(); // Check for low stock on every update
      notifyListeners();
    });

    Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      _checkAlarms();
      notifyListeners();
    });

    _connectMqtt();
    _audioPlayer.setSource(AssetSource('alarm_sound.mp3'));
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
  }

  void _checkAlarms() {
    if (now.minute == _lastTriggeredMinute) return;

    bool foundAny = false;
    final currentUserUid = FirebaseAuth.instance.currentUser?.uid;

    for (var p in patients) {
      // Only trigger alarms for patients created by current user
      if (p.createdByUid != currentUserUid) continue;

      for (var a in p.alarms) {
        if (!a.isActive) continue;
        if (a.hour == now.hour && a.minute == now.minute) {
          _alarmQueue.add({'patient': p, 'alarm': a});
          foundAny = true;
        }
      }
    }

    if (foundAny) {
      _lastTriggeredMinute = now.minute;
      _processQueue();
    }
  }

  // --- CHECK LOW STOCK AND SEND NOTIFICATION ---
  void _checkLowStock() async {
    for (var p in patients) {
      for (var a in p.alarms) {
        if (a.medication.needsRefill()) {
          // Send notification to ALL users (not just creator)
          _showNotification(
            "⚠️ Refill Needed",
            "Patient ${p.patientNumber} - ${a.medication.name} (Slot ${a.medication.slotNumber}) needs refill",
          );
        }
      }
    }
  }

  // --- SHOW PHONE NOTIFICATION ---
  Future<void> _showNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'pillpal_channel',
      'PillPal Notifications',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
    );
    const NotificationDetails details =
        NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      title,
      body,
      details,
    );
  }

  void _processQueue() async {
    if (isAlarmActive || _alarmQueue.isEmpty) return;

    final nextItem = _alarmQueue.removeAt(0);
    Patient p = nextItem['patient'];
    AlarmModel a = nextItem['alarm'];

    activePatient = p;
    activeAlarm = a;
    isAlarmActive = true;
    notifyListeners();

    // Trigger Notification - only to user who created this patient
    _showNotification(
      "💊 Time for Medication!",
      "${p.name} - ${a.medication.name} (${a.mealType.toUpperCase()})",
    );

    try {
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.resume();
    } catch (e) {
      print("Error playing sound: $e");
    }

    navigatorKey.currentState?.pushNamed('/alarm');
  }

  void dispense(BuildContext context) async {
    if (mqttStatus != "Connected") {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("Connection Error"),
          content: const Text("Kiosk offline. Check internet."),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text("OK"))
          ],
        ),
      );
      return;
    }

    if (activePatient != null && activeAlarm != null) {
      final msg = jsonEncode({
        'command': 'DISPENSE',
        'slot': activeAlarm!.medication.slotNumber
      });
      final builder = MqttClientPayloadBuilder();
      builder.addString(msg);
      _client.publishMessage(_topicCmd, MqttQos.atLeastOnce, builder.payload!);
      
      // Record as taken and reduce box count
      await _db.markTaken(activePatient!, activeAlarm!);
    }
    _close();
  }

  void skip() {
    if (activePatient != null && activeAlarm != null) {
      _db.markSkipped(activePatient!, activeAlarm!);
    }
    _close();
  }

  void _close() async {
    await _audioPlayer.stop();
    isAlarmActive = false;
    activePatient = null;
    activeAlarm = null;
    notifyListeners();

    navigatorKey.currentState?.pop();

    Future.delayed(const Duration(milliseconds: 500), () {
      _processQueue();
    });
  }

  Future<void> _connectMqtt() async {
    _client = MqttServerClient.withPort(
        'b18466311acb443e9753aae2266143d3.s1.eu.hivemq.cloud',
        'PillPal_Kiosk',
        8883);
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

class KioskModeScreen extends StatelessWidget {
  const KioskModeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<KioskState>(
      builder: (context, state, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF1565C0),
          body: Stack(
            children: [
              Positioned(
                  top: -50,
                  right: -50,
                  child: CircleAvatar(
                      radius: 100,
                      backgroundColor: Colors.white.withOpacity(0.1))),
              Positioned(
                  bottom: -50,
                  left: -50,
                  child: CircleAvatar(
                      radius: 100,
                      backgroundColor: Colors.white.withOpacity(0.1))),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          IconButton(
                              icon: const Icon(Icons.arrow_back,
                                  color: Colors.white),
                              onPressed: () => Navigator.pop(context)),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: state.mqttStatus == "Connected"
                                  ? Colors.green.withOpacity(0.2)
                                  : Colors.red.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: state.mqttStatus == "Connected"
                                      ? Colors.greenAccent
                                      : Colors.redAccent),
                            ),
                            child: Row(children: [
                              Icon(Icons.wifi,
                                  color: state.mqttStatus == "Connected"
                                      ? Colors.greenAccent
                                      : Colors.redAccent,
                                  size: 16),
                              const SizedBox(width: 8),
                              Text(
                                  state.mqttStatus == "Connected"
                                      ? "ONLINE"
                                      : "OFFLINE",
                                  style: TextStyle(
                                      color: state.mqttStatus == "Connected"
                                          ? Colors.greenAccent
                                          : Colors.redAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ]),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(DateFormat('HH:mm').format(state.now),
                                style: GoogleFonts.rubik(
                                    fontSize: 120,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                    letterSpacing: -2)),
                            Text(
                                DateFormat('EEEE, MMM dd, yyyy')
                                    .format(state.now),
                                style: const TextStyle(
                                    fontSize: 24, color: Colors.white70)),
                            const SizedBox(height: 60),
                            Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(color: Colors.white24)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.people_outline,
                                      color: Colors.white, size: 30),
                                  const SizedBox(width: 16),
                                  Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text("${state.patients.length} / 8",
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 24,
                                                fontWeight: FontWeight.bold)),
                                        const Text("Active Patients",
                                            style: TextStyle(
                                                color: Colors.white70)),
                                      ]),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class AlarmPopup extends StatelessWidget {
  const AlarmPopup({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<KioskState>(
      builder: (context, state, _) {
        final p = state.activePatient;
        final a = state.activeAlarm;
        if (p == null || a == null) return const Scaffold();
        
        IconData mealIcon = a.mealType == 'breakfast'
            ? Icons.wb_sunny
            : a.mealType == 'lunch'
                ? Icons.wb_cloudy
                : Icons.nightlight;

        return Scaffold(
          backgroundColor: const Color(0xFF1565C0),
          body: Center(
            child: Container(
              margin: const EdgeInsets.all(24),
              constraints: const BoxConstraints(maxWidth: 500),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(32)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                        color: Color(0xFFE3F2FD),
                        borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(32),
                            topRight: Radius.circular(32))),
                    child: Column(children: [
                      const Icon(Icons.medication_liquid,
                          size: 60, color: Color(0xFF1565C0)),
                      const SizedBox(height: 16),
                      Text("IT'S TIME FOR MEDICINE",
                          style: GoogleFonts.poppins(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF1565C0))),
                    ]),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircleAvatar(
                            backgroundColor: const Color(0xFF1565C0),
                            child: Text("P${p.patientNumber}",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 12),
                          Text(p.name,
                              style: const TextStyle(
                                  fontSize: 32, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.orange)),
                            child: Row(
                              children: [
                                Icon(mealIcon,
                                    size: 16, color: Colors.deepOrange),
                                const SizedBox(width: 6),
                                Text(a.mealType.toUpperCase(),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.deepOrange)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                  color: Colors.purple.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: Colors.purple)),
                              child: Text("SLOT ${a.medication.slotNumber}",
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.purple))),
                        ],
                      ),
                      const SizedBox(height: 32),
                      const Text("Medication:",
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green),
                          const SizedBox(width: 12),
                          Text(a.medication.name,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w500))
                        ],
                      ),
                      const SizedBox(height: 40),
                      Row(children: [
                        Expanded(
                            child: SizedBox(
                                height: 60,
                                child: OutlinedButton(
                                    onPressed: state.skip,
                                    child: const Text("SKIP")))),
                        const SizedBox(width: 20),
                        Expanded(
                            child: SizedBox(
                                height: 60,
                                child: ElevatedButton(
                                    onPressed: () => state.dispense(context),
                                    style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF1565C0),
                                        foregroundColor: Colors.white),
                                    child: const Text("DISPENSE")))),
                      ]),
                    ]),
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