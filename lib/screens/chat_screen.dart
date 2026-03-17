import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../services/backend_service.dart';
import '../services/chat_settings_service.dart';
import '../services/crypto_service.dart';
import '../services/realtime_service.dart';

class ChatScreen extends StatefulWidget {
  final String chatName;
  final int chatId;
  const ChatScreen({super.key, required this.chatName, this.chatId = 1});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messages = <Map<String, dynamic>>[];
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription? _sub;
  bool _e2eeEnabled = false;
  String? _e2eeKeyBase64;
  bool _loadingHistory = false;
  bool _historyLoaded = false;
  String? _historyError;

  final _rand = Random.secure();

  @override
  void initState() {
    super.initState();
    RealtimeService.instance.setActiveChatId(widget.chatId);
    RealtimeService.instance.connect();
    _subscribeRealtime();
    _initChat();
  }

  Future<void> _initChat() async {
    await _loadChatSettings();
    await _loadHistory();
  }

  Future<void> _loadChatSettings() async {
    // Prefer server truth; fall back to local cache.
    try {
      final meta = await BackendService.fetchChatMeta(widget.chatId);
      final enabled = meta['e2ee_enabled'] == true;
      final key = meta['e2ee_key_base64'];
      if (enabled == true && key is String && key.isNotEmpty) {
        await ChatSettingsService.setE2eeEnabled(widget.chatId, true);
        await ChatSettingsService.setE2eeKeyBase64(widget.chatId, key);
        setState(() {
          _e2eeEnabled = true;
          _e2eeKeyBase64 = key;
        });
        await _tryDecryptEncryptedMessages();
        return;
      }
      // If server says disabled, respect it.
      if (enabled == false) {
        await ChatSettingsService.setE2eeEnabled(widget.chatId, false);
        setState(() => _e2eeEnabled = false);
      }
    } catch (_) {
      // ignore
    }

    final cachedEnabled = await ChatSettingsService.getE2eeEnabled(widget.chatId);
    final cachedKey = await ChatSettingsService.getE2eeKeyBase64(widget.chatId);
    if (!mounted) return;
    setState(() {
      _e2eeEnabled = cachedEnabled ?? false;
      _e2eeKeyBase64 = cachedKey;
    });
    await _tryDecryptEncryptedMessages();
  }

  void _subscribeRealtime() {
    _sub?.cancel();
    _sub = RealtimeService.instance.messages.listen((data) async {
      final incomingChatId = _toInt(data['chat_id']);
      if (incomingChatId == null || incomingChatId != widget.chatId) return;

      if (data['type'] == 'chat_settings') {
        final enabled = data['e2ee_enabled'] == true;
        final key = data['e2ee_key_base64'];
        if (enabled) {
          if (key is String && key.isNotEmpty) {
            await ChatSettingsService.setE2eeEnabled(widget.chatId, true);
            await ChatSettingsService.setE2eeKeyBase64(widget.chatId, key);
            if (!mounted) return;
            setState(() {
              _e2eeEnabled = true;
              _e2eeKeyBase64 = key;
            });
            await _tryDecryptEncryptedMessages();
          } else {
            if (!mounted) return;
            setState(() => _e2eeEnabled = true);
          }
        } else {
          await ChatSettingsService.setE2eeEnabled(widget.chatId, false);
          if (!mounted) return;
          setState(() => _e2eeEnabled = false);
        }
        return;
      }

      await _handleIncomingChatMessage(data);
    });
  }

  Future<void> _handleIncomingChatMessage(Map<String, dynamic> data) async {
    final isEncrypted = data['e2ee_flag'] == true;

    String displayText;
    if (isEncrypted) {
      displayText = '[encrypted]';
      if (_e2eeEnabled && _e2eeKeyBase64 != null) {
        try {
          final pt = await CryptoService.decrypt(
            data['ciphertext'],
            data['nonce'],
            _e2eeKeyBase64!,
            data['mac'],
          );
          displayText = pt;
        } catch (_) {
          // keep placeholder
        }
      }
    } else {
      displayText = (data['text'] ?? '').toString();
    }

    final senderUsername = data['sender_username'];
    final senderEmail = data['sender_email'];
    final sender = (senderUsername ?? senderEmail ?? 'unknown').toString();

    final clientId = data['client_id']?.toString();
    final meId = _toInt(BackendService.me?['id']);
    final senderUserId = _toInt(data['sender_user_id']);
    final isFromMe = meId != null && senderUserId != null && meId == senderUserId;

    final mapped = <String, dynamic>{
      'sender': sender,
      'sender_username': senderUsername,
      'sender_email': senderEmail,
      'sender_user_id': senderUserId,
      'text': displayText,
      'time': data['time'] ?? DateTime.now().toIso8601String(),
      'encrypted': isEncrypted,
      'client_id': clientId,
    };
    if (isEncrypted) {
      mapped['ciphertext'] = data['ciphertext'];
      mapped['nonce'] = data['nonce'];
      mapped['mac'] = data['mac'];
    }

    // Dedupe: if this is our own echoed message and we have a pending optimistic row with same client_id, replace it.
    if (isFromMe && clientId != null) {
      final idx = _messages.indexWhere((m) => m['client_id']?.toString() == clientId);
      if (idx != -1) {
        setState(() {
          _messages[idx] = {..._messages[idx], ...mapped, 'pending': false};
        });
        return;
      }
    }

    setState(() => _messages.insert(0, mapped));
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      final rows = await BackendService.fetchChatHistory(widget.chatId);
      // rows are ASC by time (oldest first); append to end so they appear
      // at the top of the reversed ListView, above live messages.
      final historyMsgs = <Map<String, dynamic>>[];
      for (final row in rows) {
        final isEncrypted = row['e2ee_flag'] == true;
        String displayText = isEncrypted ? '[encrypted]' : (row['plaintext'] ?? '');
        // Attempt to decrypt history immediately if we have a key
        if (isEncrypted && _e2eeEnabled && _e2eeKeyBase64 != null) {
          try {
            final pt = await CryptoService.decrypt(row['ciphertext'], row['nonce'], _e2eeKeyBase64!, row['mac']);
            displayText = pt;
          } catch (e) {
            // leave as '[encrypted]'
          }
        }
        final m = <String, dynamic>{
          'sender': row['sender_username'] ?? row['sender_email'] ?? 'unknown',
          'sender_username': row['sender_username'],
          'sender_email': row['sender_email'],
          'text': displayText,
          'time': row['time'] ?? DateTime.now().toIso8601String(),
          'encrypted': isEncrypted,
          '_history': true,
        };
        if (isEncrypted) {
          m['ciphertext'] = row['ciphertext'];
          m['nonce'] = row['nonce'];
          m['mac'] = row['mac'];
        }
        historyMsgs.add(m);
      }

      if (historyMsgs.isNotEmpty) {
        // Insert a divider sentinel at the boundary between history and live.
        historyMsgs.add({'_divider': true});
      }

      setState(() {
        _messages.addAll(historyMsgs);
        _historyLoaded = true;
        _loadingHistory = false;
        _historyError = null;
      });
    } catch (_) {
      setState(() {
        _historyLoaded = true;
        _loadingHistory = false;
        _historyError = 'Failed to load history';
      });
    }
  }

  // Attempt to decrypt any encrypted messages (history and live) when key becomes available
  Future<void> _tryDecryptEncryptedMessages() async {
    if (_e2eeKeyBase64 == null) return;
    final key = _e2eeKeyBase64!;
    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m['encrypted'] == true && m['text'] == '[encrypted]' && m['ciphertext'] != null) {
        try {
          if (m['nonce'] == null || m['mac'] == null) continue;
          final plaintext = await CryptoService.decrypt(m['ciphertext'], m['nonce'], key, m['mac']);
          _messages[i] = {...m, 'text': plaintext};
          changed = true;
        } catch (_) {
          // keep as is
        }
      }
    }
    if (changed) setState(() {});
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final clientId = _newClientId();
    Map<String, dynamic> payloadMap;
    if (_e2eeEnabled && _e2eeKeyBase64 != null) {
      // encrypt
      final enc = await CryptoService.encrypt(text, _e2eeKeyBase64!);
      payloadMap = {
        'chat_id': widget.chatId,
        'e2ee_flag': true,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
        'client_id': clientId,
      };
    } else {
      payloadMap = {'chat_id': widget.chatId, 'text': text, 'client_id': clientId};
    }

    RealtimeService.instance.sendJson(payloadMap);

    final myUsername = (BackendService.me?['username'] ?? 'me').toString();
    setState(() {
      _messages.insert(0, {
        'sender': myUsername,
        'sender_username': myUsername,
        'text': text,
        'time': DateTime.now().toIso8601String(),
        'encrypted': _e2eeEnabled,
        'client_id': clientId,
        'pending': true,
      });
      _controller.clear();
    });
    // scroll to top (latest inserted at 0)
    _scroll.animateTo(0.0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (RealtimeService.instance.activeChatId == widget.chatId) {
      RealtimeService.instance.setActiveChatId(null);
    }
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _newClientId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final r = _rand.nextInt(1 << 32);
    return '$ts-$r';
  }

  int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  String _displaySender(Map<String, dynamic> m) {
    final senderUsername = m['sender_username'];
    if (senderUsername != null && senderUsername.toString().isNotEmpty) {
      final u = senderUsername.toString();
      return u.startsWith('@') ? u : '@$u';
    }
    final sender = (m['sender'] ?? 'unknown').toString();
    if (sender.contains('@')) return sender; // email
    return sender.startsWith('@') ? sender : '@$sender';
  }

  Widget _buildMessage(Map<String, dynamic> m) {
    if (m['_divider'] == true) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Divider(color: Colors.white24)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('— history above —', style: TextStyle(color: Colors.white38, fontSize: 11)),
          ),
          Expanded(child: Divider(color: Colors.white24)),
        ]),
      );
    }
    final sender = _displaySender(m);
    final text = m['text'] ?? '';
    final time = m['time'] ?? DateTime.now().toIso8601String();
    final t = DateTime.tryParse(time)?.toLocal();
    final timestr = t != null ? '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}' : '';
    return ListTile(
      leading: CircleAvatar(backgroundColor: Colors.purpleAccent, child: Text(sender[0].toUpperCase())),
      title: Row(children: [
        Expanded(child: Text(sender, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white))),
        if (m['pending'] == true) const Padding(
          padding: EdgeInsets.only(left: 6),
          child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        if (m['encrypted'] == true) const Padding(
          padding: EdgeInsets.only(left: 6),
          child: Icon(Icons.lock, size: 16, color: Colors.white54),
        ),
      ]),
      subtitle: Text(text, style: const TextStyle(color: Colors.white70)),
      trailing: Text(timestr, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      onTap: m['encrypted'] == true && m['ciphertext'] != null
          ? () {
              showDialog(context: context, builder: (_) => AlertDialog(
                title: const Text('Encrypted payload'),
                content: SelectableText(m['ciphertext']),
                actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
              ));
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = RealtimeService.instance;
    return Scaffold(
      appBar: AppBar(title: Text(widget.chatName), actions: [
        Row(children: [
          const Text('E2EE', style: TextStyle(color: Colors.white70)),
          Switch(
            value: _e2eeEnabled,
            activeThumbColor: Colors.deepPurpleAccent,
            onChanged: (v) async {
              if (v) {
                // enable: generate key if missing
                if (_e2eeKeyBase64 == null) {
                  final key = await CryptoService.generateKeyBase64();
                  await ChatSettingsService.setE2eeKeyBase64(widget.chatId, key);
                  setState(() => _e2eeKeyBase64 = key);
                }
              } else {
                // disable: keep key in memory but mark disabled
              }

              await ChatSettingsService.setE2eeEnabled(widget.chatId, v);
              setState(() => _e2eeEnabled = v);

              // Sync to the other user(s) in this chat.
              ws.sendJson({
                'type': 'chat_settings_update',
                'chat_id': widget.chatId,
                'e2ee_enabled': v,
                'e2ee_key_base64': v ? _e2eeKeyBase64 : null,
              });
              await _tryDecryptEncryptedMessages();
            },
          ),
        ])
      ]),
      body: Column(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: ws.connected,
            builder: (_, ok, __) {
              if (ok) return const SizedBox.shrink();
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: Colors.redAccent.withValues(alpha: 0.15),
                child: Text(ws.lastError ?? 'Connecting...', style: const TextStyle(color: Colors.white70)),
              );
            },
          ),
          if (_loadingHistory)
            const LinearProgressIndicator(minHeight: 2, color: Colors.deepPurpleAccent, backgroundColor: Colors.transparent),
          if (_historyLoaded && _historyError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(_historyError!, style: const TextStyle(color: Colors.white54)),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              itemCount: _messages.length,
              itemBuilder: (_, i) => _buildMessage(_messages[i]),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: const Color(0xFF0B0D0F),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration.collapsed(hintText: 'Type a message'),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton(
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                  color: Colors.deepPurpleAccent,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
