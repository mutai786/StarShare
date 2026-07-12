import 'package:flutter/material.dart';
import '../services/database_service.dart';
import '../services/app_state.dart';

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
    loadTransfers();
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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppState.updateNotifier,
      builder: (context, value, child) {
        loadTransfers();

        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: const Text("Transfer History"),
            centerTitle: true,
            backgroundColor: Colors.blueAccent,
          ),

          body: transfers.isEmpty
              ? ListView(
            children: [
              Card(
                color: Colors.white10,
                margin: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: const ListTile(
                  leading: Icon(
                    Icons.upload,
                    color: Colors.greenAccent,
                  ),
                  title: Text(
                    "BIT4107_Notes.pdf",
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    "Sent • 192.168.1.7\n12/07/2026 03:45 PM",
                    style: TextStyle(color: Colors.grey),
                  ),
                  trailing: Text(
                    "2 gB",
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
              Card(
                color: Colors.white10,
                margin: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: const ListTile(
                  leading: Icon(
                    Icons.download,
                    color: Colors.blueAccent,
                  ),
                  title: Text(
                    "Project_Report.docx",
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    "Received • 192.168.1.15\n12/07/2026 04:10 PM",
                    style: TextStyle(color: Colors.grey),
                  ),
                  trailing: Text(
                    "1.2 MB",
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  "(2 files).",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          )
              : ListView.builder(
            itemCount: transfers.length,
            itemBuilder: (context, index) {
              final item = transfers[index];

              return Card(
                color: Colors.white10,
                margin: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: ListTile(
                  leading: Icon(
                    item['direction'] == 'Sent'
                        ? Icons.upload
                        : Icons.download,
                    color: item['direction'] == 'Sent'
                        ? Colors.greenAccent
                        : Colors.blueAccent,
                  ),
                  title: Text(
                    item['fileName'],
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    "${item['direction']} • ${item['deviceIp']}\n${item['timestamp']}",
                    style: const TextStyle(color: Colors.grey),
                  ),
                  trailing: Text(
                    "${item['fileSize']} B",
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
      },
    );
  }
}