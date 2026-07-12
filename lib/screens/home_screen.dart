import 'package:flutter/material.dart';
import 'package:starshare/screens/qr_generator_screen.dart';
import 'package:starshare/screens/qr_scanner_screen.dart';
import 'send_file_screen.dart';
import 'receive_file_screen.dart';
import 'history_screen.dart';
import '../services/location_service.dart';
import '../services/database_service.dart';
import '../services/app_state.dart';
import '../utils/input_validator.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int sentCount = 0;
  int receivedCount = 0;
  String latitude = "Not Available";
  String longitude = "Not Available";

  final LocationService _locationService = LocationService();
  // Added for search
  final TextEditingController _searchController = TextEditingController();
  final InputValidator _validator = const InputValidator();

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

  // Search functionality
  void _searchFiles() {
    FocusScope.of(context).unfocus();

    final error = _validator.validateSearch(_searchController.text);

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "Searching for '${_searchController.text.trim()}'...",
        ),
      ),
    );

    // Search logic can be connected later
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

    AppState.setSelectedDevice(
      ip: ip,
      port: port,
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Connected to $ip:$port")),
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const SendFileScreen(),
      ),
    );
  }
  Future<void> getLocation() async {
    try {
      final position = await _locationService.getCurrentLocation();

      if (position == null) return;

      setState(() {
        latitude = position.latitude.toStringAsFixed(6);
        longitude = position.longitude.toStringAsFixed(6);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Location retrieved successfully."),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
        ),
      );
    }
  }
  @override
  void dispose() {
    AppState.updateNotifier.removeListener(loadStats);
    _searchController.dispose();
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

            // Added Search Bar
            TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _searchFiles(),
              decoration: InputDecoration(
                hintText: "Search files...",
                hintStyle: const TextStyle(color: Colors.white60),
                filled: true,
                fillColor: Colors.white10,
                prefixIcon: const Icon(
                  Icons.search,
                  color: Colors.white70,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(
                    Icons.arrow_forward,
                    color: Colors.blueAccent,
                  ),
                  onPressed: _searchFiles,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(15),
                  borderSide: BorderSide.none,
                ),
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
                  child: _statCard(
                    Icons.download,
                    "Received",
                    receivedCount.toString(),
                  ),
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
              Icons.location_on,
              "Location",
              getLocation,
            ),

            const SizedBox(height: 20),

            Card(
              color: Colors.white10,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text(
                      "Current Location",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Latitude: $latitude",
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      "Longitude: $longitude",
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
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