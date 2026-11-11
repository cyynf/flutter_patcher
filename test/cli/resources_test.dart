import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_patcher/src/cli/baseline/resources.dart';
import 'package:flutter_patcher/src/cli/patch/package.dart';
import 'package:flutter_patcher/src/cli/core.dart';

void main() {
  test(
    'manifest codec roundtrip with image variants and rejects bad input',
    () {
      final data = {
        'a': [
          {'asset': 'a'},
          {'asset': '2.0x/a', 'dpr': 2.0},
        ],
      };
      expect(AssetCodec.decode(AssetCodec.encode(data)), data);
      expect(() => AssetCodec.decode([13, 1, 7]), throwsA(isA<Failure>()));
      expect(
        () => AssetCodec.decode([...AssetCodec.encode(data), 0]),
        throwsA(isA<Failure>()),
      );
      for (final key in ['../a', '/a', 'a\\b', 'a//b', 'C:x', 'a/./b']) {
        expect(() => assetKey(key), throwsA(isA<Failure>()));
      }
    },
  );
  test('both code strategies ship exactly code and manifest', () async {
    final temporary = await Directory.systemTemp.createTemp('code-package-');
    final dir = Directory(await temporary.resolveSymbolicLinks());
    addTearDown(() => dir.delete(recursive: true));
    final code = File(p.join(dir.path, 'code'));
    await code.writeAsBytes([1, 2, 3]);
    for (final kind in codePaths.keys) {
      final draft = await packPatch(
        kind: kind,
        code: code.path,
        metadata: {'fingerprint': 'a' * 64, 'module_id': 1},
      );
      final archive = ZipDecoder().decodeBytes(draft.payload);
      expect(archive.map((f) => f.name), [
        codePaths[kind],
        'patch_manifest.json',
      ]);
      expect(draft.manifest['assets'], isEmpty);
      expect(draft.manifest['fonts'], isEmpty);
      await draft.write(dir.path);
      expect((await PatchDraft.read(dir.path)).digest, draft.digest);
      for (final key in ['assets', 'fonts']) {
        final manifest = {
          ...draft.manifest,
          key: [
            {'path': '$key/a'},
          ],
        };
        await File(p.join(dir.path, PatchDraft.file)).writeAsBytes(
          plainZip({
            codePaths[kind]!: [1, 2, 3],
            'patch_manifest.json': utf8.encode(jsonEncode(manifest)),
            '$key/a': [4],
          }),
        );
        await expectLater(PatchDraft.read(dir.path), throwsA(isA<Failure>()));
      }
    }
  });
}
