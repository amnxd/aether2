import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'backend_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Needed so background isolate can use Firebase APIs.
  await Firebase.initializeApp();
}

class PushService {
  PushService._();

  static bool _initialized = false;
  static bool _firebaseReady = false;

  static Future<void> init() async {
    if (_initialized) return;

    try {
      await Firebase.initializeApp();
      _firebaseReady = true;
    } catch (_) {
      // Firebase config missing (e.g., google-services.json not present).
      _initialized = true;
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // iOS permission; Android 13+ handled by POST_NOTIFICATIONS + runtime request.
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

    // Register current token with backend (best-effort).
    await registerWithBackend();

    // Token refresh.
    FirebaseMessaging.instance.onTokenRefresh.listen((t) {
      _registerToken(t);
    });

    _initialized = true;
  }

  static Future<void> registerWithBackend() async {
    if (!_firebaseReady) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await _registerToken(token);
    } catch (_) {
      // ignore
    }
  }

  static Future<void> _registerToken(String token) async {
    try {
      final platform = Platform.isAndroid
          ? 'android'
          : (Platform.isIOS ? 'ios' : (Platform.isMacOS ? 'macos' : 'other'));
      await BackendService.registerFcmToken(token: token, platform: platform);
    } catch (_) {
      // ignore
    }
  }
}
