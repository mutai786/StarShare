import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  bool scanned = false;
  String status = "Align QR inside the frame";

  void onDetect(BarcodeCapture capture) {
    if (scanned) return;

    final String? code = capture.barcodes.first.rawValue;
    if (code == null) return;

    if (!code.startsWith("STARSHARE:")) {
      setState(() {
        status = "Invalid QR Code";
      });
      return;
    }

    scanned = true;
    setState(() {
      status = "Device found... connecting";
    });

    final parts = code.split(":");

    final ip = parts[1];
    final port = int.parse(parts[2]);

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        Navigator.pop(context, {
          "ip": ip,
          "port": port,
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Scan QR"),
        backgroundColor: Colors.blueAccent,
      ),

      body: Stack(
        children: [

          // CAMERA
          MobileScanner(
            onDetect: onDetect,
          ),

          // DARK OVERLAY
          Container(
            color: Colors.black.withOpacity(0.4),
          ),

          // QR FRAME (CENTER BOX)
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.greenAccent,
                  width: 3,
                ),
              ),
            ),
          ),

          // CORNER LINES (STYLE IMPROVEMENT)
          Center(
            child: SizedBox(
              width: 270,
              height: 270,
              child: CustomPaint(
                painter: _QrFramePainter(),
              ),
            ),
          ),

          // BOTTOM TEXT
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.qr_code_scanner,
                    color: Colors.white,
                    size: 40,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    "Place QR inside the box",
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 🎯 FRAME DESIGN (CORNER LINES LIKE SHAREIT)
class _QrFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    const cornerLength = 25.0;

    // Top-left
    canvas.drawLine(Offset(0, 0), Offset(cornerLength, 0), paint);
    canvas.drawLine(Offset(0, 0), Offset(0, cornerLength), paint);

    // Top-right
    canvas.drawLine(Offset(size.width, 0),
        Offset(size.width - cornerLength, 0), paint);
    canvas.drawLine(Offset(size.width, 0),
        Offset(size.width, cornerLength), paint);

    // Bottom-left
    canvas.drawLine(Offset(0, size.height),
        Offset(cornerLength, size.height), paint);
    canvas.drawLine(Offset(0, size.height),
        Offset(0, size.height - cornerLength), paint);

    // Bottom-right
    canvas.drawLine(Offset(size.width, size.height),
        Offset(size.width - cornerLength, size.height), paint);
    canvas.drawLine(Offset(size.width, size.height),
        Offset(size.width, size.height - cornerLength), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}