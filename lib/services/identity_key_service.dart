import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'secret_storage.dart';

class IdentityKeyService {
  IdentityKeyService._();

  static const _privKeyKey = 'aether.identity.x25519.private';
  static const _pubKeyKey = 'aether.identity.x25519.public';

  static final _x25519 = X25519();

  static Future<String> getOrCreatePublicKeyBase64() async {
    final existing = await SecretStorage.read(_pubKeyKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final kp = await _x25519.newKeyPair();
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();

    final privB64 = base64Encode(priv);
    final pubB64 = base64Encode(pub.bytes);

    await SecretStorage.write(_privKeyKey, privB64);
    await SecretStorage.write(_pubKeyKey, pubB64);
    return pubB64;
  }

  static Future<SimpleKeyPair> _getOrCreateKeyPair() async {
    final privB64 = await SecretStorage.read(_privKeyKey);
    final pubB64 = await SecretStorage.read(_pubKeyKey);

    if (privB64 != null && pubB64 != null && privB64.isNotEmpty && pubB64.isNotEmpty) {
      final privBytes = base64Decode(privB64);
      final pubBytes = base64Decode(pubB64);
      return SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    }

    // Create fresh
    await getOrCreatePublicKeyBase64();
    final privB64New = await SecretStorage.read(_privKeyKey);
    final pubB64New = await SecretStorage.read(_pubKeyKey);
    final privBytes = base64Decode(privB64New!);
    final pubBytes = base64Decode(pubB64New!);
    return SimpleKeyPairData(
      privBytes,
      publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  static Future<String?> deriveDmChatKeyBase64({
    required int chatId,
    required int myUserId,
    required int peerUserId,
    required String peerPublicKeyBase64,
  }) async {
    if (peerPublicKeyBase64.isEmpty) return null;

    final myKeyPair = await _getOrCreateKeyPair();
    final peerPkBytes = base64Decode(peerPublicKeyBase64);
    if (peerPkBytes.length != 32) return null;

    final shared = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(peerPkBytes, type: KeyPairType.x25519),
    );

    // Derive a stable symmetric key from the shared secret, scoped to this chat.
    // This does not provide forward secrecy, but keeps the server from ever seeing the key.
    final ids = [myUserId, peerUserId]..sort();
    final info = utf8.encode('aether.dm.v1.chat:$chatId.users:${ids[0]}-${ids[1]}');

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: shared,
      info: info,
      nonce: const [],
    );

    final keyBytes = await derived.extractBytes();
    return base64Encode(keyBytes);
  }
}
