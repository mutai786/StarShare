/// Turns a name received from another device into a safe file name.
///
/// The receiver must never build a path from an untrusted name directly:
/// a name like `../../x` could write outside the download folder.
String safeFileName(
    String input, {
      String fallback = 'received_file',
      int maxLength = 120,
    }) {
  // Keep only the last path segment (handles both / and \ separators).
  var name = input.replaceAll('\\', '/').split('/').last;

  // Remove control characters and characters Android/Windows reject.
  name = name.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '');
  name = name.replaceAll(RegExp(r'[<>:"|?*]'), '_');
  name = name.trim();

  // No leading dots: blocks ".", ".." and hidden files.
  name = name.replaceAll(RegExp(r'^\.+'), '');

  if (name.isEmpty) return fallback;

  if (name.length > maxLength) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 10) {
      final extension = name.substring(dot);
      name = name.substring(0, maxLength - extension.length) + extension;
    } else {
      name = name.substring(0, maxLength);
    }
  }
  return name;
}
