import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../services/app_state.dart';
import '../services/database_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> transfers = [];

  @override
  void initState() {
    super.initState();
    // Reload only when a transfer finishes, instead of on every rebuild.
    AppState.updateNotifier.addListener(loadTransfers);
    loadTransfers();
  }

  @override
  void dispose() {
    AppState.updateNotifier.removeListener(loadTransfers);
    super.dispose();
  }

  Future<void> loadTransfers() async {
    final db = await DatabaseService.database;

    final data = await db.query(
      'transfers',
      orderBy: 'id DESC',
    );

    if (mounted) {
      setState(() {
        transfers = data;
      });
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Opens the saved file for a history row, if the row knows where it is.
  Future<void> _open(Map<String, dynamic> item) async {
    final path = item['filePath'] as String?;

    if (path == null || path.isEmpty) {
      _message('This entry has no saved file location.');
      return;
    }
    if (!await File(path).exists()) {
      _message('The file is no longer there. It may have been moved or deleted.');
      return;
    }

    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      _message('Could not open the file: ${result.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Transfer History"),
        centerTitle: true,
        backgroundColor: Colors.blueAccent,
      ),
      body: transfers.isEmpty
          ? const Center(
        child: Text(
          "No transfers yet.",
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      )
          : ListView.builder(
        itemCount: transfers.length,
        itemBuilder: (context, index) {
          final item = transfers[index];
          final sent = item['direction'] == 'Sent';
          final hasFile =
              (item['filePath'] as String?)?.isNotEmpty ?? false;

          return Card(
            color: Colors.white10,
            margin: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            child: ListTile(
              onTap: () => _open(item),
              leading: Icon(
                sent ? Icons.upload : Icons.download,
                color: sent ? Colors.greenAccent : Colors.blueAccent,
              ),
              title: Text(
                "${item['fileName']}",
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                "${item['direction']} • ${item['deviceIp']}\n"
                    "${item['timestamp']}"
                    "${hasFile ? '\nTap to open' : ''}",
                style: const TextStyle(color: Colors.grey),
              ),
              trailing: Text(
                _formatBytes((item['fileSize'] as int?) ?? 0),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.blueAccent,
        onPressed: loadTransfers,
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}
