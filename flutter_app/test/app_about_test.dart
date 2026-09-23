import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CoreStatus _aboutStatus() => CoreStatus.fromJson({
  'version': {
    'version': '3.0.34',
    'fullVersion': '3.0.34-a1b2c3d',
    'singboxVersion': '1.13.14',
  },
});

Future<void> _pumpAbout(
  WidgetTester tester, {
  AppConfig config = AppConfig.defaults,
  Size size = const Size(820, 560),
  double textScale = 1,
  required Future<void> Function(String) onOpenExternal,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: aboutContentForTest(
              status: _aboutStatus(),
              appConfig: config,
              onOpenExternal: onOpenExternal,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'About shares honest author, origin and exact core build metadata',
    (tester) async {
      await _pumpAbout(tester, onOpenExternal: (_) async {});
      expect(find.text('Джамуха (sunnydjam)'), findsOneWidget);
      expect(find.text('Droponevedimka'), findsOneWidget);
      expect(find.text('3.0.34'), findsOneWidget);
      expect(find.text('3.0.34-a1b2c3d'), findsOneWidget);
      expect(find.text('1.13.14'), findsOneWidget);
      expect(find.textContaining('Telegram'), findsNothing);
      expect(find.text('Официальная сборка'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('About actions open only their explicitly selected destinations', (
    tester,
  ) async {
    final opened = <String>[];
    await _pumpAbout(tester, onOpenExternal: (url) async => opened.add(url));
    const expected = {
      'Разработчик этой версии': 'https://github.com/sunnydjam',
      'Основа проекта': 'https://github.com/Droponevedimka',
      'Исходный код': 'https://github.com/sunnydjam/dropo-by-sunnydjam',
      'Релизы и изменения':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/releases',
      'Сообщить о проблеме':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/issues',
      'Лицензия MIT':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/blob/Dzhamuha-develop/LICENSE',
      'Сторонние компоненты':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/blob/Dzhamuha-develop/THIRD_PARTY_NOTICES.md',
    };
    for (final entry in expected.entries) {
      final link = find.byKey(ValueKey('about-link-${entry.key}'));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pump();
      expect(opened.last, entry.value);
    }
    expect(opened, expected.values.toList());
  });

  testWidgets('About remains scrollable at 320px and 200 percent text', (
    tester,
  ) async {
    await _pumpAbout(
      tester,
      size: const Size(320, 500),
      textScale: 2,
      onOpenExternal: (_) async {},
    );
    await tester.ensureVisible(find.text('Сторонние компоненты'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'About ignores legacy Telegram metadata and unsafe repository URL',
    (tester) async {
      final opened = <String>[];
      await _pumpAbout(
        tester,
        config: AppConfig.defaults.copyWith(
          githubUrl: 'file:///private/settings.json',
          telegramName: 'Telegram channel',
          telegramUrl: 'tg://legacy',
        ),
        onOpenExternal: (url) async => opened.add(url),
      );
      final link = find.byKey(const ValueKey('about-link-Релизы и изменения'));
      await tester.ensureVisible(link);
      await tester.tap(link);
      expect(opened.single, '${AppConfig.defaults.githubUrl}/releases');
      expect(find.textContaining('Telegram'), findsNothing);
    },
  );
}
