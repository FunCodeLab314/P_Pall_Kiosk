import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'services.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final FirestoreService _db = FirestoreService();
  List<HistoryRecord> _records = [];
  bool _loading = true;
  
  DateTime? _startDate;
  DateTime? _endDate;
  String _sortBy = 'actionTime';
  
  final Map<String, String> _sortOptions = {
    'actionTime': 'Date & Time',
    'patientName': 'Patient Name',
    'patientNumber': 'Patient Number',
    'adminName': 'Admin/Nurse',
  };

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _loading = true);
    try {
      final records = await _db.getHistory(
        startDate: _startDate,
        endDate: _endDate,
        sortBy: _sortBy,
      );
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error loading history: $e"))
      );
    }
  }

  Future<void> _selectDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _loadHistory();
    }
  }

  void _clearDateFilter() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _loadHistory();
  }

  void _changeSortOrder() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Sort By"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _sortOptions.entries.map((entry) {
            return RadioListTile<String>(
              title: Text(entry.value),
              value: entry.key,
              groupValue: _sortBy,
              onChanged: (value) {
                Navigator.pop(ctx);
                setState(() => _sortBy = value!);
                _loadHistory();
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _generatePDF() {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No records to export"))
      );
      return;
    }

    _db.generateHistoryReport(context, _records, _sortOptions[_sortBy]!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F9FF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          "Medication History",
          style: TextStyle(color: Color(0xFF1565C0), fontWeight: FontWeight.bold)
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF1565C0)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf, color: Colors.red),
            tooltip: "Export PDF",
            onPressed: _generatePDF,
          ),
        ],
      ),
      body: Column(
        children: [
          // Filters Section
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _selectDateRange,
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          _startDate != null && _endDate != null
                              ? "${DateFormat('MMM dd').format(_startDate!)} - ${DateFormat('MMM dd').format(_endDate!)}"
                              : "Select Date Range",
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    if (_startDate != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.clear, color: Colors.red),
                        onPressed: _clearDateFilter,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _changeSortOrder,
                  icon: const Icon(Icons.sort),
                  label: Text("Sort by: ${_sortOptions[_sortBy]}"),
                ),
              ],
            ),
          ),
          
          const Divider(height: 1),
          
          // Records Count
          if (!_loading)
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.blue[50],
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 18, color: Color(0xFF1565C0)),
                  const SizedBox(width: 8),
                  Text(
                    "${_records.length} record(s) found",
                    style: const TextStyle(fontWeight: FontWeight.bold)
                  ),
                ],
              ),
            ),
          
          // Records List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? const Center(
                        child: Text("No history records found.")
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _records.length,
                        itemBuilder: (context, index) {
                          final record = _records[index];
                          return _buildHistoryCard(record);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(HistoryRecord record) {
    Color statusColor = record.status == 'taken' ? Colors.green : Colors.orange;
    IconData statusIcon = record.status == 'taken' ? Icons.check_circle : Icons.cancel;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFFE3F2FD),
                  child: Text(
                    "P${record.patientNumber}",
                    style: const TextStyle(
                      color: Color(0xFF1565C0),
                      fontWeight: FontWeight.bold,
                      fontSize: 12
                    )
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.patientName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16
                        )
                      ),
                      Text(
                        "${record.age} yrs • ${record.gender}",
                        style: const TextStyle(fontSize: 12, color: Colors.grey)
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor)
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 14, color: statusColor),
                      const SizedBox(width: 4),
                      Text(
                        record.status.toUpperCase(),
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 11
                        )
                      ),
                    ],
                  ),
                ),
              ],
            ),
            
            const Divider(height: 20),
            
            Row(
              children: [
                Expanded(
                  child: _buildInfoRow(
                    Icons.medication,
                    record.medicationName,
                    Colors.blue
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            Row(
              children: [
                Expanded(
                  child: _buildInfoRow(
                    _getMealIcon(record.mealType),
                    record.mealType.toUpperCase(),
                    Colors.orange
                  ),
                ),
                Expanded(
                  child: _buildInfoRow(
                    Icons.grid_view,
                    "Slot ${record.slotNumber}",
                    Colors.purple
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            Row(
              children: [
                Expanded(
                  child: _buildInfoRow(
                    Icons.access_time,
                    DateFormat('MMM dd, HH:mm').format(record.actionTime),
                    Colors.grey
                  ),
                ),
                Expanded(
                  child: _buildInfoRow(
                    Icons.person_outline,
                    record.adminName,
                    Colors.teal
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String text, Color color) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  IconData _getMealIcon(String mealType) {
    switch (mealType.toLowerCase()) {
      case 'breakfast':
        return Icons.wb_sunny;
      case 'lunch':
        return Icons.wb_cloudy;
      case 'dinner':
        return Icons.nightlight;
      default:
        return Icons.restaurant;
    }
  }
}