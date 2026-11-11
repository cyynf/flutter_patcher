import 'dart:io';

import 'package:path/path.dart' as p;

/// A place in a source file, `path:line` relative to its package.
typedef SourceSite = ({String package, String file, int line});

String siteText(SourceSite s) => '${s.package}/${s.file}:${s.line}';

/// Read-only scans of a build copy's sources. They only gather facts; the
/// rules decide what the facts mean for a patch.
class SourceScan {
  SourceScan(this.roots, this.app, {required this.sdkRoots});

  /// Package name to its `lib/` URI (see `packageRoots`).
  final Map<String, dynamic> roots;
  final String app;

  /// Flutter SDKs whose packages the build copy may resolve to.
  final List<String> sdkRoots;

  static const _reserved = {'dynamic_modules', 'flutter_patcher'};

  Directory _dir(String name) =>
      Directory.fromUri((roots[name] as Uri).resolve('..'));

  /// The application and its local path packages: code the developer owns,
  /// not a pub cache or SDK package.
  late final List<String> own = [
    app,
    for (final name in roots.keys)
      if (name != app && !_reserved.contains(name) && _local(name)) name,
  ];

  bool _local(String name) {
    final dir = p.normalize(_dir(name).absolute.path);
    if (sdkRoots.any((sdk) => p.isWithin(p.normalize(sdk), dir))) return false;
    final parts = p.split(dir).map((s) => s.toLowerCase()).toList();
    return !parts.contains('hosted') &&
        !parts.contains('git') &&
        !parts.contains('pub-cache') &&
        !parts.contains('.pub-cache');
  }

  static final _entryPoint = RegExp(
    r'''@pragma\(\s*['"]vm:entry-point['"][^)]*\)\s*'''
    r'''(?:@\w+(?:\([^)]*\))?\s*)*'''
    r'''(?:(?:static|external)\s+)*'''
    r'''(?:[\w<>?,\s]+?\s+)?(\w+)\s*\(''',
  );
  static final _registration = RegExp(
    r'PluginUtilities\.getCallbackHandle|onBackgroundMessage|'
    r'Workmanager\(\)\s*\.\s*(?:initialize|registerOneOffTask|registerPeriodicTask)|'
    r'AndroidAlarmManager\.|BackgroundFetch\.|FlutterBackgroundService|'
    r'onDidReceiveBackgroundNotificationResponse|registerHeadlessTask',
  );

  /// Functions of own code that native code may start in a separate engine
  /// (entry points other than main), and the calls that register them.
  Future<({List<(String, SourceSite)> entries, List<SourceSite> registrations})>
  backgroundEntries() async {
    final entries = <(String, SourceSite)>[];
    final registrations = <SourceSite>[];
    await _eachOwnDart((site, text) {
      for (final m in _entryPoint.allMatches(text)) {
        final name = m.group(1)!;
        if (name == 'main') continue;
        entries.add((
          name,
          (
            package: site.package,
            file: site.file,
            // The function's own line, not its annotation's.
            line: _lineAt(text, m.start + m.group(0)!.lastIndexOf(name)),
          ),
        ));
      }
      for (final m in _registration.allMatches(text)) {
        registrations.add((
          package: site.package,
          file: site.file,
          line: _lineAt(text, m.start),
        ));
      }
    });
    return (entries: entries, registrations: registrations);
  }

  Future<void> _eachOwnDart(void Function(SourceSite, String) visit) async {
    for (final name in own) {
      final lib = Directory.fromUri(roots[name] as Uri);
      if (!await lib.exists()) continue;
      final base = _dir(name).path;
      await for (final entity in lib.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relative = p
            .relative(entity.path, from: base)
            .replaceAll('\\', '/');
        visit((package: name, file: relative, line: 0), await _read(entity));
      }
    }
  }

  static Future<String> _read(File file) async {
    try {
      return await file.readAsString();
    } on FileSystemException {
      return ''; // Not UTF-8 text: nothing a pattern here would match.
    }
  }

  static int _lineAt(String text, int offset) =>
      '\n'.allMatches(text.substring(0, offset)).length + 1;
}
