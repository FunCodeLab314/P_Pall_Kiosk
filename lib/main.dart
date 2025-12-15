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
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart'; // Ensure 'flutter pub add intl' is run

import 'firebase_options.dart';

// 🚀 Global Key for Navigation
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Lock Orientation to Portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]).then((_) {
    runApp(const PillPalApp());
  });
}

class PillPalApp extends StatelessWidget {
  const PillPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 🚀 Typography adjusted for Blue/White theme
    final baseTextStyle = GoogleFonts.poppins(
      textStyle: const TextStyle(color: Color(0xFF1565C0)), // Dark Blue text
    );

    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'PillPal',
        theme: ThemeData(
          // 🚀 Theme colors to Blue & White
          scaffoldBackgroundColor: Colors.white,
          primaryColor: const Color(0xFF1E88E5), // Blue 600
          cardColor: const Color(0xFFE3F2FD), // Light Blue 50
          textTheme: TextTheme(
            bodyLarge: baseTextStyle.copyWith(fontSize: 18),
            headlineLarge: baseTextStyle.copyWith(
              fontSize: 42,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF0D47A1), // Darker Blue
            ),
            headlineMedium: baseTextStyle.copyWith(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF1976D2), // Medium Blue
            ),
          ),
          colorScheme: ColorScheme.fromSwatch().copyWith(
            primary: const Color(0xFF1E88E5),
            secondary: const Color(0xFF64B5F6),
            surface: Colors.white,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E88E5),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 4,
            ),
          ),
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

// -------------------- Self-Contained Models --------------------

class Medication {
  String? id;
  String name;

  Medication({this.id, required this.name});

  factory Medication.fromFirestore(String id, Map<String, dynamic> data) {
    return Medication(id: id, name: data['name'] ?? 'Unknown Med');
  }
}

class AlarmModel {
  String id;
  int hour;
  int minute;
  bool isActive;
  String timeString;
  List<Medication> meds;

  AlarmModel({
    required this.id,
    required this.hour,
    required this.minute,
    required this.isActive,
    required this.timeString,
    required this.meds,
  });

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
      timeString: timeString,
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

  // Track triggered alarms to prevent loops (clears every minute)
  Set<String> _triggeredAlarmIds = {};
  int _currentMinute = -1;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // MQTT Config
  final String _host = 'b18466311acb443e9753aae2266143d3.s1.eu.hivemq.cloud';
  final int _port = 8883;
  final String _username = 'pillpal_device';
  final String _password = 'SecurePass123!';
  final String _clientId = 'PillPal_Flutter_Kiosk';
  final String _topicCmd = 'pillpal/device001/cmd';
  final String _topicStatus = 'pillpal/device001/status';

  late MqttServerClient _client;
  Timer? _clockTimer;
  Timer? _syncTimer;

  AppState() {
    // 1. Clock Timer: Updates UI time every second and triggers alarm checks
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      now = DateTime.now();
      notifyListeners();
      _checkAlarms();
    });

    // 2. Sync Timer: Forces data fetch every 10s to catch Mobile App edits
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _fetchFullData();
    });

    Future.microtask(() {
      _connectMqtt();
      _fetchFullData();
    });
  }

  int get patientCount => patients.length;

  // 🚀 Manual Data Fetching (No external service file needed)
  Future<void> _fetchFullData() async {
    try {
      final snapshot = await _firestore.collection('patients').get();
      List<Patient> newPatients = [];

      for (var doc in snapshot.docs) {
        final pData = doc.data();

        final alarmSnapshot = await doc.reference.collection('alarms').get();
        List<AlarmModel> pAlarms = [];

        for (var alarmDoc in alarmSnapshot.docs) {
          final aData = alarmDoc.data();

          final medSnapshot = await alarmDoc.reference
              .collection('medications')
              .get();
          List<Medication> pMeds = medSnapshot.docs
              .map((mDoc) => Medication.fromFirestore(mDoc.id, mDoc.data()))
              .toList();

          pAlarms.add(AlarmModel.fromFirestore(alarmDoc.id, aData, pMeds));
        }
        newPatients.add(Patient.fromFirestore(doc.id, pData, pAlarms));
      }

      patients = newPatients;
      notifyListeners();
    } catch (e) {
      print("Sync Error: $e");
    }
  }

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

  // 🚀 Logic to Check Alarms
  void _checkAlarms() {
    if (now.minute != _currentMinute) {
      _currentMinute = now.minute;
      _triggeredAlarmIds.clear(); // Allow alarms to ring again in a new minute
    }

    if (isAlarmActive) return;

    for (final p in patients) {
      for (final a in p.alarms) {
        if (!a.isActive) continue;

        // Skip if we already checked this alarm's date logic
        // (Note: For this simplified version, we just check time matches)
        // If you wanted to check lastDispenseDate, you would parse it here.
        // But since you want edits to re-trigger, we rely mostly on time match + minute lock.

        final uniqueAlarmId = "${p.id}_${a.id}";
        if (_triggeredAlarmIds.contains(uniqueAlarmId)) continue;

        if (a.hour == now.hour && a.minute == now.minute) {
          print("ALARM MATCH! Triggering for ${p.name} at ${a.timeString}");
          _triggeredAlarmIds.add(uniqueAlarmId);
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
    if (navigatorKey.currentState != null) {
      navigatorKey.currentState!.pushNamed('/alarm');
    }
  }

  // 🚀 Dispense: Marks as done for today
  void dispenseMedicine() async {
    if (activePatient == null || activeAlarm == null) return;

    // MQTT Command
    final msg = jsonEncode({
      'command': 'DISPENSE',
      'slot': activePatient!.slotNumber,
    });
    final builder = MqttClientPayloadBuilder();
    builder.addString(msg);
    _client.publishMessage(_topicCmd, MqttQos.atLeastOnce, builder.payload!);

    // Database Update: Mark as dispensed today
    final todayDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
    try {
      await _firestore
          .collection('patients')
          .doc(activePatient!.id)
          .collection('alarms')
          .doc(activeAlarm!.id)
          .update({'lastDispenseDate': todayDate});
    } catch (e) {
      print("Error updating dispense date: $e");
    }

    activeAlarm!.isActive = false;
    _closeAlarmScreen();
  }

  // 🚀 Skip: Marks meds as 'skipped' but allows retry (Date NOT updated)
  void skipMedicine() async {
    if (activePatient == null || activeAlarm == null) {
      print("Error: No active patient/alarm to skip.");
      return;
    }

    print("Attempting to SKIP medication for ${activePatient!.name}");

    // 1. Send STOP command to Kiosk Hardware
    final msg = jsonEncode({'command': 'STOP'});
    final builder = MqttClientPayloadBuilder();
    builder.addString(msg);
    _client.publishMessage(_topicCmd, MqttQos.atLeastOnce, builder.payload!);

    // 2. Update Only Medication Status to 'skipped' in Database
    try {
      if (activeAlarm!.meds.isEmpty) {
        print(
          "Warning: No medications found in this alarm to mark as skipped.",
        );
      }

      for (var med in activeAlarm!.meds) {
        if (med.id != null) {
          print("Marking med ${med.name} (${med.id}) as skipped...");
          await _firestore
              .collection('patients')
              .doc(activePatient!.id)
              .collection('alarms')
              .doc(activeAlarm!.id)
              .collection('medications')
              .doc(med.id)
              .update({'status': 'skipped'});
        }
      }
      print("Medicine skipped successfully. Alarm date NOT updated.");
    } catch (e) {
      print("Error updating skip status: $e");
    }

    _closeAlarmScreen();
  }

  void stopAlarm() {
    _closeAlarmScreen();
  }

  void _closeAlarmScreen() {
    isAlarmActive = false;
    activePatient = null;
    activeAlarm = null;
    notifyListeners();
    // Use navigatorKey to close the specific alarm screen
    if (navigatorKey.currentState != null) {
      navigatorKey.currentState!.popUntil(
        (route) => route.settings.name == '/clock',
      );
    }
  }

  void rebootDevice() {}

  @override
  void dispose() {
    _clockTimer?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }
}

// -------------------- UI Screens --------------------

class FadeInSlide extends StatelessWidget {
  final Widget child;
  final Duration delay;

  const FadeInSlide({super.key, required this.child, required this.delay});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (context, double value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class TitleScreen extends StatelessWidget {
  const TitleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Color(0xFFE3F2FD)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                const FadeInSlide(
                  delay: Duration(milliseconds: 0),
                  child: Icon(
                    Icons.medication_liquid_rounded,
                    size: 100,
                    color: Color(0xFF1E88E5),
                  ),
                ),
                const SizedBox(height: 20),
                FadeInSlide(
                  delay: Duration(milliseconds: 200),
                  child: Text(
                    'PillPal',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ),
                const SizedBox(height: 10),
                FadeInSlide(
                  delay: Duration(milliseconds: 400),
                  child: Text(
                    'SMART DISPENSER',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: Colors.grey[600],
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const Spacer(flex: 3),
                FadeInSlide(
                  delay: Duration(milliseconds: 600),
                  child: SizedBox(
                    width: double.infinity,
                    height: 60,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E88E5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      onPressed: () => Navigator.pushNamed(context, '/clock'),
                      child: const Text(
                        'ENTER KIOSK MODE',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          side: const BorderSide(color: Color(0xFF1E88E5)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        onPressed: () =>
                            Navigator.pushNamed(context, '/refill'),
                        child: const Text('Refill'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          side: const BorderSide(color: Color(0xFF1E88E5)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        onPressed: () =>
                            Navigator.pushNamed(context, '/instructions'),
                        child: const Text('Instructions'),
                      ),
                    ),
                  ],
                ),
                const Spacer(flex: 1),
              ],
            ),
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

  void _showPatientsDialog(BuildContext context, List<Patient> patients) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "Synced Patients",
          style: TextStyle(
            color: Color(0xFF1565C0),
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: patients.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    "No patients synced yet.",
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: patients.length,
                  separatorBuilder: (ctx, i) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final p = patients[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFE3F2FD),
                        child: Text(
                          p.slotNumber.toString(),
                          style: const TextStyle(
                            color: Color(0xFF1E88E5),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        p.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text("Age: ${p.age}"),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: -100,
                  right: -100,
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFE3F2FD).withOpacity(0.5),
                    ),
                  ),
                ),

                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.arrow_back_ios,
                              color: Color(0xFF1E88E5),
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE3F2FD),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.wifi,
                                  size: 16,
                                  color: state.mqttStatus == 'connected'
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 12),
                                GestureDetector(
                                  onTap: () => _showPatientsDialog(
                                    context,
                                    state.patients,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.people,
                                        size: 20,
                                        color: state.patients.isNotEmpty
                                            ? const Color(0xFF1E88E5)
                                            : Colors.grey,
                                      ),
                                      if (state.patients.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 6.0,
                                          ),
                                          child: Text(
                                            state.patientCount.toString(),
                                            style: const TextStyle(
                                              color: Color(0xFF1E88E5),
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    TweenAnimationBuilder(
                      tween: Tween<double>(begin: 0.98, end: 1.0),
                      duration: const Duration(seconds: 1),
                      builder: (context, double scale, child) {
                        return Transform.scale(scale: scale, child: child);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(40),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF1E88E5).withOpacity(0.1),
                              blurRadius: 30,
                              spreadRadius: 5,
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _formatTime(state.now),
                              style: Theme.of(context).textTheme.headlineLarge
                                  ?.copyWith(
                                    fontSize: 80,
                                    color: const Color(0xFF1E88E5),
                                    letterSpacing: -2,
                                  ),
                            ),
                            Text(
                              _formatDate(state.now),
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(
                                    color: Colors.grey[600],
                                    fontSize: 20,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const Spacer(),

                    Padding(
                      padding: const EdgeInsets.only(bottom: 40.0),
                      child: Column(
                        children: [
                          Text(
                            "Next Sync in...",
                            style: TextStyle(color: Colors.grey[400]),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            "${state.patientCount} Patients Active",
                            style: const TextStyle(
                              color: Color(0xFF1565C0),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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

class PulsingWidget extends StatefulWidget {
  final Widget child;
  const PulsingWidget({super.key, required this.child});
  @override
  State<PulsingWidget> createState() => _PulsingWidgetState();
}

class _PulsingWidgetState extends State<PulsingWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 1.0, end: 1.1).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _animation, child: widget.child);
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
          backgroundColor: const Color(0xFF1565C0),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(),
                  PulsingWidget(
                    child: Container(
                      padding: const EdgeInsets.all(30),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.notifications_active_rounded,
                        color: Color(0xFF1565C0),
                        size: 80,
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  const Text(
                    'MEDICATION DUE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 30),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white30),
                    ),
                    child: Column(
                      children: [
                        if (p != null)
                          Text(
                            p.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (p != null)
                          Text(
                            'Slot #${p.slotNumber}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                            ),
                          ),
                        const Divider(color: Colors.white24, height: 30),
                        if (a != null)
                          ...a.meds.map(
                            (m) => Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 4.0,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.medication,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    m.name,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 65,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF1565C0),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      onPressed: () => state.dispenseMedicine(),
                      child: const Text(
                        'DISPENSE NOW',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => state.skipMedicine(),
                    child: const Text(
                      'Skip / Stop Alarm',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
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
    appBar: AppBar(
      title: const Text("Refill"),
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF1565C0),
      elevation: 0,
    ),
    body: const Center(child: Text("Refill Instructions Placeholder")),
  );
}

class AppInstructionsPage extends StatelessWidget {
  const AppInstructionsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text("Instructions"),
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF1565C0),
      elevation: 0,
    ),
    body: const Center(child: Text("App Instructions Placeholder")),
  );
}
