import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QRScanPage extends StatefulWidget {
  const QRScanPage({super.key});

  @override
  State<QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<QRScanPage> {
  bool scanned = false;

  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan Device QR")),
      body: MobileScanner(
        controller: controller,
        onDetect: (capture) {
          if (scanned) return;

          final barcode = capture.barcodes.first;

          if (barcode.rawValue == null) return;

          scanned = true;

          controller.stop();

          Navigator.pop(context, barcode.rawValue);
        },
      ),
    );
  }
}