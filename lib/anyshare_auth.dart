import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

abstract class AnyShareCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class AnyShareAuthException implements Exception {
  const AnyShareAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SecureAnyShareCredentialStore implements AnyShareCredentialStore {
  const SecureAnyShareCredentialStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _secure(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String value) =>
      _secure(() => _storage.write(key: key, value: value));

  @override
  Future<void> delete(String key) => _secure(() => _storage.delete(key: key));

  Future<T> _secure<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException {
      if (Platform.isLinux) {
        throw const AnyShareAuthException(
          '无法访问系统密钥环。请启用并解锁 Secret Service（如 GNOME Keyring），再重试云盘登录。',
        );
      }
      rethrow;
    }
  }
}

class AnyShareAuth {
  AnyShareAuth({
    Dio? dio,
    AnyShareCredentialStore? credentials,
    this.baseUrl = 'https://yunpan.ustb.edu.cn',
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))),
       _credentials = credentials ?? const SecureAnyShareCredentialStore();

  static const callbackUrl = 'https://127.0.0.1:9010/callback';
  static const _clientKey = 'anyshare.oauth.client';
  static const _tokenKey = 'anyshare.oauth.token';

  final Dio _dio;
  final AnyShareCredentialStore _credentials;
  final String baseUrl;
  _OAuthClient? _client;
  _OAuthToken? _token;
  String? _pendingState;
  Future<String>? _refreshOperation;

  bool get hasSession =>
      _token?.refreshToken.isNotEmpty == true ||
      (_token != null && _token!.expiresAt.isAfter(DateTime.now()));

  Future<bool> restore() async {
    final rawClient = await _credentials.read(_clientKey);
    final rawToken = await _credentials.read(_tokenKey);
    try {
      _client = rawClient == null
          ? null
          : _OAuthClient.fromJson(
              jsonDecode(rawClient) as Map<String, dynamic>,
            );
      _token = rawToken == null
          ? null
          : _OAuthToken.fromJson(jsonDecode(rawToken) as Map<String, dynamic>);
    } catch (_) {
      _client = null;
      _token = null;
    }
    if (_client != null && !_canUseClient(_client!)) {
      _client = null;
      _token = null;
      await _credentials.delete(_tokenKey);
    }
    return hasSession && _client != null;
  }

  Future<Uri> beginLogin() async {
    final client = await _ensureClient();
    final state = _randomUrlSafe(32);
    _pendingState = state;
    return Uri.parse('$baseUrl/oauth2/auth').replace(
      queryParameters: {
        'client_id': client.id,
        'redirect_uri': callbackUrl,
        'response_type': 'code',
        'scope': 'offline openid all',
        'state': state,
        'nonce': _randomUrlSafe(32),
      },
    );
  }

  Future<void> finishLogin(Uri callback) async {
    if (callback.origin != Uri.parse(callbackUrl).origin ||
        callback.path != Uri.parse(callbackUrl).path) {
      throw const FormatException('登录回调地址无效');
    }
    if (_pendingState == null ||
        callback.queryParameters['state'] != _pendingState) {
      throw const FormatException('登录校验失败，请重新扫码');
    }
    _pendingState = null;
    final error = callback.queryParameters['error'];
    if (error != null) {
      throw StateError('云盘登录未完成：$error');
    }
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const FormatException('云盘没有返回授权码');
    }
    final client = _client;
    if (client == null) {
      throw StateError('云盘客户端信息丢失，请重试');
    }
    await _exchangeToken(client, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': callbackUrl,
    });
  }

  Future<String> accessToken() async {
    final token = _token;
    if (token == null) {
      throw StateError('请先登录北科云盘');
    }
    if (token.expiresAt.isAfter(
      DateTime.now().add(const Duration(minutes: 2)),
    )) {
      return token.accessToken;
    }
    final existing = _refreshOperation;
    if (existing != null) return existing;
    late final Future<String> operation;
    operation = _refresh().whenComplete(() {
      if (identical(_refreshOperation, operation)) _refreshOperation = null;
    });
    _refreshOperation = operation;
    return operation;
  }

  Future<String> _refresh() async {
    final client = _client;
    final token = _token;
    if (client == null || token == null || token.refreshToken.isEmpty) {
      throw StateError('云盘登录已过期，请重新扫码');
    }
    await _exchangeToken(client, {
      'grant_type': 'refresh_token',
      'refresh_token': token.refreshToken,
    });
    return _token!.accessToken;
  }

  Future<void> _exchangeToken(
    _OAuthClient client,
    Map<String, String> data,
  ) async {
    final basic = base64Encode(utf8.encode('${client.id}:${client.secret}'));
    final response = await _dio.post<Map<String, dynamic>>(
      '$baseUrl/oauth2/token',
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Authorization': 'Basic $basic'},
      ),
    );
    final body = response.data;
    if (body == null || body['access_token'] is! String) {
      throw const FormatException('云盘返回了无效的授权结果');
    }
    final seconds = int.tryParse('${body['expires_in'] ?? 3600}') ?? 3600;
    final next = _OAuthToken(
      accessToken: body['access_token'] as String,
      refreshToken:
          (body['refresh_token'] as String?) ?? _token?.refreshToken ?? '',
      expiresAt: DateTime.now().add(Duration(seconds: seconds)),
    );
    await _credentials.write(_tokenKey, jsonEncode(next.toJson()));
    _token = next;
  }

  Future<_OAuthClient> _ensureClient() async {
    final existing = _client;
    if (existing != null && _canUseClient(existing)) return existing;
    if (existing != null) {
      _client = null;
      _token = null;
      await _credentials.delete(_tokenKey);
    }
    final platformName = Platform.isWindows
        ? 'windows'
        : Platform.isAndroid
        ? 'android'
        : 'linux';
    // 原生桌面类型的登录页会把个人用户登录交给官方桌面宿主处理。
    // 青听使用内嵌网页，必须注册为 web 才能直接跳转学校 SSO。
    final deviceType = Platform.isWindows || Platform.isLinux
        ? 'web'
        : platformName;
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        '$baseUrl/oauth2/clients',
        data: {
          'client_name': '青听音乐同步',
          // 北科云盘的客户端注册接口要求两组参数都至少有三项。
          // 实际登录仍只使用 authorization_code 和 refresh_token。
          'grant_types': ['authorization_code', 'implicit', 'refresh_token'],
          'response_types': ['token id_token', 'code', 'token'],
          'scope': 'offline openid all',
          'redirect_uris': [callbackUrl],
          'post_logout_redirect_uris': [callbackUrl],
          'metadata': {
            'device': {
              'name': '青听 $platformName',
              'client_type': deviceType,
              'description': '青听个人音乐同步',
            },
          },
        },
      );
    } on DioException catch (error) {
      throw AnyShareAuthException(_registrationErrorMessage(error));
    }
    final body = response.data;
    if (body == null ||
        body['client_id'] is! String ||
        body['client_secret'] is! String) {
      throw const FormatException('云盘未返回客户端授权信息');
    }
    final client = _OAuthClient(
      id: body['client_id'] as String,
      secret: body['client_secret'] as String,
      clientType: deviceType,
    );
    await _credentials.write(_clientKey, jsonEncode(client.toJson()));
    _client = client;
    return client;
  }

  bool _canUseClient(_OAuthClient client) =>
      !(Platform.isWindows || Platform.isLinux) || client.clientType == 'web';

  String _registrationErrorMessage(DioException error) {
    final status = error.response?.statusCode;
    final data = error.response?.data;
    if (data is Map) {
      final hint = data['error_hint'];
      final description = data['error_description'];
      final detail = hint is String && hint.isNotEmpty
          ? hint
          : description is String && description.isNotEmpty
          ? description
          : null;
      if (detail != null) {
        return '北科云盘拒绝创建登录请求${status == null ? '' : '（HTTP $status）'}：$detail';
      }
    }
    return status == null
        ? '连接北科云盘失败，请检查网络后重试'
        : '北科云盘拒绝创建登录请求（HTTP $status），请稍后重试';
  }

  Future<void> logout() async {
    _token = null;
    _pendingState = null;
    await _credentials.delete(_tokenKey);
  }

  String _randomUrlSafe(int length) {
    final random = Random.secure();
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    return List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }
}

class _OAuthClient {
  const _OAuthClient({
    required this.id,
    required this.secret,
    required this.clientType,
  });
  final String id;
  final String secret;
  final String? clientType;
  Map<String, String?> toJson() => {
    'id': id,
    'secret': secret,
    'clientType': clientType,
  };
  factory _OAuthClient.fromJson(Map<String, dynamic> json) => _OAuthClient(
    id: json['id'] as String,
    secret: json['secret'] as String,
    clientType: json['clientType'] as String?,
  );
}

class _OAuthToken {
  const _OAuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  Map<String, String> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toIso8601String(),
  };
  factory _OAuthToken.fromJson(Map<String, dynamic> json) => _OAuthToken(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String? ?? '',
    expiresAt: DateTime.parse(json['expiresAt'] as String),
  );
}
