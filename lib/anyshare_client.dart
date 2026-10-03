import 'dart:io';

import 'package:dio/dio.dart';

import 'anyshare_auth.dart';

class AnyShareFolder {
  const AnyShareFolder({required this.id, required this.name});
  final String id;
  final String name;
}

class AnyShareFile {
  const AnyShareFile({
    required this.id,
    required this.name,
    required this.rev,
    required this.size,
  });
  final String id;
  final String name;
  final String rev;
  final int size;
}

class AnyShareChildren {
  const AnyShareChildren({required this.folders, required this.files});
  final List<AnyShareFolder> folders;
  final List<AnyShareFile> files;
}

enum AnyShareDeleteStatus { deleted, pendingApproval }

class AnyShareClient {
  AnyShareClient({required this.auth, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 5),
              sendTimeout: const Duration(minutes: 5),
            ),
          );

  final AnyShareAuth auth;
  final Dio _dio;

  Future<Options> _options() async =>
      Options(headers: {'Authorization': 'Bearer ${await auth.accessToken()}'});

  Future<List<AnyShareFolder>> ownedFolders() async {
    final response = await _dio.get<dynamic>(
      '${auth.baseUrl}/api/efast/v1/owned-doc-lib',
      options: await _options(),
    );
    final items = response.data;
    if (items is! List) throw const FormatException('云盘文档库列表格式错误');
    return items
        .whereType<Map>()
        .where((item) => item['type'] == 'user_doc_lib' && item['id'] is String)
        .map((item) {
          final rawId = (item['gns'] ?? item['id']).toString();
          return AnyShareFolder(
            id: rawId.startsWith('gns://') ? rawId : 'gns://$rawId',
            name: item['name']?.toString() ?? '个人文档库',
          );
        })
        .toList();
  }

  Future<AnyShareChildren> listChildren(String folderId) async {
    final folders = <AnyShareFolder>[];
    final files = <AnyShareFile>[];
    final seenMarkers = <String>{};
    String? marker;
    do {
      final response = await _dio.get<Map<String, dynamic>>(
        '${auth.baseUrl}/api/document/v1/folders/'
        '${Uri.encodeComponent(folderId)}/sub_objects',
        queryParameters: {
          'limit': 100,
          'sort': 'name',
          'direction': 'asc',
          'permission_attributes_required': false,
          if (marker != null && marker.isNotEmpty) 'marker': marker,
        },
        options: await _options(),
      );
      final body = response.data;
      if (body == null) throw const FormatException('云盘文件夹响应为空');
      for (final item in (body['dirs'] as List? ?? const []).whereType<Map>()) {
        if (item['id'] is String && item['name'] is String) {
          folders.add(
            AnyShareFolder(
              id: item['id'] as String,
              name: item['name'] as String,
            ),
          );
        }
      }
      for (final item
          in (body['files'] as List? ?? const []).whereType<Map>()) {
        if (item['id'] is String && item['name'] is String) {
          files.add(
            AnyShareFile(
              id: item['id'] as String,
              name: item['name'] as String,
              rev: item['rev']?.toString() ?? '',
              size: (item['size'] as num?)?.toInt() ?? -1,
            ),
          );
        }
      }
      final nextMarker = body['next_marker'];
      marker = nextMarker is String && nextMarker.isNotEmpty
          ? nextMarker
          : null;
      if (marker != null && !seenMarkers.add(marker)) {
        throw const FormatException('云盘目录分页标记重复');
      }
    } while (marker != null && marker.isNotEmpty);
    return AnyShareChildren(folders: folders, files: files);
  }

  Future<AnyShareFolder> createFolder(String parentId, String name) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '${auth.baseUrl}/api/efast/v1/dir/createmultileveldir',
      data: {'docid': parentId, 'path': name},
      options: await _options(),
    );
    final id = response.data?['docid'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('云盘未返回新建文件夹标识');
    }
    return AnyShareFolder(id: id, name: name);
  }

  Future<AnyShareFile> uploadFile(
    File file,
    String parentId,
    String name, {
    AnyShareFile? replace,
    int ondup = 2,
    void Function(int sent, int total)? onProgress,
  }) async {
    final stat = await file.stat();
    final response = await _dio.post<Map<String, dynamic>>(
      '${auth.baseUrl}/api/efast/v1/file/osbeginupload',
      data: {
        'client_mtime': stat.modified.microsecondsSinceEpoch,
        'docid': replace?.id ?? parentId,
        'length': stat.size,
        if (replace == null) 'name': name,
        if (replace == null) 'ondup': ondup,
        if (replace != null) 'editedrev': replace.rev,
        // 学校的对象存储对 POST 表单上传返回 500；使用接口默认的
        // PUT 原始文件上传，并按 authrequest 提供的请求头发送。
        'reqmethod': 'PUT',
      },
      options: await _options(),
    );
    final body = response.data;
    final request = body?['authrequest'];
    final id = body?['docid'];
    final rev = body?['rev'];
    if (request is! List ||
        request.length < 2 ||
        id is! String ||
        rev is! String) {
      throw const FormatException('云盘未返回上传地址');
    }
    final method = request[0].toString().toUpperCase();
    final uploadUrl = Uri.tryParse(request[1].toString());
    if ((method != 'POST' && method != 'PUT') ||
        uploadUrl == null ||
        uploadUrl.scheme != 'https') {
      throw const FormatException('云盘返回了不支持的上传方式');
    }
    final fields = <String, String>{};
    for (final field in request.skip(2)) {
      final value = field.toString();
      final separator = value.indexOf(': ');
      if (separator <= 0) throw const FormatException('上传表单字段错误');
      fields[value.substring(0, separator)] = value.substring(separator + 2);
    }
    if (method == 'POST') {
      final form = FormData();
      form.fields.addAll(fields.entries);
      form.files.add(
        MapEntry(
          'file',
          await MultipartFile.fromFile(file.path, filename: name),
        ),
      );
      await _dio.postUri<void>(
        uploadUrl,
        data: form,
        onSendProgress: onProgress,
      );
    } else {
      await _dio.putUri<void>(
        uploadUrl,
        data: file.openRead(),
        onSendProgress: onProgress,
        options: Options(
          headers: {...fields, 'Content-Length': stat.size},
          contentType: fields['Content-Type'] ?? 'application/octet-stream',
        ),
      );
    }
    await _dio.post<dynamic>(
      '${auth.baseUrl}/api/efast/v1/file/osendupload',
      data: {
        'docid': id,
        'rev': rev,
        if (replace != null) 'editedrev': replace.rev,
      },
      options: await _options(),
    );
    return AnyShareFile(
      id: id,
      name: body?['name']?.toString() ?? name,
      rev: rev,
      size: stat.size,
    );
  }

  Future<void> downloadFile(
    AnyShareFile remote,
    File destination, {
    void Function(int received, int total)? onProgress,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '${auth.baseUrl}/api/efast/v1/file/osdownload',
      data: {
        'docid': remote.id,
        if (remote.rev.isNotEmpty) 'rev': remote.rev,
        'authtype': 'QUERY_STRING',
      },
      options: await _options(),
    );
    final request = response.data?['authrequest'];
    if (request is! List ||
        request.length < 2 ||
        request[0].toString().toUpperCase() != 'GET') {
      throw const FormatException('云盘未返回下载地址');
    }
    final url = Uri.tryParse(request[1].toString());
    if (url == null || url.scheme != 'https') {
      throw const FormatException('云盘返回了无效的下载地址');
    }
    final signedHeaders = <String, String>{};
    for (final field in request.skip(2)) {
      final value = field.toString();
      final separator = value.indexOf(': ');
      if (separator <= 0) throw const FormatException('下载签名字段错误');
      signedHeaders[value.substring(0, separator)] = value.substring(
        separator + 2,
      );
    }
    await destination.parent.create(recursive: true);
    try {
      await _dio.downloadUri(
        url,
        destination.path,
        onReceiveProgress: onProgress,
        options: Options(headers: signedHeaders),
      );
      if (remote.size >= 0 && await destination.length() != remote.size) {
        throw const FileSystemException('云盘下载的文件大小不完整');
      }
    } catch (_) {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  Future<AnyShareDeleteStatus> deleteFile(AnyShareFile remote) async {
    final response = await _dio.post<dynamic>(
      '${auth.baseUrl}/api/efast/v1/file/delete',
      data: {'docid': remote.id},
      options: await _options(),
    );
    return response.statusCode == 202
        ? AnyShareDeleteStatus.pendingApproval
        : AnyShareDeleteStatus.deleted;
  }
}
