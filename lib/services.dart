import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ================== SLOT MAPPING ==================
class SlotMapping {
  static const Map<int, List<int>> patientSlots = {
    1: [1, 5, 9],    // Patient 1: Breakfast(1), Lunch(5), Dinner(9)
    2: [2, 6, 10],
    3: [3, 7, 11],
    4: [4, 8, 12],
    5: [13, 17, 21],
    6: [14, 18, 22],
    7: [15, 19, 23],
    8: [16, 20, 24],
  };

  static List<int> getSlotsForPatient(int patientNum) {
    return patientSlots[patientNum] ?? [];
  }

  static int getSlotForMealType(int patientNum, String mealType) {
    final slots = getSlotsForPatient(patientNum);
    switch (mealType.toLowerCase()) {
      case 'breakfast': return slots[0];
      case 'lunch': return slots[1];
      case 'dinner': return slots[2];
      default: return slots[0];
    }
  }
}

// ================== DATA MODELS ==================

class Medication {
  String? id;
  String name;
  String mealType; // 'breakfast', 'lunch', 'dinner'
  int slotNumber; // Physical slot number (1-24)
  String status; // 'pending', 'taken', 'skipped'
  DateTime? lastActionAt;
  int remainingBoxes; // 0-3 boxes per slot

  Medication({
    this.id,
    required this.name,
    required this.mealType,
    required this.slotNumber,
    this.status = 'pending',
    this.lastActionAt,
    this.remainingBoxes = 3, // Default: full
  });

  factory Medication.fromMap(Map<String, dynamic> data, String id) {
    DateTime? actionTime;
    if (data['lastActionAt'] != null) {
      actionTime = (data['lastActionAt'] as Timestamp).toDate();
    }

    return Medication(
      id: id,
      name: data['name'] ?? '',
      mealType: data['mealType'] ?? 'breakfast',
      slotNumber: data['slotNumber'] ?? 1,
      status: data['status'] ?? 'pending',
      lastActionAt: actionTime,
      remainingBoxes: data['remainingBoxes'] ?? 3,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'mealType': mealType,
      'slotNumber': slotNumber,
      'status': status,
      'remainingBoxes': remainingBoxes,
      'lastActionAt': lastActionAt != null ? Timestamp.fromDate(lastActionAt!) : null,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  bool needsRefill() => remainingBoxes <= 1;
}

class AlarmModel {
  String? id;
  String timeOfDay;
  String mealType; // 'breakfast', 'lunch', 'dinner'
  bool isActive;
  Medication medication;

  AlarmModel({
    this.id,
    required this.timeOfDay,
    required this.mealType,
    this.isActive = true,
    required this.medication,
  });

  factory AlarmModel.fromMap(
    Map<String, dynamic> data,
    String id,
    Medication med,
  ) {
    return AlarmModel(
      id: id,
      timeOfDay: data['timeOfDay'] ?? "00:00",
      mealType: data['mealType'] ?? 'breakfast',
      isActive: data['isActive'] ?? true,
      medication: med,
    );
  }

  int get hour => int.parse(timeOfDay.split(':')[0]);
  int get minute => int.parse(timeOfDay.split(':')[1]);
}

class Patient {
  String? id;
  String name;
  int age;
  int patientNumber; // 1-8
  String gender;
  String createdBy; // Admin/Nurse name
  String createdByUid; // Admin/Nurse UID
  DateTime? createdAt;
  List<AlarmModel> alarms;

  Patient({
    this.id,
    required this.name,
    required this.age,
    required this.patientNumber,
    required this.gender,
    required this.createdBy,
    required this.createdByUid,
    this.createdAt,
    required this.alarms,
  });

  factory Patient.fromMap(
    Map<String, dynamic> data,
    String id,
    List<AlarmModel> alarms,
  ) {
    DateTime? created;
    if (data['createdAt'] != null) {
      created = (data['createdAt'] as Timestamp).toDate();
    }

    return Patient(
      id: id,
      name: data['name'] ?? 'Unknown',
      age: data['age'] ?? 0,
      patientNumber: data['patientNumber'] ?? 1,
      gender: data['gender'] ?? 'N/A',
      createdBy: data['createdBy'] ?? 'Unknown',
      createdByUid: data['createdByUid'] ?? '',
      createdAt: created,
      alarms: alarms,
    );
  }

  List<int> get assignedSlots => SlotMapping.getSlotsForPatient(patientNumber);
}

class HistoryRecord {
  String? id;
  String patientId;
  String patientName;
  int patientNumber;
  int age;
  String gender;
  String medicationName;
  String mealType;
  int slotNumber;
  String status; // 'taken' or 'skipped'
  DateTime actionTime;
  String adminName;
  String adminUid;

  HistoryRecord({
    this.id,
    required this.patientId,
    required this.patientName,
    required this.patientNumber,
    required this.age,
    required this.gender,
    required this.medicationName,
    required this.mealType,
    required this.slotNumber,
    required this.status,
    required this.actionTime,
    required this.adminName,
    required this.adminUid,
  });

  factory HistoryRecord.fromMap(Map<String, dynamic> data, String id) {
    return HistoryRecord(
      id: id,
      patientId: data['patientId'] ?? '',
      patientName: data['patientName'] ?? '',
      patientNumber: data['patientNumber'] ?? 0,
      age: data['age'] ?? 0,
      gender: data['gender'] ?? '',
      medicationName: data['medicationName'] ?? '',
      mealType: data['mealType'] ?? '',
      slotNumber: data['slotNumber'] ?? 0,
      status: data['status'] ?? '',
      actionTime: (data['actionTime'] as Timestamp).toDate(),
      adminName: data['adminName'] ?? '',
      adminUid: data['adminUid'] ?? '',
    );
  }
}

// ================== DATABASE SERVICE ==================

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // --- 1. Get Available Patient Number (1-8) ---
  Future<int?> getNextAvailablePatientNumber() async {
    final snapshot = await _db.collection('patients').get();
    Set<int> usedNumbers = snapshot.docs
        .map((doc) => doc.data()['patientNumber'] as int? ?? 0)
        .toSet();

    for (int i = 1; i <= 8; i++) {
      if (!usedNumbers.contains(i)) return i;
    }
    return null; // All 8 slots taken
  }

  // --- 2. Fetch All Patients ---
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
              
              if (medSnaps.docs.isNotEmpty) {
                final medData = medSnaps.docs.first.data();
                final med = Medication.fromMap(medData, medSnaps.docs.first.id);
                alarms.add(AlarmModel.fromMap(aData, aDoc.id, med));
              }
            }
            patients.add(Patient.fromMap(pData, doc.id, alarms));
          }
          return patients;
        });
  }

  // --- 3. Add Patient ---
  Future<void> addPatient(
    String name,
    int age,
    int patientNumber,
    String gender,
    String adminName,
    String adminUid,
    List<AlarmModel> alarms,
  ) async {
    DocumentReference pRef = await _db.collection('patients').add({
      'name': name,
      'age': age,
      'patientNumber': patientNumber,
      'gender': gender,
      'createdBy': adminName,
      'createdByUid': adminUid,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    for (var alarm in alarms) {
      DocumentReference aRef = await pRef.collection('alarms').add({
        'timeOfDay': alarm.timeOfDay,
        'mealType': alarm.mealType,
        'isActive': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await aRef.collection('medications').add(alarm.medication.toMap());
    }
  }

  // --- 4. Update Patient ---
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

    // Delete old alarms
    final oldAlarms = await pRef.collection('alarms').get();
    for (var doc in oldAlarms.docs) {
      final meds = await doc.reference.collection('medications').get();
      for (var m in meds.docs) await m.reference.delete();
      await doc.reference.delete();
    }

    // Add new alarms
    for (var alarm in newAlarms) {
      DocumentReference aRef = await pRef.collection('alarms').add({
        'timeOfDay': alarm.timeOfDay,
        'mealType': alarm.mealType,
        'isActive': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await aRef.collection('medications').add(alarm.medication.toMap());
    }
  }

  // --- 5. Delete Patient ---
  Future<void> deletePatient(String id) async {
    await _db.collection('patients').doc(id).delete();
  }

  // --- 6. Record Action (History + Status Update) ---
  Future<void> _recordAction(
    Patient patient,
    AlarmModel alarm,
    String status,
  ) async {
    try {
      final now = DateTime.now();
      
      // Update medication status and reduce box count if taken
      final alarmRef = _db
          .collection('patients')
          .doc(patient.id)
          .collection('alarms')
          .doc(alarm.id);
      
      final medsSnapshot = await alarmRef.collection('medications').get();
      
      for (var medDoc in medsSnapshot.docs) {
        int currentBoxes = medDoc.data()['remainingBoxes'] ?? 3;
        
        Map<String, dynamic> updateData = {
          'status': status,
          'lastActionAt': FieldValue.serverTimestamp(),
        };

        // Reduce box count if taken
        if (status == 'taken' && currentBoxes > 0) {
          updateData['remainingBoxes'] = currentBoxes - 1;
        }

        await medDoc.reference.update(updateData);
      }

      // Add to history collection
      await _db.collection('history').add({
        'patientId': patient.id,
        'patientName': patient.name,
        'patientNumber': patient.patientNumber,
        'age': patient.age,
        'gender': patient.gender,
        'medicationName': alarm.medication.name,
        'mealType': alarm.mealType,
        'slotNumber': alarm.medication.slotNumber,
        'status': status,
        'actionTime': FieldValue.serverTimestamp(),
        'adminName': patient.createdBy,
        'adminUid': patient.createdByUid,
        'date': DateFormat('yyyy-MM-dd').format(now),
      });
      
    } catch (e) {
      print("❌ Error recording action: $e");
      rethrow;
    }
  }

  Future<void> markSkipped(Patient patient, AlarmModel alarm) async {
    await _recordAction(patient, alarm, 'skipped');
  }

  Future<void> markTaken(Patient patient, AlarmModel alarm) async {
    await _recordAction(patient, alarm, 'taken');
  }

  // --- 7. Get History with Sorting ---
  Future<List<HistoryRecord>> getHistory({
    DateTime? startDate,
    DateTime? endDate,
    String sortBy = 'actionTime', // 'actionTime', 'patientName', 'patientNumber', 'adminName'
  }) async {
    Query query = _db.collection('history');

    if (startDate != null) {
      String dateStr = DateFormat('yyyy-MM-dd').format(startDate);
      query = query.where('date', isGreaterThanOrEqualTo: dateStr);
    }

    if (endDate != null) {
      String dateStr = DateFormat('yyyy-MM-dd').format(endDate);
      query = query.where('date', isLessThanOrEqualTo: dateStr);
    }

    final snapshot = await query.get();
    List<HistoryRecord> records = snapshot.docs
        .map((doc) => HistoryRecord.fromMap(doc.data() as Map<String, dynamic>, doc.id))
        .toList();

    // Sort in memory
    records.sort((a, b) {
      switch (sortBy) {
        case 'patientName':
          return a.patientName.compareTo(b.patientName);
        case 'patientNumber':
          return a.patientNumber.compareTo(b.patientNumber);
        case 'adminName':
          return a.adminName.compareTo(b.adminName);
        default:
          return b.actionTime.compareTo(a.actionTime);
      }
    });

    return records;
  }

  // --- 8. Generate PDF Report ---
  Future<void> generateHistoryReport(
    BuildContext context,
    List<HistoryRecord> records,
    String sortBy,
  ) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final String fileName = 'PillPal_History_${DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now())}.pdf';

    try {
      final pdf = pw.Document();
      
      List<List<String>> tableRows = records.map((r) {
        return [
          'P${r.patientNumber}',
          r.patientName,
          '${r.age}',
          r.gender,
          r.medicationName,
          r.mealType.toUpperCase(),
          'Slot ${r.slotNumber}',
          DateFormat('MMM dd, HH:mm').format(r.actionTime),
          r.status.toUpperCase(),
          r.adminName,
        ];
      }).toList();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          build: (pw.Context context) {
            return [
              pw.Header(
                level: 0,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'PillPal Medication History',
                      style: pw.TextStyle(
                        fontSize: 24,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromHex('1565C0')
                      )
                    ),
                    pw.SizedBox(height: 5),
                    pw.Text(
                      'Sorted by: ${sortBy.replaceAll('_', ' ').toUpperCase()}',
                      style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)
                    ),
                    pw.Text(
                      'Generated: ${DateFormat('MMMM dd, yyyy HH:mm').format(DateTime.now())}',
                      style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)
                    ),
                  ]
                )
              ),
              pw.SizedBox(height: 20),
              
              if (tableRows.isEmpty)
                pw.Center(
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.all(40),
                    child: pw.Text(
                      "No records found.",
                      style: const pw.TextStyle(fontSize: 14, color: PdfColors.grey600)
                    )
                  )
                )
              else
                pw.Table.fromTextArray(
                  headers: ['P#', 'Patient', 'Age', 'Gender', 'Medication', 'Meal', 'Slot', 'Time', 'Status', 'Admin'],
                  data: tableRows,
                  border: pw.TableBorder.all(color: PdfColors.grey300),
                  headerStyle: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.white,
                    fontSize: 9
                  ),
                  headerDecoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('1565C0')
                  ),
                  cellAlignment: pw.Alignment.centerLeft,
                  cellStyle: const pw.TextStyle(fontSize: 8),
                ),
                
              pw.SizedBox(height: 20),
              pw.Divider(),
              pw.Text(
                "Total Records: ${records.length}",
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey)
              ),
            ];
          },
        ),
      );

      // Save File
      String path;
      if (Platform.isAndroid) {
        final directory = await getExternalStorageDirectory();
        path = directory?.path ?? "";
        if (path.contains("Android")) {
          path = path.split("Android")[0] + "Download";
        }
      } else {
        final directory = await getApplicationDocumentsDirectory();
        path = directory.path;
      }
      
      final file = File('$path/$fileName');
      if (!await Directory(path).exists()) {
        await Directory(path).create(recursive: true);
      }
      await file.writeAsBytes(await pdf.save());

      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text("Report saved: $fileName"),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: 'Open',
              textColor: Colors.white,
              onPressed: () => OpenFilex.open(file.path),
            ),
          ),
        );
      }
    } catch (e) {
      print("PDF Error: $e");
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text("Error: $e"),
            backgroundColor: Colors.red
          )
        );
      }
    }
  }

  // --- 9. Refill Medication Box ---
  Future<void> refillSlot(String patientId, String alarmId, int boxCount) async {
    final medSnapshot = await _db
        .collection('patients')
        .doc(patientId)
        .collection('alarms')
        .doc(alarmId)
        .collection('medications')
        .get();

    for (var doc in medSnapshot.docs) {
      await doc.reference.update({
        'remainingBoxes': boxCount,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }
}