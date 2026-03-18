import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'identity_key_service.dart';
import 'session_service.dart';

class BackendService {
  // Default base URL. Use 10.0.2.2 for Android emulator to reach host localhost.
  // Change to http://localhost:8080 when running on desktop or iOS simulator.
  static String baseUrl = const String.fromEnvironment('AETHER_BASE_URL', defaultValue: 'http://10.0.2.2:8080');
  static String? authToken;
  static Map<String, dynamic>? me;

  // Render (and similar hosts) may cold-start; 10s is often too short.
  static const Duration requestTimeout = Duration(seconds: 30);
  static const Duration warmUpTimeout = Duration(seconds: 20);
  static bool _warmedUp = false;

  static const String _sessionExpiredMessage = 'Session expired. Please log in again.';

  static String timeoutErrorMessage() {
    return 'Request timed out. If the backend is asleep (Render cold start), try again in a few seconds.';
  }

  static String _networkErrorMessage() {
    return 'Network error. Check internet connection and that the backend URL is correct.';
  }

  static String _tlsErrorMessage() {
    return 'Secure connection failed. Check device date/time and try again.';
  }

  static Future<void> warmUp() async {
    if (_warmedUp) return;
    try {
      final url = Uri.parse('$baseUrl/health');
      await http.get(url).timeout(warmUpTimeout);
      _warmedUp = true;
    } catch (_) {
      // Ignore warm-up failures; normal requests will surface errors.
    }
  }

  static Future<void> loadTokenFromDisk() async {
    authToken = await SessionService.getToken();
    // If token is already expired, clear it so the app starts in Login.
    await getValidAuthTokenOrNull();
  }

  static Future<void> logout() async {
    authToken = null;
    await SessionService.clearToken();
  }

  static Future<void> ensureMyPublicKeyRegistered() async {
    final token = await getValidAuthTokenOrNull();
    if (token == null) return;

    try {
      final pub = await IdentityKeyService.getOrCreatePublicKeyBase64();
      final url = Uri.parse('$baseUrl/me/public_key');
      final resp = await http
          .put(
            url,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'public_key_base64': pub}),
          )
          .timeout(requestTimeout);
      await _handleUnauthorized(resp);
    } catch (_) {
      // Best-effort; don't block login flow.
    }
  }

  static Map<String, dynamic>? _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      final payload = parts[1];
      final normalized = base64.normalize(payload);
      final bytes = base64Url.decode(normalized);
      final obj = jsonDecode(utf8.decode(bytes));
      if (obj is Map<String, dynamic>) return obj;
      if (obj is Map) return Map<String, dynamic>.from(obj);
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _isJwtExpired(String token, {Duration clockSkew = const Duration(seconds: 30)}) {
    final payload = _decodeJwtPayload(token);
    final exp = payload?['exp'];
    if (exp == null) return false; // no exp claim => treat as non-expiring

    final expSeconds = (exp is num) ? exp.toInt() : int.tryParse(exp.toString());
    if (expSeconds == null) return false;
    final expTime = DateTime.fromMillisecondsSinceEpoch(expSeconds * 1000, isUtc: true);
    final now = DateTime.now().toUtc().add(clockSkew);
    return !expTime.isAfter(now);
  }

  /// Returns a valid auth token, or clears it and returns null if missing/expired.
  static Future<String?> getValidAuthTokenOrNull() async {
    final token = authToken;
    if (token == null) return null;
    if (_isJwtExpired(token)) {
      await logout();
      return null;
    }
    return token;
  }

  static Future<String> _requireValidAuthToken() async {
    final token = await getValidAuthTokenOrNull();
    if (token == null) throw _sessionExpiredMessage;
    return token;
  }

  static Future<void> _handleUnauthorized(http.Response resp) async {
    if (resp.statusCode == 401) {
      await logout();
      throw _sessionExpiredMessage;
    }
  }

  static Future<void> registerFcmToken({
    required String token,
    required String platform,
  }) async {
    final auth = await getValidAuthTokenOrNull();
    if (auth == null) return;

    final resp = await http.post(
      Uri.parse('$baseUrl/push/register'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $auth',
      },
      body: jsonEncode({'token': token, 'platform': platform}),
    );
    await _handleUnauthorized(resp);
  }

  static Future<String?> signUp(String email, String password, {bool rememberMe = false}) async {
    final url = Uri.parse('$baseUrl/signup');
    try {
      final resp = await http
          .post(url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'password': password, 'rememberMe': rememberMe}))
          .timeout(requestTimeout);

      if (resp.statusCode == 201) {
        final data = jsonDecode(resp.body);
        authToken = data['token'];
        if (authToken != null) {
          await SessionService.setToken(authToken!);
        }
        await ensureMyPublicKeyRegistered();
        return null;
      }

      await _handleUnauthorized(resp);

      final err = _extractError(resp.body);
      return err;
    } on TimeoutException {
      return timeoutErrorMessage();
    } on SocketException {
      return _networkErrorMessage();
    } on HandshakeException {
      return _tlsErrorMessage();
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> signUpWithUsername(
    String email,
    String username,
    String password, {
    bool rememberMe = false,
  }) async {
    final url = Uri.parse('$baseUrl/signup');
    try {
      final resp = await http
          .post(url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'username': username, 'password': password, 'rememberMe': rememberMe}))
          .timeout(requestTimeout);

      if (resp.statusCode == 201) {
        final data = jsonDecode(resp.body);
        authToken = data['token'];
        if (authToken != null) {
          await SessionService.setToken(authToken!);
        }
        await ensureMyPublicKeyRegistered();
        return null;
      }

      await _handleUnauthorized(resp);

      final err = _extractError(resp.body);
      return err;
    } on TimeoutException {
      return timeoutErrorMessage();
    } on SocketException {
      return _networkErrorMessage();
    } on HandshakeException {
      return _tlsErrorMessage();
    } catch (e) {
      return e.toString();
    }
  }

  static Future<String?> login(String login, String password, {bool rememberMe = false}) async {
    final url = Uri.parse('$baseUrl/login');
    try {
      final resp = await http
          .post(url,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'login': login, 'password': password, 'rememberMe': rememberMe}))
          .timeout(requestTimeout);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        authToken = data['token'];
        if (authToken != null) {
          await SessionService.setToken(authToken!);
        }
        await ensureMyPublicKeyRegistered();
        return null;
      }

      await _handleUnauthorized(resp);

      final err = _extractError(resp.body);
      return err;
    } on TimeoutException {
      return timeoutErrorMessage();
    } on SocketException {
      return _networkErrorMessage();
    } on HandshakeException {
      return _tlsErrorMessage();
    } catch (e) {
      return e.toString();
    }
  }

  static Future<List<Map<String, dynamic>>> fetchUsers() async {
    final url = Uri.parse('$baseUrl/users');
    final token = await _requireValidAuthToken();
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static Future<List<Map<String, dynamic>>> fetchChatHistory(int chatId) async {
    final url = Uri.parse('$baseUrl/chats/$chatId/messages');
    final token = await _requireValidAuthToken();
    final resp = await http
        .get(url, headers: {'Authorization': 'Bearer $token'})
        .timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static Future<Map<String, dynamic>> fetchMe() async {
    final url = Uri.parse('$baseUrl/me');
    final token = await _requireValidAuthToken();
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) {
      final m = Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
      me = m;
      unawaited(ensureMyPublicKeyRegistered());
      return m;
    }
    throw _extractError(resp.body);
  }

  static Future<Map<String, dynamic>> fetchChatMeta(int chatId) async {
    final url = Uri.parse('$baseUrl/chats/$chatId');
    final token = await _requireValidAuthToken();
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
    }
    throw _extractError(resp.body);
  }

  static Future<List<Map<String, dynamic>>> fetchChats() async {
    final url = Uri.parse('$baseUrl/chats');
    final token = await _requireValidAuthToken();
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static Future<int> createDm(String username) async {
    final url = Uri.parse('$baseUrl/chats/dm');
    final token = await _requireValidAuthToken();
    final resp = await http
        .post(url,
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'username': username}))
        .timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      final data = jsonDecode(resp.body);
      return (data['chatId'] as num).toInt();
    }
    throw _extractError(resp.body);
  }

  static Future<int> createGroup(String name, List<String> usernames) async {
    final url = Uri.parse('$baseUrl/chats/group');
    final token = await _requireValidAuthToken();
    final resp = await http
        .post(url,
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'name': name, 'usernames': usernames}))
        .timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 201) {
      final data = jsonDecode(resp.body);
      return (data['chatId'] as num).toInt();
    }
    throw _extractError(resp.body);
  }

  static Future<List<Map<String, dynamic>>> searchUsersByUsername(String prefix) async {
    final url = Uri.parse('$baseUrl/users/search?username=${Uri.encodeQueryComponent(prefix)}');
    final token = await _requireValidAuthToken();
    final resp = await http.get(url, headers: {'Authorization': 'Bearer $token'}).timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as List<dynamic>;
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw _extractError(resp.body);
  }

  static Future<void> editMessage({required int messageId, required String text}) async {
    final token = await _requireValidAuthToken();
    final url = Uri.parse('$baseUrl/messages/$messageId');
    final resp = await http
        .patch(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'text': text}),
        )
        .timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) return;
    throw _extractError(resp.body);
  }

  static Future<void> deleteMessage({required int messageId}) async {
    final token = await _requireValidAuthToken();
    final url = Uri.parse('$baseUrl/messages/$messageId');
    final resp = await http
        .delete(
          url,
          headers: {
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(requestTimeout);
    await _handleUnauthorized(resp);
    if (resp.statusCode == 200) return;
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
