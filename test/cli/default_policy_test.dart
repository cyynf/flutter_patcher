import 'package:flutter_patcher/src/cli/cli.dart';
import 'package:test/test.dart';

void main() {
  test('a build chooses the strategy; a patch follows its host', () {
    expect(
      parser().parse([
        'build',
        'android',
        '--strategy',
        'so',
      ]).command!['strategy'],
      'so',
    );
    expect(
      () => parser().parse(['build', 'android', '--strategy', 'jit']),
      throwsFormatException,
    );
    expect(
      () => parser().parse(['patch', 'android', '--strategy', 'so']),
      throwsFormatException,
    );
  });

  test('the removed framework reuse flag is rejected', () {
    for (final command in ['build', 'patch']) {
      expect(
        () => parser().parse([command, 'android', '--framework-reuse']),
        throwsFormatException,
      );
    }
  });

  test('resource selectors are available on both patch platforms', () {
    for (final platform in ['android', 'ios']) {
      expect(
        parser().parse([
          'patch',
          platform,
          '--assets',
          'assets/a.png',
        ]).command!['assets'],
        ['assets/a.png'],
      );
    }
  });
}
