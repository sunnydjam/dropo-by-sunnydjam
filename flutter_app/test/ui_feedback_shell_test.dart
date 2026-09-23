import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FeedbackBridge extends MockCoreBridge {
  bool connected = false;
  bool error = false;
  bool publicSource = false;
  bool empty = false;
  Completer<void>? pendingConnection;

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
  };

  @override
  Future<CoreStatus> status() async => (await super.status()).copyWith(
    connected: connected,
    running: connected,
    hasError: error,
    error: error ? 'Тест: сервер временно недоступен' : '',
  );

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    if (pendingConnection != null) await pendingConnection!.future;
    connected = value;
    return super.setConnected(value);
  }

  @override
  Future<List<VpnSourceInfo>> vpnSources() async => empty
      ? const []
      : [
          VpnSourceInfo.fromJson({
            'id': 'fixture',
            'name': publicSource ? 'Публичный каталог' : 'Моя подписка',
            'kind': 'subscription',
            'selected_node': 0,
            'node_count': 1,
            'node_names': ['Сервер 1'],
            'active': connected,
            'public_catalog_id': publicSource ? 'catalog' : '',
          }),
        ];
}

Future<void> _pump(
  WidgetTester tester,
  _FeedbackBridge bridge, {
  Size size = const Size(820, 560),
  double scale = 1,
  bool motion = false,
  double pixelRatio = 1,
}) async {
  tester.view.physicalSize = size * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (!bridge.empty) {
    await bridge.saveSubscription('https://example.test/subscription');
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: !motion,
        ),
        child: child!,
      ),
      home: RepaintBoundary(
        key: const ValueKey('feedback-capture'),
        child: DropoHomePage(bridge: bridge),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
  const directory = String.fromEnvironment(
    'DROPO_UI_CAPTURE_DIR',
    defaultValue: 'build/ui-feedback-release',
  );
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      _key('feedback-capture'),
    );
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

ScrollableState _homeScroll(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find.descendant(
        of: _key('home-scroll'),
        matching: find.byType(Scrollable),
      ),
    );

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
  });

  for (final size in [const Size(684, 461), const Size(820, 560)]) {
    for (final source in ['empty', 'personal', 'public']) {
      testWidgets('first viewport $size with $source has no forced scroll', (
        tester,
      ) async {
        final bridge = _FeedbackBridge()
          ..empty = source == 'empty'
          ..publicSource = source == 'public';
        await _pump(tester, bridge, size: size);
        expect(_homeScroll(tester).position.maxScrollExtent, 0);
        for (final key in [
          'home-connect',
          'home-manage-sources',
          'home-routing-all-vpn',
          'link-service-settings',
        ]) {
          final rect = tester.getRect(_key(key));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
          expect(rect.top, greaterThanOrEqualTo(0));
        }
        expect(find.text('Отключено'), findsNothing);
        expect(_key('planet-disconnected'), findsOneWidget);
        final actionLabel = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: _key('home-connect'),
            matching: find.text('Подключить'),
          ),
        );
        expect(
          actionLabel.size.height,
          lessThanOrEqualTo(actionLabel.preferredLineHeight + 0.1),
          reason:
              'Ordinary Connect label must stay on one line, including public sources',
        );
        expect(tester.takeException(), isNull);
        await _capture(tester, 'first-${size.width.toInt()}-$source');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final scale in [1.25, 1.5, 2.0]) {
    testWidgets('desktop layout respects text and display scale $scale', (
      tester,
    ) async {
      await _pump(tester, _FeedbackBridge(), scale: scale, pixelRatio: scale);
      await _tap(tester, 'nav-settings');
      await tester.ensureVisible(_key('link-advanced'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await _capture(tester, 'settings-scale-$scale');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'small window and large text remain scrollable without overflow',
    (tester) async {
      await _pump(
        tester,
        _FeedbackBridge(),
        size: const Size(320, 480),
        scale: 2,
      );
      expect(_homeScroll(tester).position.maxScrollExtent, greaterThan(0));
      await tester.ensureVisible(_key('home-routing-all-vpn'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('five desktop destinations remain present with selected parent', (
    tester,
  ) async {
    await _pump(tester, _FeedbackBridge());
    for (final section in ['home', 'services', 'sources', 'settings', 'help']) {
      expect(_key('nav-$section'), findsOneWidget);
    }
    expect(find.text('Источники VPN'), findsOneWidget);
    await _tap(tester, 'nav-settings');
    await _tap(tester, 'link-advanced');
    final selected = find.ancestor(
      of: _key('nav-settings'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
    );
    expect(selected, findsOneWidget);
    await _tap(tester, 'nav-home');
    expect(_key('home-connect'), findsOneWidget);
    await _tap(tester, 'nav-help');
    expect(_key('help-section'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('notice insertion and dismissal never move main controls', (
    tester,
  ) async {
    final bridge = _FeedbackBridge();
    await _pump(tester, bridge, size: const Size(684, 461));
    final connectBefore = tester.getRect(_key('home-connect'));
    final sourceBefore = tester.getRect(_key('home-manage-sources'));
    final scrollBefore = _homeScroll(tester).position.pixels;
    bridge.error = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(_key('notice-overlay'), findsOneWidget);
    await _capture(tester, 'error-overlay');
    expect(tester.getRect(_key('home-connect')), connectBefore);
    expect(tester.getRect(_key('home-manage-sources')), sourceBefore);
    expect(_homeScroll(tester).position.pixels, scrollBefore);
    expect(
      tester.getRect(_key('notice-overlay')).overlaps(connectBefore),
      isFalse,
      reason: 'A passive notification must not obscure the connection action',
    );
    await _tap(tester, 'dismiss-notice');
    expect(_key('reopen-notice'), findsOneWidget);
    expect(tester.getRect(_key('home-connect')), connectBefore);
    await _tap(tester, 'reopen-notice');
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Тест: сервер временно недоступен'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'button and planet distinguish connecting, connected and errors',
    (tester) async {
      final bridge = _FeedbackBridge()..pendingConnection = Completer<void>();
      await _pump(tester, bridge);
      await _tap(tester, 'home-connect');
      expect(find.text('Подключаем…'), findsOneWidget);
      expect(_key('planet-connecting'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('home-connect')).onPressed,
        isNull,
      );
      bridge.pendingConnection!.complete();
      bridge.pendingConnection = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(_key('planet-connected'), findsOneWidget);
      expect(find.text('Отключить'), findsOneWidget);
      final semantics = tester.widget<Semantics>(_key('home-connection-state'));
      expect(semantics.properties.liveRegion, isTrue);
      expect(semantics.properties.label, 'Подключено');
      bridge.connected = false;
      bridge.error = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(_key('planet-error'), findsOneWidget);
      expect(find.text('Повторить'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('large text notice stays clear of the connection button', (
    tester,
  ) async {
    final bridge = _FeedbackBridge();
    await _pump(tester, bridge, size: const Size(390, 568), scale: 2);
    final before = tester.getRect(_key('home-connect'));
    bridge.error = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tester.getRect(_key('home-connect')), before);
    expect(tester.getRect(_key('notice-overlay')).overlaps(before), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop click surfaces expose an actual pointer cursor', (
    tester,
  ) async {
    await _pump(tester, _FeedbackBridge());
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final key in ['home-connect', 'home-manage-sources', 'nav-services']) {
      await mouse.moveTo(tester.getCenter(_key(key)));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
        reason: key,
      );
    }
    await _tap(tester, 'nav-settings');
    await mouse.moveTo(tester.getCenter(_key('link-advanced')));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
