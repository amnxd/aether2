import 'package:flutter/material.dart';

import '../services/backend_service.dart';
import '../services/realtime_service.dart';
import '../services/app_preferences.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _me;
  bool _showGlobalChat = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final showGlobal = await AppPreferences.getShowGlobalChat();
      final me = await BackendService.fetchMe();
      setState(() {
        _showGlobalChat = showGlobal;
        _me = me;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    await RealtimeService.instance.disconnect();
    await BackendService.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(me == null ? 'Not loaded' : '@${me['username'] ?? ''}'),
              subtitle: Text(me == null ? '' : (me['email'] ?? '').toString()),
            ),
            const Divider(color: Colors.white12),
            SwitchListTile(
              secondary: const Icon(Icons.public),
              title: const Text('Global chat'),
              subtitle: const Text('Show Global chat in Home'),
              value: _showGlobalChat,
              onChanged: (v) async {
                setState(() => _showGlobalChat = v);
                await AppPreferences.setShowGlobalChat(v);
              },
            ),
            const Divider(color: Colors.white12),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Backend'),
              subtitle: Text(BackendService.baseUrl),
            ),
            const Divider(color: Colors.white12),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}
