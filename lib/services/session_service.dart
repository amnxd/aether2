import 'secret_storage.dart';

class SessionService {
  static const _tokenKey = 'aether.jwt';

  static Future<String?> getToken() async {
    return SecretStorage.read(_tokenKey);
  }

  static Future<void> setToken(String token) async {
    await SecretStorage.write(_tokenKey, token);
  }

  static Future<void> clearToken() async {
    await SecretStorage.delete(_tokenKey);
  }
}
