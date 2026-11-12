import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:flutter_patcher/src/cli/cli.dart';
import 'package:flutter_patcher/src/cli/core.dart';
import 'package:flutter_patcher/src/cli/build/defines.dart';
import 'package:flutter_patcher/src/cli/build/host_policy.dart';
import 'package:flutter_patcher/src/cli/build/ios.dart';
import 'package:flutter_patcher/src/cli/build/options.dart';
import 'package:flutter_patcher/src/cli/build/pipeline.dart';
import 'package:flutter_patcher/src/cli/baseline/repository.dart';
import 'package:flutter_patcher/src/cli/sdk/artifacts.dart';
import 'package:flutter_patcher/src/cli/sdk/host.dart';

import 'release_fixture.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('build-options-'),
  );
  tearDown(() => root.delete(recursive: true));

  HostPolicy policy(String platform) => HostPolicy({
    'schema': '2',
    'application_id': 'com.example.app',
    'channel': 'production',
    'flavor': 'default',
    'version_code': '42',
    'fptc_key': '-',
    'abi': platform == 'ios' ? 'ios-arm64' : 'arm64-v8a',
    'strategy': 'bytecode',
  });
  BuildRequest request(String platform, FlutterBuildOptions options) =>
      BuildRequest(
        project: root.path,
        output: p.join(root.path, 'out'),
        publicKey: '-',
        hostPolicy: policy(platform),
        versionCode: '42',
        flutterOptions: options,
        exportMethod: options.exportMethod,
      );

  test(
    'build accepts direct verbose aliases and the Flutter argument tail',
    () async {
      for (final arguments in [
        ['build', 'ios', '-v'],
        ['build', '-v', 'android'],
        ['build', 'android', '--verbose'],
        ['build', 'ios', '--', '-v'],
        ['build', 'android', '--', '--verbose'],
      ]) {
        final args = parser().parse(arguments).command!;
        final options = await FlutterBuildOptions.resolve(
          FlutterBuildOptions.fromCommand(args),
          platform: args.rest.first,
        );
        expect(options.verbose, isTrue, reason: '$arguments');
        expect(options.arguments, anyOf(contains('-v'), contains('--verbose')));
        expect(options.receipt['arguments'], isEmpty);
      }
      final quiet = parser().parse(['build', 'android']).command!;
      final options = await FlutterBuildOptions.resolve(
        FlutterBuildOptions.fromCommand(quiet),
        platform: 'android',
      );
      expect(options.verbose, isFalse);
      expect(options.arguments, isEmpty);
    },
  );

  test(
    'direct options and -- tail preserve values with spaces and punctuation',
    () async {
      final plist = File(p.join(root.path, 'Export Options.plist'));
      await plist.writeAsString('<plist/>');
      final args = parser().parse([
        'build',
        'ios',
        '--build-name',
        '2.4.0',
        '--build-number=42',
        '--export-options-plist',
        p.relative(plist.path),
        '--',
        '--no-tree-shake-icons',
        '--verbose',
      ]).command!;
      expect(args.rest.first, 'ios');
      expect(args.arguments, contains('--'));
      final options = await FlutterBuildOptions.resolve(
        FlutterBuildOptions.fromCommand(args),
        platform: 'ios',
      );
      expect(options.arguments, [
        '--build-name',
        '2.4.0',
        '--export-options-plist',
        p.normalize(plist.absolute.path),
        '--no-tree-shake-icons',
        '--verbose',
      ]);
      expect(options.buildNumber, '42');
      expect(options.exportMethod, isNull);
    },
  );

  test(
    'conflicting or unsafe build inputs fail before running Flutter',
    () async {
      final plist = File(p.join(root.path, 'export.plist'));
      await plist.writeAsString('<plist/>');
      for (final input in [
        ['--export-options-plist', plist.path, '--export-method', 'ad-hoc'],
        ['--export-options-plist', p.join(root.path, 'missing')],
        ['--build-number=4', '--build-number=5'],
        ['--build-name'],
        ['--target=lib/other.dart'],
        ['-tlib/other.dart'],
        ['--debug'],
        ['--target-platform=android-x64'],
        ['--split-per-abi'],
        ['--obfuscate'],
        ['--extra-front-end-options=--no-tfa'],
        ['--no-pub'],
        ['--dart-define=A=1'],
        ['-DA=1'],
        ['--dart-define-from-file=config.json'],
      ]) {
        await expectLater(
          FlutterBuildOptions.resolve(input, platform: 'ios'),
          throwsA(isA<Failure>()),
          reason: '$input',
        );
      }
      await expectLater(
        FlutterBuildOptions.resolve([
          '--export-options-plist',
          plist.path,
        ], platform: 'android'),
        throwsA(isA<Failure>()),
      );
      expect(
        await runCli([
          'build',
          'android',
          '--version-code',
          '2',
          '--build-number',
          '3',
        ]),
        2,
      );
    },
  );

  test(
    'both native builds receive forwarded options with the generated entry',
    () async {
      final args = parser().parse([
        'build',
        'android',
        '--build-name=2.4.0',
        '--no-tree-shake-icons',
        '-v',
      ]).command!;
      final options = await FlutterBuildOptions.resolve(
        FlutterBuildOptions.fromCommand(args),
        platform: 'android',
      );
      final calls = <List<String>>[];
      Future<String> run(
        String executable,
        List<String> args, {
        String? cwd,
        Map<String, String>? env,
      }) async {
        calls.add(args);
        expect(cwd, root.path);
        if (args.contains('ipa')) {
          final output = File(p.join(root.path, 'build/ios/ipa/app.ipa'));
          await output.parent.create(recursive: true);
          await output.writeAsString('fixture');
        }
        return '';
      }

      final sdk = SdkIdentity(
        '/sdk',
        '3.47.0',
        'a' * 40,
        '3.13.0',
        'b' * 40,
        host: const HostIdentity('macos', 'arm64'),
      );
      final pipeline = BuildPipeline(
        Commands(root.path),
        sdk,
        '/managed',
        '/tool',
        p.join(root.path, 'cache'),
        '/aapt',
        {'build_id': 'fixture'},
        BaselineRepository(p.join(root.path, 'baselines'), null),
        const {},
      );
      await pipeline.assembleApk(
        run,
        root.path,
        request('android', options),
        'generated/main.dart',
        ['--extra-gen-snapshot-options=trace'],
      );
      await assembleIpa(
        run,
        '/managed/flutter',
        root.path,
        request('ios', options),
        'generated/main.dart',
        [],
      );
      for (final call in calls) {
        expect(
          call,
          containsAllInOrder([
            '--target',
            'generated/main.dart',
            '--build-number',
            '42',
            ...options.arguments,
          ]),
        );
        expect(call.where((v) => v == '--target').length, 1);
        expect(call, contains('--verbose'));
      }
    },
  );

  test(
    'IPA export plist keeps its path across the isolated build directory',
    () async {
      final plist = File(p.join(root.path, 'Export Options.plist'));
      await plist.writeAsString('<plist/>');
      final options = await FlutterBuildOptions.resolve([
        '--export-options-plist',
        p.relative(plist.path),
      ], platform: 'ios');
      final copy = p.join(root.path, 'copy');
      final ipa = await assembleIpa(
        (executable, args, {cwd, env}) async {
          expect(
            args[args.indexOf('--export-options-plist') + 1],
            plist.absolute.path,
          );
          expect(args, isNot(contains('--export-method')));
          final output = File(p.join(copy, 'build/ios/ipa/export.ipa'));
          await output.parent.create(recursive: true);
          await output.writeAsString('fixture');
          return '';
        },
        '/flutter',
        copy,
        request('ios', options),
        'generated.dart',
        [],
      );
      expect(File(ipa).existsSync(), isTrue);
    },
  );

  test(
    'baseline version constants and SO replay exclude local output paths',
    () async {
      final options = await FlutterBuildOptions.resolve([
        '--build-name',
        '2.4.0',
        '--split-debug-info',
        'symbols with spaces',
        '--no-tree-shake-icons',
      ], platform: 'android');
      final settings = request(
        'android',
        options,
      ).settings({'version': '1.0.0+1'});
      final replay = FlutterBuildOptions.recorded(settings);
      expect(replay.arguments, [
        '--build-name',
        '2.4.0',
        '--no-tree-shake-icons',
      ]);
      expect(recordedReleaseDefines({'flutter_build': settings}, 'default'), {
        'FLUTTER_BUILD_NAME': '2.4.0',
        'FLUTTER_BUILD_NUMBER': '42',
        'dart.vm.product': 'true',
        'dart.vm.profile': 'false',
      });
      expect(recordedReleaseDefines({}, 'default'), releaseDefines('default'));
      final defaults = request(
        'android',
        const FlutterBuildOptions(),
      ).settings({'version': '3.0.0+40'});
      expect(defaults['build_name'], '3.0.0');
      expect(
        (defaults['environment_defines'] as Map)['FLUTTER_BUILD_NUMBER'],
        '42',
      );
    },
  );

  test(
    'release archives retain optional build and resource capabilities',
    () async {
      final fixture = ReleaseFixture();
      await fixture.setUp();
      addTearDown(fixture.tearDown);
      final metadata = await fixture.policyBuild();
      final file = p.join(fixture.input, 'build_receipt.json');
      final receipt = await readObject(file);
      final settings = request(
        'android',
        const FlutterBuildOptions(),
      ).settings({'version': '3.0.0+42'});
      await writeObject(file, {
        ...receipt,
        'flutter_build': settings,
        'resource_patches': 1,
      });
      await fixture.save('42', metadata: metadata);
      final release = await fixture.repository.resolve('prod', '42');
      expect(release.receipt['flutter_build'], settings);
      expect(release.receipt['resource_patches'], 1);
    },
  );
}
