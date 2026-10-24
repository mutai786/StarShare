import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:starshare/services/app_state.dart';
import 'package:starshare/services/qr_model.dart';
import 'package:starshare/screens/send_file_screen.dart';

class QRScanPage extends StatefulWidget {
  const QRScanPage({super.key});

  @override
  State<QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<QRScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showInvalid() {
    // Allow another scan after a bad code.
    scanned = false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Invalid QR Code")),
    );
  }

  void handleQR(String raw) {
    if (scanned) return;
    scanned = true;

    final device = DeviceQR.tryParse(raw);

    if (device != null) {
      // New format: carries the receiver's public key and token.
      AppState.setSelectedDevice(
        ip: device.ip,
        port: device.port,
        publicKey: device.publicKey,
        token: device.token,
      );
    } else {
      // TODO(remove): temporary support for the old "STARSHARE:ip:port"
      // code so the app keeps working until the receiver is updated. Codes
      // in this format carry no key, so they cannot be verified.
      final legacy = _parseLegacy(raw);
      if (legacy == null) {
        _showInvalid();
        return;
      }
      AppState.setSelectedDevice(ip: legacy.ip, port: legacy.port);
    }

    AppState.lastConnectedIp = AppState.selectedIp;

    Navigator.pop(context);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const SendFileScreen(),
      ),
    );
  }

  ({String ip, int port})? _parseLegacy(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 3 || parts[0] != 'STARSHARE') return null;

    final address = InternetAddress.tryParse(parts[1]);
    final port = int.tryParse(parts[2]);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        port == null ||
        port < 1 ||
        port > 65535) {
      return null;
    }
    return (ip: parts[1], port: port);
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
        controller: _controller,
        onDetect: (capture) {
          if (capture.barcodes.isEmpty) return;

          final value = capture.barcodes.first.rawValue;
          if (value == null) return;

          handleQR(value);
        },
      ),
    );
  }
}
