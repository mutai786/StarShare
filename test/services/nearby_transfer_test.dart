import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starshare/crypto/nearby_key_agreement.dart';
import 'package:starshare/crypto/stream_cipher.dart';
import 'package:starshare/services/nearby_transfer_service.dart';

Uint8List randomBytes(int length, [int seed = 1]) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition not met in time.');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A receiver on a free local port plus folders for source and saved files.
class Fixture {
  Fixture._(this.saveDir, this.sourceDir, this.receiver, this.requests,
      this.received, this.batches, this.errors, this.errorSeen);

  final Directory saveDir;
  final Directory sourceDir;
  final NearbyReceiver receiver;
  final List<IncomingBatch> requests;
  final List<ReceivedFile> received;
  final List<List<ReceivedFile>> batches;
  final List<String> errors;
  final Completer<void> errorSeen;

  static Future<Fixture> create({bool accept = true}) async {
    final saveDir = await Directory.systemTemp.createTemp('starshare_save_');
    final sourceDir = await Directory.systemTemp.createTemp('starshare_src_');
    final requests = <IncomingBatch>[];
    final received = <ReceivedFile>[];
    final batches = <List<ReceivedFile>>[];
    final errors = <String>[];
    final errorSeen = Completer<void>();

    final receiver = NearbyReceiver(
      port: 0,
      saveDirectory: () async => saveDir,
      onRequest: (batch) async {
        requests.add(batch);
        return accept;
      },
      onReceived: received.add,
      onBatchReceived: batches.add,
      onError: (message) {
        errors.add(message);
        if (!errorSeen.isCompleted) errorSeen.complete();
      },
    );
    await receiver.start();

    return Fixture._(saveDir, sourceDir, receiver, requests, received, batches,
        errors, errorSeen);
  }

  NearbySender sender({bool viaQr = true, Uint8List? token}) {
    return NearbySender(
      ip: '127.0.0.1',
      port: receiver.listeningPort,
      receiverPublicKey: receiver.publicKey,
      token: viaQr ? (token ?? receiver.token) : null,
    );
  }

  Future<OutgoingFile> source(String name, Uint8List data,
      {String? sentAs}) async {
    final file = File('${sourceDir.path}/$name');
    await file.writeAsBytes(data);
    return OutgoingFile(file: file, name: sentAs ?? name);
  }

  List<FileSystemEntity> get savedEntries => saveDir.listSync();

  Future<void> dispose() async {
    await receiver.stop();
    if (await saveDir.exists()) await saveDir.delete(recursive: true);
    if (await sourceDir.exists()) await sourceDir.delete(recursive: true);
  }
}

Future<Uint8List> encryptToBytes(
    Uint8List plain, SecretKey key, String name, int size) async {
  final out = BytesBuilder();
  await for (final part in StarShareStreamCipher().encrypt(
    plaintext: Stream.value(plain),
    key: key,
    fileName: name,
    fileSize: size,
  )) {
    out.add(part);
  }
  return out.takeBytes();
}

/// Plays a hand-made sender so the stream can be damaged on the way.
Future<void> rawSend(
    Fixture fixture, {
      required Uint8List Function(Uint8List encryptedFile) mutate,
      int? announcedSize,
    }) async {
  final socket =
  await Socket.connect('127.0.0.1', fixture.receiver.listeningPort);
  final reader = ByteReader(socket);
  socket.done.catchError((_) {});

  final keyPair = await NearbyKeyAgreement.generateKeyPair();
  final publicKey = await NearbyKeyAgreement.publicKeyBytes(keyPair);

  socket.add([0x53, 0x53, 0x48, 0x32, 1, ...publicKey]);
  final nonce = await reader.readExact(16);

  final session = await NearbyKeyAgreement.deriveSession(
    localKeyPair: keyPair,
    remotePublicKey: fixture.receiver.publicKey,
    senderPublicKey: publicKey,
    receiverPublicKey: fixture.receiver.publicKey,
    token: [...fixture.receiver.token, ...nonce],
  );

  final plain = randomBytes(300000, 5);

  final manifest = Uint8List.fromList(utf8.encode(jsonEncode({
    'files': [
      {'name': 'x.bin', 'size': announcedSize ?? plain.length},
    ],
  })));
  final manifestKey =
  await NearbyKeyAgreement.subKey(session.fileKey, 'StarShare v2 file list');
  final fileKey =
  await NearbyKeyAgreement.subKey(session.fileKey, 'StarShare v2 file 0');

  try {
    socket.add(
        await encryptToBytes(manifest, manifestKey, 'manifest', manifest.length));
    socket.add(
        mutate(await encryptToBytes(plain, fileKey, 'x.bin', plain.length)));
    await socket.flush();
    await socket.close();
  } on SocketException {
    // The receiver may reject the stream early and drop the connection while
    // we are still writing. That is the expected outcome in these tests.
  }

  await fixture.errorSeen.future.timeout(const Duration(seconds: 10));
  await reader.cancel();
  socket.destroy();
}

void main() {
  test('delivers one file end to end after QR verification', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    final data = randomBytes(200000);
    final file = await fixture.source('photo.jpg', data);

    final outcome = await fixture.sender().sendFiles(files: [file]);

    expect(outcome, SendOutcome.delivered);
    expect(fixture.received, hasLength(1));
    expect(await File(fixture.received.single.path).readAsBytes(), data);
    expect(fixture.requests.single.verifiedByQr, isTrue);
    expect(fixture.errors, isEmpty);
    // Only the finished file remains; no temporary files.
    expect(fixture.savedEntries, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('delivers several files with a single prompt', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    final contents = {
      'a.jpg': randomBytes(150000, 1),
      'b.pdf': randomBytes(5000, 2),
      'empty.txt': Uint8List(0),
      'c.bin': randomBytes(65536, 3),
    };
    final files = [
      for (final entry in contents.entries)
        await fixture.source(entry.key, entry.value),
    ];

    final progress = <TransferProgress>[];
    String? senderCode;
    final outcome = await fixture.sender().sendFiles(
      files: files,
      onCode: (code) => senderCode = code,
      onProgress: progress.add,
    );

    expect(outcome, SendOutcome.delivered);

    // One prompt for the whole batch, listing every file.
    expect(fixture.requests, hasLength(1));
    expect(fixture.requests.single.files, hasLength(4));
    expect(fixture.requests.single.totalSize,
        contents.values.fold<int>(0, (sum, bytes) => sum + bytes.length));
    expect(fixture.requests.single.code, senderCode);

    // Every file arrived intact, and the batch was reported once.
    expect(fixture.received, hasLength(4));
    expect(fixture.batches, hasLength(1));
    for (final saved in fixture.received) {
      expect(await File(saved.path).readAsBytes(), contents[saved.fileName]);
    }
    expect(fixture.savedEntries, hasLength(4));
    expect(fixture.errors, isEmpty);

    // Progress covers the whole batch and ends at 100 percent.
    expect(progress, isNotEmpty);
    expect(progress.last.fraction, 1.0);
    expect(progress.last.fileCount, 4);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('delivers a multi-megabyte file', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    final data = randomBytes(8 * 1024 * 1024, 9);
    final file = await fixture.source('big.bin', data);

    final outcome = await fixture.sender().sendFiles(files: [file]);

    expect(outcome, SendOutcome.delivered);
    final saved = File(fixture.received.single.path);
    expect(await saved.length(), data.length);
    expect(await saved.readAsBytes(), data);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('code-only mode works and is marked as not verified', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    final data = randomBytes(5000);
    final file = await fixture.source('note.bin', data);

    String? senderCode;
    final outcome = await fixture.sender(viaQr: false).sendFiles(
      files: [file],
      onCode: (code) => senderCode = code,
    );

    expect(outcome, SendOutcome.delivered);
    expect(fixture.requests.single.verifiedByQr, isFalse);
    expect(fixture.requests.single.code, senderCode);
    expect(await File(fixture.received.single.path).readAsBytes(), data);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a declined batch saves nothing', () async {
    final fixture = await Fixture.create(accept: false);
    addTearDown(fixture.dispose);

    final files = [
      await fixture.source('a.bin', randomBytes(1000, 1)),
      await fixture.source('b.bin', randomBytes(1000, 2)),
    ];
    final outcome = await fixture.sender().sendFiles(files: files);

    expect(outcome, SendOutcome.declined);
    expect(fixture.received, isEmpty);
    expect(fixture.savedEntries, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a sender without the QR token is rejected before any prompt', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    final files = [await fixture.source('a.bin', randomBytes(1000))];
    final intruder = fixture.sender(token: Uint8List(16));

    await expectLater(
      intruder.sendFiles(files: files),
      throwsA(isA<NearbyTransferException>()),
    );

    expect(fixture.requests, isEmpty);
    expect(fixture.errors, isNotEmpty);
    expect(fixture.received, isEmpty);
    expect(fixture.savedEntries, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a hostile file name cannot escape the save folder', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    final file = await fixture.source('real.bin', randomBytes(500),
        sentAs: '../../evil.txt');
    final outcome = await fixture.sender().sendFiles(files: [file]);

    expect(outcome, SendOutcome.delivered);
    expect(fixture.received.single.fileName, 'evil.txt');
    expect(File(fixture.received.single.path).parent.path, fixture.saveDir.path);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('files with the same name in one batch do not overwrite each other',
          () async {
        final fixture = await Fixture.create();
        addTearDown(fixture.dispose);

        final first = await fixture.source('one.bin', randomBytes(100, 1),
            sentAs: 'same.bin');
        final second = await fixture.source('two.bin', randomBytes(100, 2),
            sentAs: 'same.bin');

        final outcome = await fixture.sender().sendFiles(files: [first, second]);

        expect(outcome, SendOutcome.delivered);
        expect(fixture.received, hasLength(2));
        expect(fixture.received[0].path, isNot(fixture.received[1].path));
        expect(fixture.savedEntries, hasLength(2));
      }, timeout: const Timeout(Duration(seconds: 30)));

  test('an empty file list is refused by the sender', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    await expectLater(
      fixture.sender().sendFiles(files: const []),
      throwsA(isA<NearbyTransferException>()),
    );
  });

  test('a truncated file is rejected and its temporary file removed', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    await rawSend(
      fixture,
      mutate: (encrypted) => encrypted.sublist(0, encrypted.length - 100),
    );

    await waitUntil(() => fixture.savedEntries.isEmpty);
    expect(fixture.received, isEmpty);
    expect(fixture.errors, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a tampered file is rejected and its temporary file removed', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    await rawSend(
      fixture,
      mutate: (encrypted) {
        final damaged = Uint8List.fromList(encrypted);
        damaged[damaged.length ~/ 2] ^= 0x01;
        return damaged;
      },
    );

    await waitUntil(() => fixture.savedEntries.isEmpty);
    expect(fixture.received, isEmpty);
    expect(fixture.errors, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a file that does not match the announced list is rejected', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    // The list promises 10 bytes, the stream carries 300000.
    await rawSend(fixture, mutate: (encrypted) => encrypted, announcedSize: 10);

    await waitUntil(() => fixture.savedEntries.isEmpty);
    expect(fixture.received, isEmpty);
    expect(fixture.errors, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('discovery replies carry a parseable public key', () async {
    final fixture = await Fixture.create();
    addTearDown(fixture.dispose);

    final reply =
        'STARSHARE_HERE:${encodeDiscoveryKey(fixture.receiver.publicKey)}';
    expect(parseDiscoveryReply(reply), fixture.receiver.publicKey);
    expect(parseDiscoveryReply('STARSHARE_HERE'), isNull);
    expect(parseDiscoveryReply('STARSHARE_HERE:abc'), isNull);
    expect(parseDiscoveryReply('something else'), isNull);
  });
}
