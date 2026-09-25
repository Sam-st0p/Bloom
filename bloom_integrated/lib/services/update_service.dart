import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';

/// Update info returned when a newer release is found on GitHub.
class UpdateInfo {
  final String version; // e.g. "1.0.1"
  final String downloadUrl; // direct APK asset URL
  final String? releaseNotes;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    this.releaseNotes,
  });
}

class UpdateService {
  // TODO: change these to match your repo
  static const String owner = 'YOUR_GITHUB_USERNAME';
  static const String repo = 'YOUR_REPO_NAME';

  static String get _apiUrl =>
      'https://api.github.com/repos/$owner/$repo/releases/latest';

  /// Checks GitHub for the latest release and compares it to the
  /// currently installed app version. Returns null if already up to date.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await http.get(Uri.parse(_apiUrl));
      if (response.statusCode != 200) {
        // No releases yet, rate-limited, or repo/path typo.
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String?) ?? '';
      final remoteVersion = tagName.replaceFirst(RegExp(r'^v'), '');

      final packageInfo = await PackageInfo.fromPlatform();
      final localVersion = packageInfo.version; // from pubspec.yaml

      if (!_isNewer(remoteVersion, localVersion)) {
        return null; // already up to date
      }

      final assets = data['assets'] as List<dynamic>?;
      if (assets == null || assets.isEmpty) return null;

      // Find the .apk asset among release attachments
      final apkAsset = assets.firstWhere(
        (a) => (a['name'] as String).toLowerCase().endsWith('.apk'),
        orElse: () => null,
      );
      if (apkAsset == null) return null;

      return UpdateInfo(
        version: remoteVersion,
        downloadUrl: apkAsset['browser_download_url'] as String,
        releaseNotes: data['body'] as String?,
      );
    } catch (e) {
      // Network error, malformed JSON, etc. Fail silently — don't block app startup.
      return null;
    }
  }

  /// Compares two "x.y.z" version strings. Returns true if [remote] > [local].
  static bool _isNewer(String remote, String local) {
    final r = remote.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final l = local.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final len = r.length > l.length ? r.length : l.length;
    for (var i = 0; i < len; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }

  /// Downloads the APK to the app's external cache dir (matches file_paths.xml)
  /// and returns the local file path.
  static Future<String> downloadApk(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final dir = await getExternalCacheDirectories();
    final saveDir = (dir != null && dir.isNotEmpty)
        ? dir.first
        : await getTemporaryDirectory();

    final filePath = '${saveDir.path}/update.apk';
    final file = File(filePath);

    final request = http.Request('GET', Uri.parse(url));
    final response = await http.Client().send(request);

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();

    await response.stream.map((chunk) {
      received += chunk.length;
      if (total > 0 && onProgress != null) {
        onProgress(received / total);
      }
      return chunk;
    }).pipe(sink);

    await sink.close();
    return filePath;
  }

  /// Requests the "install unknown apps" permission (Android 8+) and,
  /// if granted, opens the installer for the given APK file.
  static Future<void> installApk(String filePath) async {
    final status = await Permission.requestInstallPackages.status;
    if (!status.isGranted) {
      final result = await Permission.requestInstallPackages.request();
      if (!result.isGranted) {
        throw Exception(
          'Install permission denied. Enable "Install unknown apps" for this app in Settings.',
        );
      }
    }
    await OpenFilex.open(filePath);
  }
}