import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'services.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final FirestoreService _db = FirestoreService();
  final PageController _pageController = PageController();
  int _currentPage = 0;
  String _adminName = "Admin";
  String _adminUid = "";

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _adminUid = user.uid;
      if (user.displayName != null && user.displayName!.isNotEmpty) {
        _adminName = user.displayName!;
      }
    }
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Logout"),
        content: const Text("Are you sure you want to exit?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              FirebaseAuth.instance.signOut();
            },
            child: const Text("Logout", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showPatientDialog({Patient? patientToEdit, required List<Patient> existingPatients}) async {
    final bool isEditing = patientToEdit != null;
    
    // Get available patient number
    int? availableNum;
    if (isEditing) {
      availableNum = patientToEdit.patientNumber;
    } else {
      availableNum = await _db.getNextAvailablePatientNumber();
      if (availableNum == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Maximum 8 patients reached!"))
        );
        return;
      }
    }

    final nameCtrl = TextEditingController(text: isEditing ? patientToEdit.name : '');
    final ageCtrl = TextEditingController(text: isEditing ? patientToEdit.age.toString() : '');
    String gender = isEditing ? patientToEdit.gender : "Male";
    
    // Initialize alarms - one per meal type
    List<Map<String, dynamic>> tempAlarms = [];
    if (isEditing) {
      for (var alarm in patientToEdit.alarms) {
        tempAlarms.add({
          'time': alarm.timeOfDay,
          'mealType': alarm.mealType,
          'medication': alarm.medication,
        });
      }
    } else {
      // Default alarms for new patient
      tempAlarms = [
        {'time': '08:00', 'mealType': 'breakfast', 'medication': null},
        {'time': '13:00', 'mealType': 'lunch', 'medication': null},
        {'time': '19:00', 'mealType': 'dinner', 'medication': null},
      ];
    }

    final formKey = GlobalKey<FormState>();
    double dialogWidth = MediaQuery.of(context).size.width * 0.9;
    if (dialogWidth > 500) dialogWidth = 500;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            bool isSaving = false;

            void editMedication(int alarmIndex) {
              final currentMed = tempAlarms[alarmIndex]['medication'] as Medication?;
              final medNameCtrl = TextEditingController(text: currentMed?.name ?? '');

              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text("${tempAlarms[alarmIndex]['mealType'].toString().toUpperCase()} Medication"),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: medNameCtrl,
                        decoration: const InputDecoration(
                          labelText: "Medication Name",
                          hintText: "e.g., Aspirin 100mg"
                        ),
                        autofocus: true,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        "Slot: ${SlotMapping.getSlotForMealType(availableNum!, tempAlarms[alarmIndex]['mealType'])}",
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Cancel")
                    ),
                    ElevatedButton(
                      onPressed: () {
                        if (medNameCtrl.text.isNotEmpty) {
                          setState(() {
                            tempAlarms[alarmIndex]['medication'] = Medication(
                              name: medNameCtrl.text,
                              mealType: tempAlarms[alarmIndex]['mealType'],
                              slotNumber: SlotMapping.getSlotForMealType(
                                availableNum!,
                                tempAlarms[alarmIndex]['mealType']
                              ),
                              remainingBoxes: currentMed?.remainingBoxes ?? 3,
                            );
                          });
                          Navigator.pop(context);
                        }
                      },
                      child: const Text("Save"),
                    ),
                  ],
                ),
              );
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              insetPadding: const EdgeInsets.all(20),
              title: Text(
                isEditing ? "Edit Patient $availableNum" : "Add Patient $availableNum",
                style: const TextStyle(color: Color(0xFF1565C0))
              ),
              content: SizedBox(
                width: dialogWidth,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Patient Info
                        TextFormField(
                          controller: nameCtrl,
                          textCapitalization: TextCapitalization.words,
                          validator: (v) => v!.isEmpty ? "Required" : null,
                          decoration: const InputDecoration(
                            labelText: "Full Name",
                            prefixIcon: Icon(Icons.person)
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: ageCtrl,
                          keyboardType: TextInputType.number,
                          validator: (v) => v!.isEmpty ? "Required" : null,
                          decoration: const InputDecoration(
                            labelText: "Age",
                            prefixIcon: Icon(Icons.calendar_today)
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          value: gender,
                          decoration: const InputDecoration(
                            labelText: "Gender",
                            prefixIcon: Icon(Icons.male)
                          ),
                          items: ["Male", "Female"]
                              .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                              .toList(),
                          onChanged: (v) => gender = v!,
                        ),
                        const SizedBox(height: 10),
                        
                        // Patient Number Badge
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF1565C0))
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.badge, color: Color(0xFF1565C0)),
                              const SizedBox(width: 10),
                              Text(
                                "Patient #$availableNum",
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: Color(0xFF1565C0)
                                )
                              ),
                              const Spacer(),
                              Text(
                                "Slots: ${SlotMapping.getSlotsForPatient(availableNum!).join(', ')}",
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey
                                )
                              ),
                            ],
                          ),
                        ),
                        
                        const Divider(height: 30),
                        const Text(
                          "Medication Schedule",
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)
                        ),
                        
                        // Alarms (Breakfast, Lunch, Dinner)
                        ...tempAlarms.asMap().entries.map((entry) {
                          int index = entry.key;
                          Map<String, dynamic> alarm = entry.value;
                          Medication? med = alarm['medication'];
                          String mealType = alarm['mealType'];
                          int slotNum = SlotMapping.getSlotForMealType(availableNum!, mealType);
                          
                          IconData mealIcon = mealType == 'breakfast' 
                              ? Icons.wb_sunny 
                              : mealType == 'lunch' 
                                  ? Icons.wb_cloudy 
                                  : Icons.nightlight;
                          
                          return Card(
                            color: Colors.blue[50],
                            margin: const EdgeInsets.only(bottom: 10, top: 10),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(mealIcon, size: 20, color: const Color(0xFF1565C0)),
                                      const SizedBox(width: 8),
                                      Text(
                                        mealType.toUpperCase(),
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF1565C0)
                                        )
                                      ),
                                      const SizedBox(width: 10),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(8)
                                        ),
                                        child: Text(
                                          "Slot $slotNum",
                                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)
                                        ),
                                      ),
                                      const Spacer(),
                                      InkWell(
                                        onTap: () async {
                                          TimeOfDay? t = await showTimePicker(
                                            context: context,
                                            initialTime: TimeOfDay(
                                              hour: int.parse(alarm['time'].split(':')[0]),
                                              minute: int.parse(alarm['time'].split(':')[1])
                                            )
                                          );
                                          if (t != null) {
                                            setState(() {
                                              tempAlarms[index]['time'] = 
                                                  "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
                                            });
                                          }
                                        },
                                        child: Row(
                                          children: [
                                            const Icon(Icons.access_time, size: 16, color: Colors.grey),
                                            const SizedBox(width: 4),
                                            Text(
                                              alarm['time'],
                                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Divider(),
                                  if (med != null)
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            med.name,
                                            style: const TextStyle(fontSize: 14)
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit, size: 18),
                                          onPressed: () => editMedication(index),
                                        ),
                                      ],
                                    )
                                  else
                                    Center(
                                      child: TextButton.icon(
                                        onPressed: () => editMedication(index),
                                        icon: const Icon(Icons.add),
                                        label: const Text("Add Medication"),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Cancel")
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1565C0),
                    foregroundColor: Colors.white
                  ),
                  onPressed: isSaving ? null : () async {
                    if (formKey.currentState!.validate()) {
                      // Validate all meals have medications
                      bool allHaveMeds = tempAlarms.every((a) => a['medication'] != null);
                      if (!allHaveMeds) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Please add medication for all meals"))
                        );
                        return;
                      }

                      setState(() => isSaving = true);
                      
                      List<AlarmModel> finalAlarms = tempAlarms.map((a) {
                        return AlarmModel(
                          timeOfDay: a['time'],
                          mealType: a['mealType'],
                          isActive: true,
                          medication: a['medication'],
                        );
                      }).toList();

                      try {
                        if (isEditing) {
                          await _db.updatePatient(
                            patientToEdit!,
                            nameCtrl.text,
                            int.parse(ageCtrl.text),
                            gender,
                            finalAlarms
                          );
                        } else {
                          await _db.addPatient(
                            nameCtrl.text,
                            int.parse(ageCtrl.text),
                            availableNum!,
                            gender,
                            _adminName,
                            _adminUid,
                            finalAlarms
                          );
                        }
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(isEditing ? "Updated" : "Added successfully"),
                              backgroundColor: Colors.green
                            )
                          );
                        }
                      } catch (e) {
                        setState(() => isSaving = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red)
                          );
                        }
                      }
                    }
                  },
                  child: isSaving 
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(isEditing ? "Update" : "Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _confirmDelete(String id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Patient"),
        content: Text("Are you sure you want to remove $name?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white
            ),
            onPressed: () {
              _db.deletePatient(id);
              Navigator.pop(ctx);
            },
            child: const Text("Delete"),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsPage(List<Patient> patients) {
    int totalPatients = patients.length;
    int skippedCount = 0;
    int takenCount = 0;
    int pendingCount = 0;
    int refillNeeded = 0;

    for (var p in patients) {
      for (var a in p.alarms) {
        if (a.medication.status == 'skipped') skippedCount++;
        else if (a.medication.status == 'taken') takenCount++;
        else pendingCount++;
        
        if (a.medication.needsRefill()) refillNeeded++;
      }
    }

    bool isEmpty = (skippedCount == 0 && takenCount == 0 && pendingCount == 0);

    List<PieChartSectionData> sections;
    if (isEmpty) {
      sections = [
        PieChartSectionData(
          value: 1,
          color: Colors.grey[300],
          radius: 30,
          showTitle: false
        )
      ];
    } else {
      sections = [
        PieChartSectionData(value: takenCount.toDouble(), color: Colors.green, radius: 30, showTitle: false),
        PieChartSectionData(value: skippedCount.toDouble(), color: Colors.orange, radius: 30, showTitle: false),
        PieChartSectionData(value: pendingCount.toDouble(), color: Colors.grey[300], radius: 25, showTitle: false),
      ];
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Overview",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87)
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1565C0), Color(0xFF64B5F6)]
              ),
              borderRadius: BorderRadius.circular(20)
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Welcome back,",
                  style: TextStyle(color: Colors.white70, fontSize: 16)
                ),
                Text(
                  _adminName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold
                  )
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12)
                      ),
                      child: const Icon(Icons.people, color: Colors.white)
                    ),
                    const SizedBox(width: 15),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "$totalPatients / 8",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold
                          )
                        ),
                        const Text(
                          "Patients",
                          style: TextStyle(color: Colors.white70)
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          if (refillNeeded > 0) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red[300]!)
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "$refillNeeded slot(s) need refill",
                      style: const TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold
                      )
                    ),
                  ),
                  TextButton(
                    onPressed: () => _pageController.animateToPage(
                      2,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut
                    ),
                    child: const Text("VIEW"),
                  ),
                ],
              ),
            ),
          ],
          
          const SizedBox(height: 30),
          const Text(
            "Medication Status",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
          ),
          const SizedBox(height: 20),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: isEmpty ? 0 : 2,
                      centerSpaceRadius: 40,
                      sections: sections,
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLegendItem(Colors.green, "Taken ($takenCount)"),
                    const SizedBox(height: 10),
                    _buildLegendItem(Colors.orange, "Skipped ($skippedCount)"),
                    const SizedBox(height: 10),
                    _buildLegendItem(Colors.grey[300]!, "Pending ($pendingCount)"),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(Color color, String text) {
    return Row(
      children: [
        CircleAvatar(radius: 6, backgroundColor: color),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildPatientsPage(List<Patient> patients) {
    if (patients.isEmpty) {
      return const Center(
        child: Text("No patients found.\nTap + to add your first patient.")
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      itemCount: patients.length,
      itemBuilder: (context, index) {
        final p = patients[index];
        int refillCount = p.alarms.where((a) => a.medication.needsRefill()).length;
        
        return Card(
          elevation: 2,
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: CircleAvatar(
              radius: 25,
              backgroundColor: const Color(0xFFE3F2FD),
              child: Text(
                "P${p.patientNumber}",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1565C0)
                )
              ),
            ),
            title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("${p.age} yrs • ${p.gender} • ${p.alarms.length} Alarms"),
                Text(
                  "Created by: ${p.createdBy}",
                  style: const TextStyle(fontSize: 11, color: Colors.grey)
                ),
                if (refillCount > 0)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red[100],
                      borderRadius: BorderRadius.circular(8)
                    ),
                    child: Text(
                      "⚠ $refillCount slot(s) need refill",
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.red,
                        fontWeight: FontWeight.bold
                      )
                    ),
                  ),
              ],
            ),
            onTap: () => _showPatientDialog(patientToEdit: p, existingPatients: patients),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _confirmDelete(p.id!, p.name)
            ),
          ),
        );
      },
    );
  }

  Widget _buildRefillPage(List<Patient> patients) {
    // Collect all medications that need refill
    List<Map<String, dynamic>> refillItems = [];
    
    for (var p in patients) {
      for (var a in p.alarms) {
        if (a.medication.remainingBoxes <= 1) {
          refillItems.add({
            'patient': p,
            'alarm': a,
            'medication': a.medication,
          });
        }
      }
    }

    if (refillItems.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, size: 80, color: Colors.green),
            SizedBox(height: 20),
            Text(
              "All slots are stocked!",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: refillItems.length,
      itemBuilder: (context, index) {
        final item = refillItems[index];
        final Patient p = item['patient'];
        final AlarmModel a = item['alarm'];
        final Medication m = item['medication'];

        return Card(
          color: m.remainingBoxes == 0 ? Colors.red[50] : Colors.orange[50],
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: m.remainingBoxes == 0 ? Colors.red : Colors.orange,
              child: Text(
                "P${p.patientNumber}",
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
              ),
            ),
            title: Text(
              "${p.name} - ${m.name}",
              style: const TextStyle(fontWeight: FontWeight.bold)
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("${a.mealType.toUpperCase()} • Slot ${m.slotNumber}"),
                Text(
                  "Remaining: ${m.remainingBoxes}/3 boxes",
                  style: TextStyle(
                    color: m.remainingBoxes == 0 ? Colors.red : Colors.orange,
                    fontWeight: FontWeight.bold
                  )
                ),
              ],
            ),
            trailing: ElevatedButton(
              onPressed: () async {
                await _db.refillSlot(p.id!, a.id!, 3);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Slot refilled!"),
                    backgroundColor: Colors.green
                  )
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white
              ),
              child: const Text("Refill"),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Patient>>(
      stream: _db.getPatients(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final patients = snapshot.data!;

        return Scaffold(
          backgroundColor: const Color(0xFFF5F9FF),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            title: const Text(
              "PillPal Admin",
              style: TextStyle(
                color: Color(0xFF1565C0),
                fontWeight: FontWeight.bold
              )
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.history, color: Colors.grey),
                onPressed: () => Navigator.pushNamed(context, '/history')
              ),
              IconButton(
                icon: const Icon(Icons.logout, color: Colors.grey),
                onPressed: _confirmLogout
              ),
            ],
          ),
          body: PageView(
            controller: _pageController,
            onPageChanged: (idx) => setState(() => _currentPage = idx),
            children: [
              _buildStatsPage(patients),
              _buildPatientsPage(patients),
              _buildRefillPage(patients),
            ],
          ),
          floatingActionButton: _currentPage == 1
              ? FloatingActionButton(
                  onPressed: () => _showPatientDialog(existingPatients: patients),
                  backgroundColor: const Color(0xFF1565C0),
                  child: const Icon(Icons.add, color: Colors.white)
                )
              : null,
          bottomNavigationBar: BottomAppBar(
            height: 60,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.dashboard,
                    color: _currentPage == 0 ? const Color(0xFF1565C0) : Colors.grey
                  ),
                  onPressed: () => _pageController.animateToPage(
                    0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut
                  )
                ),
                IconButton(
                  icon: Icon(
                    Icons.people,
                    color: _currentPage == 1 ? const Color(0xFF1565C0) : Colors.grey
                  ),
                  onPressed: () => _pageController.animateToPage(
                    1,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut
                  )
                ),
                IconButton(
                  icon: Icon(
                    Icons.inventory_2,
                    color: _currentPage == 2 ? const Color(0xFF1565C0) : Colors.grey
                  ),
                  onPressed: () => _pageController.animateToPage(
                    2,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut
                  )
                ),
                IconButton(
                  icon: const Icon(Icons.devices, color: Colors.grey),
                  onPressed: () => Navigator.pushNamed(context, '/kiosk')
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}