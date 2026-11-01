import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'screens/qr_scan_page.dart';
import '../services/app_state.dart';
import '../services/database_service.dart';
import '../services/nearby_transfer_service.dart';
import '../services/notification_service.dart';
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
  static const warning = Color(0xFFF59E0B);
}

class _Picked {
  const _Picked({required this.name, required this.path, required this.size});

  final String name;
  final String path;
  final int size;
}

class SendFileScreen extends StatefulWidget {
  const SendFileScreen({super.key});

  @override
  State<SendFileScreen> createState() => _SendFileScreenState();
}

class _SendFileScreenState extends State<SendFileScreen> {
  static const int _discoveryPort = 8888;
  static const int _defaultPort = 5000;
  static const int _visibleFiles = 5;

  final List<_Picked> _files = [];
  bool _showAllFiles = false;

  /// Devices found with "Find nearby": ip -> the public key they announced.
  /// These are NOT verified; the users must compare the 6-digit code.
  final Map<String, Uint8List> _devices = {};

  String? _selectedIp;
  int _port = _defaultPort;
  Uint8List? _selectedKey;

  /// Set only when the device was chosen by scanning its QR code.
  Uint8List? _selectedToken;

  bool _scanning = false;
  bool _sending = false;
  TransferProgress? _progress; // null until the receiver accepted
  DateTime? _startedAt;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  String? _code;

  NearbySender? _sender;
  RawDatagramSocket? _discoverySocket;

  @override
  void initState() {
    super.initState();
    _selectedIp = AppState.selectedIp;
    _port = AppState.selectedPort;
    _selectedKey = AppState.selectedPublicKey;
    _selectedToken = AppState.selectedToken;
  }

  @override
  void dispose() {
    _discoverySocket?.close();
    _sender?.cancel();
    WakelockPlus.disable();
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

  int get _totalSize => _files.fold(0, (sum, file) => sum + file.size);

  void _removeFile(int index) {
    setState(() => _files.removeAt(index));
  }

  void _clearFiles() {
    setState(() {
      _files.clear();
      _showAllFiles = false;
    });
  }

  // --------------------------------------------------------------- files

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (!mounted || result == null) return;

    var unreadable = 0;
    setState(() {
      for (final picked in result.files) {
        final path = picked.path;
        if (path == null) {
          unreadable++;
          continue;
        }
        if (_files.any((file) => file.path == path)) continue;
        _files.add(_Picked(name: picked.name, path: path, size: picked.size));
      }
    });

    if (unreadable > 0) {
      _showMessage('$unreadable file(s) could not be read.');
    }
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
        final key = parseDiscoveryReply(message);
        if (key == null) return;

        final ip = datagram.address.address;
        if (mounted && !_devices.containsKey(ip)) {
          setState(() => _devices[ip] = key);
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
    if (ip != null) {
      setState(() {
        _selectedIp = ip;
        _port = AppState.selectedPort;
        _selectedKey = AppState.selectedPublicKey;
        _selectedToken = AppState.selectedToken;
      });
    }
  }

  void _selectDiscovered(String ip) {
    HapticFeedback.selectionClick();
    final key = _devices[ip];

    // Store the key with the IP, and drop any token from an earlier QR scan
    // so it can never be paired with a different device.
    AppState.setSelectedDevice(ip: ip, port: _defaultPort, publicKey: key);

    setState(() {
      _selectedIp = ip;
      _port = _defaultPort;
      _selectedKey = key;
      _selectedToken = null;
    });
  }

  // ------------------------------------------------------------ transfer

  Future<void> _sendFiles() async {
    final ip = _selectedIp;
    final key = _selectedKey;

    if (_files.isEmpty) {
      _showMessage('Pick at least one file first.');
      return;
    }
    if (ip == null) {
      _showMessage('Choose a device first.');
      return;
    }
    if (key == null) {
      _showMessage(
        'Scan the receiver\'s QR code, or pick it again with Find nearby.',
      );
      return;
    }

    // Check every file still exists before connecting.
    final missing = <_Picked>[];
    for (final file in _files) {
      if (!await File(file.path).exists()) missing.add(file);
    }
    if (missing.isNotEmpty) {
      setState(() => _files.removeWhere(missing.contains));
      _showMessage(
        missing.length == 1
            ? '${missing.first.name} is no longer available and was removed.'
            : '${missing.length} files are no longer available and were removed.',
      );
      return;
    }

    final batch = List<_Picked>.of(_files);
    final sender = NearbySender(
      ip: ip,
      port: _port,
      receiverPublicKey: key,
      token: _selectedToken,
    );
    _sender = sender;

    setState(() {
      _sending = true;
      _progress = null;
      _startedAt = null;
      _code = null;
    });

    // Keep the screen awake: a long transfer must not be paused by sleep.
    try {
      await WakelockPlus.enable();
    } catch (_) {}

    try {
      final outcome = await sender.sendFiles(
        files: [
          for (final file in batch)
            OutgoingFile(file: File(file.path), name: file.name),
        ],
        onCode: (code) {
          if (mounted) setState(() => _code = code);
        },
        onProgress: _onProgress,
      );

      final summary = batch.length == 1
          ? batch.single.name
          : '${batch.length} files';

      switch (outcome) {
        case SendOutcome.delivered:
          for (final file in batch) {
            await _saveHistory(file.name, file.size, ip);
          }
          await NotificationService.add(
            title: batch.length == 1 ? 'File sent' : 'Files sent',
            body: '$summary delivered to $ip',
          );
          HapticFeedback.mediumImpact();
          _showMessage(
            batch.length == 1
                ? 'File delivered and verified by the receiver.'
                : 'All ${batch.length} files delivered and verified.',
          );
          if (mounted) _clearFiles();
          // The picker copies chosen files into the app's cache. Free it.
          try {
            await FilePicker.platform.clearTemporaryFiles();
          } catch (_) {}
        case SendOutcome.declined:
          await NotificationService.add(
            title: 'Transfer declined',
            body: '$ip declined $summary',
          );
          HapticFeedback.heavyImpact();
          _showMessage('The receiver declined the transfer.');
        case SendOutcome.unconfirmed:
          await NotificationService.add(
            title: 'Delivery not confirmed',
            body: '$summary was sent to $ip but the receiver did not confirm it',
          );
          HapticFeedback.heavyImpact();
          _showMessage(
            'Sent, but the receiver did not confirm it arrived. '
                'Check the receiving phone.',
          );
      }
    } on NearbyCancelledException {
      _showMessage('Transfer cancelled.');
    } on NearbyTransferException catch (e) {
      await NotificationService.add(title: 'Transfer failed', body: e.message);
      HapticFeedback.heavyImpact();
      _showMessage(e.message);
    } catch (e) {
      debugPrint('Send failed: $e');
      await NotificationService.add(
        title: 'Transfer failed',
        body: 'Could not send to $ip.',
      );
      HapticFeedback.heavyImpact();
      _showMessage(
        'Transfer failed. Check that both devices are on the same network.',
      );
    } finally {
      _sender = null;
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _sending = false;
          _progress = null;
          _code = null;
        });
      }
    }
  }

  /// Limits screen updates so fast transfers do not make the UI stutter.
  void _onProgress(TransferProgress progress) {
    if (!mounted) return;
    final now = DateTime.now();
    _startedAt ??= now;
    if (now.difference(_lastUiUpdate) < const Duration(milliseconds: 150) &&
        progress.fraction < 1) {
      return;
    }
    _lastUiUpdate = now;
    setState(() => _progress = progress);
  }

  Future<void> _saveHistory(String name, int size, String ip) async {
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
  }

  void _cancelTransfer() {
    _sender?.cancel();
  }

  // --------------------------------------------------------------- build

  bool get _canSend => _files.isNotEmpty && _selectedIp != null && !_sending;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _Palette.background,
      appBar: AppBar(
        backgroundColor: _Palette.background,
        foregroundColor: _Palette.text,
        elevation: 0,
        title: const Text(
          'Send files',
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
            _buildFilesCard(),
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
              onPressed: _canSend ? _sendFiles : null,
              icon: const Icon(Icons.send_rounded),
              label: Text(
                _sending
                    ? 'Sending…'
                    : _files.length > 1
                    ? 'Send ${_files.length} files'
                    : 'Send file',
              ),
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

  Widget _buildFilesCard() {
    if (_files.isEmpty) {
      return Material(
        color: _Palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: _Palette.border),
        ),
        child: InkWell(
          onTap: _sending ? null : _pickFiles,
          borderRadius: BorderRadius.circular(16),
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                _IconBox(icon: Icons.upload_file_rounded),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose files',
                        style: TextStyle(
                          color: _Palette.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Tap to browse. You can pick several at once.',
                        style: TextStyle(color: _Palette.muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final shown = _showAllFiles || _files.length <= _visibleFiles
        ? _files.length
        : _visibleFiles;
    final hidden = _files.length - shown;

    return Container(
      decoration: BoxDecoration(
        color: _Palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _Palette.accentLight),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_files.length} ${_files.length == 1 ? 'file' : 'files'}'
                        ' · ${_formatBytes(_totalSize)}',
                    style: const TextStyle(
                      color: _Palette.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _sending ? null : _pickFiles,
                  child: const Text('Add more'),
                ),
                TextButton(
                  onPressed: _sending ? null : _clearFiles,
                  style: TextButton.styleFrom(foregroundColor: _Palette.muted),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          for (var i = 0; i < shown; i++) ...[
            const Divider(height: 1, color: _Palette.border),
            _buildFileRow(i),
          ],
          if (hidden > 0 || _showAllFiles && _files.length > _visibleFiles) ...[
            const Divider(height: 1, color: _Palette.border),
            TextButton(
              onPressed: () => setState(() => _showAllFiles = !_showAllFiles),
              child: Text(_showAllFiles ? 'Show fewer' : 'Show $hidden more'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFileRow(int index) {
    final file = _files[index];

    return GestureDetector(
      onLongPress: _sending ? null : () => _showFileOptions(index),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const _IconBox(icon: Icons.insert_drive_file_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _Palette.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _formatBytes(file.size),
                    style: const TextStyle(color: _Palette.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!_sending)
              IconButton(
                tooltip: 'Remove ${file.name}',
                icon: const Icon(Icons.close_rounded, color: _Palette.muted),
                onPressed: () => _removeFile(index),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceSection() {
    final ip = _selectedIp;
    final verified = _selectedToken != null;
    final ips = _devices.keys.toList();

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
              border: Border.all(
                color: verified ? _Palette.accentLight : _Palette.warning,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      verified
                          ? Icons.verified_rounded
                          : Icons.warning_amber_rounded,
                      color: verified ? _Palette.accentLight : _Palette.warning,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Selected: $ip:$_port',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _Palette.text),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  verified
                      ? 'Verified by QR code.'
                      : _selectedKey == null
                      ? 'No key for this device. Scan its QR code again.'
                      : 'Not verified. Compare the 6-digit code with the '
                      "receiver's screen, or scan its QR code.",
                  style: TextStyle(
                    color: verified ? _Palette.muted : _Palette.warning,
                    fontSize: 12,
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
        if (ips.isEmpty)
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
                  'Pull down or tap Find nearby to search.\n'
                      'Devices found this way are not verified.',
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
                for (var i = 0; i < ips.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: _Palette.border),
                  _DeviceRow(
                    ip: ips[i],
                    selected: ips[i] == _selectedIp,
                    onTap: _sending ? null : () => _selectDiscovered(ips[i]),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildProgressCard() {
    final progress = _progress;
    final verified = _selectedToken != null;
    final code = _code;
    final percent = progress == null ? 0 : (progress.fraction * 100).round();

    String? speed;
    if (progress != null && _startedAt != null) {
      final seconds =
          DateTime.now().difference(_startedAt!).inMilliseconds / 1000;
      if (seconds > 0.5) {
        speed = '${_formatBytes((progress.bytesDone / seconds).round())}/s';
      }
    }

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
              Expanded(
                child: Text(
                  progress != null
                      ? (progress.fileCount == 1
                      ? 'Sending'
                      : 'Sending file ${progress.fileIndex + 1} of '
                      '${progress.fileCount}')
                      : 'Waiting for the receiver to accept…',
                  style: const TextStyle(
                    color: _Palette.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (progress != null)
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
          if (progress != null) ...[
            const SizedBox(height: 4),
            Text(
              progress.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _Palette.muted, fontSize: 13),
            ),
            Text(
              '${_formatBytes(progress.bytesDone)} of '
                  '${_formatBytes(progress.bytesTotal)}'
                  '${speed == null ? '' : ' · $speed'}',
              style: const TextStyle(color: _Palette.muted, fontSize: 12),
            ),
          ],
          if (code != null) ...[
            const SizedBox(height: 12),
            const Text(
              'Verification code',
              style: TextStyle(color: _Palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              '${code.substring(0, 3)} ${code.substring(3)}',
              style: const TextStyle(
                color: _Palette.accentLight,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              verified
                  ? "It should match the code on the receiver's screen."
                  : 'Not verified. Ask the receiver to confirm this code '
                  'matches before they accept.',
              style: TextStyle(
                color: verified ? _Palette.muted : _Palette.warning,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress?.fraction,
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
  void _showFileOptions(int index) {
    final file = _files[index];
    final name = file.name;

    GestureHandler.showFileOptions(
      context,
      fileName: name,
      onOpen: () => _showMessage('Opening $name'),
      onShare: () => _showMessage('Sharing $name'),
      onRename: () => _showMessage('Rename $name'),
      onDelete: () {
        _removeFile(index);
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
                  'Size: ${_formatBytes(file.size)}',
                  style: const TextStyle(color: _Palette.text),
                ),
                const SizedBox(height: 8),
                Text(
                  'Path: ${file.path}',
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
  return '${(bytes / gb).toStringAsFixed(2)} GB';
}
