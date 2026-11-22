import 'dart:io';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Set<String> _catalogTags(String path, {String? before}) {
  var source = File(path).readAsStringSync();
  if (before != null) source = source.split(before).first;
  return RegExp(
    r'Tag:\s*"([a-z][a-z0-9-]*)"',
  ).allMatches(source).map((match) => match.group(1)!).toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every Android and Windows built-in service has specific artwork', () {
    final androidTags = _catalogTags(
      '../app/mobile/dropocore/android_services.go',
      before: 'func androidServiceByTag',
    );
    final windowsTags = _catalogTags(
      '../app/core_freeaccess.go',
      before: 'var primaryHomeRouteServiceTags',
    );
    expect(androidTags, hasLength(29));
    expect(windowsTags, equals(androidTags));
    expect(serviceIconCatalogTags, equals(androidTags));
  });

  test(
    'all brand SVGs are bundled, bounded and do not reference the network',
    () async {
      for (final tag in serviceIconCatalogTags) {
        final asset = serviceIconAssetPath(tag);
        if (asset == null) continue;
        final svg = await rootBundle.loadString(asset);
        expect(svg, contains('viewBox="0 0 24 24"'), reason: tag);
        expect(svg, contains('<path '), reason: tag);
        expect(svg, isNot(contains('<script')), reason: tag);
        expect(svg, isNot(contains('href=')), reason: tag);
        expect(svg, isNot(contains('<image')), reason: tag);
        expect(svg.length, lessThan(16000), reason: tag);
      }
    },
  );

  testWidgets('catalog artwork renders proportionally without missing assets', (
    tester,
  ) async {
    for (final tag in serviceIconCatalogTags) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: serviceIconForTesting(tag: tag)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tag);
      expect(
        tester.getSize(find.byKey(ValueKey('service-brand-icon-$tag'))),
        const Size(32, 32),
        reason: tag,
      );
      if (serviceIconAssetPath(tag) != null) {
        expect(find.byType(SvgPicture), findsOneWidget, reason: tag);
      } else {
        expect(find.byIcon(Icons.language_rounded), findsNothing, reason: tag);
      }
    }
  });

  testWidgets('future or custom services keep an honest neutral fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: serviceIconForTesting(tag: 'custom-network', size: 28),
        ),
      ),
    );
    expect(find.byIcon(Icons.language_rounded), findsOneWidget);
    expect(serviceIconAssetPath('custom-network'), isNull);
    expect(serviceIconAssetPath(' TELEGRAM '), 'assets/service-telegram.svg');
    expect(
      tester.getSize(
        find.byKey(const ValueKey('service-brand-icon-custom-network')),
      ),
      const Size(28, 28),
    );
  });
}
