import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../core.dart';

/// build bundle currently drops Flavor and treats asset platforms as Android.
/// Filter declarations in a private pubspec copy before calling it, retaining
/// directory entries and transformer configuration for Flutter to process.
bool selectBundleResources(
  Map<String, dynamic> spec,
  String flavor,
  String platform,
) {
  final original = spec['flutter'];
  if (original is! Map) return false;
  final flutter = Map<String, dynamic>.from(original);
  spec['flutter'] = flutter;
  var changed = false;
  void filter(Map<String, dynamic> section, String key) {
    final entries = section[key];
    if (entries is! List) return;
    final selected = <dynamic>[];
    for (final entry in entries) {
      if (entry is! Map ||
          (!entry.containsKey('flavors') && !entry.containsKey('platforms'))) {
        selected.add(entry);
        continue;
      }
      changed = true;
      bool matches(String key, String selected) {
        final values = entry[key];
        require(
          values == null ||
              values is List && values.every((value) => value is String),
          'PATCH_ASSET_INVALID',
          'Invalid $key asset selector',
        );
        return values == null ||
            (values as List).isEmpty ||
            values.contains(selected);
      }

      if (matches('flavors', flavor == 'default' ? '' : flavor) &&
          matches('platforms', platform)) {
        selected.add(
          {...entry}
            ..remove('flavors')
            ..remove('platforms'),
        );
      }
    }
    section[key] = selected;
  }

  filter(flutter, 'assets');
  filter(flutter, 'shaders');
  if (flutter['deferred-components'] case final List components) {
    flutter['deferred-components'] = [
      for (final component in components)
        if (component is Map)
          Map<String, dynamic>.from(component)
        else
          component,
    ];
    for (final component in flutter['deferred-components'] as List) {
      if (component is Map<String, dynamic>) filter(component, 'assets');
    }
  }
  return changed;
}

/// Flutter's bundle command has no --flavor/--build-name options. Set their
/// pubspec equivalents only in the isolated copy for this resource build.
Future<T> withBundleMetadata<T>(
  String project, {
  required String flavor,
  required String platform,
  required int buildNumber,
  String? buildName,
  required Future<T> Function() action,
}) async {
  final file = File(p.join(project, 'pubspec.yaml'));
  final original = await file.readAsString();
  final spec =
      jsonDecode(jsonEncode(loadYaml(original))) as Map<String, dynamic>;
  final flutter = Map<String, dynamic>.from(
    spec['flutter'] as Map? ?? const {},
  );
  if (flavor == 'default') {
    flutter.remove('default-flavor');
  } else {
    flutter['default-flavor'] = flavor;
  }
  spec['flutter'] = flutter;
  selectBundleResources(spec, flavor, platform);
  final name = buildName ?? '${spec['version'] ?? '1.0.0'}'.split('+').first;
  spec['version'] = '$name+$buildNumber';
  await file.writeAsString(jsonEncode(spec));
  try {
    return await action();
  } finally {
    await file.writeAsString(original);
  }
}

/// Runs [action] (the patch's `flutter build bundle`) with every package that
/// has build hooks replaced by a copy without its `hook/` directory.
///
/// Flutter runs a package's hooks whenever `hook/build.dart` exists, and the
/// hooks need the target toolchain (xcrun, the NDK) that a developer host may
/// lack. Their output is native code, which a patch never carries: `hook/` is
/// a native input, so it matches the host's. Every host takes this path, so
/// the bundle step behaves the same on Linux, macOS and Windows.
Future<T> withoutBuildHooks<T>(
  String packageConfig,
  String shadowRoot,
  Future<T> Function() action, {
  String? flavor,
  String? platform,
}) async {
  final file = File(packageConfig);
  final original = await file.readAsBytes();
  final config = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
  final base = file.parent.uri;
  var changed = false;
  for (final row in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    final root = base.resolve(
      (row['rootUri'] as String).endsWith('/')
          ? row['rootUri'] as String
          : '${row['rootUri']}/',
    );
    final hook = Directory.fromUri(root.resolve('hook/'));
    final specFile = File.fromUri(root.resolve('pubspec.yaml'));
    Map<String, dynamic>? selectedSpec;
    if (flavor != null && platform != null && await specFile.exists()) {
      final spec = jsonDecode(
        jsonEncode(loadYaml(await specFile.readAsString())),
      ) as Map<String, dynamic>;
      if (selectBundleResources(spec, flavor, platform)) selectedSpec = spec;
    }
    if (!await hook.exists() && selectedSpec == null) continue;
    final shadow = Directory(p.join(shadowRoot, row['name'] as String));
    require(
      !await shadow.exists(),
      'PATCH_SOURCE_INVALID',
      'Duplicate package ${row['name']}',
    );
    await _copyWithoutHooks(Directory.fromUri(root), shadow, hook.path);
    if (selectedSpec != null) {
      await File(p.join(shadow.path, 'pubspec.yaml'))
          .writeAsString(jsonEncode(selectedSpec));
    }
    row['rootUri'] = shadow.uri.toString();
    changed = true;
  }
  if (!changed) return action();
  await file.writeAsString(jsonEncode(config));
  try {
    return await action();
  } finally {
    await file.writeAsBytes(original);
  }
}

Future<void> _copyWithoutHooks(
  Directory from,
  Directory to,
  String hook,
) async {
  await to.create(recursive: true);
  await for (final entry in from.list(followLinks: false)) {
    if (p.equals(entry.path, hook) || p.basename(entry.path) == '.dart_tool') {
      continue;
    }
    final target = p.join(to.path, p.basename(entry.path));
    if (entry is Directory) {
      await _copyWithoutHooks(entry, Directory(target), hook);
    } else if (entry is File) {
      await entry.copy(target);
    } else {
      throw Failure(
        'PATCH_SOURCE_INVALID',
        'Package contains a link: ${entry.path}',
      );
    }
  }
}
