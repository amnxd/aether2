import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../services/backend_service.dart';
import '../services/chat_settings_service.dart';
import '../services/crypto_service.dart';
import '../services/identity_key_service.dart';
import '../services/peer_trust_service.dart';
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
  bool _isGlobalChat = false;
  bool _isDmChat = false;
  int? _peerUserId;
  String? _peerPublicKeyBase64;
  bool _loadingHistory = false;
  bool _historyLoaded = false;
  String? _historyError;

  Map<String, dynamic>? _replyTo;
  int? _editingMessageId;
  bool _sending = false;

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

  Future<void> _recomputeDmKeyIfNeeded() async {
    if (!_isDmChat) {
      _e2eeKeyBase64 = null;
      return;
    }
    if (!_e2eeEnabled) {
      _e2eeKeyBase64 = null;
      return;
    }
    final meId = _toInt(BackendService.me?['id']);
    final peerId = _peerUserId;
    final peerPk = _peerPublicKeyBase64;
    if (meId == null || peerId == null || peerPk == null || peerPk.isEmpty) {
      _e2eeKeyBase64 = null;
      return;
    }
    final key = await IdentityKeyService.deriveDmChatKeyBase64(
      chatId: widget.chatId,
      myUserId: meId,
      peerUserId: peerId,
      peerPublicKeyBase64: peerPk,
    );
    _e2eeKeyBase64 = key;
  }

  Future<void> _loadChatSettings() async {
    // Prefer server truth; fall back to local cache.
    try {
      if (BackendService.me == null) {
        await BackendService.fetchMe();
      }
      final meta = await BackendService.fetchChatMeta(widget.chatId);
      final isGlobal = meta['is_global'] == true;
      final isGroup = meta['is_group'] == true;
      var enabled = meta['e2ee_enabled'] == true;

      final membersRaw = (meta['members'] as List?)?.cast<dynamic>() ?? const [];
      final members = membersRaw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final meId = _toInt(BackendService.me?['id']);
      final isDm = !isGlobal && !isGroup && members.length == 2 && meId != null;
      int? peerId;
      String? peerPk;
      if (isDm) {
        final peer = members.firstWhere(
          (m) => _toInt(m['id']) != meId,
          orElse: () => <String, dynamic>{},
        );
        peerId = _toInt(peer['id']);
        peerPk = (peer['public_key_base64'] ?? '').toString();
        if (peerPk.isEmpty) peerPk = null;

        // Trust-on-first-use pinning to reduce key-substitution attacks.
        if (peerId != null && peerPk != null) {
          final pinned = await PeerTrustService.getPinnedPublicKeyBase64(peerId);
          if (pinned == null) {
            await PeerTrustService.pinPublicKeyBase64(peerId, peerPk);
          } else if (pinned != peerPk) {
            // Key changed unexpectedly: disable E2EE until user can verify.
            peerPk = null;
            enabled = false;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _isGlobalChat = isGlobal;
        _isDmChat = isDm;
        _peerUserId = peerId;
        _peerPublicKeyBase64 = peerPk;
      });

      if (isGlobal || isGroup) {
        // Global + group chats must never use E2EE (DM-only).
        await ChatSettingsService.setE2eeEnabled(widget.chatId, false);
        if (!mounted) return;
        setState(() {
          _e2eeEnabled = false;
          _e2eeKeyBase64 = null;
        });
        return;
      }

      // Server says enabled/disabled; respect it, but only DMs can actually encrypt.
      await ChatSettingsService.setE2eeEnabled(widget.chatId, enabled);
      if (!mounted) return;
      setState(() => _e2eeEnabled = enabled);
      await _recomputeDmKeyIfNeeded();
      if (!mounted) return;
      setState(() {});
      await _tryDecryptEncryptedMessages();
      if (_isDmChat && enabled == false && peerId != null) {
        final pinned = await PeerTrustService.getPinnedPublicKeyBase64(peerId);
        // If we have a pinned key but no current key, it indicates a change.
        if (pinned != null && _peerPublicKeyBase64 == null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Security warning: contact key changed. E2EE disabled for this chat.')),
          );
        }
      }
      return;
    } catch (_) {
      // ignore
    }

    final cachedEnabled = await ChatSettingsService.getE2eeEnabled(widget.chatId);
    if (!mounted) return;
    setState(() {
      _e2eeEnabled = cachedEnabled ?? false;
    });
    await _recomputeDmKeyIfNeeded();
    if (!mounted) return;
    setState(() {});
    await _tryDecryptEncryptedMessages();
  }

  void _subscribeRealtime() {
    _sub?.cancel();
    _sub = RealtimeService.instance.messages.listen((data) async {
      final incomingChatId = _toInt(data['chat_id']);
      if (incomingChatId == null || incomingChatId != widget.chatId) return;

      if (data['type'] == 'message_edit') {
        final id = _toInt(data['id']);
        if (id == null) return;
        final idx = _messages.indexWhere((m) => _toInt(m['id']) == id);
        if (idx == -1) return;
        final prev = _messages[idx];
        final updated = {
          ...prev,
          'text': (data['text'] ?? prev['text']).toString(),
          'edited_at': data['edited_at'] ?? DateTime.now().toIso8601String(),
          'pending': false,
        };
        if (!mounted) return;
        setState(() => _messages[idx] = updated);
        return;
      }

      if (data['type'] == 'message_delete') {
        final id = _toInt(data['id']);
        if (id == null) return;
        final idx = _messages.indexWhere((m) => _toInt(m['id']) == id);
        if (idx == -1) return;
        final prev = _messages[idx];
        final updated = {
          ...prev,
          'deleted_at': data['deleted_at'] ?? DateTime.now().toIso8601String(),
          'text': '[deleted]',
          'encrypted': false,
          'ciphertext': null,
          'nonce': null,
          'mac': null,
          'pending': false,
        };
        if (!mounted) return;
        setState(() => _messages[idx] = updated);
        return;
      }

      if (data['type'] == 'chat_settings') {
        final enabled = data['e2ee_enabled'] == true;
        if (_isGlobalChat) {
          if (!mounted) return;
          setState(() => _e2eeEnabled = false);
          return;
        }
        await ChatSettingsService.setE2eeEnabled(widget.chatId, enabled);
        if (!mounted) return;
        setState(() => _e2eeEnabled = enabled);
        await _recomputeDmKeyIfNeeded();
        if (!mounted) return;
        setState(() {});
        await _tryDecryptEncryptedMessages();
        return;
      }

      await _handleIncomingChatMessage(data);
    });
  }

  Future<void> _handleIncomingChatMessage(Map<String, dynamic> data) async {
    final id = _toInt(data['id']);
    final isEncrypted = data['e2ee_flag'] == true;
    final deletedAt = data['deleted_at'];
    final isDeleted = deletedAt != null;

    String displayText;
    if (isDeleted) {
      displayText = '[deleted]';
    } else if (isEncrypted) {
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
    final senderUserId = _toInt(data['sender_user_id']);
    final replyToId = _toInt(data['reply_to_message_id']);
    final replyTo = (data['reply_to'] is Map) ? Map<String, dynamic>.from(data['reply_to'] as Map) : null;

    final mapped = <String, dynamic>{
      'id': id,
      'sender': sender,
      'sender_username': senderUsername,
      'sender_email': senderEmail,
      'sender_user_id': senderUserId,
      'text': displayText,
      'time': data['time'] ?? DateTime.now().toIso8601String(),
      'encrypted': isEncrypted,
      'client_id': clientId,
      'reply_to_message_id': replyToId,
      'reply_to': replyTo,
      'edited_at': data['edited_at'],
      'deleted_at': deletedAt,
    };
    if (isEncrypted) {
      mapped['ciphertext'] = data['ciphertext'];
      mapped['nonce'] = data['nonce'];
      mapped['mac'] = data['mac'];
    }

    // Dedupe: if we already have a message with this client_id (optimistic or history), update it.
    if (clientId != null) {
      final idx = _messages.indexWhere((m) => m['client_id']?.toString() == clientId);
      if (idx != -1) {
        setState(() {
          final prev = _messages[idx];
          _messages[idx] = {...prev, ...mapped, 'pending': false};
        });
        _scrollToBottom();
        return;
      }
    }

    setState(() => _messages.add(mapped));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      final rows = await BackendService.fetchChatHistory(widget.chatId);
      final historyMsgs = <Map<String, dynamic>>[];
      for (final row in rows) {
        final id = _toInt(row['id']);
        final isEncrypted = row['e2ee_flag'] == true;
        final isDeleted = row['deleted_at'] != null;
        String displayText = isDeleted ? '[deleted]' : (isEncrypted ? '[encrypted]' : (row['plaintext'] ?? ''));
        // Attempt to decrypt history immediately if we have a key
        if (!isDeleted && isEncrypted && _e2eeEnabled && _e2eeKeyBase64 != null) {
          try {
            final pt = await CryptoService.decrypt(row['ciphertext'], row['nonce'], _e2eeKeyBase64!, row['mac']);
            displayText = pt;
          } catch (e) {
            // leave as '[encrypted]'
          }
        }

        final replyToId = _toInt(row['reply_to_message_id']);
        Map<String, dynamic>? replyTo;
        if (replyToId != null) {
          replyTo = {
            'id': replyToId,
            'sender_email': row['reply_sender_email'],
            'sender_username': row['reply_sender_username'],
            'sender_user_id': _toInt(row['reply_sender_user_id']),
            'e2ee_flag': row['reply_e2ee_flag'] == true,
            'deleted': row['reply_deleted_at'] != null,
            'text': (row['reply_deleted_at'] != null || row['reply_e2ee_flag'] == true) ? null : row['reply_plaintext'],
          };
        }

        final m = <String, dynamic>{
          'id': id,
          'sender': row['sender_username'] ?? row['sender_email'] ?? 'unknown',
          'sender_username': row['sender_username'],
          'sender_email': row['sender_email'],
          'sender_user_id': _toInt(row['sender_user_id']),
          'text': displayText,
          'time': row['time'] ?? DateTime.now().toIso8601String(),
          'encrypted': isEncrypted,
          'reply_to_message_id': replyToId,
          'reply_to': replyTo,
          'edited_at': row['edited_at'],
          'deleted_at': row['deleted_at'],
          '_history': true,
        };
        if (isEncrypted) {
          m['ciphertext'] = row['ciphertext'];
          m['nonce'] = row['nonce'];
          m['mac'] = row['mac'];
        }
        historyMsgs.add(m);
      }

      // Ensure chronological order regardless of backend ordering.
      historyMsgs.sort((a, b) {
        final at = DateTime.tryParse((a['time'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = DateTime.tryParse((b['time'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return at.compareTo(bt);
      });

      final merged = _mergeAndSortMessages(_messages, historyMsgs);

      setState(() {
        _messages
          ..clear()
          ..addAll(merged);
        _historyLoaded = true;
        _loadingHistory = false;
        _historyError = null;
      });
      _scrollToBottom();
    } catch (_) {
      setState(() {
        _historyLoaded = true;
        _loadingHistory = false;
        _historyError = 'Failed to load history';
      });
    }
  }

  List<Map<String, dynamic>> _mergeAndSortMessages(
    List<Map<String, dynamic>> live,
    List<Map<String, dynamic>> history,
  ) {
    final all = <Map<String, dynamic>>[...live, ...history];

    DateTime parseTime(Map<String, dynamic> m) {
      final t = DateTime.tryParse((m['time'] ?? '').toString());
      return t ?? DateTime.fromMillisecondsSinceEpoch(0);
    }

    String keyFor(Map<String, dynamic> m) {
      final clientId = m['client_id']?.toString();
      if (clientId != null && clientId.isNotEmpty) return 'c:$clientId';
      final sender = (m['sender_user_id'] ?? m['sender_email'] ?? m['sender'] ?? '').toString();
      final time = (m['time'] ?? '').toString();
      final encrypted = m['encrypted'] == true;
      final content = (m['ciphertext'] ?? m['text'] ?? '').toString();
      return 't:$time|s:$sender|e:$encrypted|m:$content';
    }

    all.sort((a, b) => parseTime(a).compareTo(parseTime(b)));

    final merged = <Map<String, dynamic>>[];
    final idxByKey = <String, int>{};

    for (final m in all) {
      if (m['_divider'] == true) continue;
      final k = keyFor(m);
      final existingIdx = idxByKey[k];
      if (existingIdx == null) {
        idxByKey[k] = merged.length;
        merged.add(m);
        continue;
      }
      final prev = merged[existingIdx];
      final prevPending = prev['pending'] == true;
      final newPending = m['pending'] == true;
      if (prevPending && !newPending) {
        merged[existingIdx] = {...prev, ...m, 'pending': false};
      }
    }

    return merged;
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
    if (_sending) return;
    if (text.isEmpty) return;

    // Editing mode: update existing message.
    if (_editingMessageId != null) {
      final id = _editingMessageId!;
      setState(() => _sending = true);
      try {
        await BackendService.editMessage(messageId: id, text: text);
        final idx = _messages.indexWhere((m) => _toInt(m['id']) == id);
        if (idx != -1) {
          final prev = _messages[idx];
          _messages[idx] = {
            ...prev,
            'text': text,
            'edited_at': DateTime.now().toIso8601String(),
            'pending': false,
          };
        }
        setState(() {
          _editingMessageId = null;
          _controller.clear();
          _sending = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
      return;
    }

    final clientId = _newClientId();
    Map<String, dynamic> payloadMap;
    final replyToId = _toInt(_replyTo?['id']);
    final canEncrypt = _isDmChat && _e2eeEnabled && _e2eeKeyBase64 != null;
    if (canEncrypt) {
      // encrypt
      final enc = await CryptoService.encrypt(text, _e2eeKeyBase64!);
      payloadMap = {
        'chat_id': widget.chatId,
        'e2ee_flag': true,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
        'client_id': clientId,
        if (replyToId != null) 'reply_to_message_id': replyToId,
      };
    } else {
      payloadMap = {
        'chat_id': widget.chatId,
        'text': text,
        'client_id': clientId,
        if (replyToId != null) 'reply_to_message_id': replyToId,
      };
    }

    RealtimeService.instance.sendJson(payloadMap);

    final myUsername = (BackendService.me?['username'] ?? 'me').toString();
    final myUserId = _toInt(BackendService.me?['id']);
    setState(() {
      _messages.add({
        'sender': myUsername,
        'sender_username': myUsername,
        'sender_user_id': myUserId,
        'text': text,
        'time': DateTime.now().toIso8601String(),
        'encrypted': canEncrypt,
        'client_id': clientId,
        'pending': true,
        'reply_to_message_id': replyToId,
        'reply_to': _replyTo,
      });
      _controller.clear();
      _replyTo = null;
    });
    _scrollToBottom();
  }

  bool _isMine(Map<String, dynamic> m) {
    final meId = _toInt(BackendService.me?['id']);
    final senderUserId = _toInt(m['sender_user_id']);
    if (meId != null && senderUserId != null) return meId == senderUserId;
    final meEmail = (BackendService.me?['email'] ?? '').toString().toLowerCase();
    final senderEmail = (m['sender_email'] ?? '').toString().toLowerCase();
    if (meEmail.isNotEmpty && senderEmail.isNotEmpty) return meEmail == senderEmail;
    return false;
  }

  String _formatTime(String? iso) {
    final t = DateTime.tryParse((iso ?? '').toString())?.toLocal();
    if (t == null) return '';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _showMessageActions(Map<String, dynamic> m) async {
    final id = _toInt(m['id']);
    final deleted = m['deleted_at'] != null;
    final mine = _isMine(m);
    final encrypted = m['encrypted'] == true;
    if (id == null) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.of(context).pop('reply'),
              ),
              if (mine && !deleted && !encrypted)
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Edit'),
                  onTap: () => Navigator.of(context).pop('edit'),
                ),
              if (mine && !deleted)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Delete'),
                  onTap: () => Navigator.of(context).pop('delete'),
                ),
            ],
          ),
        );
      },
    );

    if (!mounted || action == null) return;

    if (action == 'reply') {
      setState(() {
        _editingMessageId = null;
        _replyTo = {
          'id': id,
          'sender_username': m['sender_username'],
          'sender_email': m['sender_email'],
          'text': (encrypted || deleted) ? null : (m['text'] ?? '').toString(),
          'e2ee_flag': encrypted,
          'deleted': deleted,
        };
      });
      return;
    }

    if (action == 'edit') {
      if (encrypted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot edit encrypted messages')));
        return;
      }
      setState(() {
        _replyTo = null;
        _editingMessageId = id;
        _controller.text = (m['text'] ?? '').toString();
      });
      return;
    }

    if (action == 'delete') {
      setState(() => _sending = true);
      try {
        await BackendService.deleteMessage(messageId: id);
        final idx = _messages.indexWhere((x) => _toInt(x['id']) == id);
        if (idx != -1) {
          final prev = _messages[idx];
          _messages[idx] = {
            ...prev,
            'deleted_at': DateTime.now().toIso8601String(),
            'text': '[deleted]',
            'encrypted': false,
            'ciphertext': null,
            'nonce': null,
            'mac': null,
            'pending': false,
          };
        }
        if (!mounted) return;
        setState(() => _sending = false);
      } catch (e) {
        if (!mounted) return;
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
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
    if (sender.contains('@')) {
      final local = sender.split('@').first;
      if (local.isNotEmpty) return '@$local';
      return sender;
    }
    return sender.startsWith('@') ? sender : '@$sender';
  }

  DateTime? _parseTime(dynamic v) {
    if (v == null) return null;
    try {
      return DateTime.parse(v.toString());
    } catch (_) {
      return null;
    }
  }

  bool _shouldGroupWith(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a['_divider'] == true || b['_divider'] == true) return false;

    final aMine = _isMine(a);
    final bMine = _isMine(b);
    if (aMine != bMine) return false;

    final aSenderId = _toInt(a['sender_user_id']);
    final bSenderId = _toInt(b['sender_user_id']);
    if (aSenderId != null && bSenderId != null) {
      if (aSenderId != bSenderId) return false;
    } else {
      if (_displaySender(a) != _displaySender(b)) return false;
    }

    final ta = _parseTime(a['time']);
    final tb = _parseTime(b['time']);
    if (ta == null || tb == null) return true;
    final diff = (tb.difference(ta)).abs();
    return diff.inMinutes <= 5;
  }

  Widget _replyPreview({required String sender, required String text, Color? lineColor}) {
    final lc = (lineColor ?? Colors.white).withValues(alpha: 0.45);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 14,
          height: 18,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: lc, width: 2),
              top: BorderSide(color: lc, width: 2),
            ),
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(6)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sender,
                style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 1),
              Text(
                text,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessage(Map<String, dynamic> m, {required bool groupWithPrev, required bool groupWithNext}) {
    if (m['_divider'] == true) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Divider(color: Colors.white24)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('— history —', style: TextStyle(color: Colors.white38, fontSize: 11)),
          ),
          Expanded(child: Divider(color: Colors.white24)),
        ]),
      );
    }
    final mine = _isMine(m);
    final sender = _displaySender(m);
    final text = (m['text'] ?? '').toString();
    final timestr = _formatTime(m['time']?.toString());
    final edited = m['edited_at'] != null;
    final deleted = m['deleted_at'] != null;
    final encrypted = m['encrypted'] == true;

    final replyTo = (m['reply_to'] is Map) ? Map<String, dynamic>.from(m['reply_to'] as Map) : null;
    final replySender = replyTo == null ? null : (replyTo['sender_username'] ?? replyTo['sender_email'] ?? '');
    final replyText = replyTo == null
        ? null
        : (replyTo['deleted'] == true
            ? '[deleted]'
            : (replyTo['e2ee_flag'] == true ? '[encrypted]' : (replyTo['text'] ?? '')));

    final bubbleColor = mine
        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)
        : Theme.of(context).colorScheme.surface.withValues(alpha: 0.55);

    final showAvatarAndName = !mine && !groupWithPrev;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: groupWithPrev ? 2 : 6),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: showAvatarAndName
                  ? CircleAvatar(
                      radius: 14,
                      backgroundColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.35),
                      child: Text(
                        () {
                          final s = sender;
                          if (s.isEmpty) return '?';
                          final cleaned = s.startsWith('@') ? s.substring(1) : s;
                          return cleaned.isNotEmpty ? cleaned[0].toUpperCase() : '?';
                        }(),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    )
                  : const SizedBox(width: 28, height: 28),
            ),
          Flexible(
            child: GestureDetector(
              onLongPress: () => _showMessageActions(m),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(groupWithPrev ? 8 : 14),
                    topRight: Radius.circular(groupWithPrev ? 8 : 14),
                    bottomLeft: Radius.circular(groupWithNext ? 8 : (mine ? 14 : 4)),
                    bottomRight: Radius.circular(groupWithNext ? 8 : (mine ? 4 : 14)),
                  ),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showAvatarAndName)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(sender, style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.w700, fontSize: 12)),
                      ),
                    if (replyTo != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _replyPreview(
                          sender: (replySender ?? '').toString().isEmpty
                              ? 'Reply'
                              : _displaySender({'sender_username': replySender, 'sender': replySender}),
                          text: (replyText ?? '').toString(),
                          lineColor: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    Text(
                      text,
                      style: TextStyle(
                        color: deleted ? Colors.white54 : Colors.white,
                        fontSize: 14,
                        height: 1.25,
                        fontStyle: deleted ? FontStyle.italic : FontStyle.normal,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m['pending'] == true)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                        if (encrypted)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(Icons.lock, size: 14, color: Colors.white54),
                          ),
                        if (edited)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Text('edited', style: TextStyle(color: Colors.white54, fontSize: 11)),
                          ),
                        Text(timestr, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = RealtimeService.instance;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chatName),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: ws.onlineCount,
            builder: (_, n, __) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: Theme.of(context).colorScheme.secondary),
                    const SizedBox(width: 6),
                    Text('$n', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ],
                ),
              );
            },
          ),
          if (_isDmChat)
            Row(children: [
              const Text('E2EE', style: TextStyle(color: Colors.white70)),
              Switch(
                value: _e2eeEnabled,
                activeThumbColor: Colors.deepPurpleAccent,
                onChanged: (v) async {
                  // Enabling requires the peer public key.
                  if (v && (_peerPublicKeyBase64 == null || _peerPublicKeyBase64!.isEmpty)) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('E2EE unavailable until the other user updates/signs in again.')),
                    );
                    return;
                  }

                  await ChatSettingsService.setE2eeEnabled(widget.chatId, v);
                  if (!mounted) return;
                  setState(() => _e2eeEnabled = v);
                  await _recomputeDmKeyIfNeeded();
                  if (!mounted) return;
                  setState(() {});

                  // Sync to the other user in this DM.
                  ws.sendJson({
                    'type': 'chat_settings_update',
                    'chat_id': widget.chatId,
                    'e2ee_enabled': v,
                  });
                  await _tryDecryptEncryptedMessages();
                },
              ),
            ]),
        ],
      ),
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
              reverse: false,
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                final prev = i > 0 ? _messages[i - 1] : null;
                final next = (i + 1) < _messages.length ? _messages[i + 1] : null;
                final groupPrev = prev != null && _shouldGroupWith(prev, m);
                final groupNext = next != null && _shouldGroupWith(m, next);
                return _buildMessage(m, groupWithPrev: groupPrev, groupWithNext: groupNext);
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              color: const Color(0xFF0B0D0F),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTo != null || _editingMessageId != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_editingMessageId != null)
                                  Text(
                                    'Editing message',
                                    style: TextStyle(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.w700, fontSize: 12),
                                  )
                                else
                                  _replyPreview(
                                    sender: _displaySender(_replyTo ?? const {}),
                                    text: (((_replyTo?['text'] ?? (_replyTo?['deleted'] == true ? '[deleted]' : (_replyTo?['e2ee_flag'] == true ? '[encrypted]' : ''))) ?? '').toString()),
                                    lineColor: Theme.of(context).colorScheme.secondary,
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => setState(() {
                              _replyTo = null;
                              _editingMessageId = null;
                              _controller.clear();
                            }),
                            icon: const Icon(Icons.close, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                          ),
                          child: TextField(
                            controller: _controller,
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              border: InputBorder.none,
                            ),
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _sending ? null : _send,
                        icon: Icon(_editingMessageId != null ? Icons.check : Icons.send),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
