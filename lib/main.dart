import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'screens/home_page.dart';
import 'services/backend_service.dart';
import 'services/push_service.dart';

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
    // If a token exists on disk, start in Home; otherwise show Login.
    return BackendService.authToken != null ? const HomePage() : const LoginScreen();
  }
}

// `HomePage` moved to `lib/screens/home_page.dart`.
