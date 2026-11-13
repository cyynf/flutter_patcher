import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core.dart';
import '../baseline/manifest.dart';
import '../baseline/resources.dart';
import '../sdk/host.dart';

export '../baseline/resources.dart' show assetKey, AssetCodec, resourceReceipt;

const assetOverlay = 'asset_overlay';
const isolateEntry = 'isolate_entry';

/// This fork records resource support explicitly. Upstream 1.1.1 supports
/// it too but records only build_inputs. The intermediate code-only fork
/// predates that record and must still rebuild before receiving resources.
bool supportsResourcePatches(Map receipt) =>
    receipt['resource_patches'] == 1 ||
    (!receipt.containsKey('resource_patches') &&
        !receipt.containsKey('flutter_build') &&
        receipt['build_inputs'] is Map);

Future<List<String>> readObjectFontSources(String bundle) async {
  final file = File(p.join(bundle, 'FontManifest.json'));
  if (!await file.exists()) return [];
  final rows = jsonDecode(await file.readAsString()) as List;
  return [
    for (final row in rows)
      if (row['family'] != 'MaterialIcons')
        for (final font in row['fonts'] as List) font['asset'] as String,
  ];
}

class PatchResources {
  PatchResources(this.bundle, this.work, this.commands, this.sdk);
  final String bundle, work, sdk;
  final Commands commands;
  final Map<String, List<int>> entries = {};
  final List<Map<String, dynamic>> assets = [], fonts = [];

  /// Release asset keys (or image variants) the current bundle lacks.
  final List<String> deleted = [];

  Future<List<int>> read(String key) async {
    assetKey(key);
    final file = File(p.join(bundle, key));
    await rejectLinks(file.path);
    require(
      await file.exists() && await file.length() <= 64 * 1024 * 1024,
      'PATCH_ASSET_INVALID',
      'Missing or oversized resource: $key',
    );
    return file.readAsBytes();
  }

  void addAsset(String key, List<int> bytes) {
    assetKey(key);
    final path = 'assets/$key';
    require(
      !entries.containsKey(path),
      'PATCH_ASSET_INVALID',
      'Duplicate resource: $key',
    );
    entries[path] = bytes;
    assets.add({
      'key': key,
      'path': path,
      'length': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }

  Future<void> collect(
    Map<String, dynamic> baseline,
    List<String> requested,
  ) async {
    require(
      baseline['schema'] == 1 &&
          baseline['files'] is Map &&
          baseline['manifest'] is Map,
      'PATCH_BASELINE_INCOMPATIBLE',
      'Baseline lacks resource inventory; rebuild host',
    );
    final old = Map<String, dynamic>.from(baseline['manifest'] as Map);
    final current = AssetCodec.decode(await read('AssetManifest.bin'));
    Set<String> variants(Map<String, dynamic> manifest, String key) {
      final rows = manifest[key];
      require(
        rows is List,
        'PATCH_ASSET_INVALID',
        'Asset is not declared: $key',
      );
      return {key, for (final row in rows as List) row['asset'] as String};
    }

    // Overlays cannot delete a resource or an image variant from the host;
    // the rules reject such a patch.
    for (final key in old.keys) {
      if (!current.containsKey(key) ||
          !variants(current, key).containsAll(variants(old, key))) {
        deleted.add(key);
      }
    }
    final selected = <String>{};
    require(
      requested.toSet().length == requested.length,
      'PATCH_ASSET_INVALID',
      'Duplicate --assets key',
    );
    for (final key in requested) {
      assetKey(key);
      variants(current, key);
      selected.add(key);
    }
    if (requested.isEmpty) {
      for (final key in current.keys) {
        for (final variant in variants(current, key)) {
          final bytes = await read(variant);
          if ((baseline['files'] as Map)[variant]?['sha256'] !=
              sha256.convert(bytes).toString()) {
            selected.add(key);
          }
        }
        if (canonical(old[key]) != canonical(current[key])) selected.add(key);
      }
    }
    final keys = {for (final k in selected) ...variants(current, k)}.toList()
      ..sort();
    for (final key in keys) {
      addAsset(key, await read(key));
    }
    if (selected.isNotEmpty) {
      final merged = {...old, for (final key in selected) key: current[key]};
      addAsset('AssetManifest.bin', AssetCodec.encode(merged));
    }
  }

  /// Fonts the patch must carry. [hostIcons] (lean tier) are the icons the
  /// host program references: the host ships its icon font tree-shaken to
  /// them, and a patch font replaces the whole family, so a subset keeps them
  /// too, and none ships when the host's already covers the module. A font
  /// whose bytes equal the host's ([hostFiles], the resource inventory) is
  /// already loaded by the host and is not carried.
  ///
  /// With [wholeFamilies] (an SO patch, whose bundle was built with its own
  /// code and already subsets the icon font to it) every font file whose
  /// bytes differ from the host's ships as built.
  Future<void> collectFonts(
    List<dynamic> icons, {
    List<dynamic>? hostIcons,
    Map<dynamic, dynamic> hostFiles = const {},
    List<dynamic>? hostFonts,
    bool wholeFamilies = false,
  }) async {
    final fontFile = File(p.join(bundle, 'FontManifest.json'));
    final definitions = await fontFile.exists()
        ? jsonDecode(await fontFile.readAsString()) as List
        : <dynamic>[];
    final groups = <String, Set<int>>{};
    final fallbackFamilies = <String>{};
    for (final raw in icons) {
      final family = raw['fontFamily'],
          package = raw['fontPackage'],
          point = raw['codePoint'];
      require(
        (family == null || family is String) &&
            point is int &&
            point >= 0 &&
            point <= 0x10ffff,
        'FONT_SUBSET_FAILED',
        'IconData must identify a valid code point',
      );
      for (final fallback in raw['fontFamilyFallback'] as List? ?? []) {
        fallbackFamilies.add(
          package == null ? fallback as String : 'packages/$package/$fallback',
        );
      }
      // Icon builds a non-inheriting TextStyle. A null family uses system
      // fallback (e.g. Flutter's U+1F74A debug icon), not a bundled icon font.
      if (family == null) continue;
      final name = package == null
          ? family as String
          : 'packages/$package/$family';
      groups.putIfAbsent(name, () => {}).add(point as int);
    }
    final hostGroups = <String, Set<int>>{};
    for (final raw in hostIcons ?? const []) {
      final family = raw['fontFamily'], package = raw['fontPackage'];
      if (family is! String || raw['codePoint'] is! int) continue;
      hostGroups
          .putIfAbsent(
            package == null ? family : 'packages/$package/$family',
            () => {},
          )
          .add(raw['codePoint'] as int);
    }
    final oldFamilies = {
      for (final row in hostFonts ?? const []) row['family']: row,
    };
    final found = <String>{};
    for (final definition in definitions) {
      final family = definition['family'] as String,
          sources = definition['fonts'] as List;
      // Only the SDK's dedicated Material icon face is known to be icon-only.
      // Custom/package families may also be used by Text and must remain whole.
      final points =
          wholeFamilies ||
              fallbackFamilies.contains(family) ||
              family != 'MaterialIcons' ||
              sources.length != 1 ||
              sources.single['asset'] != 'fonts/MaterialIcons-Regular.otf'
          ? null
          : groups[family];
      // Framework material font is needed only when referenced. Text fonts are
      // carried whole because IconData does not describe their glyph usage.
      if (!wholeFamilies &&
          family == 'MaterialIcons' &&
          !groups.containsKey(family) &&
          !fallbackFamilies.contains(family)) {
        continue;
      }
      found.add(family);
      require(
        points == null || sources.length == 1,
        'FONT_SUBSET_FAILED',
        'Ambiguous icon font family: $family',
      );
      final shipped = hostGroups[family];
      if (points != null && hostIcons != null) {
        if (shipped != null && shipped.containsAll(points)) continue;
        points.addAll(shipped ?? const <int>{});
      }
      final faces = [
        for (final source in sources) await read(source['asset'] as String),
      ];
      final definitionChanged =
          hostFonts != null &&
          canonical(oldFamilies[family]) != canonical(definition);
      final bytesChanged = [
        for (var i = 0; i < sources.length; i++)
          sha256.convert(faces[i]).toString() !=
              hostFiles[sources[i]['asset']]?['sha256'],
      ].any((changed) => changed);
      if (points == null && !definitionChanged && !bytesChanged) continue;
      // Register a changed family atomically with every face; dropping an
      // unchanged weight/style would replace the host family incompletely.
      for (var i = 0; i < sources.length; i++) {
        final source = sources[i]['asset'] as String;
        var bytes = faces[i];
        if (points != null) {
          final output = p.join(work, 'font-${fonts.length}.otf');
          final host = HostIdentity.current();
          final binary = p.join(sdk, host.toolchain(host.exe('font-subset')));
          require(
            await File(binary).exists(),
            'FONT_SUBSET_FAILED',
            'SDK font-subset is missing',
          );
          await commands.run(
            binary,
            [output, p.join(bundle, source)],
            inputBytes: utf8.encode((points.toList()..sort()).join(' ')),
            code: 'FONT_SUBSET_FAILED',
          );
          require(
            await File(output).exists() && await File(output).length() > 0,
            'FONT_SUBSET_FAILED',
            'font-subset produced no font',
          );
          bytes = await File(output).readAsBytes();
        }
        final path =
            'fonts/${sha256.convert(utf8.encode('$family/$i')).toString()}.otf';
        entries[path] = bytes;
        fonts.add({
          'family': family,
          'path': path,
          'length': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          if (points != null) 'codepoints': points.length,
          'subset': points != null,
        });
      }
    }
    require(
      found.containsAll(groups.keys),
      'FONT_SUBSET_FAILED',
      'Referenced font is absent from Flutter bundle',
    );
  }
}
