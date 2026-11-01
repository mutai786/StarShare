import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/app_state.dart';
import '../services/database_service.dart';
import '../services/nearby_transfer_service.dart';
import '../services/notification_service.dart';

class _Palette {
  static const background = Color(0xFF0B1017);
  static const surface = Color(0xFF121A24);
  static const border = Color(0xFF1E2A38);
  static const text = Color(0xFFEEF2F7);
  static const muted = Color(0xFF8B98A9);
  static const accentLight = Color(0xFF60A5FA);
  static const warning = Color(0xFFF59E0B);
}

/// Files up to this size are also copied to Downloads automatically. Bigger
/// ones stay in the app folder until the user taps "Save to Downloads", so a
/// huge file does not silently take twice the storage.
const int _autoCopyLimit = 500 * 1024 * 1024;

class ReceiveFileScreen extends StatefulWidget {
  const ReceiveFileScreen({super.key});

  @override
  State<ReceiveFileScreen> createState() => _ReceiveFileScreenState();
}

class _ReceiveFileScreenState extends State<ReceiveFileScreen> {
  NearbyReceiver? _receiver;
  String? _ip;
  String _status = 'Starting…';
  bool _failed = false;
  bool _stopped = false;

  TransferProgress? _progress;
  DateTime? _startedAt;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  final List<ReceivedFile> _received = [];
  final Set<String> _inDownloads = {};

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _stopped = true;
    _receiver?.stop();
    _releaseWakeLock();
    super.dispose();
  }

  void _releaseWakeLock() {
    try {
      WakelockPlus.disable();
    } catch (_) {}
  }

  // --------------------------------------------------------------- start

  Future<void> _start() async {
    final ip = await _findLocalIp();
    if (_stopped) return;
    if (ip == null) {
      _fail('Not connected to a network. Join Wi-Fi or turn on a hotspot.');
      return;
    }

    final receiver = NearbyReceiver(
      saveDirectory: _saveDirectory,
      onRequest: _askUser,
      onProgress: _onProgress,
      onReceived: _onFileReceived,
      onBatchReceived: _onBatchReceived,
      onError: _onError,
    );

    try {
      await receiver.start();
    } catch (e) {
      _fail('Could not start receiving: $e');
      return;
    }

    // "Find nearby" is optional; the QR code works without it.
    try {
      await receiver.startDiscovery();
    } catch (e) {
      debugPrint('Discovery unavailable: $e');
    }

    if (_stopped) {
      await receiver.stop();
      return;
    }

    AppState.setCurrentDevice(ip: ip);
    setState(() {
      _receiver = receiver;
      _ip = ip;
      _status = 'Ready. Waiting for a sender…';
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _failed = true;
      _status = message;
    });
  }

  Future<String?> _findLocalIp() async {
    try {
      final interfaces =
      await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (e) {
      debugPrint('Could not read the local IP: $e');
    }
    return null;
  }

  Future<Directory> _saveDirectory() async {
    return await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
  }

  // ------------------------------------------------------------ callbacks

  /// Asks the user to approve an incoming batch. Closes itself and declines
  /// after 55 seconds so a forgotten dialog cannot block the next transfer.
  Future<bool> _askUser(IncomingBatch batch) async {
    if (!mounted) return false;

    BuildContext? dialogContext;
    final timer = Timer(const Duration(seconds: 55), () {
      final context = dialogContext;
      if (context != null && context.mounted) {
        Navigator.of(context).pop(false);
      }
    });

    const shownFiles = 5;
    final shown = batch.files.take(shownFiles).toList();
    final more = batch.files.length - shown.length;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        dialogContext = context;
        return AlertDialog(
          backgroundColor: _Palette.surface,
          title: Text(
            batch.files.length == 1
                ? 'Incoming file'
                : '${batch.files.length} incoming files',
            style: const TextStyle(color: _Palette.text),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final file in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${file.fileName}  ·  ${_formatBytes(file.fileSize)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _Palette.text),
                    ),
                  ),
                if (more > 0)
                  Text(
                    'and $more more',
                    style: const TextStyle(color: _Palette.muted),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Total ${_formatBytes(batch.totalSize)} · from '
                      '${batch.senderIp}',
                  style: const TextStyle(color: _Palette.muted),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Verification code',
                  style: TextStyle(color: _Palette.muted, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  '${batch.code.substring(0, 3)} ${batch.code.substring(3)}',
                  style: const TextStyle(
                    color: _Palette.accentLight,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  batch.verifiedByQr
                      ? 'The sender scanned your QR code. The code should '
                      "match the one on the sender's screen."
                      : 'NOT VERIFIED. This device was not found through '
                      'your QR code. Accept only if this code matches '
                      "the sender's screen.",
                  style: TextStyle(
                    color: batch.verifiedByQr
                        ? _Palette.muted
                        : _Palette.warning,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Decline'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(batch.files.length == 1 ? 'Accept' : 'Accept all'),
            ),
          ],
        );
      },
    );

    timer.cancel();
    final accepted = result ?? false;

    if (accepted) {
      // Keep the screen awake while files arrive.
      try {
        await WakelockPlus.enable();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _progress = null;
          _startedAt = null;
          _status = 'Receiving…';
        });
      }
    }
    return accepted;
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

  Future<void> _onFileReceived(ReceivedFile file) async {
    try {
      final db = await DatabaseService.database;
      await db.insert('transfers', {
        'fileName': file.fileName,
        'fileSize': file.fileSize,
        'direction': 'Received',
        'deviceIp': file.senderIp,
        'timestamp': DateFormat('dd/MM/yyyy  hh:mm a').format(DateTime.now()),
        'filePath': file.path,
      });
      AppState.notifyUpdate();
    } catch (e) {
      debugPrint('Could not save transfer history: $e');
    }

    if (mounted) {
      setState(() {
        _received.insert(0, file);
        if (_received.length > 30) _received.removeLast();
      });
    }

    // Also place a copy where the Files app, gallery and Recent files can
    // see it. The app's own folder is hidden from other apps on Android 11+.
    if (file.fileSize <= _autoCopyLimit && await _copyToDownloads(file)) {
      if (mounted) setState(() => _inDownloads.add(file.path));
    }
  }

  Future<void> _onBatchReceived(List<ReceivedFile> files) async {
    _releaseWakeLock();
    if (files.isEmpty) return;

    await NotificationService.add(
      title: files.length == 1 ? 'File received' : 'Files received',
      body: files.length == 1
          ? '${files.single.fileName} from ${files.single.senderIp}'
          : '${files.length} files from ${files.first.senderIp}',
      filePath: files.length == 1 ? files.single.path : null,
    );

    if (!mounted) return;
    setState(() {
      _progress = null;
      _status = files.length == 1
          ? 'Received ${files.single.fileName}'
          : 'Received ${files.length} files';
    });
  }

  void _onError(String message) {
    _releaseWakeLock();
    NotificationService.add(title: 'Transfer problem', body: message);
    if (!mounted) return;
    setState(() {
      _progress = null;
      _status = message;
    });
  }

  Future<bool> _copyToDownloads(ReceivedFile file) async {
    try {
      final info = await MediaStore().saveFile(
        tempFilePath: file.path,
        dirType: DirType.download,
        dirName: DirName.download,
      );
      return info != null;
    } catch (e) {
      debugPrint('Could not copy to Downloads: $e');
      return false;
    }
  }

  Future<void> _saveToDownloads(ReceivedFile file) async {
    _showMessage('Copying ${file.fileName} to Downloads…');
    final ok = await _copyToDownloads(file);
    if (!mounted) return;
    if (ok) setState(() => _inDownloads.add(file.path));
    _showMessage(ok
        ? 'Saved in Downloads/StarShare.'
        : 'Could not copy the file to Downloads.');
  }

  Future<void> _openFile(ReceivedFile file) async {
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      _showMessage('Could not open the file: ${result.message}');
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final receiver = _receiver;
    final ip = _ip;

    return Scaffold(
      backgroundColor: _Palette.background,
      appBar: AppBar(
        backgroundColor: _Palette.background,
        foregroundColor: _Palette.text,
        elevation: 0,
        title: const Text(
          'Receive files',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          if (receiver != null && ip != null)
            _buildQrCard(receiver, ip)
          else if (!_failed)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 16),
          _buildStatusCard(),
          if (_received.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text(
              'Received this session',
              style: TextStyle(
                color: _Palette.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            for (final file in _received) ...[
              _buildReceivedCard(file),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildQrCard(NearbyReceiver receiver, String ip) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _Palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _Palette.border),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: receiver.qrData(ip),
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Ask the sender to tap Scan QR and scan this code.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _Palette.text, fontSize: 15),
          ),
          const SizedBox(height: 6),
          Text(
            '$ip:${receiver.listeningPort}',
            style: const TextStyle(color: _Palette.muted, fontSize: 13),
          ),
          const SizedBox(height: 6),
          const Text(
            'This code is new each time you open this screen.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _Palette.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final progress = _progress;

    String? detail;
    if (progress != null) {
      final started = _startedAt;
      var speed = '';
      if (started != null) {
        final seconds =
            DateTime.now().difference(started).inMilliseconds / 1000;
        if (seconds > 0.5) {
          speed = ' · ${_formatBytes((progress.bytesDone / seconds).round())}/s';
        }
      }
      detail = '${_formatBytes(progress.bytesDone)} of '
          '${_formatBytes(progress.bytesTotal)}$speed';
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
          Text(
            progress != null && progress.fileCount > 1
                ? 'Receiving file ${progress.fileIndex + 1} of '
                '${progress.fileCount}'
                : _status,
            style: TextStyle(
              color: _failed ? _Palette.warning : _Palette.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: 4),
            Text(
              progress.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _Palette.muted, fontSize: 13),
            ),
            if (detail != null)
              Text(
                detail,
                style: const TextStyle(color: _Palette.muted, fontSize: 12),
              ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 6,
                color: _Palette.accentLight,
                backgroundColor: _Palette.border,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReceivedCard(ReceivedFile file) {
    final copied = _inDownloads.contains(file.path);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _Palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _Palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            file.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _Palette.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${_formatBytes(file.fileSize)} · verified and saved',
            style: const TextStyle(color: _Palette.muted, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            copied
                ? 'Also saved in Downloads/StarShare'
                : 'In the app folder only:\n${file.path}',
            style: const TextStyle(color: _Palette.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _openFile(file),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _Palette.text,
                  side: const BorderSide(color: _Palette.border),
                ),
              ),
              if (!copied)
                OutlinedButton.icon(
                  onPressed: () => _saveToDownloads(file),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Save to Downloads'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _Palette.text,
                    side: const BorderSide(color: _Palette.border),
                  ),
                ),
            ],
          ),
        ],
      ),
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
