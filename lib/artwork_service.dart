import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'app_info.dart';
import 'id3_lyrics_embedder.dart';

/// Bounded artwork loading shared by downloads and manual metadata editing.
class ArtworkService {
  ArtworkService(this._dio);
  final Dio _dio;
  static const maxCoverBytes = 5 * 1024 * 1024;

  Future<Id3CoverImage?> download(
    String? coverUrl, {
    required String referer,
    CancelToken? cancelToken,
  }) async {
    if (coverUrl == null || coverUrl.trim().isEmpty) {
      return null;
    }

    for (final headers in [
      {
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        'Referer': referer,
        'User-Agent': appUserAgent,
      },
      {
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        'User-Agent': appUserAgent,
      },
    ]) {
      final coverRequestToken = CancelToken();
      final activeDownloadToken = cancelToken;
      if (activeDownloadToken != null) {
        if (activeDownloadToken.isCancelled) {
          coverRequestToken.cancel(activeDownloadToken.cancelError);
        } else {
          unawaited(
            activeDownloadToken.whenCancel.then((error) {
              if (!coverRequestToken.isCancelled) {
                coverRequestToken.cancel(error);
              }
            }),
          );
        }
      }
      try {
        final response = await _dio.getUri<ResponseBody>(
          Uri.parse(coverUrl),
          cancelToken: coverRequestToken,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 12),
            headers: headers,
          ),
        );
        final status = response.statusCode ?? 0;
        final body = response.data;
        if (status >= 400 || body == null) {
          return null;
        }
        final bytes = await _readResponseBytes(
          body,
          maxBytes: maxCoverBytes,
          advertisedLength: int.tryParse(
            response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
          ),
          requestToken: coverRequestToken,
        );
        if (bytes == null || bytes.isEmpty) {
          return null;
        }
        final mimeType = _coverMimeType(
          bytes,
          contentType: response.headers.value(Headers.contentTypeHeader),
          url: coverUrl,
        );
        if (mimeType == null) {
          return null;
        }
        return Id3CoverImage(mimeType: mimeType, bytes: bytes);
      } on DioException catch (error) {
        if (activeDownloadToken?.isCancelled ?? false) {
          rethrow;
        }
        if (CancelToken.isCancel(error) && coverRequestToken.isCancelled) {
          return null;
        }
      } catch (_) {
        // Retry once without the Referer header below.
      }
    }
    return null;
  }

  Future<Uint8List?> _readResponseBytes(
    ResponseBody body, {
    required int maxBytes,
    required int? advertisedLength,
    required CancelToken requestToken,
  }) async {
    if (advertisedLength != null && advertisedLength > maxBytes) {
      final subscription = body.stream.listen(null, onError: (_) {});
      requestToken.cancel('cover response exceeds $maxBytes bytes');
      await subscription.cancel();
      return null;
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (builder.length + chunk.length > maxBytes) {
        requestToken.cancel('cover response exceeds $maxBytes bytes');
        return null;
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<Id3CoverImage?> loadManual(String input) async {
    final uri = Uri.tryParse(input);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      return download(input, referer: 'https://www.gequbao.com/');
    }

    try {
      final file = File(input);
      if (!await file.exists()) {
        return null;
      }
      final coverFile = await file.open();
      late final Uint8List bytes;
      try {
        final length = await coverFile.length();
        if (length == 0 || length > maxCoverBytes) {
          return null;
        }
        // Bound the read as well as checking length, including growing files.
        bytes = await coverFile.read(maxCoverBytes + 1);
        if (bytes.isEmpty || bytes.length > maxCoverBytes) {
          return null;
        }
      } finally {
        await coverFile.close();
      }
      final mimeType = _coverMimeType(bytes, contentType: null, url: input);
      if (mimeType == null) {
        return null;
      }
      return Id3CoverImage(
        mimeType: mimeType,
        bytes: Uint8List.fromList(bytes),
      );
    } catch (_) {
      return null;
    }
  }

  String? _coverMimeType(
    List<int> bytes, {
    required String? contentType,
    required String url,
  }) {
    final normalizedContentType = contentType
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (normalizedContentType == 'image/jpeg' ||
        normalizedContentType == 'image/png' ||
        normalizedContentType == 'image/webp') {
      return normalizedContentType;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }

    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (path.endsWith('.png')) {
      return 'image/png';
    }
    if (path.endsWith('.webp')) {
      return 'image/webp';
    }
    return null;
  }
}
