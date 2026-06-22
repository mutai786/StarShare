import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/database_service.dart';
import '../services/app_state.dart';

class ReceiveFileScreen extends StatefulWidget {
  const ReceiveFileScreen({super.key});

  @override
  State<ReceiveFileScreen> createState() => _ReceiveFileScreenState();
}

class _ReceiveFileScreenState extends State<ReceiveFileScreen> {
  String status = "Waiting...";
  ServerSocket? server;
  RawDatagramSocket? udp;

  @override
  void initState() {
    super.initState();
    startServer();
    startDiscovery();
  }

  void startDiscovery() async {
    try {
      udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8888,
      );

      udp!.broadcastEnabled = true;

      udp!.listen((event) {
        final dg = udp!.receive();

        if (dg == null) return;

        final msg = utf8.decode(dg.data);

        if (msg == "STARSHARE_DISCOVER") {
          udp!.send(
            utf8.encode("STARSHARE_HERE"),
            dg.address,
            dg.port,
          );
        }
      });
    } catch (e) {
      setState(() {
        status = "Discovery Error: $e";
      });
    }
  }

  void startServer() async {
    try {
      server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        5000,
      );

      setState(() {
        status = "Listening...";
      });

      server!.listen((Socket client) async {
        try {
          final command = await _readLine(client);

          if (command != "CONNECT") {
            client.destroy();
            return;
          }

          final fileName = await _readLine(client);

          final sizeString = await _readLine(client);
          final size = int.tryParse(sizeString) ?? 0;

          if (size <= 0) {
            client.destroy();
            return;
          }

          client.writeln("ACCEPT");

          final List<int> buffer = [];

          await for (final data in client) {
            buffer.addAll(data);

            if (buffer.length >= size) {
              break;
            }
          }

          final dir = await getExternalStorageDirectory();

          if (dir == null) {
            throw Exception("Storage directory unavailable");
          }

          final file = File('${dir.path}/$fileName');

          await file.writeAsBytes(buffer);

          final db = await DatabaseService.database;

          await db.insert(
            'transfers',
            {
              'fileName': fileName,
              'fileSize': size,
              'direction': 'Received',
              'deviceIp': client.remoteAddress.address,
              'timestamp': DateTime.now().toString(),
            },
          );

          AppState.notifyUpdate();

          if (mounted) {
            setState(() {
              status = "Received: $fileName";
            });
          }

          await client.flush();
          await client.close();
        } catch (e) {
          if (mounted) {
            setState(() {
              status = "Transfer Error: $e";
            });
          }
        }
      });
    } catch (e) {
      setState(() {
        status = "Server Error: $e";
      });
    }
  }

  Future<String> _readLine(Socket socket) async {
    final completer = Completer<String>();

    String buffer = "";

    late StreamSubscription subscription;

    subscription = socket.listen(
          (data) {
        buffer += utf8.decode(data);

        if (buffer.contains('\n')) {
          final line = buffer
              .substring(0, buffer.indexOf('\n'))
              .trim();

          subscription.cancel();

          if (!completer.isCompleted) {
            completer.complete(line);
          }
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

  @override
  void dispose() {
    server?.close();
    udp?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Receive File"),
      ),
      body: Center(
        child: Text(
          status,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
          ),
        ),
      ),
    );
  }
}