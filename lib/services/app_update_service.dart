import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'backend_service.dart';

enum AppUpdateStatus {
  none,
  available,
  required,
}

class AppUpdateInfo {
  final AppUpdateStatus status;
  final int? latestBuild;
  final int? minBuild;
  final int currentBuild;
  final String? updateUrl;

  const AppUpdateInfo({
    required this.status,
    required this.currentBuild,
    this.latestBuild,
    this.minBuild,
    this.updateUrl,
  });
}

class AppUpdateService {
  static const Duration _timeout = Duration(seconds: 10);

  static Future<AppUpdateInfo> check({required String platform}) async {
    final info = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(info.buildNumber) ?? 0;

    try {
      final url = Uri.parse('${BackendService.baseUrl}/app/version?platform=$platform');
      final resp = await http.get(url).timeout(_timeout);
      if (resp.statusCode != 200) {
        return AppUpdateInfo(status: AppUpdateStatus.none, currentBuild: currentBuild);
      }

      final data = jsonDecode(resp.body);
      if (data is! Map) {
        return AppUpdateInfo(status: AppUpdateStatus.none, currentBuild: currentBuild);
      }

      final latest = _toInt(data['latestBuild']);
      final min = _toInt(data['minBuild']);
      final updateUrl = data['updateUrl']?.toString();

      if (min != null && currentBuild > 0 && currentBuild < min) {
        return AppUpdateInfo(
          status: AppUpdateStatus.required,
          currentBuild: currentBuild,
          latestBuild: latest,
          minBuild: min,
          updateUrl: updateUrl,
        );
      }

      if (latest != null && currentBuild > 0 && currentBuild < latest) {
        return AppUpdateInfo(
          status: AppUpdateStatus.available,
          currentBuild: currentBuild,
          latestBuild: latest,
          minBuild: min,
          updateUrl: updateUrl,
        );
      }

      return AppUpdateInfo(
        status: AppUpdateStatus.none,
        currentBuild: currentBuild,
        latestBuild: latest,
        minBuild: min,
        updateUrl: updateUrl,
      );
    } catch (_) {
      return AppUpdateInfo(status: AppUpdateStatus.none, currentBuild: currentBuild);
    }
  }

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}
