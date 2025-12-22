import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ================== DATA MODELS ==================

class Medication {
  String? id;
  String name;
  String status; // 'pending', 'taken', 'skipped'
  DateTime? lastActionAt;

  Medication({
    this.id,
    required this.name,
    this.status = 'pending',
    this.lastActionAt,
  });

  factory Medication.fromMap(Map<String, dynamic> data, String id) {
    DateTime? actionTime;
    if (data['lastActionAt'] != null) {
      actionTime = (data['lastActionAt'] as Timestamp).toDate();
    } else if (data['lastSkippedAt'] != null) {
      actionTime = DateTime.tryParse(data['lastSkippedAt'].toString());
    } else if (data['lastTakenAt'] != null) {
      actionTime = DateTime.tryParse(data['lastTakenAt'].toString());
    }

    return Medication(
      id: id,
      name: data['name'] ?? '',
      status: data['status'] ?? 'pending',
      lastActionAt: actionTime,
    );
  }
}

class AlarmModel {
  String? id;
  String timeOfDay;
  String type; // 'Breakfast', 'Lunch', 'Dinner'
  bool isActive;
  List<Medication> medications;

  AlarmModel({
    this.id,
    required this.timeOfDay,
    this.type = 'Breakfast',
    this.isActive = true,
    required this.medications,
  });

  factory AlarmModel.fromMap(
    Map<String, dynamic> data,
    String id,
    List<Medication> meds,
  ) {
    return AlarmModel(
      id: id,
      timeOfDay: data['timeOfDay'] ?? "00:00",
      type: data['type'] ?? 'Breakfast',
      isActive: data['isActive'] ?? true,
      medications: meds,
    );
  }

  int get hour => int.parse(timeOfDay.split(':')[0]);
  int get minute => int.parse(timeOfDay.split(':')[1]);
}

class Patient {
  String? id;
  String name;
  int age;
  int patientNumber; // 1 to 8
  String gender;
  String createdBy; // Admin Name
  List<AlarmModel> alarms;
  Map<String, int> slotInventory; // Key: Slot Number, Value: Count (Max 3)

  Patient({
    this.id,
    required this.name,
    required this.age,
    required this.patientNumber,
    required this.gender,
    required this.createdBy,
    required this.alarms,
    required this.slotInventory,
  });

  factory Patient.fromMap(
    Map<String, dynamic> data,
    String id,
    List<AlarmModel> alarms,
  ) {
    return Patient(
      id: id,
      name: data['name'] ?? 'Unknown',
      age: data['age'] ?? 0,
      patientNumber: data['patientNumber'] ?? 0,
      gender: data['gender'] ?? 'N/A',
      createdBy: data['createdBy'] ?? 'Unknown',
      slotInventory: Map<String, int>.from(data['slotInventory'] ?? {}),
      alarms: alarms,
    );
  }
  
  // Helper to get slots as a string list for UI display
  String get assignedSlots {
    List<String> slots = [];
    if (patientNumber <= 4) {
      // Patients 1-4: P#, P#+4, P#+8
      slots = [patientNumber.toString(), (patientNumber + 4).toString(), (patientNumber + 8).toString()];
    } else {
      // Patients 5-8: P#+8, P#+12, P#+16
      slots = [(patientNumber + 8).toString(), (patientNumber + 12).toString(), (patientNumber + 16).toString()];
    }
    return slots.join(', ');
  }

  String get slotNumber => assignedSlots; // Alias for backward compatibility if needed
}

class HistoryRecord {
  final String patientName;
  final int patientNumber;
  final String medicationName;
  final String status;
  final String adminName; // Created By
  final DateTime actionTime;
  final String slot;

  HistoryRecord({
    required this.patientName,
    required this.patientNumber,
    required this.medicationName,
    required this.status,
    required this.adminName,
    required this.actionTime,
    required this.slot,
  });
}

// ================== DATABASE SERVICE ==================

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // --- 1. Fetch All Data ---
  Stream<List<Patient>> getPatients() {
    return _db
        .collection('patients')
        .orderBy('patientNumber')
        .snapshots()
        .asyncMap((snapshot) async {
      List<Patient> patients = [];
      for (var doc in snapshot.docs) {
        final pData = doc.data();
        final alarmSnaps = await doc.reference.collection('alarms').get();
        List<AlarmModel> alarms = [];

        for (var aDoc in alarmSnaps.docs) {
          final aData = aDoc.data();
          final medSnaps = await aDoc.reference.collection('medications').get();
          final meds = medSnaps.docs
              .map((m) => Medication.fromMap(m.data(), m.id))
              .toList();
          alarms.add(AlarmModel.fromMap(aData, aDoc.id, meds));
        }
        patients.add(Patient.fromMap(pData, doc.id, alarms));
      }
      return patients;
    });
  }

  // --- 2. Add Data (Auto Assign 1-8) ---
  Future<void> addPatient(
    String name,
    int age,
    String gender,
    String adminName,
    List<AlarmModel> alarms,
  ) async {
    // Determine next available Patient Number (1-8)
    final snapshot = await _db.collection('patients').get();
    Set<int> usedNumbers = snapshot.docs.map((d) => d.data()['patientNumber'] as int).toSet();
    
    int nextNum = -1;
    for (int i = 1; i <= 8; i++) {
      if (!usedNumbers.contains(i)) {
        nextNum = i;
        break;
      }
    }

    if (nextNum == -1) {
      throw Exception("Max 8 patients reached. Delete a patient to add a new one.");
    }

    // Calculate Slots based on mapping
    List<String> mySlots = [];
    if (nextNum <= 4) {
      // 1 -> 1, 5, 9
      mySlots = [nextNum.toString(), (nextNum + 4).toString(), (nextNum + 8).toString()];
    } else {
      // 5 -> 13, 17, 21
      mySlots = [(nextNum + 8).toString(), (nextNum + 12).toString(), (nextNum + 16).toString()];
    }

    // Initialize Inventory (3 boxes per slot)
    Map<String, int> initialInventory = {
      mySlots[0]: 3,
      mySlots[1]: 3,
      mySlots[2]: 3,
    };

    DocumentReference pRef = await _db.collection('patients').add({
      'name': name,
      'age': age,
      'patientNumber': nextNum,
      'gender': gender,
      'createdBy': adminName,
      'slotInventory': initialInventory,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    for (var alarm in alarms) {
      DocumentReference aRef = await pRef.collection('alarms').add({
        'timeOfDay': alarm.timeOfDay,
        'type': alarm.type,
        'isActive': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      for (var med in alarm.medications) {
        await aRef.collection('medications').add({
          'name': med.name,
          'status': 'pending',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }
  }

  // --- 3. Update Data ---
  Future<void> updatePatient(
    Patient patient,
    String name,
    int age,
    String gender,
    List<AlarmModel> newAlarms,
  ) async {
    final pRef = _db.collection('patients').doc(patient.id);

    await pRef.update({
      'name': name,
      'age': age,
      'gender': gender,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // Replace alarms (simplistic approach: delete old, add new)
    final oldAlarms = await pRef.collection('alarms').get();
    for (var doc in oldAlarms.docs) {
      final meds = await doc.reference.collection('medications').get();
      for (var m in meds.docs) await m.reference.delete();
      await doc.reference.delete();
    }

    for (var alarm in newAlarms) {
      DocumentReference aRef = await pRef.collection('alarms').add({
        'timeOfDay': alarm.timeOfDay,
        'type': alarm.type,
        'isActive': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      for (var med in alarm.medications) {
        await aRef.collection('medications').add({
          'name': med.name,
          'status': 'pending',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }
  }

  Future<void> deletePatient(String id) async {
    await _db.collection('patients').doc(id).delete();
  }

  // --- Inventory Refill ---
  Future<void> refillSlot(String patientId, String slotNumber) async {
    await _db.collection('patients').doc(patientId).update({
      'slotInventory.$slotNumber': 3, // Reset to Max
    });
  }

  // --- Action Recording with Inventory Decrement ---
  Future<void> markTaken(String pId, String aId, List<Medication> meds) async {
    final pRef = _db.collection('patients').doc(pId);
    final pSnap = await pRef.get();
    final pData = pSnap.data();

    // Determine slot based on alarm Type and Patient Number
    final aSnap = await pRef.collection('alarms').doc(aId).get();
    final aData = aSnap.data();
    String type = aData?['type'] ?? 'Breakfast';
    int pNum = pData?['patientNumber'] ?? 0;
    
    // Logic to find slot from Type + PatientNum mapping
    String targetSlot = "0";
    if (pNum <= 4) {
      if (type == 'Breakfast') targetSlot = pNum.toString();
      else if (type == 'Lunch') targetSlot = (pNum + 4).toString();
      else if (type == 'Dinner') targetSlot = (pNum + 8).toString();
    } else {
      if (type == 'Breakfast') targetSlot = (pNum + 8).toString();
      else if (type == 'Lunch') targetSlot = (pNum + 12).toString();
      else if (type == 'Dinner') targetSlot = (pNum + 16).toString();
    }

    // Decrement Inventory
    if (pData != null && pData['slotInventory'] != null) {
      Map<String, dynamic> inv = pData['slotInventory'];
      int current = inv[targetSlot] ?? 0;
      if (current > 0) {
        await pRef.update({'slotInventory.$targetSlot': current - 1});
      }
    }

    await _recordAction(pId, aId, meds, 'taken', targetSlot, pData?['createdBy'] ?? 'Unknown');
  }

  Future<void> markSkipped(String pId, String aId, List<Medication> meds) async {
     // Skipped does not decrement inventory
    await _recordAction(pId, aId, meds, 'skipped', 'N/A', 'N/A');
  }

  Future<void> _recordAction(
    String patientId,
    String alarmId,
    List<Medication> meds,
    String status,
    String slotUsed,
    String adminName,
  ) async {
    final now = DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd').format(now);
    final timeStr = DateFormat('HH:mm').format(now);

    // Update Status in Subcollection (for Dashboard Chart)
    final alarmRef = _db.collection('patients').doc(patientId).collection('alarms').doc(alarmId);
    final medsSnapshot = await alarmRef.collection('medications').get();
    
    for (var medDoc in medsSnapshot.docs) {
      if (meds.any((m) => m.name == medDoc['name'])) {
        await medDoc.reference.update({
          'status': status,
          'lastActionAt': FieldValue.serverTimestamp(),
        });
      }
    }

    // Add to History (for PDF Reports)
    final historyRef = _db.collection('patients').doc(patientId).collection('history');
    for (var med in meds) {
      await historyRef.add({
        'medicationName': med.name,
        'status': status,
        'actionTime': FieldValue.serverTimestamp(),
        'date': dateStr,
        'time': timeStr,
        'slot': slotUsed,
        'adminName': adminName, // Recorded here for report
        'alarmId': alarmId,
      });
    }
  }

  // --- 6. Fetch History for Reports (Enhanced) ---
  Future<List<HistoryRecord>> getHistory(DateTime? date) async {
    List<HistoryRecord> records = [];
    String? targetDateStr = date != null ? DateFormat('yyyy-MM-dd').format(date) : null;

    final patientsSnap = await _db.collection('patients').get();
    
    for (var pDoc in patientsSnap.docs) {
      final pData = pDoc.data();
      Query historyQuery = pDoc.reference.collection('history');
      
      if (targetDateStr != null) {
        historyQuery = historyQuery.where('date', isEqualTo: targetDateStr);
      }

      final historySnap = await historyQuery.get();
      for (var hDoc in historySnap.docs) {
        final hData = hDoc.data() as Map<String, dynamic>;
        records.add(HistoryRecord(
          patientName: pData['name'],
          patientNumber: pData['patientNumber'],
          medicationName: hData['medicationName'] ?? '-',
          status: hData['status'] ?? 'UNKNOWN',
          adminName: pData['createdBy'] ?? 'Unknown',
          slot: hData['slot'] ?? '-',
          actionTime: (hData['actionTime'] as Timestamp).toDate(),
        ));
      }
    }
    return records;
  }

  // --- PDF Generation (Updated) ---
  Future<void> generatePdfReport(
    List<HistoryRecord> records,
    BuildContext context,
    DateTime date,
  ) async {
    final pdf = pw.Document();
    final String dateStr = DateFormat('MMMM d, yyyy').format(date);
    
    List<List<String>> tableData = records.map((r) => [
      r.patientName,
      r.patientNumber.toString(),
      r.medicationName,
      DateFormat('HH:mm').format(r.actionTime),
      r.status.toUpperCase(),
      r.slot,
      r.adminName,
    ]).toList();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return [
            pw.Header(level: 0, child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('Daily Medication Report', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('1565C0'))),
              pw.Text(dateStr),
            ])),
            pw.SizedBox(height: 20),
            pw.Table.fromTextArray(
              headers: ['Patient', 'No.', 'Medication', 'Time', 'Status', 'Slot', 'Admin'],
              data: tableData,
              headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('1565C0')),
              headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
            ),
             pw.SizedBox(height: 20),
             pw.Text("Generated by PillPal System", style: const pw.TextStyle(color: PdfColors.grey)),
          ];
        },
      ),
    );

    // Save File
    String path;
    if (Platform.isAndroid) {
      final directory = await getExternalStorageDirectory();
      path = directory?.path ?? "";
      if (path.contains("Android")) path = path.split("Android")[0] + "Download";
    } else {
      final directory = await getApplicationDocumentsDirectory();
      path = directory.path;
    }
    final file = File('$path/PillPal_Report_${DateFormat('yyyyMMdd').format(date)}.pdf');
    if (!await Directory(path).exists()) await Directory(path).create(recursive: true);
    await file.writeAsBytes(await pdf.save());

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Saved to $path"), action: SnackBarAction(label: 'Open', onPressed: () => OpenFilex.open(file.path))));
    }
  }
}