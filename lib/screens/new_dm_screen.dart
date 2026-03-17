import 'package:flutter/material.dart';

import '../services/backend_service.dart';

class NewDmScreen extends StatefulWidget {
  const NewDmScreen({super.key});

  @override
  State<NewDmScreen> createState() => _NewDmScreenState();
}

class _NewDmScreenState extends State<NewDmScreen> {
  final _controller = TextEditingController();
  bool _loading = false;

  String? _validate(String v) {
    final u = v.trim().toLowerCase();
    if (u.isEmpty) return 'Enter a username';
    if (u.length < 3 || u.length > 24) return 'Username must be 3-24 characters';
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(u)) return 'Use only letters, numbers, underscore';
    return null;
  }

  Future<void> _create() async {
    final err = _validate(_controller.text);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }

    setState(() => _loading = true);
    try {
      final chatId = await BackendService.createDm(_controller.text.trim().toLowerCase());
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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New DM')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Username',
                hintText: 'e.g. aman_123',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading ? null : _create,
                child: _loading ? const CircularProgressIndicator() : const Text('Create DM'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
