import 'package:flutter/material.dart';

import 'receive_file_screen.dart';

/// The QR code now lives on the Receive screen.
///
/// It has to carry the one-time key and token of the session that is actually
/// listening for files, so a separate screen cannot create a valid code.
/// This wrapper only keeps the existing "Generate" button working.
class QrGeneratorScreen extends StatelessWidget {
  const QrGeneratorScreen({super.key});

  @override
  Widget build(BuildContext context) => const ReceiveFileScreen();
}
