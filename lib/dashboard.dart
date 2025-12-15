import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final FirestoreService _db = FirestoreService();

  void _showAddPatientDialog() {
    final nameCtrl = TextEditingController();
    final ageCtrl = TextEditingController();
    final slotCtrl = TextEditingController();
    final timeCtrl = TextEditingController(text: "08:00");
    final medCtrl = TextEditingController();
    String gender = "Male";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          "Add New Patient",
          style: TextStyle(color: Color(0xFF1565C0)),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: "Name"),
              ),
              TextField(
                controller: ageCtrl,
                decoration: const InputDecoration(labelText: "Age"),
              ),
              TextField(
                controller: slotCtrl,
                decoration: const InputDecoration(
                  labelText: "Slot Number (1-24)",
                ),
              ),
              DropdownButtonFormField<String>(
                value: gender,
                items: ["Male", "Female"]
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => gender = v!,
              ),
              const Divider(),
              const Text("Initial Alarm Setup"),
              TextField(
                controller: timeCtrl,
                decoration: const InputDecoration(labelText: "Time (HH:mm)"),
              ),
              TextField(
                controller: medCtrl,
                decoration: const InputDecoration(labelText: "Medication Name"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              _db.addPatient(
                nameCtrl.text,
                int.parse(ageCtrl.text),
                slotCtrl.text,
                gender,
                timeCtrl.text,
                medCtrl.text,
              );
              Navigator.pop(ctx);
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("PillPal Admin"),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1565C0),
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: StreamBuilder<List<Patient>>(
        stream: _db.getPatients(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final patients = snapshot.data!;

          if (patients.isEmpty)
            return const Center(
              child: Text("No patients found. Add one below."),
            );

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: patients.length,
            itemBuilder: (context, index) {
              final p = patients[index];
              return Card(
                elevation: 3,
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFE3F2FD),
                    child: Text(
                      p.slotNumber,
                      style: const TextStyle(
                        color: Color(0xFF1565C0),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    p.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    "${p.age} years • ${p.gender} • ${p.alarms.length} Alarms",
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _db.deletePatient(p.id!),
                  ),
                ),
              );
            },
          );
        },
      ),
      // NAVBAR FROM MAIN-KIOSK ADAPTED
      bottomNavigationBar: BottomAppBar(
        color: const Color(0xFFE3F2FD),
        shape: const CircularNotchedRectangle(),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            // PDF Generation
            IconButton(
              icon: const Icon(Icons.picture_as_pdf, color: Color(0xFF1565C0)),
              onPressed: () async {
                final patients = await _db.getPatients().first;
                _db.generateReport(patients, context);
              },
              tooltip: "Report",
            ),
            // Add Patient
            FloatingActionButton(
              onPressed: _showAddPatientDialog,
              backgroundColor: const Color(0xFF1565C0),
              elevation: 0,
              child: const Icon(Icons.add),
            ),
            // Kiosk Mode Switch
            IconButton(
              icon: const Icon(Icons.devices, color: Color(0xFF1565C0)),
              onPressed: () => Navigator.pushNamed(context, '/kiosk'),
              tooltip: "Kiosk Mode",
            ),
          ],
        ),
      ),
    );
  }
}
