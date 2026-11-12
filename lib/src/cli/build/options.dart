import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core.dart';

/// Flutter arguments are individual process arguments, never a shell command.
/// Build identity and the generated entry remain owned by the patcher.
class FlutterBuildOptions {
  const FlutterBuildOptions({
    this.arguments = const [],
    this.buildNumber,
    this.buildName,
    this.exportMethod,
  });

  final List<String> arguments;
  final String? buildNumber, buildName, exportMethod;

  bool get verbose => arguments.any(_isVerbose);

  static bool _isVerbose(String value) =>
      value == '--verbose' || RegExp(r'^-v+$').hasMatch(value);

  static const _owned = {
    '--debug',
    '--profile',
    '--jit-release',
    '--no-release',
    '--target',
    '-t',
    '--target-platform',
    '--flavor',
    '--output',
    '-o',
    '--build-dir',
    '--split-per-abi',
    '--config-only',
    '--no-codesign',
    '--no-pub',
    '--packages',
    '--package-config',
    '--precompiled-dill',
    '--initialize-from-dill',
    '--filesystem-root',
    '--filesystem-scheme',
    '--local-engine',
    '--local-engine-src-path',
    '--local-engine-host',
    '--extra-front-end-options',
    '--extra-gen-snapshot-options',
    '--frontend-server-starter-path',
    '--obfuscate',
    '--enable-experiment',
    '--dart-define',
    '--dart-define-from-file',
    '-D',
    '--help',
    '-h',
    '--version',
  };

  static List<String> fromCommand(ArgResults args) => [
    if (args['verbose'] == true) '--verbose',
    for (final key in [
      'build-name',
      'build-number',
      'export-options-plist',
      'split-debug-info',
    ])
      if (args.wasParsed(key)) ...['--$key', args[key] as String],
    if (args.wasParsed('tree-shake-icons'))
      args['tree-shake-icons'] == true
          ? '--tree-shake-icons'
          : '--no-tree-shake-icons',
    ...args.rest.skip(1),
  ];

  static Future<FlutterBuildOptions> resolve(
    List<String> input, {
    required String platform,
    String? exportMethod,
  }) async {
    final result = <String>[];
    String? buildNumber, buildName;
    var exportPlist = false;
    for (var i = 0; i < input.length; i++) {
      final argument = input[i];
      final key = argument.split('=').first;
      require(
        argument.isNotEmpty && !argument.contains('\u0000'),
        'BUILD_CONFIG_INVALID',
        'Invalid Flutter build argument.',
      );
      require(
        !_owned.contains(key) &&
            !key.startsWith('-D') &&
            !(key.startsWith('-t') && !key.startsWith('--')) &&
            !(key.startsWith('-o') && !key.startsWith('--')),
        'BUILD_CONFIG_INVALID',
        '$key cannot be forwarded: the patcher controls build mode, entry, '
            'ABI and compiler inputs. --dart-define is not supported.',
      );
      String value() {
        final equals = argument.indexOf('=');
        if (equals >= 0) {
          final value = argument.substring(equals + 1);
          require(
            value.isNotEmpty,
            'BUILD_CONFIG_INVALID',
            '$key needs a value.',
          );
          return value;
        }
        require(
          i + 1 < input.length && !input[i + 1].startsWith('-'),
          'BUILD_CONFIG_INVALID',
          '$key needs a value.',
        );
        return input[++i];
      }

      switch (key) {
        case '--build-number':
          final next = value();
          require(
            buildNumber == null || buildNumber == next,
            'BUILD_CONFIG_INVALID',
            'Conflicting --build-number values.',
          );
          require(
            RegExp(r'^[1-9][0-9]*$').hasMatch(next),
            'BUILD_CONFIG_INVALID',
            '--build-number must be a positive integer.',
          );
          buildNumber = next;
        case '--build-name':
          final next = value();
          require(
            buildName == null || buildName == next,
            'BUILD_CONFIG_INVALID',
            'Conflicting --build-name values.',
          );
          buildName = next;
        case '--export-method':
          final next = value();
          require(
            exportMethod == null || exportMethod == next,
            'BUILD_CONFIG_INVALID',
            'Conflicting --export-method values.',
          );
          exportMethod = next;
        case '--export-options-plist':
          require(
            platform == 'ios' && !exportPlist,
            'BUILD_CONFIG_INVALID',
            '--export-options-plist applies once to iOS builds.',
          );
          final path = p.normalize(p.absolute(value()));
          require(
            await File(path).exists(),
            'BUILD_CONFIG_INVALID',
            'Export options plist does not exist: $path',
          );
          result.addAll([key, path]);
          exportPlist = true;
        case '--split-debug-info':
          // Resolve before entering the isolated build copy, so Flutter writes
          // debugging symbols to the caller's chosen directory.
          result.addAll([key, p.normalize(p.absolute(value()))]);
        default:
          require(
            key != '--',
            'BUILD_CONFIG_INVALID',
            'Unexpected -- separator.',
          );
          result.add(argument);
      }
    }
    require(
      !exportPlist || exportMethod == null,
      'BUILD_CONFIG_INVALID',
      '--export-options-plist and --export-method cannot be combined.',
    );
    return FlutterBuildOptions(
      arguments: List.unmodifiable([
        if (buildName != null) ...['--build-name', buildName],
        ...result,
      ]),
      buildNumber: buildNumber,
      buildName: buildName,
      exportMethod: exportMethod,
    );
  }

  /// Inputs needed by an SO rebuild; export destinations are local build
  /// outputs and must not make a later patch write to the old machine's path.
  Map<String, Object?> get receipt {
    final replay = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      // Logging is a choice of this invocation, not a host build input.
      if (_isVerbose(arguments[i])) continue;
      if (const {
        '--export-options-plist',
        '--split-debug-info',
      }.contains(arguments[i])) {
        i++;
        continue;
      }
      replay.add(arguments[i]);
    }
    return {
      'arguments': replay,
      if (buildName != null) 'build_name': buildName,
    };
  }

  static FlutterBuildOptions recorded(Object? value) {
    if (value == null) return const FlutterBuildOptions();
    require(
      value is Map &&
          value['arguments'] is List &&
          (value['arguments'] as List).every((e) => e is String) &&
          (value['build_name'] == null || value['build_name'] is String),
      'PATCH_BASELINE_INCOMPATIBLE',
      'Invalid recorded Flutter build arguments.',
    );
    final row = value as Map;
    return FlutterBuildOptions(
      arguments: List<String>.from(row['arguments'] as List),
      buildName: row['build_name'] as String?,
    );
  }
}
