import 'package:flutter/material.dart';
import '../services/backend_service.dart';
import 'chat_screen.dart';
import 'login_screen.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loadingUsers = false;
  List<Map<String, dynamic>> _users = [];
  final List<Map<String, dynamic>> _chats = List.generate(
    16,
    (i) => {
      'id': i + 1,
      'name': i % 3 == 0 ? 'Dev Group ${i ~/ 3 + 1}' : 'User ${i + 1}',
      'last': i % 3 == 0 ? 'Discussing release notes' : 'Hey, are you free later?',
      'time': '${(10 + i) % 24}:${(i * 7) % 60}'.padLeft(2, '0'),
      'isGroup': i % 3 == 0,
    },
  );

  Future<void> _fetchUsers() async {
    setState(() => _loadingUsers = true);
    try {
      final users = await BackendService.fetchUsers();
      setState(() => _users = users);
      showModalBottomSheet(
        context: context,
        builder: (_) => SizedBox(
          height: 400,
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: _users.length,
            separatorBuilder: (_, __) => const Divider(color: Colors.white12),
            itemBuilder: (context, index) {
              final u = _users[index];
              return ListTile(
                leading: CircleAvatar(backgroundColor: Colors.purpleAccent, child: Text('U${u['id']}')),
                title: Text(u['email'] ?? ''),
                subtitle: Text('id: ${u['id']}', style: const TextStyle(color: Colors.white54)),
              );
            },
          ),
        ),
      );
    } catch (e) {
      final msg = e?.toString() ?? 'Failed to fetch users';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      setState(() => _loadingUsers = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aether'),
        actions: [
          IconButton(onPressed: _loadingUsers ? null : _fetchUsers, icon: const Icon(Icons.people)),
          IconButton(
            onPressed: () async {
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
            ListTile(leading: const Icon(Icons.chat), title: const Text('Chats'), onTap: () {}),
            ListTile(leading: const Icon(Icons.settings), title: const Text('Settings'), onTap: () {}),
          ],
        ),
      ),
      body: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: _chats.length,
          itemBuilder: (context, index) {
            final chat = _chats[index];
            return Card(
              color: const Color(0xFF0F1417),
              margin: const EdgeInsets.symmetric(vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: InkWell(
                onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatName: chat['name'], chatId: (chat['id'] as num).toInt())));
                },
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: chat['isGroup'] ? const Color(0xFF4C1D95) : Colors.purpleAccent,
                            child: Text(
                              chat['isGroup'] ? chat['name'][0] : (chat['name'] as String).split(' ').last[0],
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle, border: Border.all(color: Color(0xFF0F1417), width: 2)),
                            ),
                          )
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    chat['name'],
                                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(chat['time'], style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              chat['last'],
                              style: const TextStyle(color: Colors.white70),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      )
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.deepPurpleAccent,
        child: const Icon(Icons.create),
        onPressed: () async {
          final result = await showDialog<Map<String, dynamic>>(context: context, builder: (ctx) {
            final _nameCtrl = TextEditingController();
            bool _isGroup = false;
            return StatefulBuilder(builder: (c, setState) {
              return AlertDialog(
                backgroundColor: const Color(0xFF0B0D0F),
                title: const Text('Create chat'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
                  Row(children: [
                    const Text('Group?'),
                    Checkbox(value: _isGroup, onChanged: (v) => setState(() => _isGroup = v ?? false)),
                  ])
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancel')),
                  ElevatedButton(
                    onPressed: () {
                      final name = _nameCtrl.text.trim();
                      if (name.isEmpty) return; 
                      Navigator.of(c).pop({'name': name, 'isGroup': _isGroup});
                    },
                    child: const Text('Create'),
                  )
                ],
              );
            });
          });
          if (result != null) {
            setState(() {
              _chats.insert(0, {
                'id': DateTime.now().millisecondsSinceEpoch,
                'name': result['name'],
                'last': 'Chat created',
                'time': '${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
                'isGroup': result['isGroup'] ? 1 : 0,
              });
            });
          }
        },
      ),
    );
  }
}
