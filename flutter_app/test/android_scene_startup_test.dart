import 'package:dropo/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('missing scene readiness falls back after a bounded wait', (
    tester,
  ) async {
    var failures = 0;
    final guard = AndroidSceneLoadGuard(onFailure: () => failures++);
    addTearDown(guard.dispose);
    // Loading the HTML itself is deliberately not treated as scene readiness.
    await tester.pump(const Duration(seconds: 7));
    expect(failures, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(failures, 1);
    guard.ready();
    await tester.pump(const Duration(seconds: 20));
    expect(failures, 1);
  });

  testWidgets('ready scene cancels the startup fallback', (tester) async {
    var failures = 0;
    final guard = AndroidSceneLoadGuard(onFailure: () => failures++);
    guard.ready();
    await tester.pump(const Duration(seconds: 20));
    expect(failures, 0);
    guard.dispose();
  });

  testWidgets('background loading gets a fresh foreground startup budget', (
    tester,
  ) async {
    var failures = 0;
    final guard = AndroidSceneLoadGuard(onFailure: () => failures++);
    addTearDown(guard.dispose);
    await tester.pump(const Duration(seconds: 5));
    guard.setActive(false);
    await tester.pump(const Duration(minutes: 5));
    expect(failures, 0);
    guard.setActive(true);
    await tester.pump(const Duration(seconds: 5));
    guard.setActive(true); // Native refresh must not keep extending the budget.
    await tester.pump(const Duration(seconds: 3));
    expect(failures, 1);
  });

  testWidgets('disposing a loading scene never invokes a later fallback', (
    tester,
  ) async {
    var failures = 0;
    final guard = AndroidSceneLoadGuard(onFailure: () => failures++);
    guard.dispose();
    await tester.pump(const Duration(seconds: 20));
    expect(failures, 0);
  });

  test('critical asset failures are distinct from optional fonts', () {
    const base = 'file:///android_asset/flutter_assets/assets/android_home/';
    for (final file in [
      'index.html',
      'bootstrap.js',
      'scene.js',
      'art.js',
      'scene.css',
      'vendor/three-0.160.1.min.js',
    ]) {
      expect(isAndroidSceneCriticalResource('$base$file'), isTrue);
    }
    expect(isAndroidSceneCriticalResource('${base}vendor/Caveat.ttf'), isFalse);
    expect(isAndroidSceneCriticalResource(null), isFalse);
  });
}
