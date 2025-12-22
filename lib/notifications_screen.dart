import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<List<NotificationItem>> _getNotifications() {
    return _db
        .collection('notifications')
        .orderBy('timestamp', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        return NotificationItem(
          id: doc.id,
          title: data['title'] ?? '',
          body: data['body'] ?? '',
          type: data['type'] ?? 'info', // 'medication', 'refill', 'info'
          timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
          isRead: data['isRead'] ?? false,
        );
      }).toList();
    });
  }

  Future<void> _markAsRead(String id) async {
    await _db.collection('notifications').doc(id).update({'isRead': true});
  }

  Future<void> _clearAll() async {
    final batch = _db.batch();
    final docs = await _db.collection('notifications').get();
    for (var doc in docs.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F9FF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          "Notifications",
          style: TextStyle(
            color: Color(0xFF1565C0),
            fontWeight: FontWeight.bold
          )
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF1565C0)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: Colors.red),
            tooltip: "Clear All",
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("Clear All Notifications"),
                  content: const Text("Are you sure you want to clear all notifications?"),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text("Cancel")
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white
                      ),
                      onPressed: () {
                        _clearAll();
                        Navigator.pop(ctx);
                      },
                      child: const Text("Clear"),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<List<NotificationItem>>(
        stream: _getNotifications(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 80,
                    color: Colors.grey
                  ),
                  SizedBox(height: 20),
                  Text(
                    "No notifications yet",
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey
                    )
                  ),
                ],
              ),
            );
          }

          final notifications = snapshot.data!;
          final unreadCount = notifications.where((n) => !n.isRead).length;

          return Column(
            children: [
              if (unreadCount > 0)
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.blue[50],
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 18,
                        color: Color(0xFF1565C0)
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "$unreadCount unread notification(s)",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1565C0)
                        )
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: notifications.length,
                  itemBuilder: (context, index) {
                    final notification = notifications[index];
                    return _buildNotificationCard(notification);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildNotificationCard(NotificationItem notification) {
    IconData icon;
    Color color;

    switch (notification.type) {
      case 'medication':
        icon = Icons.medication;
        color = Colors.blue;
        break;
      case 'refill':
        icon = Icons.warning_amber_rounded;
        color = Colors.orange;
        break;
      default:
        icon = Icons.info;
        color = Colors.grey;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: notification.isRead ? 1 : 3,
      color: notification.isRead ? Colors.white : Colors.blue[50],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: notification.isRead
            ? BorderSide.none
            : const BorderSide(color: Color(0xFF1565C0), width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.2),
          child: Icon(icon, color: color),
        ),
        title: Text(
          notification.title,
          style: TextStyle(
            fontWeight: notification.isRead ? FontWeight.normal : FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(notification.body),
            const SizedBox(height: 8),
            Text(
              DateFormat('MMM dd, yyyy • HH:mm').format(notification.timestamp),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        trailing: !notification.isRead
            ? IconButton(
                icon: const Icon(Icons.check_circle_outline, color: Colors.green),
                tooltip: "Mark as read",
                onPressed: () => _markAsRead(notification.id),
              )
            : null,
      ),
    );
  }
}

class NotificationItem {
  final String id;
  final String title;
  final String body;
  final String type;
  final DateTime timestamp;
  final bool isRead;

  NotificationItem({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.timestamp,
    required this.isRead,
  });
}