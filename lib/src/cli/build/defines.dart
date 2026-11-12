import '../core.dart';

/// Compile-time environment of a Flutter release build: flutter_tools'
/// release `buildModeOptions` plus its flavor define. Baseline and patch
/// kernels must use exactly these, or `kReleaseMode`, `kDebugMode`,
/// `appFlavor` and other `fromEnvironment` constants in patched code differ
/// from the host's (without them a patch saw kReleaseMode == false).
Map<String, String> releaseDefines(
  String? flavor, {
  String? buildName,
  String? buildNumber,
}) => {
  'FLUTTER_BUILD_NAME': ?buildName,
  'FLUTTER_BUILD_NUMBER': ?buildNumber,
  'dart.vm.profile': 'false',
  'dart.vm.product': 'true',
  if (flavor != null && flavor != 'default') 'FLUTTER_APP_FLAVOR': flavor,
};

List<String> defineArgs(Map<String, String> defines) => [
  for (final e in defines.entries) '-D${e.key}=${e.value}',
];

/// Patches use the host's version constants even when pubspec has moved on.
Map<String, String> recordedReleaseDefines(Map receipt, String? flavor) {
  final settings = receipt['flutter_build'];
  final values = settings is Map ? settings['environment_defines'] : null;
  if (values == null) return releaseDefines(flavor);
  require(
    values is Map &&
        values.entries.every((e) => e.key is String && e.value is String),
    'PATCH_BASELINE_INCOMPATIBLE',
    'Invalid recorded compile-time environment.',
  );
  return Map<String, String>.from(values as Map);
}
