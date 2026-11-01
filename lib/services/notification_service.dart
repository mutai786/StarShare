import 'app_state.dart';
import 'database_service.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.isRead,
    this.filePath,
  });

  final int id;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool isRead;

  /// Set for "file received" entries so tapping them can open the file.
  final String? filePath;

  factory AppNotification.fromRow(Map<String, Object?> row) {
    return AppNotification(
      id: row['id'] as int,
      title: '${row['title'] ?? ''}',
      body: '${row['body'] ?? ''}',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['createdAt'] as int?) ?? 0,
      ),
      isRead: (row['isRead'] as int?) == 1,
      filePath: row['filePath'] as String?,
    );
  }
}

/// In-app notification centre backed by the local database.
class NotificationService {
  static const int _maxStored = 200;

  /// Records an event. Never throws: a notification problem must not break a
  /// file transfer.
  static Future<void> add({
    required String title,
    required String body,
    String? filePath,
  }) async {
    try {
      final db = await DatabaseService.database;
      await db.insert('notifications', {
        'title': title,
        'body': body,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'isRead': 0,
        'filePath': filePath,
      });
      // Keep the table small.
      await db.rawDelete(
        'DELETE FROM notifications WHERE id NOT IN '
            '(SELECT id FROM notifications ORDER BY id DESC LIMIT $_maxStored)',
      );
      AppState.notifyUpdate();
    } catch (_) {}
  }

  static Future<List<AppNotification>> list({int limit = 100}) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'notifications',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(AppNotification.fromRow).toList();
  }

  static Future<int> unreadCount() async {
    try {
      final db = await DatabaseService.database;
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM notifications WHERE isRead = 0',
      );
      return (rows.first['count'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> markAllRead() async {
    final db = await DatabaseService.database;
    await db.update('notifications', {'isRead': 1}, where: 'isRead = 0');
  }

  static Future<void> clearAll() async {
    final db = await DatabaseService.database;
    await db.delete('notifications');
    AppState.notifyUpdate();
  }
}
