import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise the real two-level navigation instead of reaching hidden sections.
Future<void> openSection(WidgetTester tester, String section) async {
  if (section != 'home' &&
      section != 'settings' &&
      find.byKey(const ValueKey('navigation-drawer')).evaluate().isNotEmpty) {
    await openSection(tester, 'settings');
  }
  final target = find.byKey(ValueKey('nav-$section'));
  if (target.evaluate().isEmpty) {
    if (section == 'home' || section == 'settings') {
      await tester.tap(find.byKey(const ValueKey('toggle-navigation')));
      await tester.pump();
    } else {
      final parent = switch (section) {
        'services' => 'service-settings',
        'profiles' ||
        'work' ||
        'dropo_space' ||
        'technical-settings' => 'advanced',
        'logs' || 'stats' || 'about' || 'exit' => 'help',
        _ => 'settings',
      };
      await openSection(tester, parent);
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
