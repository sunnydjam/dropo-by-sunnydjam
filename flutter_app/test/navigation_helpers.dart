import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise real navigation; legacy service test names open Home's accordion.
Future<void> openSection(WidgetTester tester, String section) async {
  if (section == 'services' || section == 'service-settings') {
    await openSection(tester, 'home');
    if (find
        .byKey(const ValueKey('toggle-home-route-services'))
        .evaluate()
        .isEmpty) {
      final selectedMode = find.byKey(const ValueKey('home-routing-selected'));
      await tester.ensureVisible(selectedMode);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(selectedMode);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }
    if (find.byKey(const ValueKey('service-search')).evaluate().isEmpty) {
      final disclosure = find.byKey(
        const ValueKey('toggle-home-route-services'),
      );
      await tester.ensureVisible(disclosure);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(disclosure);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }
    return;
  }
  const primary = {'home', 'sources', 'settings', 'account', 'help'};
  Finder locate() {
    final nav = find.byKey(ValueKey('nav-$section'));
    return nav.evaluate().isNotEmpty
        ? nav
        : find.byKey(ValueKey('link-$section'));
  }

  var target = locate();
  if (target.evaluate().isEmpty) {
    if (primary.contains(section)) {
      await tester.tap(find.byKey(const ValueKey('toggle-navigation')));
      await tester.pump();
      target = locate();
    } else {
      final parent = switch (section) {
        'profiles' ||
        'work' ||
        'dropo_space' ||
        'technical-settings' => 'advanced',
        'logs' || 'stats' || 'about' || 'exit' => 'help',
        _ => 'settings',
      };
      await openSection(tester, parent);
      target = locate();
      if (target.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          target,
          160,
          scrollable: find.byType(Scrollable).last,
        );
      }
    }
  }
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Open a compact service row's inline settings, without leaving Home.
Future<void> openHomeService(WidgetTester tester, String tag) async {
  await openSection(tester, 'services');
  final search = find.byKey(const ValueKey('service-search'));
  await tester.ensureVisible(search);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(search, tag);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final details = find.byKey(ValueKey('home-service-details-$tag'));
  if (details.evaluate().isEmpty) {
    final row = find.byKey(ValueKey('home-service-row-$tag'));
    await tester.ensureVisible(row);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}
