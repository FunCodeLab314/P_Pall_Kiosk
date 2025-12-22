import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'services.dart';
import 'main.dart'; // To access flutterLocalNotificationsPlugin

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
  Set<String> _notifiedSlots = {}; // To prevent spamming notifications for the same low slot

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user?.displayName != null && user!.displayName!.isNotEmpty) {
      _adminName = user.displayName!;
    }
  }

  // --- REFILL & NOTIFICATION LOGIC ---
  void _checkInventoryLevels(List<Patient> patients) {
    for (var p in patients) {
      p.slotInventory.forEach((slot, count) {
        String key = "${p.id}_$slot";
        
        // If Low Stock (<= 1) and not yet notified this session
        if (count <= 1 && !_notifiedSlots.contains(key)) {
          _showLowStockNotification(p.name, slot, count);
          _notifiedSlots.add(key);
        } 
        // If refilled (count > 1), remove from notified set so we can notify again later
        else if (count > 1 && _notifiedSlots.contains(key)) {
          _notifiedSlots.remove(key);
        }
      });
    }
  }

  Future<void> _showLowStockNotification(String pName, String slot, int count) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'refill_channel', 'Refill Alerts',
      importance: Importance.high,
      priority: Priority.high,
      color: Colors.red,
      playSound: true,
    );
    const NotificationDetails details = NotificationDetails(android: androidDetails);
    
    // Only send to the device where this admin is logged in (implicit by running on this device)
    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecond,
      "Refill Warning!",
      "Slot $slot for $pName is low ($count boxes left). Please refill.",
      details,
    );
  }

  void _showRefillDialog(List<Patient> patients) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.inventory, color: Color(0xFF1565C0)), SizedBox(width: 10), Text("Inventory Management")]),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: patients.length,
            itemBuilder: (context, index) {
              final p = patients[index];
              return ExpansionTile(
                title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text("Patient #${p.patientNumber}"),
                children: p.slotInventory.entries.map((entry) {
                  String slot = entry.key;
                  int count = entry.value;
                  bool isLow = count <= 1;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isLow ? Colors.red : Colors.green,
                      child: Icon(isLow ? Icons.warning : Icons.check, color: Colors.white, size: 16),
                    ),
                    title: Text("Slot $slot"),
                    subtitle: Text(isLow ? "Low Stock!" : "Healthy"),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text("$count/3 Boxes", style: TextStyle(color: isLow ? Colors.red : Colors.black, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: () {
                             _db.refillSlot(p.id!, slot);
                             Navigator.pop(ctx);
                             ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Slot $slot refilled for ${p.name}!")));
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1565C0), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 10)),
                          child: const Text("Refill"),
                        )
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close"))],
      ),
    );
  }

  // --- DIALOGS & NAVIGATION ---

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Logout"),
        content: const Text("Are you sure you want to exit?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          TextButton(onPressed: () {
            Navigator.pop(ctx);
            FirebaseAuth.instance.signOut();
          }, child: const Text("Logout", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

  void _openHistoryScreen() {
    Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => HistoryScreen(db: _db)));
  }

  void _showPatientDialog({Patient? patientToEdit}) {
    final bool isEditing = patientToEdit != null;
    final nameCtrl = TextEditingController(text: isEditing ? patientToEdit.name : '');
    final ageCtrl = TextEditingController(text: isEditing ? patientToEdit.age.toString() : '');
    String gender = isEditing ? patientToEdit.gender : "Male";
    
    List<Map<String, dynamic>> tempAlarms = [];
    if (isEditing) {
      for (var alarm in patientToEdit.alarms) {
        tempAlarms.add({
          'time': alarm.timeOfDay,
          'type': alarm.type,
          'meds': alarm.medications.map((m) => m.name).toList(),
        });
      }
    }

    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            bool isSaving = false;

            // --- KEY LOGIC UPDATE FOR UI DISPLAY ---
            String getSlotForType(String type, int pNum) {
               if (!isEditing && pNum == 0) return "Auto-Assigned";
               
               if (pNum <= 4) {
                 if (type == 'Breakfast') return pNum.toString();
                 if (type == 'Lunch') return (pNum + 4).toString();
                 if (type == 'Dinner') return (pNum + 8).toString();
               } else {
                 if (type == 'Breakfast') return (pNum + 8).toString();
                 if (type == 'Lunch') return (pNum + 12).toString();
                 if (type == 'Dinner') return (pNum + 16).toString();
               }
               return "-";
            }

            void addAlarm() {
               setState(() => tempAlarms.add({'time': '08:00', 'type': 'Breakfast', 'meds': <String>[]}));
            }

            void addMedication(int alarmIndex) {
               TextEditingController medInput = TextEditingController();
               showDialog(
                 context: context,
                 builder: (c) => AlertDialog(
                   title: const Text("Add Medication"),
                   content: TextField(controller: medInput, decoration: const InputDecoration(hintText: "Med Name")),
                   actions: [
                     TextButton(onPressed: () => Navigator.pop(c), child: const Text("Cancel")),
                     ElevatedButton(onPressed: () {
                       if (medInput.text.isNotEmpty) {
                         setState(() => tempAlarms[alarmIndex]['meds'].add(medInput.text));
                         Navigator.pop(c);
                       }
                     }, child: const Text("Add"))
                   ],
                 )
               );
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Text(isEditing ? "Edit Patient" : "Add Patient", style: const TextStyle(color: Color(0xFF1565C0))),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: nameCtrl,
                          textCapitalization: TextCapitalization.words,
                          validator: (v) => v!.isEmpty ? "Required" : null,
                          decoration: const InputDecoration(labelText: "Full Name", prefixIcon: Icon(Icons.person)),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: ageCtrl,
                          keyboardType: TextInputType.number,
                          validator: (v) => v!.isEmpty ? "Required" : null,
                          decoration: const InputDecoration(labelText: "Age", prefixIcon: Icon(Icons.calendar_today)),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          value: gender,
                          decoration: const InputDecoration(labelText: "Gender", prefixIcon: Icon(Icons.male)),
                          items: ["Male", "Female"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                          onChanged: (v) => gender = v!,
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(8)),
                          child: Text(isEditing 
                            ? "Patient #${patientToEdit!.patientNumber} - Assigned Slots: ${patientToEdit.assignedSlots}"
                            : "Patient Number & Slots will be auto-assigned (1-8) upon saving.",
                            style: const TextStyle(fontSize: 12, color: Colors.black54)
                          ),
                        ),
                        const Divider(height: 30),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text("Alarms", style: TextStyle(fontWeight: FontWeight.bold)),
                          IconButton(onPressed: addAlarm, icon: const Icon(Icons.add_circle, color: Color(0xFF1565C0))),
                        ]),
                        ...tempAlarms.asMap().entries.map((entry) {
                          int index = entry.key;
                          Map<String, dynamic> alarm = entry.value;
                          return Card(
                            elevation: 0,
                            color: Colors.blue[50],
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Column(
                                children: [
                                  Row(children: [
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        value: alarm['type'],
                                        items: ["Breakfast", "Lunch", "Dinner"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                                        onChanged: (v) => setState(() => alarm['type'] = v),
                                        decoration: const InputDecoration(labelText: "Meal/Type", isDense: true, border: InputBorder.none),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    InkWell(
                                      onTap: () async {
                                        TimeOfDay? t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 8, minute: 0));
                                        if (t != null) {
                                          String h = t.hour.toString().padLeft(2, '0');
                                          String m = t.minute.toString().padLeft(2, '0');
                                          setState(() => alarm['time'] = "$h:$m");
                                        }
                                      },
                                      child: Text(alarm['time'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF1565C0))),
                                    ),
                                    IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => setState(() => tempAlarms.removeAt(index))),
                                  ]),
                                  const Divider(),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text("Target Slot: ${getSlotForType(alarm['type'], isEditing ? patientToEdit!.patientNumber : 0)}", style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(height: 5),
                                  Wrap(spacing: 6, children: [
                                    ...(alarm['meds'] as List<String>).map((m) => Chip(label: Text(m), backgroundColor: Colors.white, onDeleted: () => setState(() => (alarm['meds'] as List<String>).remove(m)))),
                                    ActionChip(label: const Text("+ Med"), backgroundColor: Colors.white, onPressed: () => addMedication(index)),
                                  ])
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
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: isSaving ? null : () async {
                    if (formKey.currentState!.validate()) {
                      setState(() => isSaving = true);
                      List<AlarmModel> finalAlarms = tempAlarms.map((a) {
                        return AlarmModel(
                          timeOfDay: a['time'],
                          type: a['type'],
                          isActive: true,
                          medications: (a['meds'] as List<String>).map((mName) => Medication(name: mName)).toList(),
                        );
                      }).toList();

                      try {
                        if (isEditing) {
                          await _db.updatePatient(patientToEdit!, nameCtrl.text, int.parse(ageCtrl.text), gender, finalAlarms);
                        } else {
                          await _db.addPatient(nameCtrl.text, int.parse(ageCtrl.text), gender, _adminName, finalAlarms);
                        }
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Saved Successfully"), backgroundColor: Colors.green));
                        }
                      } catch (e) {
                        setState(() => isSaving = false);
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1565C0), foregroundColor: Colors.white),
                  child: isSaving ? const CircularProgressIndicator(color: Colors.white) : const Text("Save"),
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
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
    // Check inventory levels every time the stats page rebuilds (or updates)
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkInventoryLevels(patients));

    int takenCount = 0;
    int skippedCount = 0;
    int pendingCount = 0;
    
    for (var p in patients) {
      for (var a in p.alarms) {
        for (var m in a.medications) {
           if (m.status == 'taken') takenCount++;
           else if (m.status == 'skipped') skippedCount++;
           else pendingCount++;
        }
      }
    }
    bool isEmpty = (takenCount + skippedCount + pendingCount) == 0;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Overview", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              // Refill Button
              IconButton(onPressed: () => _showRefillDialog(patients), icon: const Icon(Icons.inventory, color: Color(0xFF1565C0), size: 30)),
            ],
          ),
          const SizedBox(height: 20),
          Container(
             width: double.infinity,
             padding: const EdgeInsets.all(20),
             decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF64B5F6)]), borderRadius: BorderRadius.circular(20)),
             child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
               const Text("Welcome back,", style: TextStyle(color: Colors.white70)),
               Text(_adminName, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
               const SizedBox(height: 10),
               Text("Patients: ${patients.length}/8", style: const TextStyle(color: Colors.white, fontSize: 16)),
             ]),
          ),
          const SizedBox(height: 30),
          Expanded(
            child: isEmpty ? const Center(child: Text("No Data Available")) : PieChart(
              PieChartData(
                sections: [
                   PieChartSectionData(value: takenCount.toDouble(), color: Colors.green, radius: 30, showTitle: false),
                   PieChartSectionData(value: skippedCount.toDouble(), color: Colors.orange, radius: 30, showTitle: false),
                   PieChartSectionData(value: pendingCount.toDouble(), color: Colors.grey[300], radius: 25, showTitle: false),
                ],
                centerSpaceRadius: 40,
              )
            ),
          ),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
             CircleAvatar(radius: 6, backgroundColor: Colors.green), const SizedBox(width: 5), Text("Taken ($takenCount)"), const SizedBox(width: 15),
             CircleAvatar(radius: 6, backgroundColor: Colors.orange), const SizedBox(width: 5), Text("Skipped ($skippedCount)"),
          ]),
        ],
      ),
    );
  }

  Widget _buildPatientsPage(List<Patient> patients) {
    if (patients.isEmpty) return const Center(child: Text("No patients found."));
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: patients.length,
      itemBuilder: (context, index) {
        final p = patients[index];
        return Card(
          elevation: 2,
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: CircleAvatar(radius: 25, backgroundColor: const Color(0xFFE3F2FD), child: Text("${p.patientNumber}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Color(0xFF1565C0)))),
            title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Age: ${p.age} • ${p.gender}"),
                Text("Assigned Slots: ${p.assignedSlots}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text("Created By: ${p.createdBy}", style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
              ],
            ),
            trailing: IconButton(icon: const Icon(Icons.edit, color: Colors.grey), onPressed: () => _showPatientDialog(patientToEdit: p)),
            onLongPress: () => _confirmDelete(p.id!, p.name),
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
        if (!snapshot.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final patients = snapshot.data!;

        return Scaffold(
          backgroundColor: const Color(0xFFF5F9FF),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            title: const Text("PillPal Admin", style: TextStyle(color: Color(0xFF1565C0), fontWeight: FontWeight.bold)),
            actions: [
              IconButton(icon: const Icon(Icons.history, color: Colors.grey), onPressed: _openHistoryScreen),
              IconButton(icon: const Icon(Icons.logout, color: Colors.grey), onPressed: _confirmLogout),
            ],
          ),
          body: PageView(
            controller: _pageController,
            onPageChanged: (idx) => setState(() => _currentPage = idx),
            children: [
              _buildStatsPage(patients),
              _buildPatientsPage(patients),
            ],
          ),
          floatingActionButton: _currentPage == 1
              ? FloatingActionButton(onPressed: () => _showPatientDialog(), backgroundColor: const Color(0xFF1565C0), child: const Icon(Icons.add, color: Colors.white))
              : null,
          bottomNavigationBar: BottomAppBar(
             height: 60,
             child: Row(
               mainAxisAlignment: MainAxisAlignment.spaceAround,
               children: [
                 IconButton(icon: Icon(Icons.dashboard, color: _currentPage == 0 ? const Color(0xFF1565C0) : Colors.grey), onPressed: () => _pageController.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut)),
                 IconButton(icon: Icon(Icons.people, color: _currentPage == 1 ? const Color(0xFF1565C0) : Colors.grey), onPressed: () => _pageController.animateToPage(1, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut)),
                 IconButton(icon: const Icon(Icons.devices, color: Colors.grey), onPressed: () => Navigator.pushNamed(context, '/kiosk')),
               ],
             ),
          ),
        );
      },
    );
  }
}

// ================== NEW HISTORY SCREEN ==================

class HistoryScreen extends StatefulWidget {
  final FirestoreService db;
  const HistoryScreen({super.key, required this.db});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  DateTime _selectedDate = DateTime.now();
  List<HistoryRecord> _records = [];
  bool _isLoading = true;
  String _sortColumn = 'Time';
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  void _fetchHistory() async {
    setState(() => _isLoading = true);
    final data = await widget.db.getHistory(_selectedDate);
    setState(() {
      _records = data;
      _sortRecords();
      _isLoading = false;
    });
  }

  void _sortRecords() {
    _records.sort((a, b) {
      int cmp = 0;
      switch (_sortColumn) {
        case 'Patient Name': cmp = a.patientName.compareTo(b.patientName); break;
        case 'Patient No.': cmp = a.patientNumber.compareTo(b.patientNumber); break;
        case 'Time': cmp = a.actionTime.compareTo(b.actionTime); break;
        case 'Admin': cmp = a.adminName.compareTo(b.adminName); break;
      }
      return _sortAsc ? cmp : -cmp;
    });
  }

  void _onSort(String column) {
    if (_sortColumn == column) {
      setState(() {
        _sortAsc = !_sortAsc;
        _sortRecords();
      });
    } else {
      setState(() {
        _sortColumn = column;
        _sortAsc = true;
        _sortRecords();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Medication History", style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: () => widget.db.generatePdfReport(_records, context, _selectedDate),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Colors.grey[100],
            child: Row(children: [
              const Text("Date: ", style: TextStyle(fontWeight: FontWeight.bold)),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(DateFormat('yyyy-MM-dd').format(_selectedDate)),
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: _selectedDate, firstDate: DateTime(2024), lastDate: DateTime.now());
                  if (d != null) {
                    setState(() => _selectedDate = d);
                    _fetchHistory();
                  }
                },
              ),
              const Spacer(),
              const Text("Sort by: ", style: TextStyle(fontSize: 12)),
              DropdownButton<String>(
                value: _sortColumn,
                style: const TextStyle(fontSize: 12, color: Colors.black),
                items: ['Patient Name', 'Patient No.', 'Time', 'Admin'].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => _onSort(v!),
              )
            ]),
          ),
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator()) 
              : _records.isEmpty 
                  ? const Center(child: Text("No records found for this date."))
                  : SingleChildScrollView(
                      scrollDirection: Axis.vertical,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          sortColumnIndex: ['Patient Name', 'Patient No.', 'Medication', 'Time', 'Status', 'Slot', 'Admin'].indexOf(_sortColumn) == -1 ? 3 : ['Patient Name', 'Patient No.', 'Medication', 'Time', 'Status', 'Slot', 'Admin'].indexOf(_sortColumn),
                          sortAscending: _sortAsc,
                          headingRowColor: MaterialStateProperty.all(Colors.blue[50]),
                          columns: [
                            DataColumn(label: const Text("Patient"), onSort: (_,__) => _onSort('Patient Name')),
                            DataColumn(label: const Text("No."), numeric: true, onSort: (_,__) => _onSort('Patient No.')),
                            const DataColumn(label: Text("Medication")),
                            DataColumn(label: const Text("Time"), onSort: (_,__) => _onSort('Time')),
                            const DataColumn(label: Text("Status")),
                            const DataColumn(label: Text("Slot")),
                            DataColumn(label: const Text("Admin"), onSort: (_,__) => _onSort('Admin')),
                          ],
                          rows: _records.map((r) => DataRow(cells: [
                            DataCell(Text(r.patientName)),
                            DataCell(Text(r.patientNumber.toString())),
                            DataCell(Text(r.medicationName)),
                            DataCell(Text(DateFormat('HH:mm').format(r.actionTime))),
                            DataCell(Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: r.status == 'taken' ? Colors.green[100] : Colors.orange[100], borderRadius: BorderRadius.circular(12)),
                              child: Text(r.status.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: r.status == 'taken' ? Colors.green[800] : Colors.orange[800]))
                            )),
                            DataCell(Text(r.slot)),
                            DataCell(Text(r.adminName, style: const TextStyle(fontStyle: FontStyle.italic))),
                          ])).toList(),
                        ),
                      ),
                    ),
          ),
        ],
      ),
    );
  }
}