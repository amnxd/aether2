import 'secret_storage.dart';

class ChatSettingsService {
  static String _enabledKey(int chatId) => 'aether.chat.$chatId.e2ee.enabled';
  static String _keyKey(int chatId) => 'aether.chat.$chatId.e2ee.key';

  static Future<bool?> getE2eeEnabled(int chatId) async {
    final raw = await SecretStorage.read(_enabledKey(chatId));
    if (raw == null) return null;
    return raw == '1';
  }

  static Future<void> setE2eeEnabled(int chatId, bool enabled) async {
    await SecretStorage.write(_enabledKey(chatId), enabled ? '1' : '0');
  }

  static Future<String?> getE2eeKeyBase64(int chatId) async {
    return SecretStorage.read(_keyKey(chatId));
  }

  static Future<void> setE2eeKeyBase64(int chatId, String keyBase64) async {
    await SecretStorage.write(_keyKey(chatId), keyBase64);
  }
}
