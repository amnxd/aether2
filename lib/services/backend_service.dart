import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'session_service.dart';

class BackendService {
  // Default base URL. Use 10.0.2.2 for Android emulator to reach host localhost.
  // Change to http://localhost:8080 when running on desktop or iOS simulator.
  static String baseUrl = const String.fromEnvironment('AETHER_BASE_URL', defaultValue: 'http://10.0.2.2:8080');
  static String? authToken;

  // Render (and similar hosts) may cold-start; 10s is often too short.
  static const Duration requestTimeout = Duration(seconds: 30);

  static String timeoutErrorMessage() {
    return 'Request timed out. If the backend is asleep (Render cold start), try again in a few seconds.';
  }

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
          .timeout(requestTimeout);

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
    } on TimeoutException {
      return timeoutErrorMessage();
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> signUpWithUsername(String email, String username, String password) async {
    final url = Uri.parse('$baseUrl/signup');
    try {
      final resp = await http
          .post(url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'username': username, 'password': password}))
          .timeout(requestTimeout);

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
    } on TimeoutException {
      return timeoutErrorMessage();
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
          .timeout(requestTimeout);

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
    } on TimeoutException {
      return timeoutErrorMessage();
    } catch (e) {
      return e.toString();
    }
  }

  static Future<List<Map<String, dynamic>>> fetchUsers() async {
    final url = Uri.parse('$baseUrl/users');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
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
        .timeout(requestTimeout);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static Future<Map<String, dynamic>> fetchMe() async {
    final url = Uri.parse('$baseUrl/me');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
    if (resp.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
    }
    throw _extractError(resp.body);
  }

  static Future<List<Map<String, dynamic>>> fetchChats() async {
    final url = Uri.parse('$baseUrl/chats');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static Future<int> createDm(String username) async {
    final url = Uri.parse('$baseUrl/chats/dm');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http
        .post(url,
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'username': username}))
        .timeout(requestTimeout);
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      final data = jsonDecode(resp.body);
      return (data['chatId'] as num).toInt();
    }
    throw _extractError(resp.body);
  }

  static Future<int> createGroup(String name, List<String> usernames) async {
    final url = Uri.parse('$baseUrl/chats/group');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http
        .post(url,
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'name': name, 'usernames': usernames}))
        .timeout(requestTimeout);
    if (resp.statusCode == 201) {
      final data = jsonDecode(resp.body);
      return (data['chatId'] as num).toInt();
    }
    throw _extractError(resp.body);
  }

  static Future<List<Map<String, dynamic>>> searchUsersByUsername(String prefix) async {
    final url = Uri.parse('$baseUrl/users/search?username=${Uri.encodeQueryComponent(prefix)}');
    final token = authToken;
    if (token == null) throw 'Missing auth token';
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
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
