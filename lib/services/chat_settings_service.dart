import 'package:shared_preferences/shared_preferences.dart';

class ChatSettingsService {
  static String _enabledKey(int chatId) => 'aether.chat.$chatId.e2ee.enabled';
  static String _keyKey(int chatId) => 'aether.chat.$chatId.e2ee.key';

  static Future<bool?> getE2eeEnabled(int chatId) async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_enabledKey(chatId))) return null;
    return prefs.getBool(_enabledKey(chatId));
  }

  static Future<void> setE2eeEnabled(int chatId, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey(chatId), enabled);
  }

  static Future<String?> getE2eeKeyBase64(int chatId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyKey(chatId));
  }

  static Future<void> setE2eeKeyBase64(int chatId, String keyBase64) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyKey(chatId), keyBase64);
  }
}
