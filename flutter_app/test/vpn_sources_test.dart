import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _subscription = SubscriptionInfo(
  hasSubscription: false,
  url: '',
  proxyCount: 0,
);
const _provider = PublicVpnProviderInfo(
  id: 'test-public',
  name: 'VPN Checker · RU',
  description:
      'Публичный список. Последний резерв после ваших подписок; доступность и скорость не гарантируются.',
  website: 'https://example.com/public',
);

VpnSourceInfo _source(
  String id, {
  bool public = false,
  bool active = false,
  int count = 2,
}) => VpnSourceInfo.fromJson({
  'id': id,
  'name': public ? _provider.name : 'Моя подписка',
  'kind': 'subscription',
  'public_catalog_id': public ? _provider.id : '',
  'active': active,
  'selected_node': 0,
  'node_count': count,
  'node_names': [
    for (var i = 0; i < count; i++)
      '${i == 455 ? 'Германия' : 'Сервер'} ${i + 1}',
  ],
  'last_updated': '2026-09-17 12:00:00',
});

class _SourceBridge extends MockCoreBridge {
  List<VpnSourceInfo> sources = [];
  int publicAdds = 0;
  bool consentReceived = false;
  bool throwOnPublicAdd = false;
  bool throwOnCatalog = false;

  @override
  Future<List<VpnSourceInfo>> vpnSources() async => sources;

  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async {
    if (throwOnCatalog) throw StateError('offline');
    return [_provider];
  }

  @override
  Future<Map<String, dynamic>> addPublicVpnSource(
    String id,
    bool consent,
  ) async {
    publicAdds++;
    consentReceived = consent;
    if (throwOnPublicAdd) throw StateError('Не удалось загрузить список');
    sources = [...sources, _source('free', public: true, count: 600)];
    return {'success': true};
  }
}

Future<void> _pumpEditor(
  WidgetTester tester,
  _SourceBridge bridge, {
  Size size = const Size(960, 800),
  double textScale = 1,
  GlobalKey? captureKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final editor = VpnSourcesDialog(bridge: bridge, subscription: _subscription);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF86EFAC),
          brightness: Brightness.dark,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: captureKey == null
          ? editor
          : RepaintBoundary(key: captureKey, child: editor),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (const bool.fromEnvironment('DROPO_UI_CAPTURE')) {
      await (FontLoader(
        'Inter',
      )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  testWidgets(
    'public catalog is visible without a subscription and never auto-enabled',
    (tester) async {
      final bridge = _SourceBridge();
      await _pumpEditor(tester, bridge);
      expect(find.text('Своя подписка или бесплатный резерв'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-personal-vpn')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('add-public-vpn-test-public')),
        findsOneWidget,
      );
      expect(bridge.publicAdds, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('public add requires consent and cancellation does not write', (
    tester,
  ) async {
    final bridge = _SourceBridge();
    await _pumpEditor(tester, bridge);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('add-public-vpn-test-public')),
    );
    expect(find.text('Использовать бесплатные серверы?'), findsOneWidget);
    expect(bridge.publicAdds, 0);
    await _tapVisible(tester, find.text('Отмена'));
    expect(bridge.publicAdds, 0);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('add-public-vpn-test-public')),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('public-vpn-consent')));
    expect(bridge.publicAdds, 1);
    expect(bridge.consentReceived, isTrue);
    expect(find.byKey(const ValueKey('vpn-source-free')), findsOneWidget);
    expect(find.text('Уже добавлен'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network exceptions release the busy editor and allow retry', (
    tester,
  ) async {
    final bridge = _SourceBridge()..throwOnPublicAdd = true;
    await _pumpEditor(tester, bridge);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('add-public-vpn-test-public')),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('public-vpn-consent')));
    expect(find.textContaining('Не удалось загрузить список'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('add-public-vpn-test-public')),
    );
    expect(button.onPressed, isNotNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog errors do not prevent adding a personal subscription', (
    tester,
  ) async {
    final bridge = _SourceBridge()..throwOnCatalog = true;
    await _pumpEditor(tester, bridge);
    await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
    expect(find.text('Проверить и добавить'), findsOneWidget);
    expect(find.textContaining('Каталог недоступен'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('source editor has no overflow at 960x640 scale $scale', (
      tester,
    ) async {
      final bridge = _SourceBridge()
        ..sources = [
          _source('personal', active: true),
          _source('free', public: true),
        ];
      await _pumpEditor(
        tester,
        bridge,
        size: const Size(960, 640),
        textScale: scale,
      );
      expect(find.textContaining('Используется сейчас'), findsOneWidget);
      expect(
        find.textContaining('Бесплатный · последний резерв'),
        findsOneWidget,
      );
      final up = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Выше по приоритету',
        ),
      );
      final down = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Ниже по приоритету',
        ),
      );
      expect(up.onPressed, isNull);
      expect(down.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    '600 servers use a lazy searchable picker retaining original indices',
    (tester) async {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selected = await showDialog<int>(
                    context: context,
                    builder: (context) =>
                        VpnNodePicker(source: _source('free', count: 600)),
                  );
                },
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await _tapVisible(tester, find.text('Открыть'));
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      await tester.enterText(
        find.byKey(const ValueKey('vpn-node-search')),
        'Германия',
      );
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vpn-node-455')));
      await tester.pumpAndSettle();
      expect(selected, 455);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('capture source editor previews when explicitly requested', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
    for (final configured in [false, true]) {
      final bridge = _SourceBridge();
      if (configured) {
        bridge.sources = [
          _source('personal', active: true),
          _source('free', public: true, count: 600),
        ];
      }
      final key = GlobalKey();
      await _pumpEditor(
        tester,
        bridge,
        size: const Size(1120, 980),
        captureKey: key,
      );
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('build/ui-review');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/vpn-sources-${configured ? 'configured' : 'empty'}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
