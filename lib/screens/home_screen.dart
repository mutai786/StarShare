import 'package:flutter/material.dart';
import 'package:starshare/screens/qr_generator_screen.dart';
import 'package:starshare/screens/qr_scanner_screen.dart';
import 'send_file_screen.dart';
import 'receive_file_screen.dart';
import 'history_screen.dart';

import '../services/database_service.dart';
import '../services/app_state.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int sentCount = 0;
  int receivedCount = 0;

  @override
  void initState() {
    super.initState();
    loadStats();
    AppState.updateNotifier.addListener(loadStats);
  }

  Future<void> loadStats() async {
    final db = await DatabaseService.database;

    final sent = await db.rawQuery(
      "SELECT COUNT(*) as count FROM transfers WHERE direction = 'Sent'",
    );

    final received = await db.rawQuery(
      "SELECT COUNT(*) as count FROM transfers WHERE direction = 'Received'",
    );

    if (!mounted) return;

    setState(() {
      sentCount = (sent.first['count'] as int?) ?? 0;
      receivedCount = (received.first['count'] as int?) ?? 0;
    });
  }

  // ✅ FIXED QR HANDLING
  void scanAndSend() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );

    if (result == null) return;

    final ip = result['ip'];
    final port = result['port'];

    if (ip == null || port == null) return;

    // Save for SendFileScreen auto-connect
    AppState.setSelectedDevice(
      ip: ip,
      port: port,
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Connected to $ip:$port")),
    );

    // OPTIONAL: auto-open send screen
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const SendFileScreen(),
      ),
    );
  }

  @override
  void dispose() {
    AppState.updateNotifier.removeListener(loadStats);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      appBar: AppBar(
        title: const Text("StarShare"),
        backgroundColor: Colors.blueAccent,
        actions: const [
          Icon(Icons.notifications),
          SizedBox(width: 10),
          Icon(Icons.person),
          SizedBox(width: 10),
        ],
      ),

      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            const Text(
              "Good Afternoon 👋",
              style: TextStyle(
                fontSize: 24,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 25),

            Row(
              children: [
                Expanded(
                  child: _statCard(Icons.send, "Sent", sentCount.toString()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _statCard(Icons.download, "Received", receivedCount.toString()),
                ),
              ],
            ),

            const SizedBox(height: 25),

            const Text(
              "Quick Actions",
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 15),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [

                _actionButton(
                  context,
                  Icons.upload_file,
                  "Send",
                      () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SendFileScreen(),
                      ),
                    );
                  },
                ),

                _actionButton(
                  context,
                  Icons.download,
                  "Receive",
                      () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ReceiveFileScreen(),
                      ),
                    );
                  },
                ),

                _actionButton(
                  context,
                  Icons.qr_code_scanner,
                  "Scan",
                  scanAndSend,
                ),

                _actionButton(
                  context,
                  Icons.qr_code,
                  "Generate",
                      () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const QrGeneratorScreen(),
                      ),
                    );
                  },
                ),

              ],
            ),

            const SizedBox(height: 20),

            _actionButton(
              context,
              Icons.history,
              "History",
                  () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const HistoryScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(IconData icon, String title, String value) {
    return Card(
      color: Colors.white10,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: Colors.greenAccent, size: 30),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(title, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _actionButton(
      BuildContext context,
      IconData icon,
      String label,
      VoidCallback onTap,
      ) {
    return Column(
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: Colors.blueAccent,
          child: IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: onTap,
          ),
        ),
        const SizedBox(height: 5),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}