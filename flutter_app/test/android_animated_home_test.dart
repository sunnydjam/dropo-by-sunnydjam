import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'scene bridge rejects arbitrary calls, malformed input and unknown modes',
    () {
      for (final input in [
        'null',
        '[]',
        '{',
        '{"action":"openExternal","value":"https://example.com"}',
        '{"action":"mode","value":"direct"}',
        '{"action":true}',
        'x' * 257,
      ]) {
        expect(parseAndroidSceneAction(input), isNull, reason: input);
      }
      expect(parseAndroidSceneAction('{"action":"toggle"}')?.action, 'toggle');
      expect(parseAndroidSceneAction('{"action":"cancel"}')?.action, 'cancel');
      expect(
        parseAndroidSceneAction(
          '{"action":"mode","value":"all_traffic"}',
        )?.value,
        'all_traffic',
      );
    },
  );

  testWidgets(
    'Android footer opens login with Boost destination and hides version',
    (tester) async {
      debugMobileShellOverride = true;
      debugAndroidPlatformOverride = true;
      addTearDown(() {
        debugMobileShellOverride = null;
        debugAndroidPlatformOverride = null;
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: DropoHomePage(bridge: MockCoreBridge())),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final boost = find.byKey(const ValueKey('android-buy-boost'));
      expect(boost, findsOneWidget);
      expect(find.text('Купить'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-version')), findsNothing);
      expect(tester.getCenter(boost).dx, greaterThan(280));
      expect(tester.getCenter(boost).dy, greaterThan(750));
      await tester.tap(boost);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.widget<AccountPage>(find.byType(AccountPage)).showTurbo,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('nav-account')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.widget<AccountPage>(find.byType(AccountPage)).showTurbo,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
