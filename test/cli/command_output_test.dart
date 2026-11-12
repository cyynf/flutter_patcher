import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/core.dart';

import 'host_tools.dart';

void main() {
  test('verbose streams both output channels before exit, preserving captured output and logs', () async {
    final root = await Directory.systemTemp.createTemp('verbose-output-');
    addTearDown(() => root.delete(recursive: true));
    final emitter = File(p.join(root.path, 'emitter.dart'));
    await emitter.writeAsString(r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  stdout.writeln('live stdout ✓');
  await stdout.flush();
  stderr.writeln('live stderr ✓');
  await stderr.flush();
  while (!await File(args.single).exists()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
''');
    final wrapper = File(p.join(root.path, 'wrapper.dart'));
    await wrapper.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
import 'package:flutter_patcher/src/cli/core.dart';
Future<void> main(List<String> args) async {
  final result = await Commands(args[0], verbose: args[3] == 'verbose').runResult(
    Platform.resolvedExecutable, [args[1], args[2]],
    logPath: '${args[0]}/step.log', timeout: const Duration(seconds: 10),
  );
  stdout.writeln(jsonEncode({'out': result.stdout, 'err': result.stderr, 'exit': result.exitCode}));
}
''');
    for (final verbose in [true, false]) {
      final ready = Completer<void>();
      final release = File(
        p.join(root.path, 'release-${verbose ? 'verbose' : 'quiet'}'),
      );
      if (!verbose) {
        await release.writeAsString('ready');
      }
      final process = await Process.start(dartVm, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        wrapper.path,
        root.path,
        emitter.path,
        release.path,
        verbose ? 'verbose' : 'quiet',
      ]);
      final captured = process.stdout.transform(utf8.decoder).join();
      final messages = StringBuffer();
      final diagnostics = process.stderr.transform(utf8.decoder).map((text) {
        messages.write(text);
        if (!ready.isCompleted &&
            messages.toString().contains('live stdout ✓') &&
            messages.toString().contains('live stderr ✓')) {
          ready.complete();
        }
        return text;
      }).join();
      try {
        if (verbose) {
          // The emitter cannot exit until the parent sees its live output.
          await ready.future.timeout(const Duration(seconds: 10));
          await release.writeAsString('ready');
        }
        expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
        final result = jsonDecode(await captured) as Map;
        expect(result, {
          'out': 'live stdout ✓\n',
          'err': 'live stderr ✓\n',
          'exit': 0,
        });
        final diagnostic = await diagnostics;
        expect(diagnostic, verbose ? contains('[flutter_patcher]') : isEmpty);
        final log = await File(p.join(root.path, 'step.log')).readAsString();
        expect(
          log,
          allOf(contains('live stdout ✓'), contains('live stderr ✓')),
        );
      } finally {
        await release.writeAsString('ready');
        process.kill();
      }
    }
  });
  test(
    'tool output that is not UTF-8 is decoded instead of aborting',
    () async {
      expect(await collectOutput(Stream.value(utf8.encode('ok ✓'))), 'ok ✓');
      // "你好" in GBK, as Windows prints its own errors on a Chinese system.
      final text = await collectOutput(
        Stream.fromIterable([
          [0xc4, 0xe3],
          [0xba, 0xc3],
        ]),
      );
      expect(text, isNotEmpty);
    },
  );

  test(
    'a batch launcher under a spaced path receives spaced arguments',
    () async {
      final root = (await Directory.systemTemp.createTemp('launcher ')).path;
      final launcher = p.join(root, 'tool dir', 'echo.bat');
      await File(launcher).create(recursive: true);
      await File(launcher).writeAsString('@echo off\r\necho [%~1][%~2]\r\n');
      final result = await Commands(root)
          .runResult(launcher, [p.join(root, 'a b'), 'plain']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout.trim(), '[${p.join(root, 'a b')}][plain]');
    },
    skip: Platform.isWindows ? null : 'Batch launchers exist only on Windows',
  );
}
