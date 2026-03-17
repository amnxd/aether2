import 'package:flutter/material.dart';

import '../services/backend_service.dart';

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _nameController = TextEditingController();
  final _usernamesController = TextEditingController();
  bool _loading = false;

  List<String> _parseUsernames(String raw) {
    return raw
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }

  String? _validate() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return 'Enter a group name';
    if (name.length > 60) return 'Group name too long';
    final users = _parseUsernames(_usernamesController.text);
    if (users.isEmpty) return 'Add at least one username';
    for (final u in users) {
      if (u.length < 3 || u.length > 24) return 'Invalid username: $u';
      if (!RegExp(r'^[a-z0-9_]+$').hasMatch(u)) return 'Invalid username: $u';
    }
    return null;
  }

  Future<void> _create() async {
    final err = _validate();
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }

    setState(() => _loading = true);
    try {
      final chatId = await BackendService.createGroup(
        _nameController.text.trim(),
        _parseUsernames(_usernamesController.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop(chatId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernamesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Group name'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernamesController,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Usernames (comma-separated)',
                hintText: 'e.g. alice,bob,charlie',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _create,
                child: _loading ? const CircularProgressIndicator() : const Text('Create group'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
