import 'package:flutter_test/flutter_test.dart';
import 'package:starshare/utils/safe_file_name.dart';

void main() {
  test('keeps a normal name unchanged', () {
    expect(safeFileName('report.pdf'), 'report.pdf');
    expect(safeFileName('My Holiday Photo.jpg'), 'My Holiday Photo.jpg');
  });

  test('removes path traversal', () {
    expect(safeFileName('../../evil.sh'), 'evil.sh');
    expect(safeFileName('/etc/passwd'), 'passwd');
    expect(safeFileName(r'C:\Windows\system32\x.dll'), 'x.dll');
  });

  test('rejects names that are only dots or separators', () {
    expect(safeFileName('..'), 'received_file');
    expect(safeFileName('.'), 'received_file');
    expect(safeFileName('a/b/'), 'received_file');
    expect(safeFileName(''), 'received_file');
  });

  test('strips control characters and reserved characters', () {
    expect(safeFileName('a\nb\u0000c.txt'), 'abc.txt');
    expect(safeFileName('we<ir>d:na"me?.txt'), 'we_ir_d_na_me_.txt');
  });

  test('removes leading dots so files are not hidden', () {
    expect(safeFileName('.bashrc'), 'bashrc');
  });

  test('shortens long names but keeps the extension', () {
    final result = safeFileName('${'a' * 300}.pdf');
    expect(result.length, 120);
    expect(result.endsWith('.pdf'), isTrue);
  });
}
