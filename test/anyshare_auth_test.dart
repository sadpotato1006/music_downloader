import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/anyshare_auth.dart';

class _MemoryCredentials implements AnyShareCredentialStore {
  final values = <String, String>{};
  bool failWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('keyring locked');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test(
    'failed credential persistence cannot leave a falsely saved session',
    () async {
      final credentials = _MemoryCredentials()..failWrites = true;
      final dio = Dio();
      var registrations = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (request.path.endsWith('/oauth2/clients')) {
              registrations++;
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 201,
                  data: {
                    'client_id': 'client-$registrations',
                    'client_secret': 'secret',
                  },
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'access_token': 'token',
                    'refresh_token': 'refresh',
                    'expires_in': 3600,
                  },
                ),
              );
            }
          },
        ),
      );
      final auth = AnyShareAuth(dio: dio, credentials: credentials);
      await expectLater(auth.beginLogin(), throwsStateError);
      credentials.failWrites = false;
      final url = await auth.beginLogin();
      expect(registrations, 2);
      expect(url.queryParameters['client_id'], 'client-2');
      credentials.failWrites = true;
      await expectLater(
        auth.finishLogin(
          Uri.parse(
            '${AnyShareAuth.callbackUrl}?code=code&state=${url.queryParameters['state']}',
          ),
        ),
        throwsStateError,
      );
      expect(auth.hasSession, isFalse);
      credentials.failWrites = false;
      final retry = await auth.beginLogin();
      await auth.finishLogin(
        Uri.parse(
          '${AnyShareAuth.callbackUrl}?code=code&state=${retry.queryParameters['state']}',
        ),
      );
      expect(auth.hasSession, isTrue);
      expect(
        await AnyShareAuth(dio: dio, credentials: credentials).restore(),
        isTrue,
      );
    },
  );

  test(
    'OAuth callback checks state and refreshes an expired access token',
    () async {
      final credentials = _MemoryCredentials();
      final dio = Dio();
      var registered = 0;
      var issued = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (request.path.endsWith('/oauth2/clients')) {
              registered++;
              final body = request.data as Map<String, dynamic>;
              expect(body['grant_types'], [
                'authorization_code',
                'implicit',
                'refresh_token',
              ]);
              expect(body['response_types'], [
                'token id_token',
                'code',
                'token',
              ]);
              final device = (body['metadata'] as Map)['device'] as Map;
              expect(
                device['client_type'],
                Platform.isWindows || Platform.isLinux
                    ? 'web'
                    : Platform.isAndroid
                    ? 'android'
                    : 'linux',
              );
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 201,
                  data: {'client_id': 'client', 'client_secret': 'secret'},
                ),
              );
              return;
            }
            if (request.path.endsWith('/oauth2/token')) {
              issued++;
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'access_token': 'access-$issued',
                    'refresh_token': 'refresh',
                    'expires_in': issued == 1 ? 1 : 3600,
                  },
                ),
              );
              return;
            }
            handler.reject(DioException(requestOptions: request));
          },
        ),
      );
      final auth = AnyShareAuth(dio: dio, credentials: credentials);
      final url = await auth.beginLogin();
      expect(registered, 1);
      final state = url.queryParameters['state']!;
      await expectLater(
        auth.finishLogin(
          Uri.parse('${AnyShareAuth.callbackUrl}?code=code&state=wrong'),
        ),
        throwsFormatException,
      );
      await auth.finishLogin(
        Uri.parse('${AnyShareAuth.callbackUrl}?code=code&state=$state'),
      );
      expect(await auth.accessToken(), 'access-2');
      expect(issued, 2);
      final restored = AnyShareAuth(dio: dio, credentials: credentials);
      expect(await restored.restore(), isTrue);
      expect(await restored.accessToken(), 'access-2');
      await restored.logout();
      expect(await restored.restore(), isFalse);
    },
  );

  test('registration shows the server validation hint', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.reject(
          DioException(
            requestOptions: request,
            response: Response(
              requestOptions: request,
              statusCode: 400,
              data: {
                'error': 'invalid_request',
                'error_hint': 'grant_types: Array must have at least 3 items',
              },
            ),
            type: DioExceptionType.badResponse,
          ),
        ),
      ),
    );

    final auth = AnyShareAuth(dio: dio, credentials: _MemoryCredentials());
    await expectLater(
      auth.beginLogin(),
      throwsA(
        isA<AnyShareAuthException>().having(
          (error) => error.message,
          'message',
          contains('grant_types: Array must have at least 3 items'),
        ),
      ),
    );
  });

  test(
    'desktop replaces old native-type client before login',
    () async {
      final credentials = _MemoryCredentials();
      credentials.values['anyshare.oauth.client'] =
          '{"id":"old-client","secret":"old-secret"}';
      credentials.values['anyshare.oauth.token'] =
          '{"accessToken":"old-token","refreshToken":"old-refresh",'
          '"expiresAt":"2099-01-01T00:00:00.000"}';
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final body = request.data as Map<String, dynamic>;
            final device = (body['metadata'] as Map)['device'] as Map;
            expect(device['client_type'], 'web');
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 201,
                data: {
                  'client_id': 'web-client',
                  'client_secret': 'new-secret',
                },
              ),
            );
          },
        ),
      );
      final auth = AnyShareAuth(dio: dio, credentials: credentials);
      expect(await auth.restore(), isFalse);
      expect(credentials.values.containsKey('anyshare.oauth.token'), isFalse);
      final url = await auth.beginLogin();
      expect(url.queryParameters['client_id'], 'web-client');
      expect(credentials.values['anyshare.oauth.client'], contains('"web"'));
    },
    skip: !(Platform.isWindows || Platform.isLinux),
  );
}
