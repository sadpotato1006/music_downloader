import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_info.dart';

const appReleasePage =
    'https://github.com/sadpotato1006/music_downloader/releases';
const _repositoryPath = 'sadpotato1006/music_downloader';

class UpdateVersion implements Comparable<UpdateVersion> {
  UpdateVersion._(this.parts, this.build);

  factory UpdateVersion.parse(String value) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(value);
    if (match == null) throw const FormatException('更新版本号无效');
    return UpdateVersion._([
      for (var i = 1; i <= 3; i++) int.parse(match.group(i)!),
    ], int.parse(match.group(4) ?? '0'));
  }

  final List<int> parts;
  final int build;

  String get release => parts.join('.');
  @override
  String toString() => '$release+$build';
  @override
  int compareTo(UpdateVersion other) {
    for (var i = 0; i < 3; i++) {
      final result = parts[i].compareTo(other.parts[i]);
      if (result != 0) return result;
    }
    return build.compareTo(other.build);
  }
}

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.version,
    required this.notes,
    required this.assetName,
    required this.url,
    required this.size,
    required this.sha256Hex,
  });

  final UpdateVersion version;
  final String notes;
  final String assetName;
  final Uri url;
  final int size;
  final String sha256Hex;
}

abstract class AppUpdateSource {
  Future<AppUpdateRelease?> check(UpdateVersion current, CancelToken cancel);
  Future<File> download(
    AppUpdateRelease release,
    CancelToken cancel,
    void Function(int received, int total) progress,
  );
  void close() {}
}

/// Only accepts release assets from this repository. Redirects are restricted
/// to GitHub's HTTPS asset hosts; the downloaded executable is never a shell command.
class GitHubUpdateSource extends AppUpdateSource {
  GitHubUpdateSource({Dio? dio, Future<Directory> Function()? cacheDirectory})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ),
          ),
      _cacheDirectory = cacheDirectory ?? defaultUpdateDirectory;

  static const maxInstallerBytes = 256 * 1024 * 1024;
  final Dio _dio;
  final Future<Directory> Function() _cacheDirectory;

  static Future<Directory> defaultUpdateDirectory() async {
    if (Platform.isWindows && Platform.environment['LOCALAPPDATA'] != null) {
      return Directory(
        p.join(Platform.environment['LOCALAPPDATA']!, 'QingTing', 'updates'),
      );
    }
    return Directory(
      p.join((await getApplicationSupportDirectory()).path, 'updates'),
    );
  }

  static Uri assetUri(Map<String, dynamic> asset, String tag) {
    final name = asset['name'];
    final rawUrl = asset['browser_download_url'];
    if (name is! String || rawUrl is! String) {
      throw const FormatException('更新附件信息不完整');
    }
    final uri = Uri.parse(rawUrl);
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.join('/') !=
            '$_repositoryPath/releases/download/$tag/$name' ||
        p.basename(name) != name ||
        name.contains('\\')) {
      throw const FormatException('更新附件不是青听官方发布文件');
    }
    return uri;
  }

  Future<ResponseBody> _open(Uri uri, CancelToken cancel) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.port != 443 ||
          !const {
            'api.github.com',
            'github.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
          }.contains(uri.host)) {
        throw const FormatException('更新下载地址无效');
      }
      final response = await _dio.getUri<ResponseBody>(
        uri,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (status) =>
              status != null &&
              (status == 200 ||
                  status == 404 ||
                  const {301, 302, 303, 307, 308}.contains(status)),
          headers: {
            'User-Agent': appProjectUserAgent,
            'Accept': uri.host == 'api.github.com'
                ? 'application/vnd.github+json'
                : 'application/octet-stream',
          },
        ),
      );
      final body = response.data!;
      if (response.statusCode == 200) return body;
      await body.stream.listen(null).cancel();
      if (response.statusCode == 404) throw const UpdateNotPublished();
      final location = response.headers.value('location');
      if (location == null) throw const FormatException('更新下载地址缺少跳转目标');
      uri = uri.resolve(location);
    }
    throw const FormatException('更新下载跳转次数过多');
  }

  Future<Map<String, dynamic>> _json(
    Uri uri,
    CancelToken cancel,
    int limit,
  ) async {
    final response = await _open(uri, cancel);
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('更新信息过大');
      }
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic>) throw const FormatException('更新信息格式无效');
    return data;
  }

  @override
  Future<AppUpdateRelease?> check(
    UpdateVersion current,
    CancelToken cancel,
  ) async {
    Map<String, dynamic> release;
    try {
      release = await _json(
        Uri.https('api.github.com', '/repos/$_repositoryPath/releases/latest'),
        cancel,
        1024 * 1024,
      );
    } on UpdateNotPublished {
      return null;
    }
    if (release['draft'] != false || release['prerelease'] != false) {
      return null;
    }
    final tag = release['tag_name'];
    if (tag is! String) throw const FormatException('缺少发布版本号');
    final tagVersion = UpdateVersion.parse(tag);
    // Older stable tags need no update manifest (the updater predates them).
    if (UpdateVersion.parse(
          tagVersion.release,
        ).compareTo(UpdateVersion.parse(current.release)) <
        0) {
      return null;
    }
    final assets = (release['assets'] as List? ?? [])
        .whereType<Map>()
        .map((a) => Map<String, dynamic>.from(a))
        .toList();
    final manifests = assets
        .where((a) => a['name'] == 'qingting-update.json')
        .toList();
    if (manifests.length != 1) {
      if (tagVersion.compareTo(current) <= 0) return null;
      throw const FormatException('新版尚未提供应用内更新文件，可前往发布页下载');
    }
    final manifest = await _json(
      assetUri(manifests.single, tag),
      cancel,
      64 * 1024,
    );
    if (manifest['schemaVersion'] != 1 || manifest['version'] is! String) {
      throw const FormatException('不支持的更新信息格式');
    }
    final version = UpdateVersion.parse(manifest['version'] as String);
    if (version.release != tagVersion.release || version.build < 1) {
      throw const FormatException('更新版本信息不一致');
    }
    if (version.compareTo(current) <= 0) return null;
    final windows = manifest['windows-x64'];
    if (windows is! Map ||
        windows['installer'] is! String ||
        windows['size'] is! int ||
        windows['sha256'] is! String) {
      throw const FormatException('缺少 Windows x64 更新包');
    }
    final name = windows['installer'] as String;
    final size = windows['size'] as int;
    final hash = (windows['sha256'] as String).toLowerCase();
    if (name != 'QingTingSetup-v${version.release.replaceAll('.', '_')}.exe' ||
        size <= 0 ||
        size > maxInstallerBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('更新包校验信息无效');
    }
    final installers = assets.where((a) => a['name'] == name).toList();
    if (installers.length != 1 || installers.single['size'] != size) {
      throw const FormatException('发布附件与更新清单不一致');
    }
    final digest = installers.single['digest'];
    if (digest != null && digest != 'sha256:$hash') {
      throw const FormatException('发布附件校验值不一致');
    }
    return AppUpdateRelease(
      version: version,
      notes: (release['body'] as String? ?? '').substring(
        0,
        (release['body'] as String? ?? '').length.clamp(0, 20000),
      ),
      assetName: name,
      url: assetUri(installers.single, tag),
      size: size,
      sha256Hex: hash,
    );
  }

  @override
  Future<File> download(
    AppUpdateRelease release,
    CancelToken cancel,
    void Function(int, int) progress,
  ) async {
    final root = await _cacheDirectory();
    await root.create(recursive: true);
    final directory = await root.createTemp('download-');
    final partial = File(p.join(directory.path, '${release.assetName}.part'));
    final output = partial.openWrite();
    var success = false;
    try {
      final response = await _open(release.url, cancel);
      var received = 0;
      await for (final chunk in response.stream) {
        if (cancel.isCancelled) throw cancel.cancelError!;
        received += chunk.length;
        if (received > release.size || received > maxInstallerBytes) {
          throw const FormatException('更新包大小超出预期');
        }
        output.add(chunk);
        // Bound the write queue for slow disks as well as the network stream.
        await output.flush();
        progress(received, release.size);
      }
      await output.close();
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (received != release.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.sha256Hex) {
        throw const FormatException('更新包校验失败，请重新下载');
      }
      final file = await partial.rename(
        p.join(directory.path, release.assetName),
      );
      success = true;
      return file;
    } finally {
      await output.close();
      if (!success && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  @override
  void close() => _dio.close(force: true);
}

class UpdateNotPublished implements Exception {
  const UpdateNotPublished();
}
