import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:starshare/services/qr_model.dart';

Uint8List bytes(int length, int start) =>
    Uint8List.fromList(List.generate(length, (i) => (start + i) % 256));

DeviceQR sample({
  String ip = '192.168.1.5',
  int port = 5000,
  Uint8List? key,
  Uint8List? token,
}) {
  return DeviceQR(
    ip: ip,
    port: port,
    publicKey: key ?? bytes(32, 1),
    token: token ?? bytes(16, 100),
  );
}

void main() {
  test('round trip keeps every field', () {
    final original = sample();
    final parsed = DeviceQR.tryParse(original.toQR());

    expect(parsed, isNotNull);
    expect(parsed!.ip, '192.168.1.5');
    expect(parsed.port, 5000);
    expect(parsed.publicKey, original.publicKey);
    expect(parsed.token, original.token);
  });

  test('payload is small enough for a clear QR code', () {
    expect(sample().toQR().length, lessThan(200));
  });

  test('rejects the old STARSHARE:ip:port format', () {
    expect(DeviceQR.tryParse('STARSHARE:192.168.1.5:5000'), isNull);
  });

  test('rejects other schemes and garbage', () {
    expect(DeviceQR.tryParse('https://example.com'), isNull);
    expect(DeviceQR.tryParse('hello'), isNull);
    expect(DeviceQR.tryParse(''), isNull);
  });

  test('rejects a missing field', () {
    expect(DeviceQR.tryParse('starshare://v1?ip=192.168.1.5&port=5000'), isNull);
  });

  test('rejects a public key of the wrong length', () {
    expect(DeviceQR.tryParse(sample(key: bytes(31, 1)).toQR()), isNull);
  });

  test('rejects a token of the wrong length', () {
    expect(DeviceQR.tryParse(sample(token: bytes(15, 1)).toQR()), isNull);
  });

  test('rejects an invalid or non-IPv4 address', () {
    expect(DeviceQR.tryParse(sample(ip: 'not-an-ip').toQR()), isNull);
    expect(DeviceQR.tryParse(sample(ip: '::1').toQR()), isNull);
  });

  test('rejects an out-of-range port', () {
    expect(DeviceQR.tryParse(sample(port: 0).toQR()), isNull);
    expect(DeviceQR.tryParse(sample(port: 70000).toQR()), isNull);
  });
}
