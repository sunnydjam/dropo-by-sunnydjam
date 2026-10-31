import 'dart:async';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProgressBridge extends MockCoreBridge {
  final controller = StreamController<BridgeEvent>.broadcast();
  int eventId = 100;

  @override
  bool get prefersPushEvents => true;

  @override
  Stream<BridgeEvent> watchEvents() => controller.stream;

  void emit(String name, Map<String, dynamic> payload) =>
      controller.add(BridgeEvent(id: eventId++, name: name, payload: payload));

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
    'reduceMotion': true,
    'routingMode': 'blocked_only',
  };
}

Future<_ProgressBridge> _pump(
  WidgetTester tester,
  Size size,
  double scale,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  debugMobileShellOverride = size.width < 500;
  final bridge = _ProgressBridge();
  addTearDown(bridge.controller.close);
  await bridge.saveSubscription('https://example.test/fixture');
  await bridge.setConnected(true);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: DropoHomePage(bridge: bridge),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pump();
  return bridge;
}

Finder _key(String key) => find.byKey(ValueKey(key));

Offset _expectWarningActuallyVisible(WidgetTester tester) {
  final summary = find.descendant(
    of: _key('route-probe-details'),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().startsWith('До часа'),
    ),
  );
  final paragraph = tester.renderObject<RenderParagraph>(summary);
  const warning = 'До часа';
  expect(paragraph.text.toPlainText(), startsWith(warning));
  final boxes = paragraph.getBoxesForSelection(
    const TextSelection(baseOffset: 0, extentOffset: warning.length),
  );
  final clip = tester.getRect(_key('notice-overlay')).inflate(0.5);
  expect(boxes, isNotEmpty);
  for (final box in boxes) {
    final bounds = box.toRect().shift(paragraph.localToGlobal(Offset.zero));
    expect(
      clip.contains(bounds.topLeft) && clip.contains(bounds.bottomRight),
      isTrue,
      reason:
          'The complete time warning must be painted inside the notice: '
          '$bounds, clip $clip',
    );
  }
  // The remaining summary may wrap below the compact clip. Hit the actual
  // visible warning, rather than the centre of the taller offscreen button.
  return boxes.first
      .toRect()
      .shift(paragraph.localToGlobal(Offset.zero))
      .center;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    WidgetController.hitTestWarningShouldBeFatal = true;
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await preloadAtlasPlanetForTesting();
  });

  tearDown(() {
    debugMobileShellOverride = null;
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  for (final (size, scale) in [
    (const Size(684, 461), 1.0),
    (const Size(320, 568), 2.0),
  ]) {
    testWidgets('extended search warning is visible at $size / $scale', (
      tester,
    ) async {
      final bridge = await _pump(tester, size, scale);
      expect(_key('notice-overlay'), findsNothing);
      bridge.emit('route-probe-start', const {
        'extendedSearch': true,
        'serviceCount': 2,
        'services': [
          {'tag': 'youtube', 'name': 'YouTube'},
          {'tag': 'discord', 'name': 'Discord'},
        ],
      });
      bridge.emit('route-probe-candidate', const {
        'serviceTag': 'discord',
        'serviceName': 'Discord',
        'methodLabel': 'Fixture strategy',
        'status': 'checking',
        'attempt': 2,
        'attemptTotal': 4,
        'strategyIndex': 1,
        'strategyTotal': 3,
      });
      await tester.pump(const Duration(milliseconds: 300));
      final visibleWarning = _expectWarningActuallyVisible(tester);
      expect(find.textContaining('Discord'), findsOneWidget);
      expect(find.textContaining('способ 1/3'), findsOneWidget);
      expect(find.textContaining('попытка 2/4'), findsOneWidget);
      await tester.tapAt(visibleWarning);
      await tester.pump();
      expect(find.text('0 из 2 сервисов готовы'), findsOneWidget);
      await tester.tapAt(visibleWarning);
      await tester.pump();
      expect(find.text('0 из 2 сервисов готовы'), findsNothing);

      bridge.emit('route-probe-service', const {
        'tag': 'youtube',
        'name': 'YouTube',
        'success': false,
        'final': true,
        'error': 'Fixture endpoint unavailable',
      });
      await tester.pump(const Duration(milliseconds: 300));
      _expectWarningActuallyVisible(tester);
      expect(find.textContaining('До часа · Discord'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('home-connect')).onPressed,
        isNotNull,
        reason: 'Background service selection must not lock the connection',
      );

      await tester.tap(_key('dismiss-notice'));
      await tester.pump();
      expect(find.text('Поиск до часа'), findsOneWidget);
      expect(_key('reopen-notice').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('normal connection has no empty notice at $size / $scale', (
      tester,
    ) async {
      final bridge = await _pump(tester, size, scale);
      bridge.emit('app-busy', const {
        'id': 'vpn-connect',
        'active': true,
        'message': 'Fixture bootstrap details',
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(_key('notice-overlay'), findsNothing);
      expect(find.text('Fixture bootstrap details'), findsNothing);
      expect(
        tester.widget<FilledButton>(_key('home-connect')).onPressed,
        isNull,
      );
      bridge.emit('app-busy', const {
        'id': 'vpn-connect',
        'active': false,
        'message': 'Готово',
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(_key('notice-overlay'), findsNothing);
      expect(
        tester.widget<FilledButton>(_key('home-connect')).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
