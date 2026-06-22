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
        // reload when notifier changes
        loadTransfers();

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
              "No transfer history yet",
              style: TextStyle(color: Colors.grey),
            ),
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
                    "${item['direction']} • ${item['deviceIp']}",
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