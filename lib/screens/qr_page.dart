import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/app_state.dart';

class MyQRPage extends StatefulWidget {
  const MyQRPage({super.key});

  @override
  State<MyQRPage> createState() => _MyQRPageState();
}

class _MyQRPageState extends State<MyQRPage> {
  String? localIp;

  @override
  void initState() {
    super.initState();
    getLocalIp();
  }

  void getLocalIp() async {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 &&
            !addr.address.startsWith('127')) {
          setState(() {
            localIp = addr.address;

            // Save globally for app use
            AppState.deviceIp = localIp;
          });
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = localIp == null
        ? "STARSHARE:WAIT"
        : "STARSHARE:$localIp";

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("My QR Code"),
        backgroundColor: Colors.blueAccent,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [

            const Text(
              "Scan this QR to connect",
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),

            const SizedBox(height: 20),

            if (localIp == null)
              const CircularProgressIndicator()
            else
              QrImageView(
                data: data,
                size: 220,
                backgroundColor: Colors.white,
              ),

            const SizedBox(height: 20),

            Text(
              localIp ?? "Finding IP...",
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}