import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import '../services/notification_service.dart';

class _Palette {
  static const background = Color(0xFF0B1017);
  static const surface = Color(0xFF121A24);
  static const border = Color(0xFF1E2A38);
  static const text = Color(0xFFEEF2F7);
  static const muted = Color(0xFF8B98A9);
  static const accentLight = Color(0xFF60A5FA);
  static const accentTint = Color(0x292563EB);
  static const warning = Color(0xFFF59E0B);
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await NotificationService.list();
    // Items keep their unread flag in memory, so they stay highlighted
    // during this visit even though they are now marked as read.
    await NotificationService.markAllRead();

    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    await NotificationService.clearAll();
    if (!mounted) return;
    setState(() => _items = const []);
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openItem(AppNotification item) async {
    final path = item.filePath;
    if (path == null || path.isEmpty) return;

    if (!await File(path).exists()) {
      _message('The file is no longer there. It may have been moved or deleted.');
      return;
    }

    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      _message('Could not open the file: ${result.message}');
    }
  }

  IconData _iconFor(AppNotification item) {
    if (item.title.contains('received')) return Icons.south_west_rounded;
    if (item.title.contains('sent')) return Icons.north_east_rounded;
    return Icons.info_outline_rounded;
  }

  bool _isProblem(AppNotification item) {
    return item.title.startsWith('Transfer failed') ||
        item.title.startsWith('Transfer problem') ||
        item.title.startsWith('Delivery not confirmed');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Palette.background,
      appBar: AppBar(
        backgroundColor: _Palette.background,
        foregroundColor: _Palette.text,
        elevation: 0,
        title: const Text(
          'Notifications',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              onPressed: _clear,
              child: const Text('Clear all'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'No notifications yet.\n'
                'Files you send or receive will be listed here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _Palette.muted, fontSize: 15),
          ),
        ),
      )
          : ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _buildItem(_items[index]),
      ),
    );
  }

  Widget _buildItem(AppNotification item) {
    final problem = _isProblem(item);
    final canOpen = item.filePath != null && item.filePath!.isNotEmpty;

    return Material(
      color: _Palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: item.isRead ? _Palette.border : _Palette.accentLight,
        ),
      ),
      child: InkWell(
        onTap: canOpen ? () => _openItem(item) : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _Palette.accentTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _iconFor(item),
                  color: problem ? _Palette.warning : _Palette.accentLight,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        color: _Palette.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.body,
                      style: const TextStyle(
                        color: _Palette.muted,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat('dd/MM/yyyy  hh:mm a').format(item.createdAt) +
                          (canOpen ? '  ·  Tap to open' : ''),
                      style: const TextStyle(
                        color: _Palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
