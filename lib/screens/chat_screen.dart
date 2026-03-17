import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';

import '../services/backend_service.dart';
import '../services/crypto_service.dart';

class ChatScreen extends StatefulWidget {
  final String chatName;
  final int chatId;
  const ChatScreen({super.key, required this.chatName, this.chatId = 1});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  IOWebSocketChannel? _channel;
  final _messages = <Map<String, dynamic>>[];
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  bool _connected = false;
  StreamSubscription? _sub;
  String? _connectionError;
  bool _e2eeEnabled = false;
  String? _e2eeKeyBase64;
  bool _loadingHistory = false;
  bool _historyLoaded = false;

  @override
  void initState() {
    super.initState();
    _connect();
    _loadHistory();
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
          'sender': row['sender_email'] ?? 'unknown',
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
      });
    } catch (_) {
      setState(() {
        _historyLoaded = true;
        _loadingHistory = false;
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

  void _connect() {
    final token = BackendService.authToken;
    if (token == null) {
      _connectionError = 'Missing auth token';
      _connected = false;
      return;
    }
    final base = Uri.parse(BackendService.baseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : (base.scheme == 'https' ? 443 : 80),
      path: '/ws',
      queryParameters: {'token': token},
    );
    _channel = IOWebSocketChannel.connect(wsUri);
    _connected = true;
    _connectionError = null;
    _sub = _channel!.stream.listen((dynamic msg) async {
      try {
        final data = jsonDecode(msg as String) as Map<String, dynamic>;
        // If message is flagged as E2EE, attempt to decrypt if we have the key.
        if (data['e2ee_flag'] == true) {
          if (_e2eeEnabled && _e2eeKeyBase64 != null) {
            try {
              final plaintext = await CryptoService.decrypt(data['ciphertext'], data['nonce'], _e2eeKeyBase64!, data['mac']);
              setState(() => _messages.insert(0, {
                    'sender': data['sender'],
                    'text': plaintext,
                    'time': data['time'],
                    'encrypted': true,
                    'ciphertext': data['ciphertext'],
                    'nonce': data['nonce'],
                    'mac': data['mac'],
                  }));
            } catch (e) {
              // decryption failed
              setState(() => _messages.insert(0, {
                    'sender': data['sender'],
                    'text': '[encrypted]',
                    'time': data['time'],
                    'ciphertext': data['ciphertext'],
                    'nonce': data['nonce'],
                    'mac': data['mac'],
                    'encrypted': true
                  }));
            }
          } else {
            // No key available locally; show placeholder and ciphertext
            setState(() => _messages.insert(0, {
                  'sender': data['sender'],
                  'text': '[encrypted]',
                  'time': data['time'],
                  'ciphertext': data['ciphertext'],
                  'nonce': data['nonce'],
                  'mac': data['mac'],
                  'encrypted': true
                }));
          }
        } else {
          setState(() => _messages.insert(0, data));
        }
      } catch (_) {
        // non-json message
        setState(() => _messages.insert(0, {'sender': 'remote', 'text': msg.toString(), 'time': DateTime.now().toIso8601String()}));
      }
    }, onDone: () {
      setState(() => _connected = false);
    }, onError: (e) {
      setState(() => _connected = false);
      // Avoid using ScaffoldMessenger during initState; render error in UI.
      setState(() => _connectionError = 'WebSocket error');
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !_connected) return;
    Map<String, dynamic> payloadMap;
    if (_e2eeEnabled && _e2eeKeyBase64 != null) {
      // encrypt
      final enc = await CryptoService.encrypt(text, _e2eeKeyBase64!);
      payloadMap = {
        'e2ee_flag': true,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
      };
    } else {
      payloadMap = {'text': text};
    }
    final payload = jsonEncode(payloadMap);
    _channel?.sink.add(payload);
    setState(() {
      _messages.insert(0, {'sender': 'Me', 'text': text, 'time': DateTime.now().toIso8601String(), 'encrypted': _e2eeEnabled});
      _controller.clear();
    });
    // scroll to top (latest inserted at 0)
    _scroll.animateTo(0.0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _sub?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
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
    final sender = m['sender'] ?? 'unknown';
    final text = m['text'] ?? '';
    final time = m['time'] ?? DateTime.now().toIso8601String();
    final t = DateTime.tryParse(time)?.toLocal();
    final timestr = t != null ? '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}' : '';
    return ListTile(
      leading: CircleAvatar(backgroundColor: Colors.purpleAccent, child: Text(sender[0].toUpperCase())),
      title: Row(children: [
        Expanded(child: Text(sender, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white))),
        if (m['encrypted'] == true) const Icon(Icons.lock, size: 16, color: Colors.white54),
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
    return Scaffold(
      appBar: AppBar(title: Text(widget.chatName), actions: [
        Row(children: [
          const Text('E2EE', style: TextStyle(color: Colors.white70)),
          Switch(
            value: _e2eeEnabled,
            activeColor: Colors.deepPurpleAccent,
            onChanged: (v) async {
              if (v) {
                // enable: generate key if missing
                if (_e2eeKeyBase64 == null) {
                  final key = await CryptoService.generateKeyBase64();
                  setState(() => _e2eeKeyBase64 = key);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('E2EE enabled: local key generated')));
                }
              } else {
                // disable: keep key in memory but mark disabled
              }
              setState(() => _e2eeEnabled = v);
            },
          ),
        ])
      ]),
      body: Column(
        children: [
          if (_loadingHistory)
            const LinearProgressIndicator(minHeight: 2, color: Colors.deepPurpleAccent, backgroundColor: Colors.transparent),
          Expanded(
            child: _connected
                ? ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _buildMessage(_messages[i]),
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(_connectionError ?? 'Connecting...'),
                      ],
                    ),
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
                  onPressed: _connected ? _send : null,
                  icon: const Icon(Icons.send),
                  color: _connected ? Colors.deepPurpleAccent : Colors.white24,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
