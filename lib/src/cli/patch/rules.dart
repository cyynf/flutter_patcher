import '../core.dart';
import 'scan.dart';

/// Engine support for booting background isolates through the patch entry.
const isolateEntry = 'isolate_entry';

/// When a rule's facts are known. The pipeline checks each stage as soon as it
/// reaches it, so a rejection never waits for a later, slower step.
enum PatchStage {
  /// Sources and dependencies compared with the release.
  inputs,

  /// The compiled module.
  compile,

  /// The code the patch ships.
  code,

  /// Entry points that run in background isolates.
  background,

  /// The whole patch.
  result,
}

/// What the pipeline has learned about a patch; rules read it.
class PatchFacts {
  PatchFacts(this.strategy, this.platform, this.evidence);
  final String strategy, platform;

  /// Work directory, quoted in messages as evidence.
  final String evidence;

  /// The application's own native files changed since the release.
  bool appNativeChanged = false;

  /// When every change to them is only CRLF against LF: those files.
  List<String> lineEndingChanges = const [];

  /// Dependencies whose native capability or native files changed.
  final List<String> nativeDependencies = [];

  /// Plugins whose Dart sources changed (bytecode).
  final List<String> changedPlugins = [];

  /// Packages pinned since the release that it did not pin (bytecode).
  final List<String> newlyPinned = [];

  /// Changed pinned packages: name -> why pinned, and the release's version.
  final Map<String, ({String why, Object? version})> changedPinned = {};

  /// The tools report of the module just compiled, or of the final one.
  Map<String, dynamic>? report;

  /// `lean` or `whole` (bytecode).
  String? tier;

  /// What the host's engine offers (its release's capabilities).
  List<String> engineCapabilities = const [];

  /// Everything the patch changes; empty means there is nothing to ship.
  final List<String> changed = [];

  /// Whether the patch changes Dart code, its own or a dependency's.
  bool get codeChanged => changed.any(
    (c) =>
        c.startsWith('package:') ||
        c.startsWith('dependency:') ||
        c == 'libapp.so',
  );

  /// Own entry points native code may start in a separate engine, and the
  /// calls that register them.
  List<(String, SourceSite)> backgroundEntries = const [];
  List<SourceSite> backgroundRegistrations = const [];
}

String _list(Iterable<String> items, {int limit = 5}) {
  final all = items.toList();
  final more = all.length > limit ? ' (+${all.length - limit} more)' : '';
  return '${all.take(limit).join(', ')}$more';
}

/// The library URI of the file at [site].
String _library(SourceSite site) =>
    'package:${site.package}/${site.file.replaceFirst(RegExp('^lib/'), '')}';

class PatchRule {
  const PatchRule(
    this.code,
    this.stage,
    this.findings, {
    this.strategies = const {'bytecode', 'so'},
    this.reject = true,
  });

  /// The failure code a rejection carries, or the code of a warning.
  final String code;
  final PatchStage stage;
  final Set<String> strategies;

  /// False for a warning: the patch ships, and the report says why to look.
  final bool reject;

  /// One message per finding.
  final List<String> Function(PatchFacts facts) findings;
}

/// Every boundary a patch is held to. A rule here is the only place its
/// condition is decided; producers only gather facts.
final patchRules = <PatchRule>[
  PatchRule(
    'PATCH_NATIVE_CHANGE',
    PatchStage.inputs,
    (f) => [
      if (f.appNativeChanged)
        f.lineEndingChanges.isEmpty
            ? 'Application native sources changed; rebuild host'
            : 'Application native files differ from the release only in '
                  'line endings (CRLF/LF): ${_list(f.lineEndingChanges)}. '
                  'Check out the sources with the line endings the host was '
                  'built from (git core.autocrlf), then patch again.',
      for (final name in f.nativeDependencies)
        'Native plugin/build hook changed: $name',
      for (final name in f.changedPlugins)
        'Native plugin changes require a new host release: $name',
      if (f.newlyPinned.isNotEmpty)
        'Packages with native capability, or reached from one, are new '
            'since the release and need a new host release: '
            '${f.newlyPinned.join(', ')}',
    ],
  ),
  PatchRule(
    'PATCH_PINNED_PACKAGE_CHANGED',
    PatchStage.inputs,
    (f) => [
      for (final e in f.changedPinned.entries)
        '${e.key} stays in the host (${e.value.why}), so a patch cannot '
            'change it; a new host release can. To keep the release\'s copy'
            '${e.value.version == null ? '' : ', add to pubspec.yaml:\n'
                      'dependency_overrides:\n  ${e.key}: ${e.value.version}'}',
    ],
    strategies: const {'bytecode'},
  ),
  // The interpreter cannot make FFI calls in an AOT runtime: a module with
  // one would abort the app, whichever tier carried it.
  PatchRule('PATCH_FFI_UNSUPPORTED', PatchStage.compile, (f) {
    final sites = (f.report?['checks'] as Map?)?['ffi'];
    if (sites is! List || sites.isEmpty) return const [];
    final first = sites.first as Map;
    return [
      'Patched code would run FFI in the interpreter (${first['message']} at '
          '${first['file']}:${first['line']}). Move FFI calls into a package the '
          'host keeps, such as a plugin, which a patch may call, or ship a '
          'new host release.',
    ];
  }, strategies: const {'bytecode'}),
  PatchRule(
    'PATCH_UNSAFE',
    PatchStage.code,
    (f) => [
      if (f.report?['status'] != 'compiled')
        '${f.tier == 'lean' ? 'Lean' : 'Whole'}-tier checks failed: '
            '${checkSummary(f.report ?? const {})}; evidence: ${f.evidence}. '
            'If the host interface lacks an unchanged library, rebuild the '
            'host with this flutter_patcher to enable library reuse.',
    ],
    strategies: const {'bytecode'},
  ),
  // Without the engine's entry hook only main runs the generated entry that
  // installs a patch. With it every engine boots with the patch, and a
  // bytecode patch runs its version of each entry point it carries.
  PatchRule('PATCH_BACKGROUND_ENTRY', PatchStage.background, (f) {
    if (f.engineCapabilities.contains(isolateEntry)) {
      if (f.strategy == 'so' || !f.codeChanged) return const [];
      final carried = (f.report?['entries'] as List? ?? const [])
          .cast<String>();
      final missed = [
        for (final (name, site) in f.backgroundEntries)
          if (!carried.any(
            (key) =>
                key.startsWith('${_library(site)}#') &&
                (key.endsWith('#$name') || key.endsWith('.$name')),
          ))
            '$name (${siteText(site)})',
      ];
      if (missed.isEmpty) return const [];
      return [
        'Entry points this patch does not carry run the release\'s code in a '
            'separate engine: ${_list(missed)}',
      ];
    }
    final sites = [
      for (final (name, site) in f.backgroundEntries)
        '$name (${siteText(site)})',
      for (final site in f.backgroundRegistrations) siteText(site),
    ];
    if (sites.isEmpty) return const [];
    if (f.strategy == 'so' || !f.codeChanged) return const [];
    return [
      'Entry points started in a separate engine run the release\'s code: '
          '${_list(sites)}',
    ];
  }, reject: false),
  PatchRule(
    'PATCH_NO_CHANGES',
    PatchStage.result,
    (f) => [if (f.changed.isEmpty) 'No Dart or dependency changes detected'],
  ),
];

/// Applies [rules] stage by stage: the first rejection throws, warnings
/// accumulate for the report.
class PatchRules {
  PatchRules([List<PatchRule>? rules]) : rules = rules ?? patchRules;
  final List<PatchRule> rules;
  final List<Map<String, String>> warnings = [];

  void check(PatchStage stage, PatchFacts facts) {
    for (final rule in rules) {
      if (rule.stage != stage || !rule.strategies.contains(facts.strategy)) {
        continue;
      }
      for (final message in rule.findings(facts)) {
        if (rule.reject) throw Failure(rule.code, message);
        warnings.add({'code': rule.code, 'message': message});
      }
    }
  }

  /// The rule table, for documentation and the report.
  static List<Map<String, Object>> describe() => [
    for (final r in patchRules)
      {
        'code': r.code,
        'stage': r.stage.name,
        'strategies': r.strategies.toList()..sort(),
        'severity': r.reject ? 'reject' : 'warn',
      },
  ];
}

/// The first few rejection reasons of a tools report, one line each.
String checkSummary(Map<String, dynamic> report, {int limit = 3}) {
  final lines = <String>[];
  final checks = report['checks'];
  if (checks is Map) {
    for (final entry in checks.entries) {
      if (entry.value is! List) continue;
      for (final row in entry.value as List) {
        if (row is! Map) continue;
        final message = '${row['message'] ?? row['code']}'.split('\n').first;
        lines.add(
          '${entry.key}: ${message.replaceFirst(RegExp(r'^org-dartlang-root:///'), '')}',
        );
      }
    }
  }
  if (lines.isEmpty) return 'see the report';
  final more = lines.length > limit ? ' (+${lines.length - limit} more)' : '';
  return '${lines.take(limit).join('; ')}$more';
}
