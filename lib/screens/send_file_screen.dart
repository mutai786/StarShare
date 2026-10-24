import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'screens/qr_scan_page.dart';
import '../services/app_state.dart';
import '../services/database_service.dart';
import '../utils/gesture_handler.dart';

/// Colors used on this screen (same as the home screen). Move these into
/// your app's ThemeData when you restyle the other screens.
class _Palette {
  static const background = Color(0xFF0B1017);
  static const surface = Color(0xFF121A24);
  static const border = Color(0xFF1E2A38);
  static const text = Color(0xFFEEF2F7);
  static const muted = Color(0xFF8B98A9);
  static const accent = Color(0xFF2563EB);
  static const accentLight = Color(0xFF60A5FA);
  static const accentTint = Color(0x292563EB); // accent at about 16%
}

class _CancelledException implements Exception {
  const _CancelledException();
}

class SendFileScreen extends StatefulWidget {
  const SendFileScreen({super.key});

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  static const int _discoveryPort = 8888;

  String? _fileName;
  String? _filePath;
  int? _fileSize;

  final List<String> _devices = [];
  String? _selectedIp;

  bool _scanning = false;
  bool _sending = false;
  bool _cancelled = false;
  double _progress = 0;

  Socket? _socket;
  RawDatagramSocket? _discoverySocket;

  @override
  void initState() {
    super.initState();
    _selectedIp = AppState.selectedIp;
  }

  @override
  void dispose() {
    _discoverySocket?.close();
    _socket?.destroy();
    super.dispose();
  }

  // ------------------------------------------------------------- helpers

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _Palette.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _Palette.border),
          ),
        ),
      );
  }

  void _clearFile() {
    setState(() {
      _fileName = null;
      _filePath = null;
      _fileSize = null;
    });
  }

  // --------------------------------------------------------------- files

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (!mounted || result == null) return;

    final picked = result.files.single;
    if (picked.path == null) {
      _showMessage('Could not read that file.');
      return;
    }

    setState(() {
      _fileName = picked.name;
      _filePath = picked.path;
      _fileSize = picked.size;
    });
  }

  // ----------------------------------------------------------- discovery

  Future<void> _discoverDevices() async {
    if (_scanning) return;

    setState(() {
      _scanning = true;
      _devices.clear();
    });

    try {
      // Close any socket left over from a previous search. Binding the
      // same port twice throws, which broke "Find" the second time.
      _discoverySocket?.close();

      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
      );
      _discoverySocket = socket;
      socket.broadcastEnabled = true;

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;

        final message = utf8.decode(datagram.data, allowMalformed: true);
        if (message != 'STARSHARE_HERE') return;

        final ip = datagram.address.address;
        if (mounted && !_devices.contains(ip)) {
          setState(() => _devices.add(ip));
        }
      });

      socket.send(
        utf8.encode('STARSHARE_DISCOVER'),
        InternetAddress('255.255.255.255'),
        _discoveryPort,
      );

      // Give devices a few seconds to answer, then stop listening.
      await Future<void>.delayed(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('Discovery failed: $e');
      _showMessage('Could not search for devices. Check your Wi-Fi.');
    } finally {
      _discoverySocket?.close();
      _discoverySocket = null;
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _scanQrAndConnect() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const QRScanPage()),
    );
    if (!mounted) return;

    final ip = AppState.selectedIp;
    if (ip != null) setState(() => _selectedIp = ip);
  }

  // ------------------------------------------------------------ transfer

  /// Reads one line from the receiver (for example ACCEPT).
  Future<String> _readLine(Socket socket) async {
    final completer = Completer<String>();
    final buffer = StringBuffer();

    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
          (data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        if (buffer.toString().contains('\n') && !completer.isCompleted) {
          completer.complete(buffer.toString().trim());
          sub.cancel();
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(buffer.toString().trim());
        }
      },
    );

    return completer.future;
  }

  Future<void> _sendFile() async {
    final path = _filePath;
    final name = _fileName;
    final ip = _selectedIp;

    if (path == null || name == null) {
      _showMessage('Pick a file first.');
      return;
    }
    if (ip == null) {
      _showMessage('Choose a device first.');
      return;
    }

    final file = File(path);
    if (!await file.exists()) {
      _clearFile();
      _showMessage('That file is no longer available.');
      return;
    }

    setState(() {
      _sending = true;
      _cancelled = false;
      _progress = 0;
    });

    Socket? socket;
    try {
      final size = await file.length();

      socket = await Socket.connect(
        ip,
        AppState.selectedPort,
        timeout: const Duration(seconds: 10),
      );
      _socket = socket;

      // Same handshake as before. File names are cleaned so a new line in
      // a name can't break the protocol.
      socket.writeln('CONNECT');
      socket.writeln(name.replaceAll(RegExp(r'[\r\n]'), ' '));
      socket.writeln(size.toString());

      final response =
      await _readLine(socket).timeout(const Duration(seconds: 30));

      if (response != 'ACCEPT') {
        HapticFeedback.heavyImpact();
        _showMessage('The receiver declined the transfer.');
        return;
      }

      // Stream the file instead of loading all of it into memory, so large
      // files no longer crash the app.
      var sent = 0;
      var lastPercent = -1;
      await socket.addStream(
        file.openRead().map((chunk) {
          if (_cancelled) throw const _CancelledException();
          sent += chunk.length;
          final percent = size == 0 ? 100 : sent * 100 ~/ size;
          if (percent != lastPercent && mounted) {
            lastPercent = percent;
            setState(() => _progress = percent / 100);
          }
          return chunk;
        }),
      );
      await socket.flush();
      await socket.close();

      try {
        final db = await DatabaseService.database;
        await db.insert('transfers', {
          'fileName': name,
          'fileSize': size,
          'direction': 'Sent',
          'deviceIp': ip,
          'timestamp': DateFormat('dd/MM/yyyy  hh:mm a').format(DateTime.now()),
        });
        AppState.notifyUpdate();
      } catch (e) {
        debugPrint('Could not save transfer history: $e');
      }

      HapticFeedback.mediumImpact();
      _showMessage('File sent.');
    } on TimeoutException {
      _showMessage('The receiver did not respond.');
    } catch (e) {
      debugPrint('Send failed: $e');
      HapticFeedback.heavyImpact();
      _showMessage(
        _cancelled
            ? 'Transfer cancelled.'
            : 'Transfer failed. Check that both devices are on the same network.',
      );
    } finally {
      socket?.destroy();
      _socket = null;
      if (mounted) setState(() => _sending = false);
    }
  }

  void _cancelTransfer() {
    _cancelled = true;
    _socket?.destroy();
  }

  // --------------------------------------------------------------- build

  bool get _canSend => _fileName != null && _selectedIp != null && !_sending;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Palette.background,
      appBar: AppBar(
        backgroundColor: _Palette.background,
        foregroundColor: _Palette.text,
        elevation: 0,
        title: const Text(
          'Send file',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _discoverDevices,
        color: _Palette.accentLight,
        backgroundColor: _Palette.surface,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _buildFileCard(),
            const SizedBox(height: 24),
            _buildDeviceSection(),
            if (_sending) ...[
              const SizedBox(height: 20),
              _buildProgressCard(),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: SizedBox(
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _canSend ? _sendFile : null,
              icon: const Icon(Icons.send_rounded),
              label: Text(_sending ? 'Sending…' : 'Send file'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _Palette.accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _Palette.surface,
                disabledForegroundColor: _Palette.muted,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileCard() {
    final hasFile = _fileName != null;

    return GestureDetector(
      onLongPress: hasFile ? _showFileOptions : null,
      child: Material(
        color: _Palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: hasFile ? _Palette.accentLight : _Palette.border,
          ),
        ),
        child: InkWell(
          onTap: _sending ? null : _pickFile,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _IconBox(
                  icon: hasFile
                      ? Icons.insert_drive_file_rounded
                      : Icons.upload_file_rounded,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasFile ? _fileName! : 'Choose a file',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _Palette.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasFile
                            ? (_fileSize == null
                            ? 'Tap to change'
                            : '${_formatBytes(_fileSize!)} · Tap to change')
                            : 'Tap to browse your files',
                        style: const TextStyle(
                          color: _Palette.muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasFile && !_sending)
                  IconButton(
                    tooltip: 'Remove file',
                    icon: const Icon(
                      Icons.close_rounded,
                      color: _Palette.muted,
                    ),
                    onPressed: _clearFile,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceSection() {
    final ip = _selectedIp;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Send to',
          style: TextStyle(
            color: _Palette.text,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _OutlineAction(
                icon: Icons.qr_code_scanner_rounded,
                label: 'Scan QR',
                onPressed: _sending ? null : _scanQrAndConnect,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _OutlineAction(
                icon: Icons.wifi_find_rounded,
                label: _scanning ? 'Searching…' : 'Find nearby',
                onPressed: (_sending || _scanning) ? null : _discoverDevices,
              ),
            ),
          ],
        ),
        if (ip != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _Palette.accentTint,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _Palette.accentLight),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: _Palette.accentLight,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Connected: $ip:${AppState.selectedPort}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _Palette.text),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          'Nearby devices',
          style: TextStyle(
            color: _Palette.muted,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (_scanning)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(
              minHeight: 3,
              color: _Palette.accentLight,
              backgroundColor: _Palette.border,
            ),
          ),
        if (_devices.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
            decoration: BoxDecoration(
              color: _Palette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _Palette.border),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.devices_other_rounded,
                  color: _Palette.muted,
                  size: 28,
                ),
                const SizedBox(height: 10),
                Text(
                  _scanning ? 'Looking for devices…' : 'No devices found',
                  style: const TextStyle(
                    color: _Palette.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Pull down or tap Find nearby to search.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _Palette.muted, fontSize: 13),
                ),
              ],
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: _Palette.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _Palette.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < _devices.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: _Palette.border),
                  _DeviceRow(
                    ip: _devices[i],
                    selected: _devices[i] == _selectedIp,
                    onTap: _sending
                        ? null
                        : () {
                      HapticFeedback.selectionClick();
                      setState(() => _selectedIp = _devices[i]);
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildProgressCard() {
    final percent = (_progress * 100).round();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _Palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _Palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Sending',
                style: TextStyle(
                  color: _Palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '$percent%',
                style: const TextStyle(
                  color: _Palette.accentLight,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 6,
              color: _Palette.accentLight,
              backgroundColor: _Palette.border,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _cancelTransfer,
              style: TextButton.styleFrom(
                foregroundColor: _Palette.muted,
                minimumSize: const Size(48, 48),
              ),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }

  /// Same long-press menu as before, using your GestureHandler.
  void _showFileOptions() {
    final name = _fileName;
    if (name == null) return;

    GestureHandler.showFileOptions(
      context,
      fileName: name,
      onOpen: () => _showMessage('Opening $name'),
      onShare: () => _showMessage('Sharing $name'),
      onRename: () => _showMessage('Rename $name'),
      onDelete: () {
        _clearFile();
        _showMessage('File removed.');
      },
      onDetails: () {
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: _Palette.surface,
            title: const Text(
              'File details',
              style: TextStyle(color: _Palette.text),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Name: $name',
                  style: const TextStyle(color: _Palette.text),
                ),
                const SizedBox(height: 8),
                Text(
                  'Size: ${_fileSize == null ? 'Unknown' : _formatBytes(_fileSize!)}',
                  style: const TextStyle(color: _Palette.text),
                ),
                const SizedBox(height: 8),
                Text(
                  'Path: ${_filePath ?? 'Unknown'}',
                  style: const TextStyle(color: _Palette.muted),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- widgets

class _OutlineAction extends StatelessWidget {
  const _OutlineAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: _Palette.text,
        disabledForegroundColor: _Palette.muted,
        backgroundColor: _Palette.surface,
        minimumSize: const Size(48, 52),
        side: const BorderSide(color: _Palette.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.ip,
    required this.selected,
    required this.onTap,
  });

  final String ip;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const _IconBox(icon: Icons.smartphone_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                ip,
                style: const TextStyle(
                  color: _Palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? _Palette.accentLight : _Palette.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _Palette.accentTint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: _Palette.accentLight, size: 20),
    );
  }
}

String _formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}