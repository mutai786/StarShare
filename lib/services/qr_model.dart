import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What a receiving phone puts in its QR code.
///
/// Format:  starshare://v1?ip=<ipv4>&port=<port>&k=<public key>&t=<token>
///
/// - k: the receiver's one-time X25519 public key (32 bytes, base64url)
/// - t: a random secret token (16 bytes, base64url). It is mixed into the
///      key derivation and never sent over the network.
class DeviceQR {
  DeviceQR({
    required this.ip,
    required this.port,
    required this.publicKey,
    required this.token,
  });

  static const int publicKeyLength = 32;
  static const int tokenLength = 16;

  final String ip;
  final int port;
  final Uint8List publicKey;
  final Uint8List token;

  String toQR() {
    return Uri(
      scheme: 'starshare',
      host: 'v1',
      queryParameters: {
        'ip': ip,
        'port': port.toString(),
        'k': _encode(publicKey),
        't': _encode(token),
      },
    ).toString();
  }

  /// Returns null for anything that is not a valid StarShare v1 code.
  static DeviceQR? tryParse(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      if (uri.scheme != 'starshare' || uri.host != 'v1') return null;

      final ip = uri.queryParameters['ip'];
      final port = int.tryParse(uri.queryParameters['port'] ?? '');
      final key = uri.queryParameters['k'];
      final token = uri.queryParameters['t'];
      if (ip == null || port == null || key == null || token == null) {
        return null;
      }

      final address = InternetAddress.tryParse(ip);
      if (address == null || address.type != InternetAddressType.IPv4) {
        return null;
      }
      if (port < 1 || port > 65535) return null;

      final publicKey = _decode(key);
      final tokenBytes = _decode(token);
      if (publicKey.length != publicKeyLength ||
          tokenBytes.length != tokenLength) {
        return null;
      }

      return DeviceQR(
        ip: ip,
        port: port,
        publicKey: publicKey,
        token: tokenBytes,
      );
    } on FormatException {
      return null;
    }
  }

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _decode(String text) =>
      Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));
}
