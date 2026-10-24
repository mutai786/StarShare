import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:starshare/crypto/crypto_exceptions.dart';
import 'package:starshare/crypto/stream_cipher.dart';

final cipher = StarShareStreamCipher();

Future<SecretKey> newKey() => AesGcm.with256bits().newSecretKey();

Uint8List randomBytes(int length, [int seed = 1]) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

Stream<List<int>> chunked(Uint8List data, int size) async* {
  for (var i = 0; i < data.length; i += size) {
    yield data.sublist(i, min(i + size, data.length));
  }
}

Future<Uint8List> encryptBytes(
    Uint8List plain,
    SecretKey key, {
      String name = 'a.bin',
      int? declaredSize,
    }) async {
  final out = BytesBuilder();
  await for (final part in cipher.encrypt(
    plaintext: chunked(plain, 1000),
    key: key,
    fileName: name,
    fileSize: declaredSize ?? plain.length,
  )) {
    out.add(part);
  }
  return out.takeBytes();
}

class Decrypted {
  String? name;
  int? size;
  final data = BytesBuilder();
}

Future<Decrypted> decryptBytes(Uint8List encrypted, SecretKey key) async {
  final result = Decrypted();
  await cipher.decrypt(
    input: chunked(encrypted, 777),
    key: key,
    onMetadata: (meta) {
      result.name = meta.fileName;
      result.size = meta.fileSize;
    },
    onData: result.data.add,
  );
  return result;
}

/// Splits encrypted output into its frames (everything after the header).
List<Uint8List> splitFrames(Uint8List encrypted) {
  final frames = <Uint8List>[];
  var position = StarShareStreamCipher.headerLength;
  final view = ByteData.sublistView(encrypted);
  while (position < encrypted.length) {
    final end = position + 5 + view.getUint32(position + 1);
    frames.add(encrypted.sublist(position, end));
    position = end;
  }
  return frames;
}

Uint8List rebuild(Uint8List original, List<Uint8List> frames) {
  final out = BytesBuilder();
  out.add(original.sublist(0, StarShareStreamCipher.headerLength));
  frames.forEach(out.add);
  return out.takeBytes();
}

void main() {
  group('round trip', () {
    for (final size in [0, 1, 100, 65535, 65536, 65537, 200000]) {
      test('recovers the original file ($size bytes)', () async {
        final key = await newKey();
        final plain = randomBytes(size);

        final encrypted = await encryptBytes(plain, key, name: 'report.pdf');
        final decrypted = await decryptBytes(encrypted, key);

        expect(decrypted.data.takeBytes(), plain);
        expect(decrypted.name, 'report.pdf');
        expect(decrypted.size, size);
      });
    }

    test('hides the file name and contents in the ciphertext', () async {
      final key = await newKey();
      final plain = Uint8List.fromList(utf8.encode('top secret contents here'));

      final encrypted = await encryptBytes(plain, key, name: 'secret-name.txt');
      final text = latin1.decode(encrypted);

      expect(text.contains('secret-name'), isFalse);
      expect(text.contains('top secret'), isFalse);
    });

    test('sanitizes a hostile file name', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(
        randomBytes(10),
        key,
        name: '../../evil.sh',
      );
      final decrypted = await decryptBytes(encrypted, key);
      expect(decrypted.name, 'evil.sh');
    });
  });

  group('wrong key', () {
    test('is rejected', () async {
      final encrypted = await encryptBytes(randomBytes(5000), await newKey());
      expect(
        decryptBytes(encrypted, await newKey()),
        throwsA(isA<AuthenticationFailedException>()),
      );
    });
  });

  group('tampering', () {
    test('a modified ciphertext byte is detected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(200000), key);
      encrypted[encrypted.length ~/ 2] ^= 0x01;
      expect(
        decryptBytes(encrypted, key),
        throwsA(isA<AuthenticationFailedException>()),
      );
    });

    test('a modified header (nonce prefix) is detected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(5000), key);
      encrypted[3] ^= 0x01;
      expect(
        decryptBytes(encrypted, key),
        throwsA(isA<AuthenticationFailedException>()),
      );
    });

    test('a bad magic number is rejected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(5000), key);
      encrypted[0] ^= 0x01;
      expect(
        decryptBytes(encrypted, key),
        throwsA(isA<MalformedStreamException>()),
      );
    });

    test('clearing the final flag is detected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(5000), key);
      final frames = splitFrames(encrypted);
      frames.last[0] = 0;
      expect(
        decryptBytes(rebuild(encrypted, frames), key),
        throwsA(isA<AuthenticationFailedException>()),
      );
    });
  });

  group('truncation', () {
    test('dropping the last frame is detected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(200000), key);
      final frames = splitFrames(encrypted)..removeLast();
      expect(
        decryptBytes(rebuild(encrypted, frames), key),
        throwsA(isA<TruncatedStreamException>()),
      );
    });

    test('cutting the stream mid-frame is detected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(200000), key);
      final cut = encrypted.sublist(0, encrypted.length - 10);
      expect(
        decryptBytes(cut, key),
        throwsA(isA<TruncatedStreamException>()),
      );
    });

    test('an empty stream is rejected', () async {
      expect(
        decryptBytes(Uint8List(0), await newKey()),
        throwsA(isA<TruncatedStreamException>()),
      );
    });
  });

  group('reorder, replay and substitution', () {
    test('swapping two frames is detected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(200000), key);
      final frames = splitFrames(encrypted);
      final swap = frames[1];
      frames[1] = frames[2];
      frames[2] = swap;
      expect(
        decryptBytes(rebuild(encrypted, frames), key),
        throwsA(isA<AuthenticationFailedException>()),
      );
    });

    test('replaying an earlier frame is detected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(200000), key);
      final frames = splitFrames(encrypted);
      frames[2] = frames[1];
      expect(
        decryptBytes(rebuild(encrypted, frames), key),
        throwsA(isA<AuthenticationFailedException>()),
      );
    });

    test('a frame from another transfer under the same key is detected', () async {
      final key = await newKey();
      final first = await encryptBytes(randomBytes(200000, 1), key);
      final second = await encryptBytes(randomBytes(200000, 2), key);
      final frames = splitFrames(first);
      frames[1] = splitFrames(second)[1];
      expect(
        decryptBytes(rebuild(first, frames), key),
        throwsA(isA<AuthenticationFailedException>()),
      );
    });
  });

  group('announced size', () {
    test('less data than announced is rejected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(5), key, declaredSize: 10);
      expect(
        decryptBytes(encrypted, key),
        throwsA(isA<MalformedStreamException>()),
      );
    });

    test('more data than announced is rejected', () async {
      final key = await newKey();
      final encrypted = await encryptBytes(randomBytes(5), key, declaredSize: 3);
      expect(
        decryptBytes(encrypted, key),
        throwsA(isA<MalformedStreamException>()),
      );
    });
  });

  group('nonces', () {
    test('are unique for every counter value within a stream', () {
      final prefix = Uint8List.fromList([1, 2, 3, 4]);
      final seen = <String>{};
      for (var counter = 0; counter < 10000; counter++) {
        seen.add(StarShareStreamCipher.buildNonce(prefix, counter).join(','));
      }
      expect(seen.length, 10000);
    });

    test('differ between streams with different prefixes', () {
      final a = StarShareStreamCipher.buildNonce([1, 2, 3, 4], 7);
      final b = StarShareStreamCipher.buildNonce([4, 3, 2, 1], 7);
      expect(a, isNot(b));
    });
  });
}
