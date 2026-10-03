import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/file_deletion_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qingting/file_operations');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'failed trash operation preserves the song without permanent deletion',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-trash-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final song = await File(
        '${directory.path}/song.mp3',
      ).writeAsString('song');
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'moveToRecycleBin');
        expect((call.arguments as Map)['path'], song.path);
        throw PlatformException(code: 'trash_failed');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = PlatformFileDeletionService();
      expect(service.movesFilesToRecycleBin, isTrue);
      await expectLater(
        service.deleteFile(song.path),
        throwsA(isA<PlatformException>()),
      );
      expect(await song.readAsString(), 'song');
    },
    skip: !(Platform.isLinux || Platform.isWindows),
  );
}
