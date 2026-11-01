import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../crypto/crypto_exceptions.dart';
import '../crypto/nearby_key_agreement.dart';
import '../crypto/stream_cipher.dart';
import '../utils/safe_file_name.dart';
import 'qr_model.dart';

// ---------------------------------------------------------------------------
// Protocol v2 (one TCP connection carries a whole batch of files)
//
//   1. sender   -> receiver : 'SSH2' | mode (1 byte) | sender public key (32)
//        mode 1 = sender scanned the receiver's QR code (token is used)
//        mode 0 = code-only (picked from "Find nearby", no token)
//   2. receiver -> sender   : 16 random bytes (fresh for every connection)
//   3. both sides derive the session key and the 6-digit code
//   4. sender   -> receiver : the encrypted file LIST (names and sizes), using
//      a key derived from the session key. The receiver decrypts it, proving
//      the sender holds the key, and only then asks its user.
//   5. receiver -> sender   : 1 byte, 1 = accept, 0 = decline
//   6. sender   -> receiver : each file as its own encrypted stream, one after
//      the other, each with its OWN key derived from the session key
//   7. receiver -> sender   : 1 byte receipt, sent only after every file
//      verified and was saved
// ---------------------------------------------------------------------------

const List<int> _helloMagic = [0x53, 0x53, 0x48, 0x32];
const int _helloLength = 4 + 1 + NearbyKeyAgreement.publicKeyLength;
const int _nonceLength = 16;
const int _modeCodeOnly = 0;
const int _modeScannedQr = 1;
const int _answerDecline = 0;
const int _answerAccept = 1;
const int _receiptOk = 1;

const int _maxFiles = 1000;
const int _maxManifestBytes = 1024 * 1024;

const String _manifestLabel = 'StarShare v2 file list';
String _fileLabel(int index) => 'StarShare v2 file $index';

/// Base64url (no padding) for the key in "Find nearby" replies.
String encodeDiscoveryKey(List<int> publicKey) =>
    base64Url.encode(publicKey).replaceAll('=', '');

/// Reads a discovery reply such as `STARSHARE_HERE:<key>`.
/// Returns the receiver's public key, or null if it is not a valid reply.
Uint8List? parseDiscoveryReply(String message) {
  const prefix = 'STARSHARE_HERE:';
  if (!message.startsWith(prefix)) return null;
  try {
    final text = message.substring(prefix.length).trim();
    final key = Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));
    return key.length == NearbyKeyAgreement.publicKeyLength ? key : null;
  } on FormatException {
    return null;
  }
}

class NearbyTransferException implements Exception {
  const NearbyTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NearbyCancelledException extends NearbyTransferException {
  const NearbyCancelledException() : super('Transfer cancelled.');
}

class _Declined implements Exception {
  const _Declined();
}

/// One file the receiver's user is asked to approve.
class IncomingFile {
  const IncomingFile({required this.fileName, required this.fileSize});

  final String fileName;
  final int fileSize;
}

/// What the receiver's user is asked to approve: the whole batch at once.
class IncomingBatch {
  const IncomingBatch({
    required this.files,
    required this.code,
    required this.verifiedByQr,
    required this.senderIp,
  });

  final List<IncomingFile> files;

  /// 6-digit code. The sender's screen shows the same code.
  final String code;

  /// True when the sender proved it scanned this receiver's QR code.
  /// False means the sender is NOT verified: accept only if the code matches.
  final bool verifiedByQr;
  final String senderIp;

  int get totalSize => files.fold(0, (sum, file) => sum + file.fileSize);
}

/// Progress of a whole batch, shared by sender and receiver.
class TransferProgress {
  const TransferProgress({
    required this.fileIndex,
    required this.fileCount,
    required this.fileName,
    required this.bytesDone,
    required this.bytesTotal,
  });

  /// 0-based index of the file being transferred.
  final int fileIndex;
  final int fileCount;
  final String fileName;

  /// Bytes finished across the whole batch, and the batch total.
  final int bytesDone;
  final int bytesTotal;

  double get fraction => bytesTotal == 0 ? 1.0 : bytesDone / bytesTotal;
}

class ReceivedFile {
  const ReceivedFile({
    required this.path,
    required this.fileName,
    required this.fileSize,
    required this.senderIp,
  });

  final String path;
  final String fileName;
  final int fileSize;
  final String senderIp;
}

class OutgoingFile {
  const OutgoingFile({required this.file, required this.name});

  final File file;

  /// The name the receiver will see.
  final String name;
}

class _Entry {
  const _Entry(this.safeName, this.size);

  final String safeName;
  final int size;
}

List<_Entry> _parseManifest(Uint8List bytes) {
  try {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final list = json['files'] as List<dynamic>;
    if (list.isEmpty || list.length > _maxFiles) {
      throw const FormatException('file count');
    }
    return [for (final item in list) _entryFrom(item as Map<String, dynamic>)];
  } on Object {
    throw const MalformedStreamException('Invalid file list.');
  }
}

_Entry _entryFrom(Map<String, dynamic> map) {
  final size = map['size'] as int;
  if (size < 0) throw const FormatException('size');
  return _Entry(safeFileName(map['name'] as String), size);
}

// ---------------------------------------------------------------------------
// Receiver
// ---------------------------------------------------------------------------

class NearbyReceiver {
  NearbyReceiver({
    this.port = 5000,
    required this.saveDirectory,
    required this.onRequest,
    this.onProgress,
    this.onReceived,
    this.onBatchReceived,
    this.onError,
  });

  /// Use 0 in tests to let the system pick a free port.
  final int port;

  final Future<Directory> Function() saveDirectory;

  /// Asked once per batch, after the sender proved it holds the key.
  final Future<bool> Function(IncomingBatch batch) onRequest;

  final void Function(TransferProgress progress)? onProgress;

  /// Called for every file as soon as it is verified and saved.
  final void Function(ReceivedFile file)? onReceived;

  /// Called once, after every file of the batch was verified and saved.
  final void Function(List<ReceivedFile> files)? onBatchReceived;

  final void Function(String message)? onError;

  final StarShareStreamCipher _cipher = StarShareStreamCipher();
  final Random _random = Random.secure();

  SimpleKeyPair? _keyPair;
  Uint8List? _publicKey;
  Uint8List? _token;
  ServerSocket? _server;
  RawDatagramSocket? _discovery;
  Socket? _active;

  int get listeningPort => _server?.port ?? port;

  /// One-time public key of this receive session (goes into the QR code).
  Uint8List get publicKey => _publicKey!;

  /// One-time secret token of this receive session (goes into the QR code).
  Uint8List get token => _token!;

  /// Creates fresh keys and starts listening. Keys live only as long as this
  /// object, so closing the Receive screen invalidates the QR code.
  Future<void> start() async {
    final keyPair = await NearbyKeyAgreement.generateKeyPair();
    _keyPair = keyPair;
    _publicKey = await NearbyKeyAgreement.publicKeyBytes(keyPair);
    _token = Uint8List.fromList(
      List.generate(DeviceQR.tokenLength, (_) => _random.nextInt(256)),
    );

    final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(
      _handleClient,
      onError: (Object e) => onError?.call('Server error: $e'),
    );
  }

  /// Answers "Find nearby" searches with this session's public key.
  /// Devices found this way are NOT verified, so the 6-digit code must be
  /// compared by the users.
  Future<void> startDiscovery() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8888);
    socket.broadcastEnabled = true;
    _discovery = socket;

    final reply = utf8.encode('STARSHARE_HERE:${encodeDiscoveryKey(publicKey)}');
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final message = utf8.decode(datagram.data, allowMalformed: true);
      if (message == 'STARSHARE_DISCOVER') {
        socket.send(reply, datagram.address, datagram.port);
      }
    });
  }

  /// Text for the QR code that senders scan.
  String qrData(String ip) => DeviceQR(
    ip: ip,
    port: listeningPort,
    publicKey: publicKey,
    token: token,
  ).toQR();

  Future<void> stop() async {
    _active?.destroy();
    await _server?.close();
    _server = null;
    _discovery?.close();
    _discovery = null;
  }

  Future<void> _handleClient(Socket client) async {
    // One transfer at a time.
    if (_active != null || _keyPair == null) {
      client.destroy();
      return;
    }
    _active = client;

    final senderIp = client.remoteAddress.address;
    final reader = ByteReader(client);
    File? partFile;
    RandomAccessFile? output;
    Timer? watchdog;
    var lastActivity = DateTime.now();

    try {
      final hello = await reader
          .readExact(_helloLength)
          .timeout(const Duration(seconds: 10));
      for (var i = 0; i < _helloMagic.length; i++) {
        if (hello[i] != _helloMagic[i]) return;
      }
      final mode = hello[4];
      if (mode != _modeCodeOnly && mode != _modeScannedQr) return;
      final viaQr = mode == _modeScannedQr;
      final senderPublic = Uint8List.fromList(hello.sublist(5));

      final nonce = Uint8List.fromList(
        List.generate(_nonceLength, (_) => _random.nextInt(256)),
      );
      client.add(nonce);
      await client.flush();

      final session = await NearbyKeyAgreement.deriveSession(
        localKeyPair: _keyPair!,
        remotePublicKey: senderPublic,
        senderPublicKey: senderPublic,
        receiverPublicKey: _publicKey!,
        token: [...(viaQr ? _token! : const <int>[]), ...nonce],
      );

      // Step 4: the encrypted file list. Decrypting it proves the sender has
      // the key; a sender without the QR token fails here, before any prompt.
      final manifestKey =
      await NearbyKeyAgreement.subKey(session.fileKey, _manifestLabel);
      final manifestBytes = BytesBuilder();
      await _cipher.decryptFrom(
        reader: reader,
        key: manifestKey,
        onMetadata: (meta) {
          if (meta.fileSize > _maxManifestBytes) {
            throw const MalformedStreamException('File list is too large.');
          }
        },
        onData: manifestBytes.add,
      ).timeout(const Duration(seconds: 30));
      final entries = _parseManifest(manifestBytes.takeBytes());
      final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.size);

      final accepted = await onRequest(
        IncomingBatch(
          files: [
            for (final e in entries)
              IncomingFile(fileName: e.safeName, fileSize: e.size),
          ],
          code: session.shortCode,
          verifiedByQr: viaQr,
          senderIp: senderIp,
        ),
      ).timeout(const Duration(seconds: 60), onTimeout: () => false);

      if (!accepted) {
        client.add([_answerDecline]);
        await client.flush();
        throw const _Declined();
      }

      final directory = await saveDirectory();
      await directory.create(recursive: true);

      client.add([_answerAccept]);
      await client.flush();

      lastActivity = DateTime.now();
      watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        if (DateTime.now().difference(lastActivity) >
            const Duration(seconds: 60)) {
          client.destroy();
        }
      });

      // Step 6: every file, one after another.
      final saved = <ReceivedFile>[];
      var doneBytes = 0;

      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final fileKey =
        await NearbyKeyAgreement.subKey(session.fileKey, _fileLabel(i));

        final metadata = await _cipher.decryptFrom(
          reader: reader,
          key: fileKey,
          onMetadata: (meta) async {
            // The stream must be exactly the file that was announced.
            if (meta.fileSize != entry.size || meta.fileName != entry.safeName) {
              throw const MalformedStreamException(
                'A file did not match the announced list.',
              );
            }
            // Write to a hidden temporary file; it only becomes the real file
            // after the final frame has been verified.
            partFile = File(
              p.join(directory.path, '.starshare_${_randomHex(8)}.part'),
            );
            output = await partFile!.open(mode: FileMode.write);
          },
          onData: (bytes) async {
            await output!.writeFrom(bytes);
            doneBytes += bytes.length;
            lastActivity = DateTime.now();
            onProgress?.call(
              TransferProgress(
                fileIndex: i,
                fileCount: entries.length,
                fileName: entry.safeName,
                bytesDone: doneBytes,
                bytesTotal: totalBytes,
              ),
            );
          },
        );

        await output!.close();
        output = null;

        final target = await _uniqueFile(directory, metadata.fileName);
        await partFile!.rename(target.path);
        partFile = null;

        final file = ReceivedFile(
          path: target.path,
          fileName: p.basename(target.path),
          fileSize: metadata.fileSize,
          senderIp: senderIp,
        );
        saved.add(file);
        onReceived?.call(file);
      }

      onBatchReceived?.call(saved);

      client.add([_receiptOk]);
      await client.flush();
      await client.close();
    } on _Declined {
      // The user said no. Nothing to report.
    } on TimeoutException {
      onError?.call('A device connected but did not finish the handshake.');
    } on AuthenticationFailedException {
      onError?.call('A transfer was rejected because it failed verification.');
    } on CryptoException catch (e) {
      onError?.call('Transfer failed: ${e.message}');
    } catch (e) {
      onError?.call('Transfer error: $e');
    } finally {
      watchdog?.cancel();
      try {
        await output?.close();
      } catch (_) {}
      final leftover = partFile;
      if (leftover != null) {
        try {
          await leftover.delete();
        } catch (_) {}
      }
      try {
        await reader.cancel();
      } catch (_) {}
      client.destroy();
      _active = null;
    }
  }

  String _randomHex(int bytes) => List.generate(
    bytes,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<File> _uniqueFile(Directory directory, String name) async {
    var candidate = File(p.join(directory.path, name));
    if (!await candidate.exists()) return candidate;

    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; i < 10000; i++) {
      candidate = File(p.join(directory.path, '$stem ($i)$extension'));
      if (!await candidate.exists()) return candidate;
    }
    throw const FileSystemException('Could not choose a file name');
  }
}

// ---------------------------------------------------------------------------
// Sender
// ---------------------------------------------------------------------------

enum SendOutcome {
  /// The receiver verified every file and saved it.
  delivered,

  /// The receiver's user declined.
  declined,

  /// Everything was sent but the receiver's final confirmation never arrived.
  unconfirmed,
}

class NearbySender {
  /// Pass [token] when the receiver was found by scanning its QR code.
  /// Leave it null for devices picked from "Find nearby"; the users must
  /// then compare the 6-digit code.
  NearbySender({
    required this.ip,
    required this.port,
    required this.receiverPublicKey,
    this.token,
  });

  final String ip;
  final int port;
  final Uint8List receiverPublicKey;
  final Uint8List? token;

  final StarShareStreamCipher _cipher = StarShareStreamCipher();
  Socket? _socket;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _socket?.destroy();
  }

  /// Sends all [files] over one connection with a single accept prompt.
  /// Throws [NearbyTransferException] (or [NearbyCancelledException]) when
  /// the transfer cannot be completed.
  Future<SendOutcome> sendFiles({
    required List<OutgoingFile> files,
    void Function(String code)? onCode,
    void Function(TransferProgress progress)? onProgress,
    Duration acceptTimeout = const Duration(minutes: 2),
  }) async {
    if (files.isEmpty) {
      throw const NearbyTransferException('Nothing to send.');
    }
    if (files.length > _maxFiles) {
      throw const NearbyTransferException('Too many files in one transfer.');
    }

    final sizes = <int>[];
    for (final item in files) {
      sizes.add(await item.file.length());
    }
    final totalBytes = sizes.fold<int>(0, (sum, size) => sum + size);

    Socket? socket;
    ByteReader? reader;

    try {
      socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 10),
      );
      _socket = socket;
      reader = ByteReader(socket);

      final keyPair = await NearbyKeyAgreement.generateKeyPair();
      final myPublic = await NearbyKeyAgreement.publicKeyBytes(keyPair);

      socket.add([
        ..._helloMagic,
        token == null ? _modeCodeOnly : _modeScannedQr,
        ...myPublic,
      ]);
      await socket.flush();

      final Uint8List nonce;
      try {
        nonce = await reader
            .readExact(_nonceLength)
            .timeout(const Duration(seconds: 15));
      } on TruncatedStreamException {
        throw const NearbyTransferException('The receiver closed the connection.');
      } on SocketException {
        throw const NearbyTransferException('The receiver closed the connection.');
      } on TimeoutException {
        throw const NearbyTransferException(
          'The receiver did not answer. Is its Receive screen open?',
        );
      }

      final session = await NearbyKeyAgreement.deriveSession(
        localKeyPair: keyPair,
        remotePublicKey: receiverPublicKey,
        senderPublicKey: myPublic,
        receiverPublicKey: receiverPublicKey,
        token: [...?token, ...nonce],
      );
      onCode?.call(session.shortCode);

      // The encrypted file list goes first; files wait for the answer.
      final manifestKey =
      await NearbyKeyAgreement.subKey(session.fileKey, _manifestLabel);
      final manifest = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'files': [
              for (var i = 0; i < files.length; i++)
                {'name': files[i].name, 'size': sizes[i]},
            ],
          }),
        ),
      );
      await socket.addStream(
        _cipher.encrypt(
          plaintext: Stream.value(manifest),
          key: manifestKey,
          fileName: 'manifest',
          fileSize: manifest.length,
        ),
      );
      await socket.flush();

      final int answer;
      try {
        answer = (await reader.readExact(1).timeout(acceptTimeout))[0];
      } on TruncatedStreamException {
        throw const NearbyTransferException(
          'The receiver closed the connection. If you scanned a QR code, '
              'scan it again.',
        );
      } on SocketException {
        throw const NearbyTransferException('The receiver closed the connection.');
      } on TimeoutException {
        throw const NearbyTransferException('The receiver did not respond.');
      }
      if (answer != _answerAccept) return SendOutcome.declined;

      var doneBytes = 0;
      for (var i = 0; i < files.length; i++) {
        final item = files[i];
        final fileKey =
        await NearbyKeyAgreement.subKey(session.fileKey, _fileLabel(i));

        final plaintext = item.file.openRead().map((chunk) {
          if (_cancelled) throw const NearbyCancelledException();
          doneBytes += chunk.length;
          onProgress?.call(
            TransferProgress(
              fileIndex: i,
              fileCount: files.length,
              fileName: item.name,
              bytesDone: doneBytes,
              bytesTotal: totalBytes,
            ),
          );
          return chunk;
        });

        await socket.addStream(
          _cipher.encrypt(
            plaintext: plaintext,
            key: fileKey,
            fileName: item.name,
            fileSize: sizes[i],
          ),
        );
      }
      await socket.flush();

      try {
        final receipt =
        (await reader.readExact(1).timeout(const Duration(seconds: 60)))[0];
        return receipt == _receiptOk
            ? SendOutcome.delivered
            : SendOutcome.unconfirmed;
      } on TruncatedStreamException {
        return SendOutcome.unconfirmed;
      } on SocketException {
        return SendOutcome.unconfirmed;
      } on TimeoutException {
        return SendOutcome.unconfirmed;
      }
    } on NearbyTransferException {
      rethrow;
    } catch (e) {
      if (_cancelled) throw const NearbyCancelledException();
      rethrow;
    } finally {
      try {
        await reader?.cancel();
      } catch (_) {}
      socket?.destroy();
      _socket = null;
    }
  }
}
