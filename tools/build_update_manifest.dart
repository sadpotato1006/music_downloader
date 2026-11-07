import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Run after building both packages; additive fields remain compatible with
/// existing Windows clients reading schemaVersion 1.
Future<void> main(List<String> arguments) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final pubspec = await File(p.join(root.path, 'pubspec.yaml')).readAsString();
  final match = RegExp(
    r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec)!;
  final version = match.group(1)!;
  final build = match.group(2)!;
  final output = arguments.isEmpty
      ? Directory(p.join(root.path, 'dist', 'v$version'))
      : Directory(arguments.single);
  final manifest = <String, Object>{
    'schemaVersion': 1,
    'version': '$version+$build',
  };
  for (final entry in {
    'windows-x64': 'QingTingSetup-v${version.replaceAll('.', '_')}.exe',
    'android': 'QingTing-v$version-build$build.apk',
  }.entries) {
    final file = File(p.join(output.path, entry.value));
    manifest[entry.key] = {
      'installer': entry.value,
      'size': await file.length(),
      'sha256': (await sha256.bind(file.openRead()).first).toString(),
    };
  }
  final target = File(p.join(output.path, 'qingting-update.json'));
  await target.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    flush: true,
  );
  stdout.writeln('Created ${target.path} for $version+$build');
}
