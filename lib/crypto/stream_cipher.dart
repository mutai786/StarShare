import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/safe_file_name.dart';
import 'crypto_exceptions.dart';

/// Name and size of the file inside an encrypted stream.
class StreamMetadata {
  const StreamMetadata({required this.fileName, required this.fileSize});

  /// Already sanitized with [safeFileName]; safe to use inside a folder.
  final String fileName;
  final int fileSize;
}

/// Reads exact byte counts from a stream that can only be listened to once
/// (such as a dart:io Socket). Use ONE reader per socket for everything:
/// handshake lines and encrypted frames.
class ByteReader {
  ByteReader(Stream<List<int>> source) : _iterator = StreamIterator(source);

  final StreamIterator<List<int>> _iterator;
  List<int> _buffer = const [];
  int _position = 0;

  Future<Uint8List> readExact(int length) async {
    final out = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      if (_position >= _buffer.length) {
        if (!await _iterator.moveNext()) {
          throw TruncatedStreamException(
            'Stream ended after $filled of $length expected bytes.',
          );
        }
        _buffer = _iterator.current;
        _position = 0;
        continue;
      }
      final take = min(length - filled, _buffer.length - _position);
      out.setRange(filled, filled + take, _buffer, _position);
      filled += take;
      _position += take;
    }
    return out;
  }

  Future<void> cancel() => _iterator.cancel();
}

/// Authenticated, chunked file encryption (AES-256-GCM).
///
/// Wire format:
///   header : 'S' 'S' 0x01 | noncePrefix (4 random bytes) | chunkSize (u32)
///   frame  : flag (1 = final) | bodyLength (u32) | ciphertext | 16-byte tag
///
/// Frame 0 holds the file name and size (encrypted). Frames 1..n hold file
/// data; the last one has flag = 1.
///
/// Every frame is bound to its position and to the stream:
///   nonce = noncePrefix | counter (u64)
///   aad   = header | counter (u64) | flag
/// so reordered, replayed, substituted or truncated frames fail to verify.
///
/// IMPORTANT: use a NEW random key for every stream. The nonce counter makes
/// nonces unique inside a stream; key uniqueness makes them unique overall.
class StarShareStreamCipher {
  StarShareStreamCipher({Random? random}) : _random = random ?? Random.secure();

  static const int chunkSize = 64 * 1024;
  static const int tagLength = 16;
  static const int headerLength = 11;

  static const int _frameHeaderLength = 5;
  static const int _minChunkSize = 1024;
  static const int _maxChunkSize = 1024 * 1024;
  static const List<int> _magic = [0x53, 0x53, 0x01];

  final Random _random;
  final AesGcm _aes = AesGcm.with256bits();

  // ------------------------------------------------------------ encrypt

  /// Encrypts [plaintext] and yields the header followed by frames.
  /// Memory use is about one chunk plus the size of one incoming read.
  Stream<List<int>> encrypt({
    required Stream<List<int>> plaintext,
    required SecretKey key,
    required String fileName,
    required int fileSize,
  }) async* {
    final header = _buildHeader();
    final prefix = Uint8List.sublistView(header, 3, 7);
    yield header;

    var counter = 0;

    final metadata = utf8.encode(jsonEncode({'name': fileName, 'size': fileSize}));
    if (metadata.length > chunkSize) {
      throw ArgumentError('File name is too long.');
    }
    yield await _sealFrame(header, prefix, key, counter++, false, metadata);

    final pending = BytesBuilder();
    await for (final data in plaintext) {
      pending.add(data);
      if (pending.length > chunkSize) {
        final all = pending.takeBytes();
        var offset = 0;
        while (all.length - offset > chunkSize) {
          yield await _sealFrame(
            header,
            prefix,
            key,
            counter++,
            false,
            Uint8List.sublistView(all, offset, offset + chunkSize),
          );
          offset += chunkSize;
        }
        pending.add(Uint8List.sublistView(all, offset));
      }
    }

    // Whatever remains (0..chunkSize bytes) is the final frame.
    yield await _sealFrame(header, prefix, key, counter++, true, pending.takeBytes());
  }

  // ------------------------------------------------------------ decrypt

  /// Convenience wrapper for a plain stream.
  Future<StreamMetadata> decrypt({
    required Stream<List<int>> input,
    required SecretKey key,
    required FutureOr<void> Function(StreamMetadata metadata) onMetadata,
    required FutureOr<void> Function(List<int> bytes) onData,
  }) async {
    final reader = ByteReader(input);
    try {
      return await decryptFrom(
        reader: reader,
        key: key,
        onMetadata: onMetadata,
        onData: onData,
      );
    } finally {
      await reader.cancel();
    }
  }

  /// Decrypts from a [ByteReader]. Returns only after the final frame has
  /// been verified and the announced size matches.
  ///
  /// [onData] receives authenticated chunks as they arrive, but the file is
  /// only complete and trustworthy once this future completes normally.
  /// Write to a temporary file and rename it afterwards; delete it if this
  /// throws.
  Future<StreamMetadata> decryptFrom({
    required ByteReader reader,
    required SecretKey key,
    required FutureOr<void> Function(StreamMetadata metadata) onMetadata,
    required FutureOr<void> Function(List<int> bytes) onData,
  }) async {
    final header = await reader.readExact(headerLength);
    for (var i = 0; i < _magic.length; i++) {
      if (header[i] != _magic[i]) {
        throw const MalformedStreamException('Not a StarShare stream.');
      }
    }
    final prefix = Uint8List.sublistView(header, 3, 7);
    final declaredChunkSize = ByteData.sublistView(header).getUint32(7);
    if (declaredChunkSize < _minChunkSize || declaredChunkSize > _maxChunkSize) {
      throw const MalformedStreamException('Unsupported chunk size.');
    }

    StreamMetadata? metadata;
    var total = 0;
    var counter = 0;

    while (true) {
      final frameHeader = await reader.readExact(_frameHeaderLength);
      final flag = frameHeader[0];
      if (flag > 1) {
        throw const MalformedStreamException('Invalid frame flag.');
      }
      final bodyLength = ByteData.sublistView(frameHeader).getUint32(1);
      if (bodyLength < tagLength || bodyLength > declaredChunkSize + tagLength) {
        throw const MalformedStreamException('Invalid frame length.');
      }

      final body = await reader.readExact(bodyLength);
      final box = SecretBox(
        Uint8List.sublistView(body, 0, bodyLength - tagLength),
        nonce: buildNonce(prefix, counter),
        mac: Mac(Uint8List.sublistView(body, bodyLength - tagLength)),
      );

      final List<int> plain;
      try {
        plain = await _aes.decrypt(
          box,
          secretKey: key,
          aad: _buildAad(header, counter, flag),
        );
      } on SecretBoxAuthenticationError {
        throw const AuthenticationFailedException();
      }

      if (counter == 0) {
        if (flag == 1) {
          throw const MalformedStreamException('Stream has no metadata.');
        }
        metadata = _parseMetadata(plain);
        await onMetadata(metadata);
      } else {
        total += plain.length;
        if (total > metadata!.fileSize) {
          throw const MalformedStreamException('More data than announced.');
        }
        if (plain.isNotEmpty) await onData(plain);
        if (flag == 1) break;
      }
      counter++;
    }

    if (total != metadata!.fileSize) {
      throw const MalformedStreamException('File size does not match.');
    }
    return metadata;
  }

  // ------------------------------------------------------------ helpers

  Uint8List _buildHeader() {
    final header = Uint8List(headerLength);
    header.setRange(0, 3, _magic);
    for (var i = 3; i < 7; i++) {
      header[i] = _random.nextInt(256);
    }
    ByteData.sublistView(header).setUint32(7, chunkSize);
    return header;
  }

  /// nonce = 4-byte per-stream prefix | 8-byte big-endian counter.
  @visibleForTesting
  static Uint8List buildNonce(List<int> prefix, int counter) {
    final nonce = Uint8List(12);
    nonce.setRange(0, 4, prefix);
    ByteData.sublistView(nonce).setUint64(4, counter);
    return nonce;
  }

  static Uint8List _buildAad(Uint8List header, int counter, int flag) {
    final aad = Uint8List(header.length + 9);
    aad.setRange(0, header.length, header);
    ByteData.sublistView(aad).setUint64(header.length, counter);
    aad[header.length + 8] = flag;
    return aad;
  }

  Future<Uint8List> _sealFrame(
      Uint8List header,
      Uint8List prefix,
      SecretKey key,
      int counter,
      bool isFinal,
      List<int> plain,
      ) async {
    final flag = isFinal ? 1 : 0;
    final box = await _aes.encrypt(
      plain,
      secretKey: key,
      nonce: buildNonce(prefix, counter),
      aad: _buildAad(header, counter, flag),
    );
    final cipherLength = box.cipherText.length;
    final bodyLength = cipherLength + box.mac.bytes.length;

    final out = Uint8List(_frameHeaderLength + bodyLength);
    out[0] = flag;
    ByteData.sublistView(out).setUint32(1, bodyLength);
    out.setRange(_frameHeaderLength, _frameHeaderLength + cipherLength, box.cipherText);
    out.setRange(_frameHeaderLength + cipherLength, out.length, box.mac.bytes);
    return out;
  }

  StreamMetadata _parseMetadata(List<int> plain) {
    try {
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final name = json['name'] as String;
      final size = json['size'] as int;
      if (size < 0) throw const FormatException('negative size');
      return StreamMetadata(fileName: safeFileName(name), fileSize: size);
    } on Object {
      throw const MalformedStreamException('Invalid file metadata.');
    }
  }
}
