import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        '{"action":"ready"}',
        '{"action":"ready","value":"0;connect()"}',
        '{"action":"toggle"}',
        'x' * 257,
      ]) {
        expect(parseAndroidSceneAction(input), isNull, reason: input);
      }
      expect(
        parseAndroidSceneAction('{"action":"connect"}')?.action,
        'connect',
      );
      expect(
        parseAndroidSceneAction('{"action":"disconnect"}')?.action,
        'disconnect',
      );
      expect(
        parseAndroidSceneAction('{"action":"ready","value":"2"}')?.value,
        '2',
      );
      expect(parseAndroidSceneAction('{"action":"cancel"}')?.action, 'cancel');
      expect(parseAndroidSceneAction('{"action":"landed"}')?.action, 'landed');
      expect(
        parseAndroidSceneAction(
          '{"action":"mode","value":"all_traffic"}',
        )?.value,
        'all_traffic',
      );
    },
  );

  testWidgets('Android drawer slides over the page and keeps one footer', (
    tester,
  ) async {
    debugMobileShellOverride = true;
    debugAndroidPlatformOverride = true;
    addTearDown(() {
      debugMobileShellOverride = null;
      debugAndroidPlatformOverride = null;
    });
    final feedback = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        feedback.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: DropoHomePage(bridge: MockCoreBridge())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final drawer = find.byKey(const ValueKey('navigation-drawer'));
    final boost = find.byKey(const ValueKey('android-buy-boost'));
    final footer = find.byKey(const ValueKey('nav-account'));
    final footerPosition = tester.getRect(footer);
    final boostPosition = tester.getRect(boost);
    final brandStyle = tester.widget<Text>(find.text('Dropo').first).style;
    expect(drawer, findsNothing);

    await tester.tap(find.byKey(const ValueKey('toggle-navigation')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getTopLeft(drawer).dx, lessThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(drawer).dx, closeTo(0, .01));
    expect(
      tester.getBottomRight(drawer).dy,
      lessThanOrEqualTo(footerPosition.top),
    );
    expect(find.byKey(const ValueKey('home-connect')), findsOneWidget);
    expect(footer, findsOneWidget);
    expect(tester.getRect(footer), footerPosition);
    expect(tester.getRect(boost), boostPosition);
    expect(
      tester
          .widget<Text>(
            find.descendant(of: drawer, matching: find.text('Dropo')),
          )
          .style,
      brandStyle,
    );
    expect(feedback, hasLength(1));

    // Tap outside the panel. The center of the scrim is underneath the drawer.
    await tester.tapAt(const Offset(360, 230));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(drawer, findsNothing);
    expect(feedback, hasLength(1));

    await tester.dragFrom(const Offset(5, 220), const Offset(140, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(drawer, findsOneWidget);
    expect(feedback, hasLength(2));

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('link-app-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final haptics = find.text('Виброотклик');
    await tester.scrollUntilVisible(
      haptics,
      360,
      scrollable: find.byType(Scrollable).first,
    );
    final row = find.ancestor(of: haptics, matching: find.byType(Row)).first;
    final toggle = find.descendant(of: row, matching: find.byType(Switch));
    await tester.ensureVisible(toggle);
    await tester.pump();
    expect(tester.widget<Switch>(toggle).value, true);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<Switch>(toggle).value, false);

    final count = feedback.length;
    await tester.tap(find.byKey(const ValueKey('toggle-navigation')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(drawer, findsOneWidget);
    expect(feedback, hasLength(count));
    await tester.tapAt(const Offset(360, 230));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(toggle); // Restore the test's process-wide preference.
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
