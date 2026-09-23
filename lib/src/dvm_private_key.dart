import 'package:ndk/ndk.dart';

/// Why [DvmPrivateKey.parse] rejected a key.
class DvmPrivateKeyException implements Exception {
  final String message;

  const DvmPrivateKeyException(this.message);

  @override
  String toString() => message;
}

/// A DVM private key, parsed from 64 hex characters or an `nsec1` key.
class DvmPrivateKey {
  static final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  final String hex;

  const DvmPrivateKey._(this.hex);

  /// Trims [value] and accepts either form in any case. Throws a
  /// [DvmPrivateKeyException] when it is neither.
  static DvmPrivateKey parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const DvmPrivateKeyException('DVM private key is empty');
    }

    if (trimmed.toLowerCase().startsWith('nsec1')) {
      final decoded = Nip19.decode(trimmed.toLowerCase());
      if (!_hexPattern.hasMatch(decoded)) {
        throw const DvmPrivateKeyException('DVM nsec private key is invalid');
      }
      return DvmPrivateKey._(decoded.toLowerCase());
    }

    if (!_hexPattern.hasMatch(trimmed)) {
      throw const DvmPrivateKeyException(
        'DVM private key must be 64 hex characters or an nsec1 key',
      );
    }

    return DvmPrivateKey._(trimmed.toLowerCase());
  }
}
