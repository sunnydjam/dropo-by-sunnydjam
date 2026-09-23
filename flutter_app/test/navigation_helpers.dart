import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise persistent primary navigation and real nested links on each page.
Future<void> openSection(WidgetTester tester, String section) async {
  const primary = {'home', 'services', 'sources', 'settings', 'help'};
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
