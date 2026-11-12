import 'dart:convert';
import 'dart:io';

import 'package:flutter_patcher/src/cli/patch/hooks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'bundle filters flavor/platform selectors without losing transformers',
    () {
      final spec = <String, dynamic>{
        'flutter': {
          'assets': [
            'common.txt',
            {
              'path': 'paid/',
              'flavors': ['paid'],
            },
            {
              'path': 'free/',
              'flavors': ['free'],
            },
            {
              'path': 'ios.png',
              'platforms': ['ios'],
              'transformers': [
                {'package': 'images'},
              ],
            },
            {
              'path': 'android.png',
              'platforms': ['android'],
            },
          ],
          'shaders': [
            {
              'path': 'paid.frag',
              'flavors': ['paid'],
            },
          ],
          'deferred-components': [
            {
              'name': 'feature',
              'assets': [
                {
                  'path': 'feature.txt',
                  'flavors': ['paid'],
                },
              ],
            },
          ],
        },
      };
      expect(selectBundleResources(spec, 'paid', 'ios'), isTrue);
      final flutter = spec['flutter'] as Map;
      expect(flutter['assets'], [
        'common.txt',
        {'path': 'paid/'},
        {
          'path': 'ios.png',
          'transformers': [
            {'package': 'images'},
          ],
        },
      ]);
      expect(flutter['shaders'], [
        {'path': 'paid.frag'},
      ]);
      expect((flutter['deferred-components'] as List).single['assets'], [
        {'path': 'feature.txt'},
      ]);
      expect(selectBundleResources(spec, 'paid', 'ios'), isFalse);
    },
  );

  test('dependency resource selectors are applied to a copy of its pubspec', () async {
    final temp = await Directory.systemTemp.createTemp('bundle-dependency-');
    addTearDown(() => temp.delete(recursive: true));
    final spec = File(p.join(temp.path, 'dep/pubspec.yaml'));
    await spec.parent.create(recursive: true);
    const original =
        'name: dep\nflutter:\n  assets:\n    - path: ios.png\n      platforms: [ios]\n';
    await spec.writeAsString(original);
    final config = p.join(temp.path, 'package_config.json');
    await File(config).writeAsString(
      jsonEncode({
        'packages': [
          {'name': 'dep', 'rootUri': 'dep/', 'packageUri': 'lib/'},
        ],
      }),
    );
    final before = await File(config).readAsString();
    await withoutBuildHooks(
      config,
      p.join(temp.path, 'shadow'),
      () async {
        final rows =
            jsonDecode(await File(config).readAsString())['packages'] as List;
        final copy = File.fromUri(
          Uri.parse(rows.single['rootUri'] as String).resolve('pubspec.yaml'),
        );
        expect(copy.path, isNot(spec.path));
        expect(jsonDecode(await copy.readAsString())['flutter']['assets'], [
          {'path': 'ios.png'},
        ]);
      },
      flavor: 'default',
      platform: 'ios',
    );
    expect(await File(config).readAsString(), before);
    expect(await spec.readAsString(), original);
  });

  test('bundle uses the release version/flavor and restores pubspec on failure', () async {
    final temp = await Directory.systemTemp.createTemp('bundle-metadata-');
    addTearDown(() => temp.delete(recursive: true));
    final spec = File(p.join(temp.path, 'pubspec.yaml'));
    const original =
        'name: app\nversion: 9.0.0+90\nflutter:\n  default-flavor: other\n  assets: [a.png]\n';
    await spec.writeAsString(original);
    for (final flavor in ['paid', 'default']) {
      await expectLater(
        withBundleMetadata(
          temp.path,
          flavor: flavor,
          platform: 'android',
          buildName: '2.0.0',
          buildNumber: 42,
          action: () async {
            final value = jsonDecode(await spec.readAsString()) as Map;
            expect(value['version'], '2.0.0+42');
            expect(
              value['flutter']['default-flavor'],
              flavor == 'default' ? null : flavor,
            );
            expect(value['flutter']['assets'], ['a.png']);
            throw StateError('build failed');
          },
        ),
        throwsStateError,
      );
      expect(await spec.readAsString(), original);
    }
  });
  test(
    'the bundle step sees hook packages without hook/, then the real config',
    () async {
      final temp = await Directory.systemTemp.createTemp('hooks-');
      addTearDown(() => temp.delete(recursive: true));
      Future<void> write(String path, String text) async =>
          File(p.join(temp.path, path))
              .create(recursive: true)
              .then((f) => f.writeAsString(text));
      await write('pub/native/lib/native.dart', 'void f() {}');
      await write('pub/native/hook/build.dart', 'void main() {}');
      await write('pub/plain/lib/plain.dart', 'void g() {}');
      final config = p.join(temp.path, 'app/.dart_tool/package_config.json');
      final text = jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'native',
            'rootUri': '../../pub/native',
            'packageUri': 'lib/',
          },
          {
            'name': 'plain',
            'rootUri': '../../pub/plain/',
            'packageUri': 'lib/',
          },
        ],
      });
      await write('app/.dart_tool/package_config.json', text);
      final seen = await withoutBuildHooks(
        config,
        p.join(temp.path, 'shadow'),
        () async {
          final rows = {
            for (final row
                in (jsonDecode(await File(config).readAsString())['packages']
                    as List))
              row['name']: Uri.parse(row['rootUri'] as String),
          };
          final native = Directory.fromUri(rows['native']!);
          return [
            await File(p.join(native.path, 'lib/native.dart')).exists(),
            await Directory(p.join(native.path, 'hook')).exists(),
            rows['plain'].toString(),
          ];
        },
      );
      expect(seen, [true, false, '../../pub/plain/']);
      expect(await File(config).readAsString(), text);
    },
  );
}
