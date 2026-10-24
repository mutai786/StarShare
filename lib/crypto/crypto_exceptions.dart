/// Errors raised by the StarShare crypto core.
///
/// Callers should treat every one of these as "do not trust this transfer":
/// delete any partial output and tell the user the transfer failed.
class CryptoException implements Exception {
  const CryptoException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A chunk failed AES-GCM authentication. Causes: wrong key, modified
/// ciphertext, modified header, or chunks reordered / replayed / swapped.
class AuthenticationFailedException extends CryptoException {
  const AuthenticationFailedException()
      : super('Authentication failed: data was modified or the key is wrong.');
}

/// The stream ended before the final authenticated chunk arrived.
class TruncatedStreamException extends CryptoException {
  const TruncatedStreamException(super.message);
}

/// The stream is not a valid StarShare stream (bad magic, bad lengths,
/// inconsistent size, bad metadata).
class MalformedStreamException extends CryptoException {
  const MalformedStreamException(super.message);
}
