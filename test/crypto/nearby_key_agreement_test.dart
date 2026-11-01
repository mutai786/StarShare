import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starshare/crypto/crypto_exceptions.dart';
import 'package:starshare/crypto/nearby_key_agreement.dart';
import 'package:starshare/crypto/stream_cipher.dart';

class Pair {
  Pair(this.sender, this.receiver, this.senderPublic, this.receiverPublic);

  final SimpleKeyPair sender;
  final SimpleKeyPair receiver;
  final Uint8List senderPublic;
  final Uint8List receiverPublic;
}

Future<Pair> newPair() async {
  final sender = await NearbyKeyAgreement.generateKeyPair();
  final receiver = await NearbyKeyAgreement.generateKeyPair();
  return Pair(
    sender,
    receiver,
    await NearbyKeyAgreement.publicKeyBytes(sender),
    await NearbyKeyAgreement.publicKeyBytes(receiver),
  );
}

Future<NearbySession> senderSide(Pair p, {List<int> token = const []}) {
  return NearbyKeyAgreement.deriveSession(
    localKeyPair: p.sender,
    remotePublicKey: p.receiverPublic,
    senderPublicKey: p.senderPublic,
    receiverPublicKey: p.receiverPublic,
    token: token,
  );
}

Future<NearbySession> receiverSide(Pair p, {List<int> token = const []}) {
  return NearbyKeyAgreement.deriveSession(
    localKeyPair: p.receiver,
    remotePublicKey: p.senderPublic,
    senderPublicKey: p.senderPublic,
    receiverPublicKey: p.receiverPublic,
    token: token,
  );
}

void main() {
  final token = List<int>.generate(16, (i) => i + 1);

  test('both sides derive the same key and the same 6-digit code', () async {
    final pair = await newPair();
    final a = await senderSide(pair, token: token);
    final b = await receiverSide(pair, token: token);

    expect(await a.fileKey.extractBytes(), await b.fileKey.extractBytes());
    expect(a.shortCode, b.shortCode);
    expect(a.shortCode, matches(RegExp(r'^\d{6}$')));
    expect((await a.fileKey.extractBytes()).length, 32);
  });

  test('a different QR token gives a different key', () async {
    final pair = await newPair();
    final a = await senderSide(pair, token: token);
    final b = await receiverSide(pair, token: List<int>.filled(16, 9));

    expect(
      await a.fileKey.extractBytes(),
      isNot(await b.fileKey.extractBytes()),
    );
  });

  test('every session gets a fresh key', () async {
    final first = await senderSide(await newPair(), token: token);
    final second = await senderSide(await newPair(), token: token);

    expect(
      await first.fileKey.extractBytes(),
      isNot(await second.fileKey.extractBytes()),
    );
  });

  test('a man in the middle cannot obtain the receiver\'s key', () async {
    final pair = await newPair();
    final attacker = await NearbyKeyAgreement.generateKeyPair();
    final attackerPublic = await NearbyKeyAgreement.publicKeyBytes(attacker);

    // The sender was tricked into using the attacker's public key.
    final fooled = await NearbyKeyAgreement.deriveSession(
      localKeyPair: pair.sender,
      remotePublicKey: attackerPublic,
      senderPublicKey: pair.senderPublic,
      receiverPublicKey: pair.receiverPublic,
      token: token,
    );
    final genuine = await receiverSide(pair, token: token);

    expect(
      await fooled.fileKey.extractBytes(),
      isNot(await genuine.fileKey.extractBytes()),
    );
  });

  test('a low-order (all-zero) public key is rejected', () async {
    final pair = await newPair();
    expect(
      NearbyKeyAgreement.deriveSession(
        localKeyPair: pair.sender,
        remotePublicKey: Uint8List(32),
        senderPublicKey: pair.senderPublic,
        receiverPublicKey: pair.receiverPublic,
        token: token,
      ),
      throwsA(anything),
    );
  });

  test('a public key of the wrong length is rejected', () async {
    final pair = await newPair();
    expect(
      NearbyKeyAgreement.deriveSession(
        localKeyPair: pair.sender,
        remotePublicKey: Uint8List(31),
        senderPublicKey: pair.senderPublic,
        receiverPublicKey: pair.receiverPublic,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('derived keys encrypt on one side and decrypt on the other', () async {
    final pair = await newPair();
    final sender = await senderSide(pair, token: token);
    final receiver = await receiverSide(pair, token: token);

    final random = Random(7);
    final plain = Uint8List.fromList(
      List.generate(150000, (_) => random.nextInt(256)),
    );

    final cipher = StarShareStreamCipher();
    final encrypted = BytesBuilder();
    await for (final part in cipher.encrypt(
      plaintext: Stream.value(plain),
      key: sender.fileKey,
      fileName: 'photo.jpg',
      fileSize: plain.length,
    )) {
      encrypted.add(part);
    }

    final decrypted = BytesBuilder();
    String? name;
    await cipher.decrypt(
      input: Stream.value(encrypted.takeBytes()),
      key: receiver.fileKey,
      onMetadata: (meta) => name = meta.fileName,
      onData: decrypted.add,
    );

    expect(decrypted.takeBytes(), plain);
    expect(name, 'photo.jpg');
  });

  test('sub keys differ per label and match on both sides', () async {
    final pair = await newPair();
    final a = await senderSide(pair, token: token);
    final b = await receiverSide(pair, token: token);

    final aFile0 = await NearbyKeyAgreement.subKey(a.fileKey, 'file 0');
    final aFile1 = await NearbyKeyAgreement.subKey(a.fileKey, 'file 1');
    final bFile0 = await NearbyKeyAgreement.subKey(b.fileKey, 'file 0');

    expect(await aFile0.extractBytes(), await bFile0.extractBytes());
    expect(await aFile0.extractBytes(), isNot(await aFile1.extractBytes()));
    expect(await aFile0.extractBytes(),
        isNot(await a.fileKey.extractBytes()));
    expect((await aFile0.extractBytes()).length, 32);
  });

  test('an eavesdropper with the wrong key cannot decrypt', () async {
    final pair = await newPair();
    final sender = await senderSide(pair, token: token);
    final eavesdropper = await senderSide(await newPair(), token: token);

    final cipher = StarShareStreamCipher();
    final encrypted = BytesBuilder();
    await for (final part in cipher.encrypt(
      plaintext: Stream.value(Uint8List.fromList([1, 2, 3, 4, 5])),
      key: sender.fileKey,
      fileName: 'x.bin',
      fileSize: 5,
    )) {
      encrypted.add(part);
    }

    expect(
      cipher.decrypt(
        input: Stream.value(encrypted.takeBytes()),
        key: eavesdropper.fileKey,
        onMetadata: (_) {},
        onData: (_) {},
      ),
      throwsA(isA<AuthenticationFailedException>()),
    );
  });
}
