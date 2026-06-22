import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:starshare/services/app_state.dart';
import 'package:starshare/screens/send_file_screen.dart';

class QRScanPage extends StatefulWidget {
  const QRScanPage({super.key});

  @override
  State<QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<QRScanPage> {
  bool scanned = false;

  void handleQR(String raw) {
    if (scanned) return;
    scanned = true;

    if (!raw.startsWith("STARSHARE:")) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Invalid QR Code")),
      );
      return;
    }

    final ip = raw.replaceFirst("STARSHARE:", "").trim();

    if (ip.isEmpty) return;

    // Save global state
    AppState.selectedIp = ip;
    AppState.lastConnectedIp = ip;

    Navigator.pop(context);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const SendFileScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Scan Device QR"),
        backgroundColor: Colors.blueAccent,
      ),
      body: MobileScanner(
        controller: MobileScannerController(
          detectionSpeed: DetectionSpeed.noDuplicates,
        ),
        onDetect: (capture) {
          final barcode = capture.barcodes.first;

          if (barcode.rawValue == null) return;

          handleQR(barcode.rawValue!);
        },
      ),
    );
  }
}