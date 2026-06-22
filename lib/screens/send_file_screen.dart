import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'screens/qr_scan_page.dart';
import '../services/database_service.dart';
import '../services/app_state.dart';

class SendFileScreen extends StatefulWidget {
  const SendFileScreen({super.key});

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  String? fileName;
  String? filePath;

  List<String> devices = [];
  String? selectedIp;

  @override
  void initState() {
    super.initState();

    if (AppState.selectedIp != null) {
      selectedIp = AppState.selectedIp;
    }
  }

  void pickFile() async {
    final result = await FilePicker.platform.pickFiles();

    if (result != null && result.files.single.path != null) {
      setState(() {
        fileName = result.files.single.name;
        filePath = result.files.single.path;
      });
    }
  }

  void discoverDevices() async {
    final socket =
    await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8888);

    socket.broadcastEnabled = true;

    socket.send(
      utf8.encode("STARSHARE_DISCOVER"),
      InternetAddress("255.255.255.255"),
      8888,
    );

    socket.listen((event) {
      final dg = socket.receive();
      if (dg == null) return;

      final msg = utf8.decode(dg.data);

      if (msg == "STARSHARE_HERE") {
        final ip = dg.address.address;

        if (!devices.contains(ip)) {
          setState(() {
            devices.add(ip);
          });
        }
      }
    });
  }

  // ✅ FIXED SAFE STREAM READER
  Future<String> _readLine(Socket socket) async {
    final completer = Completer<String>();
    String buffer = "";

    late StreamSubscription sub;

    sub = socket.listen(
          (data) {
        buffer += utf8.decode(data);

        if (buffer.contains('\n') && !completer.isCompleted) {
          completer.complete(buffer.trim());
          sub.cancel();
        }
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(buffer.trim());
        }
      },
    );

    return completer.future;
  }

  void sendFile() async {
    if (filePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Pick a file first")),
      );
      return;
    }

    if (selectedIp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No device connected")),
      );
      return;
    }

    try {
      final file = File(filePath!);
      final bytes = await file.readAsBytes();

      final socket = await Socket.connect(
        selectedIp!,
        AppState.selectedPort, // ✅ FIXED: use QR port
        timeout: const Duration(seconds: 10),
      );

      socket.writeln("CONNECT");
      socket.writeln(fileName);
      socket.writeln(bytes.length.toString());

      final response = await _readLine(socket);

      if (response != "ACCEPT") {
        await socket.close();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Receiver rejected connection")),
          );
        }
        return;
      }

      socket.add(bytes);
      await socket.flush();
      await socket.close();

      final db = await DatabaseService.database;

      await db.insert(
        'transfers',
        {
          'fileName': fileName,
          'fileSize': bytes.length,
          'direction': 'Sent',
          'deviceIp': selectedIp,
          'timestamp': DateTime.now().toString(),
        },
      );

      AppState.notifyUpdate();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("File Sent 🚀")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Transfer failed: $e")),
        );
      }
    }
  }

  Future<void> scanQRAndConnect() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const QRScanPage(),
      ),
    );

    if (AppState.selectedIp != null) {
      setState(() {
        selectedIp = AppState.selectedIp;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Send File"),
        centerTitle: true,
        backgroundColor: Colors.blueAccent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.blueAccent),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Selected File",
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    fileName ?? "No file selected",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: pickFile,
                    icon: const Icon(Icons.attach_file),
                    label: const Text("Pick File"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: discoverDevices,
                    icon: const Icon(Icons.wifi),
                    label: const Text("Find"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: scanQRAndConnect,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text("Scan QR & Auto Connect"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
              ),
            ),

            const SizedBox(height: 20),

            if (selectedIp != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  border: Border.all(color: Colors.green),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  "Connected: $selectedIp:${AppState.selectedPort}",
                  style: const TextStyle(color: Colors.white),
                ),
              ),

            const SizedBox(height: 20),

            ElevatedButton.icon(
              onPressed: sendFile,
              icon: const Icon(Icons.send),
              label: const Text("Send File"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
            ),

            const SizedBox(height: 20),

            Expanded(
              child: devices.isEmpty
                  ? const Center(
                child: Text(
                  "No devices found",
                  style: TextStyle(color: Colors.grey),
                ),
              )
                  : ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, i) {
                  return Card(
                    color: Colors.white10,
                    child: ListTile(
                      title: Text(
                        devices[i],
                        style: const TextStyle(color: Colors.white),
                      ),
                      trailing: const Icon(
                        Icons.send,
                        color: Colors.greenAccent,
                      ),
                      onTap: () {
                        setState(() {
                          selectedIp = devices[i];
                        });
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}