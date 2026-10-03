import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/anyshare_auth.dart';
import 'package:qingting/anyshare_client.dart';

class _TestAuth extends AnyShareAuth {
  _TestAuth() : super(baseUrl: 'https://yunpan.ustb.edu.cn');

  @override
  Future<String> accessToken() async => 'test-token';
}

void main() {
  test('reports HTTP 202 as pending approval', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          handler.resolve(Response(requestOptions: request, statusCode: 202));
        },
      ),
    );
    final status = await AnyShareClient(auth: _TestAuth(), dio: dio).deleteFile(
      const AnyShareFile(
        id: 'gns://root/song',
        name: 'song.mp3',
        rev: 'rev-1',
        size: 4,
      ),
    );
    expect(status, AnyShareDeleteStatus.pendingApproval);
  });

  test('deletes a cloud file through the documented endpoint', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          expect(request.method, 'POST');
          expect(request.uri.path, '/api/efast/v1/file/delete');
          expect(request.data, {'docid': 'gns://root/song'});
          handler.resolve(Response(requestOptions: request, statusCode: 200));
        },
      ),
    );
    final status = await AnyShareClient(auth: _TestAuth(), dio: dio).deleteFile(
      const AnyShareFile(
        id: 'gns://root/song',
        name: 'song.mp3',
        rev: 'rev-1',
        size: 4,
      ),
    );
    expect(status, AnyShareDeleteStatus.deleted);
  });

  test('uploads bytes with the signed PUT request', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-put-test-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
    await file.writeAsBytes([1, 2, 3]);
    final dio = Dio();
    var stored = 0;
    var begun = 0;
    var finished = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.path.endsWith('/osbeginupload')) {
            begun++;
            final body = request.data as Map<String, dynamic>;
            expect(body['reqmethod'], 'PUT');
            expect(body['length'], 3);
            if (begun == 1) {
              expect(body['ondup'], 2);
              expect(body.containsKey('editedrev'), isFalse);
            } else {
              expect(body['editedrev'], 'revision-1');
            }
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'docid': 'gns://root/file',
                  'rev': 'revision-$begun',
                  'authrequest': [
                    'PUT',
                    'https://storage.example.com/objects/test',
                    'Content-Type: application/octet-stream',
                    'X-Test-Signature: signed',
                  ],
                },
              ),
            );
            return;
          }
          if (request.uri.host == 'storage.example.com') {
            expect(request.method, 'PUT');
            expect(request.headers['Content-Length'], 3);
            expect(request.headers['X-Test-Signature'], 'signed');
            final bytes = await (request.data as Stream<List<int>>)
                .expand((part) => part)
                .toList();
            expect(bytes, [1, 2, 3]);
            stored++;
            handler.resolve(Response(requestOptions: request, statusCode: 200));
            return;
          }
          if (request.path.endsWith('/osendupload')) {
            finished++;
            expect(stored, finished);
            final body = request.data as Map<String, dynamic>;
            if (finished == 2) expect(body['editedrev'], 'revision-1');
            handler.resolve(Response(requestOptions: request, statusCode: 200));
            return;
          }
          handler.reject(DioException(requestOptions: request));
        },
      ),
    );

    try {
      final client = AnyShareClient(auth: _TestAuth(), dio: dio);
      final uploaded = await client.uploadFile(file, 'gns://root', 'song.mp3');
      expect(uploaded.id, 'gns://root/file');
      final replaced = await client.uploadFile(
        file,
        'gns://root',
        'song.mp3',
        replace: uploaded,
      );
      expect(replaced.rev, 'revision-2');
      expect(finished, 2);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
