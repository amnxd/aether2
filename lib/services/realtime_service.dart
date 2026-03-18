import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'backend_service.dart';
import 'notification_service.dart';

class RealtimeService {
  RealtimeService._();

  static final RealtimeService instance = RealtimeService._();

  final StreamController<Map<String, dynamic>> _messages = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);
  final ValueNotifier<int> onlineCount = ValueNotifier<int>(0);
  String? lastError;

  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;

  int? _activeChatId;
  int? get activeChatId => _activeChatId;

  void setActiveChatId(int? chatId) {
    _activeChatId = chatId;
  }

  Future<void> connect() async {
    final token = await BackendService.getValidAuthTokenOrNull();
    if (token == null) {
      lastError = 'Missing auth token';
      connected.value = false;
      return;
    }

    // already connected/connecting
    if (_channel != null) return;

    final base = Uri.parse(BackendService.baseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : (base.scheme == 'https' ? 443 : 80),
      path: '/ws',
      queryParameters: {'token': token},
    );

    try {
      _channel = IOWebSocketChannel.connect(wsUri);
      connected.value = true;
      lastError = null;

      _sub = _channel!.stream.listen(
        (dynamic msg) async {
          final payload = _decodeMessage(msg);
          if (payload == null) return;

          // Presence broadcast: online user count.
          if (payload['type'] == 'presence') {
            final v = payload['online_count'];
            final n = (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '');
            if (n != null) onlineCount.value = n;
            return;
          }

          // Notifications (best-effort): only show for other users and when not currently viewing that chat.
          final incomingChatId = _toInt(payload['chat_id']);
          final senderUserId = _toInt(payload['sender_user_id']);
          final meId = _toInt(BackendService.me?['id']);
          final isFromMe = meId != null && senderUserId != null && meId == senderUserId;

          if (!isFromMe && incomingChatId != null && incomingChatId != _activeChatId) {
            final senderUsername = payload['sender_username'];
            final senderEmail = payload['sender_email'];
            final sender = (senderUsername ?? senderEmail ?? 'Someone').toString();
            final text = (payload['text'] ?? (payload['e2ee_flag'] == true ? '[encrypted]' : '')).toString();
            await NotificationService.showChatMessage(
              chatId: incomingChatId,
              title: (senderUsername != null && senderUsername.toString().isNotEmpty)
                  ? (sender.startsWith('@') ? sender : '@$sender')
                  : sender,
              body: text,
            );
          }

          _messages.add(payload);
        },
        onDone: () {
          _cleanupChannel();
          connected.value = false;
          lastError = 'Disconnected';
          _scheduleReconnect();
        },
        onError: (_) {
          _cleanupChannel();
          connected.value = false;
          lastError = 'WebSocket error';
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _cleanupChannel();
      connected.value = false;
      lastError = e.toString();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      // allow future connect attempt
      connect();
    });
  }

  void _cleanupChannel() {
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cleanupChannel();
    connected.value = false;
  }

  void sendJson(Map<String, dynamic> payload) {
    final encoded = jsonEncode(payload);
    _channel?.sink.add(encoded);
  }

  Map<String, dynamic>? _decodeMessage(dynamic msg) {
    try {
      final data = jsonDecode(msg as String);
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return null;
    } catch (_) {
      return null;
    }
  }

  int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}
