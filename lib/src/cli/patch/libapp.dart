import 'dart:io';

import 'package:path/path.dart' as p;

import '../core.dart';
import '../build/bootstrap.dart';
import '../build/host_policy.dart';
import '../build/pipeline.dart';
import '../build/runtime_package.dart';
import '../sdk/android.dart';
import 'pipeline.dart';

/// An SO host's patch: the host's APK rebuilt from the changed sources with
/// the same engine, flavor, versionCode, host policy and generated entry. It
/// ships only the rebuilt libapp.so.
class LibappProducer implements CodeProducer {
  LibappProducer(this.run);
  final PatchRun run;
  late final HostPolicy policy;
  late final BuildPipeline builder;

  PatchPipeline get _p => run.pipeline;

  @override
  Future<void> prepare() async {
    final resolved = run.resolved;
    require(
      resolved.compile['flutter_version'] == _p.sdk.version &&
          resolved.compile['engine_commit'] == _p.sdk.engine &&
          resolved.buildId == _p.engine?['build_id'],
      'PATCH_BASELINE_INCOMPATIBLE',
      'SDK or engine build differs from the release',
    );
    policy = HostPolicy.parse(
      await File(p.join(resolved.releaseRoot, 'host_policy.json'))
          .readAsString(),
    );
    final android = await resolveAndroidSdk(
      _p.commands,
      _p.sdk.host,
      _p.sdk.flutter,
    );
    checkJavaHome(_p.sdk.host);
    builder = BuildPipeline(
      _p.commands,
      _p.sdk,
      _p.managed,
      _p.tool,
      _p.cache,
      await selectAapt(android, _p.sdk.host),
      _p.engine!,
      _p.baselines,
      {for (final release in builtWith(resolved)) release.kind: release},
    );
  }

  /// A rebuilt libapp.so carries every Dart change, of any package.
  @override
  Future<void> inputs(bool dependencyChanged) async {}

  @override
  Future<PatchCode> produce() async {
    final req = run.req, work = run.work, receipt = run.receipt;
    final step = builder.runner(work, () => run.phase);
    run.phase = 'apk';
    final request = BuildRequest(
      project: run.project,
      output: p.join(work, 'unused'),
      publicKey: receipt['public_key'] as String,
      target: req.target,
      flavor: req.flavor == 'default' ? null : req.flavor,
      versionCode: req.minBuild.toString(),
      hostPolicy: policy,
    );
    final host = p.join(work, 'host');
    await Directory(host).create();
    final fingerprint = run.resolved.fingerprint;
    final trust = await builder.writeHostTrust(
      run.project,
      host,
      policy,
      fingerprint,
    );
    final target = await writeBootstrapEntry(
      run.project,
      bootstrapSource(
        run.app,
        req.target.substring(4),
        fingerprint,
        receipt['public_key'] as String,
        modules: false,
      ),
    );
    final apk = await builder.assembleApk(
      step,
      run.project,
      request,
      target,
      const [],
    );
    run.phase = 'verify-apk';
    final info = await builder.verifyApk(apk, host, request, trust);
    if (info['libapp_sha256'] != receipt['libapp_sha256']) {
      run.facts.changed.add('libapp.so');
    }
    return PatchCode(kind: 'libapp', file: p.join(host, 'libapp.so'));
  }
}
