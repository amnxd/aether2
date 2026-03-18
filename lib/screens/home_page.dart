import 'package:flutter/material.dart';
import '../services/backend_service.dart';
import '../services/notification_service.dart';
import '../services/realtime_service.dart';
import '../services/push_service.dart';
import '../services/app_preferences.dart';
import 'chat_screen.dart';
import 'login_screen.dart';
import 'new_dm_screen.dart';
import 'new_group_screen.dart';
import 'settings_screen.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _me;
  List<Map<String, dynamic>> _chats = [];
  bool _showGlobalChat = true;

  @override
  void initState() {
    super.initState();
    // Best-effort: ask for notification permission early so incoming chats can notify.
    NotificationService.requestPermissionsIfNeeded();
    _loadPrefs();
    _refresh();
    RealtimeService.instance.connect();
    PushService.registerWithBackend();
  }

  Future<void> _loadPrefs() async {
    final show = await AppPreferences.getShowGlobalChat();
    if (!mounted) return;
    setState(() => _showGlobalChat = show);
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = await BackendService.fetchMe();
      final chats = await BackendService.fetchChats();
      setState(() {
        _me = me;
        _chats = chats;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  String _displayNameForChat(Map<String, dynamic> chat) {
    if (chat['is_global'] == true) return 'Global chat';
    if (chat['is_group'] == true) return (chat['name'] ?? 'Group').toString();

    final meId = _me?['id'];
    final members = (chat['members'] as List?)?.cast<Map>() ?? const [];
    for (final m in members) {
      final id = m['id'];
      if (meId != null && id == meId) continue;
      final uname = m['username'];
      if (uname != null && uname.toString().isNotEmpty) return '@$uname';
      final email = m['email'];
      if (email != null && email.toString().isNotEmpty) {
        final e = email.toString();
        final local = e.contains('@') ? e.split('@').first : e;
        return local.isNotEmpty ? '@$local' : e;
      }
    }
    return 'DM';
  }

  Future<void> _createDm() async {
    final chatId = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => const NewDmScreen()));
    if (!mounted || chatId == null) return;
    await _refresh();
    final chat = _chats.firstWhere((c) => (c['id'] as num).toInt() == chatId, orElse: () => {'id': chatId});
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(chatName: _displayNameForChat(chat), chatId: chatId),
    ));
  }

  Future<void> _createGroup() async {
    final chatId = await Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => const NewGroupScreen()));
    if (!mounted || chatId == null) return;
    await _refresh();
    final chat = _chats.firstWhere((c) => (c['id'] as num).toInt() == chatId, orElse: () => {'id': chatId, 'name': 'Group', 'is_group': true});
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(chatName: _displayNameForChat(chat), chatId: chatId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final global = _chats.where((c) => c['is_global'] == true).cast<Map<String, dynamic>>().toList();
    final globalChat = global.isNotEmpty ? global.first : null;
    final dms = _chats.where((c) => c['is_global'] != true && c['is_group'] != true).cast<Map<String, dynamic>>().toList();
    final groups = _chats.where((c) => c['is_global'] != true && c['is_group'] == true).cast<Map<String, dynamic>>().toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aether'),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: RealtimeService.instance.onlineCount,
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
          IconButton(onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'dm') _createDm();
              if (v == 'group') _createGroup();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'dm', child: Text('New DM')),
              PopupMenuItem(value: 'group', child: Text('New group')),
            ],
            icon: const Icon(Icons.add),
          ),
          IconButton(
            onPressed: () async {
              await RealtimeService.instance.disconnect();
              await BackendService.logout();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            icon: const Icon(Icons.logout),
          )
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: const BoxDecoration(color: Color(0xFF2E1065)),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text('Aether', style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat),
              title: const Text('Chats'),
              onTap: () {
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const SettingsScreen()))
                    .then((_) => _loadPrefs());
              },
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
            if (_showGlobalChat)
              Card(
                color: const Color(0xFF0F1417),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                child: ListTile(
                  leading: const CircleAvatar(backgroundColor: Color(0xFF4C1D95), child: Icon(Icons.public, color: Colors.white)),
                  title: const Text('Global chat', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: const Text('Everyone can chat here', style: TextStyle(color: Colors.white70)),
                  onTap: globalChat == null
                      ? null
                      : () {
                          final id = (globalChat['id'] as num).toInt();
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatName: 'Global chat', chatId: id)));
                        },
                ),
              ),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text('Direct messages', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
            ),
            if (dms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text('No DMs yet. Use + → New DM.', style: TextStyle(color: Colors.white38)),
              ),
            for (final chat in dms)
              Card(
                color: const Color(0xFF0F1417),
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                child: ListTile(
                  leading: CircleAvatar(backgroundColor: Colors.purpleAccent, child: Text(_displayNameForChat(chat)[0].toUpperCase())),
                  title: Text(_displayNameForChat(chat), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text((chat['last'] ?? '').toString(), style: const TextStyle(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    final id = (chat['id'] as num).toInt();
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatName: _displayNameForChat(chat), chatId: id)));
                  },
                ),
              ),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text('Groups', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
            ),
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text('No groups yet. Use + → New group.', style: TextStyle(color: Colors.white38)),
              ),
            for (final chat in groups)
              Card(
                color: const Color(0xFF0F1417),
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                child: ListTile(
                  leading: CircleAvatar(backgroundColor: const Color(0xFF4C1D95), child: Text(_displayNameForChat(chat)[0].toUpperCase())),
                  title: Text(_displayNameForChat(chat), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text((chat['last'] ?? '').toString(), style: const TextStyle(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    final id = (chat['id'] as num).toInt();
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatName: _displayNameForChat(chat), chatId: id)));
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
