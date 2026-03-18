import 'secret_storage.dart';

class PeerTrustService {
  PeerTrustService._();

  static String _peerKey(int peerUserId) => 'aether.peer.$peerUserId.public_key_base64.pinned';

  static Future<String?> getPinnedPublicKeyBase64(int peerUserId) async {
    final v = await SecretStorage.read(_peerKey(peerUserId));
    if (v == null || v.isEmpty) return null;
    return v;
  }

  static Future<void> pinPublicKeyBase64(int peerUserId, String publicKeyBase64) async {
    if (publicKeyBase64.isEmpty) return;
    await SecretStorage.write(_peerKey(peerUserId), publicKeyBase64);
  }
}
