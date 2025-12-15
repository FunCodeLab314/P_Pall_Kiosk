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

  Medication({this.id, required this.name, this.status = 'pending'});

  factory Medication.fromMap(Map<String, dynamic> data, String id) {
    return Medication(
      id: id,
      name: data['name'] ?? '',
      status: data['status'] ?? 'pending',
    );
  }
  Map<String, dynamic> toJson() => {'name': name, 'status': status};
}

class AlarmModel {
  String? id;
  String timeOfDay; // Format "HH:mm"
  bool isActive;
  List<Medication> medications;

  AlarmModel({
    this.id,
    required this.timeOfDay,
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
      isActive: data['isActive'] ?? true,
      medications: meds,
    );
  }
  // Helpers for logic
  int get hour => int.parse(timeOfDay.split(':')[0]);
  int get minute => int.parse(timeOfDay.split(':')[1]);
}

class Patient {
  String? id;
  String name;
  int age;
  String slotNumber;
  String gender;
  List<AlarmModel> alarms;

  Patient({
    this.id,
    required this.name,
    required this.age,
    required this.slotNumber,
    required this.gender,
    required this.alarms,
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
      slotNumber: data['slotNumber']?.toString() ?? '0',
      gender: data['gender'] ?? 'N/A',
      alarms: alarms,
    );
  }
}

// ================== DATABASE SERVICE ==================

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // --- 1. Fetch All Data (Realtime) ---
  Stream<List<Patient>> getPatients() {
    return _db.collection('patients').snapshots().asyncMap((snapshot) async {
      List<Patient> patients = [];
      for (var doc in snapshot.docs) {
        final pData = doc.data();

        // Get Alarms
        final alarmSnaps = await doc.reference.collection('alarms').get();
        List<AlarmModel> alarms = [];

        for (var aDoc in alarmSnaps.docs) {
          final aData = aDoc.data();
          // Get Medications
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

  // --- 2. Add Data ---
  Future<void> addPatient(
    String name,
    int age,
    String slot,
    String gender,
    String alarmTime,
    String medName,
  ) async {
    // Add Patient
    DocumentReference pRef = await _db.collection('patients').add({
      'name': name,
      'age': age,
      'slotNumber': slot,
      'gender': gender,
      'lastUpdatedBy': 'KioskAdmin',
    });

    // Add Alarm
    DocumentReference aRef = await pRef.collection('alarms').add({
      'timeOfDay': alarmTime,
      'isActive': true,
    });

    // Add Medication
    await aRef.collection('medications').add({
      'name': medName,
      'status': 'pending',
    });
  }

  // --- 3. Delete Data ---
  Future<void> deletePatient(String id) async {
    await _db.collection('patients').doc(id).delete();
  }

  // --- 4. Special Kiosk Logic: Mark Skipped ---
  Future<void> markSkipped(
    String patientId,
    String alarmId,
    List<Medication> meds,
  ) async {
    final now = DateTime.now().toIso8601String();
    for (var med in meds) {
      if (med.id != null) {
        await _db
            .collection('patients')
            .doc(patientId)
            .collection('alarms')
            .doc(alarmId)
            .collection('medications')
            .doc(med.id)
            .update({'status': 'skipped', 'lastSkippedAt': now});
      }
    }
  }

  // --- 5. PDF Generation (From Main-Kiosk) ---
  Future<void> generateReport(
    List<Patient> patients,
    BuildContext context,
  ) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(
                level: 0,
                child: pw.Text(
                  'PillPal Patient Report',
                  style: pw.TextStyle(fontSize: 24),
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Table.fromTextArray(
                context: context,
                border: pw.TableBorder.all(),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.grey300,
                ),
                headers: ['Slot', 'Name', 'Age', 'Gender', 'Alarms'],
                data: patients
                    .map(
                      (p) => [
                        p.slotNumber,
                        p.name,
                        p.age.toString(),
                        p.gender,
                        p.alarms.length.toString(),
                      ],
                    )
                    .toList(),
              ),
            ],
          );
        },
      ),
    );

    try {
      final output = await getApplicationDocumentsDirectory();
      final file = File("${output.path}/PillPal_Report.pdf");
      await file.writeAsBytes(await pdf.save());

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("PDF Generated! Opening...")),
      );
      await OpenFilex.open(file.path);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }
}
