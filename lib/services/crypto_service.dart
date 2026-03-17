import 'dart:convert';
import 'package:cryptography/cryptography.dart';

class CryptoService {
  static final _algorithm = Xchacha20.poly1305Aead();

  /// Generate a new random symmetric key (32 bytes) and return as base64 string.
  static Future<String> generateKeyBase64() async {
    final key = await _algorithm.newSecretKey();
    final bytes = await key.extractBytes();
    return base64Encode(bytes);
  }

  /// Encrypt plaintext using base64-encoded key. Returns map with ciphertext (base64) and nonce (base64).
  static Future<Map<String, String>> encrypt(String plaintext, String keyBase64) async {
    final keyBytes = base64Decode(keyBase64);
    final secretKey = SecretKey(keyBytes);
    final nonce = _algorithm.newNonce();
    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    return {
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  /// Decrypt ciphertext with base64 key and nonce. Returns plaintext string.
  static Future<String> decrypt(String ciphertextBase64, String nonceBase64, String keyBase64, String macBase64) async {
    final keyBytes = base64Decode(keyBase64);
    final secretKey = SecretKey(keyBytes);
    final cipherBytes = base64Decode(ciphertextBase64);
    final nonce = base64Decode(nonceBase64);
    final mac = Mac(base64Decode(macBase64));
    final secretBox = SecretBox(cipherBytes, nonce: nonce, mac: mac);
    final clear = await _algorithm.decrypt(secretBox, secretKey: secretKey);
    return utf8.decode(clear);
  }
}
