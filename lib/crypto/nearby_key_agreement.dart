import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_exceptions.dart';

/// Result of a nearby key agreement.
class NearbySession {
  const NearbySession({required this.fileKey, required this.shortCode});

  /// 256-bit key for [StarShareStreamCipher]. Unique to this session.
  final SecretKey fileKey;

  /// 6-digit code. Both phones show it; the users compare. A mismatch means
  /// someone is sitting between the devices.
  final String shortCode;
}

/// Key agreement for device-to-device transfers.
///
/// Intended flow:
///   1. Receiver opens the Receive screen and creates a FRESH key pair, plus
///      a random 16-byte token. Both go into the QR code, with ip and port.
///   2. Sender scans the QR code, creates its own fresh key pair and sends its
///      public key in the handshake.
///   3. Both sides call [deriveSession] and get the same key and code.
///
/// Why this is safe on a local network:
///   - The receiver's public key arrives through the QR code, not the
///     network, so an attacker on the Wi-Fi cannot swap it.
///   - The token is mixed into the key derivation but never sent over the
///     network, so only a device that scanned the QR can derive the key.
///   - Both key pairs are ephemeral, so recording traffic today and stealing
///     a phone tomorrow does not reveal past files (forward secrecy).
///
/// If a device is picked from "Find nearby" (no QR), pass an empty token and
/// REQUIRE the users to compare [NearbySession.shortCode] before sending.
class NearbyKeyAgreement {
  static const int publicKeyLength = 32;

  static final X25519 _x25519 = X25519();
  static final Hkdf _hkdfKey = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final Hkdf _hkdfCode = Hkdf(hmac: Hmac.sha256(), outputLength: 4);
  static final Sha256 _sha256 = Sha256();

  static Future<SimpleKeyPair> generateKeyPair() => _x25519.newKeyPair();

  static Future<Uint8List> publicKeyBytes(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  /// Derives an independent 256-bit key from a session key for one purpose,
  /// for example one file inside a batch. Every file therefore gets its own
  /// key, so no two streams ever share a key and nonce.
  static Future<SecretKey> subKey(SecretKey sessionKey, String label) {
    return _hkdfKey.deriveKey(
      secretKey: sessionKey,
      info: utf8.encode(label),
    );
  }

  /// Both sides pass the SAME [senderPublicKey], [receiverPublicKey] and
  /// [token]; [localKeyPair] and [remotePublicKey] are each side's own view.
  static Future<NearbySession> deriveSession({
    required SimpleKeyPair localKeyPair,
    required List<int> remotePublicKey,
    required List<int> senderPublicKey,
    required List<int> receiverPublicKey,
    List<int> token = const [],
  }) async {
    for (final key in [remotePublicKey, senderPublicKey, receiverPublicKey]) {
      if (key.length != publicKeyLength) {
        throw ArgumentError('Public keys must be $publicKeyLength bytes.');
      }
    }

    final shared = await _x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: SimplePublicKey(remotePublicKey, type: KeyPairType.x25519),
    );

    // Reject the all-zero result produced by low-order public keys.
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((byte) => byte == 0)) {
      throw const CryptoException('Invalid public key.');
    }

    // Bind the keys to who is talking to whom, and to the QR token.
    final transcript = await _sha256.hash([
      ...senderPublicKey,
      ...receiverPublicKey,
      ...token,
    ]);

    final fileKey = await _hkdfKey.deriveKey(
      secretKey: shared,
      nonce: transcript.bytes,
      info: utf8.encode('StarShare v1 file key'),
    );

    final codeKey = await _hkdfCode.deriveKey(
      secretKey: shared,
      nonce: transcript.bytes,
      info: utf8.encode('StarShare v1 verification code'),
    );
    final codeBytes = Uint8List.fromList(await codeKey.extractBytes());
    final number = ByteData.sublistView(codeBytes).getUint32(0) % 1000000;

    return NearbySession(
      fileKey: fileKey,
      shortCode: number.toString().padLeft(6, '0'),
    );
  }
}
