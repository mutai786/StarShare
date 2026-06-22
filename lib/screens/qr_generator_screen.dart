import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QrGeneratorScreen extends StatefulWidget {
  const QrGeneratorScreen({super.key});

  @override
  State<QrGeneratorScreen> createState() => _QrGeneratorScreenState();
}

class _QrGeneratorScreenState extends State<QrGeneratorScreen> {
  String? ip;

  @override
  void initState() {
    super.initState();
    getLocalIp();
  }

  Future<void> getLocalIp() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.address.startsWith("127")) {
            setState(() {
              ip = addr.address;
            });
            return;
          }
        }
      }
    } catch (e) {
      setState(() {
        ip = "UNKNOWN";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = "STARSHARE:${ip ?? 'LOADING'}:5000";

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("Share via QR")),
      body: Center(
        child: ip == null
            ? const CircularProgressIndicator()
            : QrImageView(
          data: data,
          size: 250,
          backgroundColor: Colors.white,
        ),
      ),
    );
  }
}