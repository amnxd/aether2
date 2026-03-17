import 'dart:convert';
import 'package:http/http.dart' as http;

import 'session_service.dart';

class BackendService {
  // Default base URL. Use 10.0.2.2 for Android emulator to reach host localhost.
  // Change to http://localhost:8080 when running on desktop or iOS simulator.
  static String baseUrl = const String.fromEnvironment('AETHER_BASE_URL', defaultValue: 'http://10.0.2.2:8080');
  static String? authToken;

  static Future<void> loadTokenFromDisk() async {
    authToken = await SessionService.getToken();
  }

  static Future<void> logout() async {
    authToken = null;
    await SessionService.clearToken();
  }

  static Future<String?> signUp(String email, String password) async {
    final url = Uri.parse('$baseUrl/signup');
    try {
      final resp = await http
          .post(url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'password': password}))
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 201) {
        final data = jsonDecode(resp.body);
        authToken = data['token'];
        if (authToken != null) {
          await SessionService.setToken(authToken!);
        }
        return null;
      }

      final err = _extractError(resp.body);
      return err;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> login(String email, String password) async {
    final url = Uri.parse('$baseUrl/login');
    try {
      final resp = await http
          .post(url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'password': password}))
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        authToken = data['token'];
        if (authToken != null) {
          await SessionService.setToken(authToken!);
        }
        return null;
      }

      final err = _extractError(resp.body);
      return err;
    } catch (e) {
      return e.toString();
    }
  }

  static Future<List<Map<String, dynamic>>> fetchUsers() async {
    final url = Uri.parse('$baseUrl/users');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static Future<List<Map<String, dynamic>>> fetchChatHistory(int chatId) async {
    final url = Uri.parse('$baseUrl/chats/$chatId/messages');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http
        .get(url, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static String _extractError(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map && data['error'] != null) return data['error'].toString();
      return body;
    } catch (_) {
      return body;
    }
  }
}
