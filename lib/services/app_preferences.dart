import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences {
  static const String _showGlobalChatKey = 'aether.show_global_chat';

  static Future<bool> getShowGlobalChat() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showGlobalChatKey) ?? true;
  }

  static Future<void> setShowGlobalChat(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showGlobalChatKey, value);
  }
}
