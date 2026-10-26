import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'app_log.dart';
import 'models.dart';

class InvalidAudioResponse implements Exception {
  const InvalidAudioResponse(this.message);
  final String message;
  @override
  String toString() => message;
}

/// HTTP and file validation only; queue, source resolution and library state
/// belong to their respective controllers.
class DownloadTransferService {
  DownloadTransferService(this._dio);
  final Dio _dio;

  Future<void> download(
    DownloadTask task,
    CancelToken token, {
    required void Function(int received, int? total) onProgress,
    required void Function(int received, int? total, String? validator)
    onResponse,
    bool allowResume = true,
  }) async {
    final file = File(task.savePath);
    await file.parent.create(recursive: true);
    final offset = allowResume && await file.exists() ? await file.length() : 0;
    final headers = <String, dynamic>{...task.candidate.headers}
      ..removeWhere(
        (key, _) => const {'range', 'if-range'}.contains(key.toLowerCase()),
      );
    final validator = task.resumeValidator?.trim() ?? '';
    if (offset > 0) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$offset-';
      if (validator.isNotEmpty && !validator.startsWith('W/')) {
        headers[HttpHeaders.ifRangeHeader] = validator;
      }
    }
    final response = await _dio.getUri<ResponseBody>(
      Uri.parse(task.candidate.url),
      cancelToken: token,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (status) =>
            status == 200 || status == 206 || status == 416,
      ),
    );
    final body = response.data;
    if (body == null) throw const InvalidAudioResponse('下载响应为空。');
    final range = response.headers.value(HttpHeaders.contentRangeHeader);
    final responseValidator = _validator(response.headers);

    Future<void> restart(String reason) async {
      await body.stream.listen(null, onError: (_) {}).cancel();
      if (token.isCancelled) throw token.cancelError!;
      if (!allowResume) throw InvalidAudioResponse(reason);
      AppLog.instance.warning('download', reason);
      // A full response replaces the file only after its headers are checked.
      await download(
        task,
        token,
        onProgress: onProgress,
        onResponse: onResponse,
        allowResume: false,
      );
    }

    if (response.statusCode == 416) {
      final totalMatch = RegExp(
        r'^bytes\s+\*/(\d+)$',
        caseSensitive: false,
      ).firstMatch(range?.trim() ?? '');
      final total = totalMatch == null ? null : int.tryParse(totalMatch[1]!);
      if (offset > 0 &&
          total == offset &&
          validator.isNotEmpty &&
          !validator.startsWith('W/') &&
          responseValidator == validator) {
        await body.stream.listen(null, onError: (_) {}).cancel();
        await _validateFile(file);
        onResponse(offset, total, responseValidator);
        onProgress(offset, total);
        return;
      }
      await restart('断点文件身份或长度无法确认，重新完整下载。');
      return;
    }

    final contentType =
        response.headers
            .value(Headers.contentTypeHeader)
            ?.split(';')
            .first
            .trim()
            .toLowerCase() ??
        '';
    if (contentType.startsWith('text/') ||
        contentType.contains('json') ||
        contentType.contains('xml') ||
        contentType.startsWith('image/')) {
      await body.stream.listen(null, onError: (_) {}).cancel();
      throw const InvalidAudioResponse('服务器返回了网页或其他非音频内容，请重新解析下载链接。');
    }
    final partial = response.statusCode == 206;
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
      caseSensitive: false,
    ).firstMatch(range?.trim() ?? '');
    final start = match == null ? null : int.tryParse(match[1]!);
    final end = match == null ? null : int.tryParse(match[2]!);
    final rangeTotal = match == null ? null : int.tryParse(match[3]!);
    final length = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (partial &&
        (start != offset ||
            end == null ||
            end < offset ||
            (rangeTotal != null && end >= rangeTotal) ||
            (length != null && length != end - offset + 1))) {
      await restart('服务器返回了无效的断点范围，重新完整下载。');
      return;
    }
    if (partial &&
        offset > 0 &&
        validator.isNotEmpty &&
        (validator.startsWith('W/') || responseValidator != validator)) {
      await restart('断点文件版本已变化或无法确认，重新完整下载。');
      return;
    }
    final base = partial ? offset : 0;
    final total = partial
        ? rangeTotal ?? (length == null ? null : base + length)
        : length;
    onResponse(
      base,
      total,
      responseValidator.isEmpty ? null : responseValidator,
    );
    final output = await file.open(
      mode: partial && offset > 0 ? FileMode.append : FileMode.write,
    );
    var received = base;
    try {
      await for (final chunk in body.stream) {
        if (token.isCancelled) throw token.cancelError!;
        await output.writeFrom(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (token.isCancelled) throw token.cancelError!;
    if (total != null && received != total) {
      if (received > total && await file.exists()) await file.delete();
      throw FileSystemException(
        received < total
            ? '下载响应提前结束：应接收 $total 字节，实际收到 $received 字节。'
            : '下载响应超过声明长度：应接收 $total 字节，实际收到 $received 字节。',
        file.path,
      );
    }
    try {
      await _validateFile(file);
    } on InvalidAudioResponse {
      // Never resume from an HTML page or another invalid payload next time.
      if (await file.exists()) await file.delete();
      rethrow;
    }
    onProgress(received, total ?? received);
  }

  static String _validator(Headers headers) =>
      (headers.value(HttpHeaders.etagHeader) ??
              headers.value(HttpHeaders.lastModifiedHeader) ??
              '')
          .trim();

  static Future<void> _validateFile(File file) async {
    final input = await file.open();
    late final Uint8List prefix;
    try {
      prefix = await input.read(512);
    } finally {
      await input.close();
    }
    bool at(int offset, String text) =>
        prefix.length >= offset + text.length &&
        List.generate(
          text.length,
          (index) => prefix[offset + index] == text.codeUnitAt(index),
        ).every((value) => value);
    final supported =
        at(0, 'ID3') ||
        at(0, 'fLaC') ||
        at(0, 'OggS') ||
        (at(0, 'RIFF') && at(8, 'WAVE')) ||
        at(4, 'ftyp') ||
        (prefix.length >= 2 && prefix[0] == 0xff && (prefix[1] & 0xe0) == 0xe0);
    if (!supported) {
      throw const InvalidAudioResponse('下载内容不是可识别的音频文件，已停止入库，请重新解析或更换歌曲源。');
    }
  }
}
