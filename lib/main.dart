import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screens/login_screen.dart';
import 'screens/home_page.dart';
import 'services/backend_service.dart';
import 'services/push_service.dart';
import 'services/app_update_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackendService.loadTokenFromDisk();
  unawaited(PushService.init());
  runApp(const AetherApp());
}

class AetherApp extends StatelessWidget {
  const AetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: false);
    final colorScheme = base.colorScheme.copyWith(
      primary: Colors.deepPurpleAccent,
      secondary: Colors.purpleAccent,
      surface: const Color(0xFF0F1720),
    );

    return MaterialApp(
      title: 'Aether',
      theme: base.copyWith(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0F1720),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0D0F),
          elevation: 0,
        ),
        drawerTheme: const DrawerThemeData(backgroundColor: Color(0xFF0B0D0F)),
      ),
      home: const AppGate(),
    );
  }
}

class AppGate extends StatelessWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context) {
    return const _UpdateGate();
  }
}

class _UpdateGate extends StatefulWidget {
  const _UpdateGate();

  @override
  State<_UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<_UpdateGate> {
  bool _checked = false;
  AppUpdateInfo? _info;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    final info = await AppUpdateService.check(platform: platform);
    if (!mounted) return;
    setState(() {
      _info = info;
      _checked = true;
    });

    if (info.status == AppUpdateStatus.available) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showOptionalUpdate(info);
      });
    }
  }

  Future<void> _showOptionalUpdate(AppUpdateInfo info) async {
    final url = info.updateUrl;
    await showDialog<void>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Update available'),
          content: Text(
            'A newer version is available (build ${info.latestBuild ?? ''}).\n'
            'You are on build ${info.currentBuild}.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Later')),
            TextButton(
              onPressed: url == null
                  ? null
                  : () async {
                      final uri = Uri.tryParse(url);
                      if (uri != null) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
              child: const Text('Update'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (info != null && info.status == AppUpdateStatus.required) {
      final url = info.updateUrl;
      return Scaffold(
        appBar: AppBar(title: const Text('Update required')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Please update Aether to continue.',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  'Your build: ${info.currentBuild}\nMinimum build: ${info.minBuild ?? ''}',
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: url == null
                        ? null
                        : () async {
                            final uri = Uri.tryParse(url);
                            if (uri != null) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                    child: const Text('Update'),
                  ),
                ),
                if (url == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('Update link not configured.', style: TextStyle(color: Colors.white54)),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // If a token exists on disk, start in Home; otherwise show Login.
    return BackendService.authToken != null ? const HomePage() : const LoginScreen();
  }
}

// `HomePage` moved to `lib/screens/home_page.dart`.
