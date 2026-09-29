import 'dart:async';
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
      'Сторонний публичный список. Приоритет можно изменить; доступность и скорость не гарантируются.',
  website: 'https://example.com/public',
);

VpnSourceInfo _source(
  String id, {
  bool public = false,
  bool active = false,
  int count = 2,
  String responseState = 'unavailable',
  int? latency,
  bool disabled = false,
}) => VpnSourceInfo.fromJson({
  'id': id,
  'name': public ? _provider.name : 'Моя подписка',
  'kind': 'subscription',
  'public_catalog_id': public ? _provider.id : '',
  'active': active,
  'disabled': disabled,
  'response': {
    'state': responseState,
    'latencyMs': latency,
    'checkedAt': DateTime.now().toUtc().toIso8601String(),
  },
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
  int personalTests = 0;
  int personalAdds = 0;
  int autoSelections = 0;
  bool autoSelect = false;
  bool running = true;
  bool failMove = false;
  final List<(String, int)> nodeChanges = [];
  int removals = 0;

  @override
  Future<Map<String, dynamic>> setVpnSourceNode(String id, int node) async {
    nodeChanges.add((id, node));
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> removeVpnSource(String id) async {
    removals++;
    sources = sources.where((source) => source.id != id).toList();
    return {'success': true};
  }

  @override
  Future<VpnSourcesSnapshot> vpnSourcesSnapshot() async => VpnSourcesSnapshot(
    sources: await vpnSources(),
    autoSelect: autoSelect,
    running: running,
  );

  @override
  Future<Map<String, dynamic>> enableVpnSourceAutoSelect() async {
    autoSelections++;
    autoSelect = true;
    return {'success': true};
  }

  bool consentReceived = false;
  bool throwOnPublicAdd = false;
  bool throwOnCatalog = false;
  bool failPersonalAdd = false;
  String personalAddError = 'Источник временно недоступен';
  Completer<List<PublicVpnProviderInfo>>? pendingCatalog;
  String lastPersonalName = '';
  String lastPersonalUri = '';
  final List<(String, int)> moves = [];

  @override
  Future<Map<String, dynamic>> moveVpnSource(String id, int index) async {
    moves.add((id, index));
    if (failMove) {
      return {'success': false, 'error': 'Не удалось переключить источник'};
    }
    autoSelect = false;
    final moved = sources.firstWhere((source) => source.id == id);
    sources = [...sources.where((source) => source.id != id)]
      ..insert(index, moved);
    return {'success': true};
  }

  @override
  Future<List<VpnSourceInfo>> vpnSources() async => sources;

  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async {
    if (throwOnCatalog) throw StateError('offline');
    if (pendingCatalog case final pending?) return pending.future;
    return [_provider];
  }

  @override
  Future<Map<String, dynamic>> testSubscription(String value) async {
    personalTests++;
    return {'success': true, 'count': 3, 'proxies': const []};
  }

  @override
  Future<Map<String, dynamic>> addVpnSource(String name, String uri) async {
    personalAdds++;
    lastPersonalName = name;
    lastPersonalUri = uri;
    if (failPersonalAdd) {
      return {'success': false, 'error': personalAddError};
    }
    sources = [
      ...sources,
      VpnSourceInfo.fromJson({
        'id': 'personal-$personalAdds',
        'name': name,
        'kind': 'subscription',
        'active': false,
        'selected_node': 0,
        'node_count': 3,
        'node_names': const ['NL 1', 'DE 1', 'FI 1'],
      }),
    ];
    return {'success': true, 'sourceCount': sources.length};
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
  SubscriptionInfo subscription = _subscription,
  VoidCallback? onChanged,
  VoidCallback? onReadyToConnect,
  bool settle = true,
  bool openPersonal = false,
  bool openFree = false,
  bool embedded = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final editor = VpnSourcesDialog(
    embedded: embedded,
    bridge: bridge,
    subscription: subscription,
    onChanged: onChanged,
    onReadyToConnect: onReadyToConnect,
  );
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
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  if (openPersonal || openFree) {
    final choice = find.byKey(
      ValueKey(openPersonal ? 'choose-personal-source' : 'toggle-free-catalog'),
    );
    if (choice.evaluate().isEmpty) {
      await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
    }
    await _tapVisible(tester, choice);
  }
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'source snapshot retains mode and running state without inventing legacy values',
    () {
      final legacy = VpnSourcesSnapshot.fromJson({'sources': []});
      expect(legacy.autoSelect, isNull);
      expect(legacy.running, isNull);
      final current = VpnSourcesSnapshot.fromJson({
        'autoSelect': false,
        'running': true,
        'sources': [
          {
            'id': 'one',
            'response': {
              'state': 'ok',
              'latencyMs': 42,
              'checkedAt': DateTime.now().toUtc().toIso8601String(),
            },
          },
        ],
      });
      expect(current.autoSelect, isFalse);
      expect(current.running, isTrue);
      expect(current.sources.single.response.current, isTrue);
      expect(current.sources.single.response.label, '42 мс');
    },
  );
  testWidgets('sources lead the page and optional offers stay secondary', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..sources = [
        _source('personal', active: true, responseState: 'ok', latency: 42),
      ];
    await _pumpEditor(tester, bridge, size: const Size(820, 560));
    expect(
      find.byKey(const ValueKey('vpn-source-personal')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('Отклик · 42 мс'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('choose-vpn-node-personal')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('add-public-vpn-test-public')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('boost-preview')), findsNothing);
    await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('toggle-free-catalog')),
    );
    expect(
      find.byKey(const ValueKey('add-public-vpn-test-public')),
      findsOneWidget,
    );
    expect(bridge.publicAdds, 0);
  });

  testWidgets('selecting the first source also leaves automatic mode', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..autoSelect = true
      ..sources = [_source('one'), _source('two')];
    await _pumpEditor(tester, bridge);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('source-auto-select')))
          .selected,
      isTrue,
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('vpn-source-first-one')),
    );
    expect(bridge.moves, [('one', 0)]);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('source-manual-select')),
          )
          .selected,
      isTrue,
    );
    expect(find.text('Выбран'), findsOneWidget);
    expect(find.textContaining('Подключён сейчас'), findsNothing);
  });

  for (final state in ['pending', 'failed', 'stale', 'unavailable']) {
    testWidgets('source response $state never shows fake milliseconds', (
      tester,
    ) async {
      final bridge = _SourceBridge()
        ..sources = [_source('one', responseState: state, latency: 42)];
      await _pumpEditor(tester, bridge);
      expect(find.textContaining('42 мс'), findsNothing);
      final expected = switch (state) {
        'pending' => 'Проверяем…',
        'failed' => 'Нет ответа',
        'stale' => 'Данные устарели',
        _ => 'Нет данных',
      };
      expect(find.text('Отклик · $expected'), findsOneWidget);
    });
  }

  testWidgets('disconnected and disabled sources suppress recorded latency', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..running = false
      ..sources = [
        _source('one', responseState: 'ok', latency: 42),
        _source('two', disabled: true, responseState: 'ok', latency: 14),
      ];
    await _pumpEditor(tester, bridge);
    expect(find.text('Отклик · После подключения'), findsOneWidget);
    expect(find.text('Отклик · Выключен'), findsOneWidget);
    expect(find.textContaining('42 мс'), findsNothing);
    expect(find.textContaining('14 мс'), findsNothing);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('vpn-source-first-two')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('source page restores automatic latency choice explicitly', (
    tester,
  ) async {
    final bridge = _SourceBridge()..sources = [_source('one'), _source('two')];
    await _pumpEditor(tester, bridge);
    await _tapVisible(tester, find.byKey(const ValueKey('source-auto-select')));
    expect(bridge.autoSelections, 1);
    expect(bridge.moves, isEmpty);
    expect(find.textContaining('Автовыбор включён.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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
    'empty state offers two explicit choices and never auto-enables public sources',
    (tester) async {
      final bridge = _SourceBridge();
      await _pumpEditor(tester, bridge);
      expect(find.text('Источники VPN'), findsOneWidget);
      expect(find.text('Dropo Boost · скоро'), findsOneWidget);
      expect(find.byKey(const ValueKey('personal-vpn-uri')), findsNothing);
      expect(find.byKey(const ValueKey('submit-personal-vpn')), findsNothing);
      expect(find.byKey(const ValueKey('add-personal-vpn')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('add-public-vpn-test-public')),
        findsNothing,
      );
      expect(bridge.publicAdds, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('add action reveals the form after a long source list', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..sources = [for (var i = 0; i < 8; i++) _source('personal-$i')];
    await _pumpEditor(tester, bridge, size: const Size(820, 560));
    expect(find.byKey(const ValueKey('personal-vpn-uri')), findsNothing);
    expect(
      find.byKey(const ValueKey('add-personal-vpn')).hitTestable(),
      findsOneWidget,
    );
    await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('choose-personal-source')),
    );
    expect(
      find.byKey(const ValueKey('personal-vpn-uri')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('public add requires consent and cancellation does not write', (
    tester,
  ) async {
    final bridge = _SourceBridge();
    await _pumpEditor(tester, bridge, openFree: true);
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

  testWidgets(
    'public sources can move across personal sources and stay in requested order',
    (tester) async {
      final bridge = _SourceBridge()
        ..sources = [_source('personal'), _source('free', public: true)];
      await _pumpEditor(tester, bridge);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-first-free')),
      );
      expect(bridge.moves, [('free', 0)]);
      expect(bridge.sources.map((source) => source.id), ['free', 'personal']);
      expect(
        find.textContaining('Бесплатный · Выбран для подключения'),
        findsOneWidget,
      );
      await _tapVisible(tester, find.byKey(const ValueKey('source-order')));
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-down-free')),
      );
      expect(bridge.sources.map((source) => source.id), ['personal', 'free']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new subscription offers priority without changing saved order', (
    tester,
  ) async {
    final bridge = _SourceBridge()..sources = [_source('free', public: true)];
    await _pumpEditor(tester, bridge, openPersonal: true);
    await tester.enterText(
      find.byKey(const ValueKey('personal-vpn-uri')),
      'https://example.test/subscription',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('submit-personal-vpn')),
    );
    expect(bridge.sources.map((source) => source.id), ['free', 'personal-1']);
    expect(bridge.moves, isEmpty);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('new-source-make-primary')),
    );
    expect(bridge.sources.map((source) => source.id), ['personal-1', 'free']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('network exceptions release the busy editor and allow retry', (
    tester,
  ) async {
    final bridge = _SourceBridge()..throwOnPublicAdd = true;
    await _pumpEditor(tester, bridge, openFree: true);
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
    await _pumpEditor(tester, bridge, openPersonal: true);
    expect(find.text('Проверить и добавить'), findsOneWidget);
    expect(find.byKey(const ValueKey('personal-vpn-uri')), findsOneWidget);
    expect(find.byKey(const ValueKey('personal-vpn-uri')), findsOneWidget);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('toggle-free-catalog')),
    );
    expect(find.textContaining('Каталог недоступен'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slow optional catalog never disables personal onboarding', (
    tester,
  ) async {
    final catalog = Completer<List<PublicVpnProviderInfo>>();
    final bridge = _SourceBridge()..pendingCatalog = catalog;
    await _pumpEditor(tester, bridge, settle: false, openPersonal: true);

    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('personal-vpn-uri')),
    );
    final submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey('submit-personal-vpn')),
    );
    expect(input.enabled, isTrue);
    expect(submit.onPressed, isNotNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    catalog.complete([_provider]);
    await tester.pumpAndSettle();
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('toggle-free-catalog')),
    );
    expect(
      find.byKey(const ValueKey('add-public-vpn-test-public')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'configured personal source keeps the optional add form collapsed',
    (tester) async {
      final bridge = _SourceBridge()..sources = [_source('personal')];
      await _pumpEditor(
        tester,
        bridge,
        subscription: const SubscriptionInfo(
          hasSubscription: true,
          url: '',
          proxyCount: 2,
        ),
      );
      expect(find.byKey(const ValueKey('vpn-source-personal')), findsOneWidget);
      expect(find.byKey(const ValueKey('personal-vpn-uri')), findsNothing);
      expect(find.byKey(const ValueKey('add-personal-vpn')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsafe personal input is rejected before a bridge call', (
    tester,
  ) async {
    final bridge = _SourceBridge();
    await _pumpEditor(tester, bridge, openPersonal: true);
    final input = find.byKey(const ValueKey('personal-vpn-uri'));
    final submit = find.byKey(const ValueKey('submit-personal-vpn'));

    await _tapVisible(tester, submit);
    expect(
      find.text('Вставьте HTTPS-ссылку подписки или VPN-ключ.'),
      findsOneWidget,
    );
    expect(bridge.personalTests, 0);

    await tester.enterText(input, 'http://example.test/private-token');
    await _tapVisible(tester, submit);
    expect(
      find.textContaining('нужна корректная HTTPS-ссылка'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data?.contains('private-token') ?? false),
      ),
      findsNothing,
    );
    expect(bridge.personalTests, 0);

    await tester.enterText(input, 'https://user:secret@example.test/sub');
    await _tapVisible(tester, submit);
    expect(find.textContaining('Логин и пароль нельзя'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data?.contains('secret') ?? false),
      ),
      findsNothing,
    );
    expect(bridge.personalTests, 0);
    expect(bridge.personalAdds, 0);
  });

  testWidgets('failed personal add preserves input and succeeds on retry', (
    tester,
  ) async {
    final bridge = _SourceBridge()..failPersonalAdd = true;
    var changes = 0;
    var readyActions = 0;
    await _pumpEditor(
      tester,
      bridge,
      openPersonal: true,
      onChanged: () => changes++,
      onReadyToConnect: () => readyActions++,
    );
    final uri = find.byKey(const ValueKey('personal-vpn-uri'));
    final name = find.byKey(const ValueKey('personal-vpn-name'));
    final submit = find.byKey(const ValueKey('submit-personal-vpn'));
    await tester.enterText(uri, 'https://example.test/subscription');
    await tester.enterText(name, 'Рабочий VPN');
    await _tapVisible(tester, submit);

    expect(find.textContaining('Источник временно недоступен'), findsOneWidget);
    expect(
      tester.widget<TextField>(uri).controller?.text,
      contains('example.test'),
    );
    expect(tester.widget<TextField>(name).controller?.text, 'Рабочий VPN');
    expect(bridge.personalTests, 1);
    expect(bridge.personalAdds, 1);
    expect(changes, 0);
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);

    bridge.failPersonalAdd = false;
    await _tapVisible(tester, submit);
    expect(bridge.personalTests, 2);
    expect(bridge.personalAdds, 2);
    expect(changes, 1);
    expect(
      find.text('3 сервера добавлено. Можно подключаться.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('vpn-source-personal-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('personal-vpn-uri')), findsNothing);
    expect(
      find.byKey(const ValueKey('onboarding-ready-connect')),
      findsOneWidget,
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('onboarding-ready-connect')),
    );
    expect(readyActions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android subscription errors are localized without wrappers', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..failPersonalAdd = true
      ..personalAddError =
          'VPN subscription could not be downloaded or contains no supported Android servers';
    await _pumpEditor(tester, bridge, openPersonal: true);
    await tester.enterText(
      find.byKey(const ValueKey('personal-vpn-uri')),
      'https://example.test/subscription',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('submit-personal-vpn')),
    );

    expect(
      find.text(
        'Не удалось загрузить подписку или в ней нет поддерживаемых серверов для Android.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Bad state:'), findsNothing);
    expect(find.textContaining('could not be downloaded'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android uses an honest single-subscription editor', (
    tester,
  ) async {
    debugMobileShellOverride = true;
    addTearDown(() => debugMobileShellOverride = null);
    final bridge = _SourceBridge()..sources = [_source('personal', count: 4)];
    await _pumpEditor(
      tester,
      bridge,
      size: const Size(390, 844),
      subscription: const SubscriptionInfo(
        hasSubscription: true,
        url: '',
        proxyCount: 4,
      ),
    );

    expect(find.text('Источники VPN'), findsOneWidget);
    expect(find.textContaining('одна активная подписка'), findsOneWidget);
    expect(find.textContaining('4 сервера'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(
      find.byKey(const ValueKey('choose-vpn-node-personal')),
      findsNothing,
    );
    expect(find.text('Обновить списки'), findsNothing);
    await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('choose-personal-source')),
    );
    expect(find.text('Проверить и заменить'), findsOneWidget);
    expect(find.byKey(const ValueKey('personal-vpn-name')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in [const Size(390, 844), const Size(320, 568)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'empty onboarding fits ${viewport.width.toInt()}x${viewport.height.toInt()} at $scale',
        (tester) async {
          debugMobileShellOverride = true;
          addTearDown(() => debugMobileShellOverride = null);
          await _pumpEditor(
            tester,
            _SourceBridge(),
            size: viewport,
            textScale: scale,
            openPersonal: true,
          );
          final input = find.byKey(const ValueKey('personal-vpn-uri'));
          final submit = find.byKey(const ValueKey('submit-personal-vpn'));
          await tester.ensureVisible(input);
          await tester.ensureVisible(submit);
          expect(
            tester.getSize(input).width,
            lessThanOrEqualTo(viewport.width),
          );
          expect(tester.getSize(submit).height, greaterThanOrEqualTo(48));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
      expect(find.textContaining('Подключён сейчас'), findsOneWidget);
      expect(find.textContaining('Бесплатный · Резервный'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const ValueKey('source-order')));
      final up = tester.widget<TextButton>(
        find.byKey(const ValueKey('vpn-source-up-personal')),
      );
      final down = tester.widget<TextButton>(
        find.byKey(const ValueKey('vpn-source-down-personal')),
      );
      expect(up.onPressed, isNull);
      expect(down.onPressed, isNotNull);
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

  testWidgets('add stays reachable after scrolling a long embedded list', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..sources = [for (var i = 0; i < 20; i++) _source('long-$i')];
    await _pumpEditor(
      tester,
      bridge,
      embedded: true,
      size: const Size(820, 560),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('vpn-source-long-19')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('add-personal-vpn')).hitTestable(),
      findsOneWidget,
    );
    await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
    expect(
      find.byKey(const ValueKey('choose-personal-source')).hitTestable(),
      findsOneWidget,
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('choose-personal-source')),
    );
    expect(
      find.byKey(const ValueKey('personal-vpn-uri')).hitTestable(),
      findsOneWidget,
    );
    expect(bridge.moves, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual mode skips disabled sources and preserves enabled fallback order',
    (tester) async {
      final bridge = _SourceBridge()
        ..autoSelect = true
        ..sources = [
          _source('disabled', disabled: true),
          _source('one'),
          _source('two'),
        ];
      await _pumpEditor(tester, bridge);
      expect(find.byKey(const ValueKey('source-order')), findsNothing);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-manual-select')),
      );
      expect(bridge.moves, [('one', 0)]);
      expect(bridge.sources.map((s) => s.id), ['one', 'disabled', 'two']);
      expect(find.textContaining('Выбран для подключения'), findsOneWidget);
      expect(find.byKey(const ValueKey('source-order')), findsOneWidget);
    },
  );

  testWidgets('failed manual selection leaves automatic choice selected', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..autoSelect = true
      ..failMove = true
      ..sources = [_source('one')];
    await _pumpEditor(tester, bridge);
    expect(find.text('Выбрать вручную'), findsOneWidget);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('vpn-source-first-one')),
    );
    expect(bridge.autoSelect, isTrue);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('source-auto-select')))
          .selected,
      isTrue,
    );
    expect(
      find.textContaining('Не удалось переключить источник'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets(
    'details and cancelled server selection do not mutate the source',
    (tester) async {
      final bridge = _SourceBridge()
        ..autoSelect = true
        ..sources = [_source('one')];
      await _pumpEditor(tester, bridge);
      await _tapVisible(
        tester,
        find.byKey(const PageStorageKey('source-details-one')),
      );
      expect(find.text('Удалить источник'), findsOneWidget);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-one')),
      );
      await _tapVisible(tester, find.text('Отмена'));
      expect(bridge.moves, isEmpty);
      expect(bridge.nodeChanges, isEmpty);
      expect(bridge.autoSelect, isTrue);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-one')),
      );
      await _tapVisible(tester, find.byKey(const ValueKey('vpn-node-1')));
      expect(bridge.nodeChanges, [('one', 1)]);
      expect(bridge.moves, isEmpty);
    },
  );

  testWidgets(
    'remove remains explicit and cancelling it preserves the source',
    (tester) async {
      final bridge = _SourceBridge()..sources = [_source('one')];
      await _pumpEditor(tester, bridge);
      await _tapVisible(
        tester,
        find.byKey(const PageStorageKey('source-details-one')),
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('remove-source-one')),
      );
      await _tapVisible(tester, find.text('Отмена'));
      expect(bridge.removals, 0);
      expect(bridge.sources.length, 1);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('remove-source-one')),
      );
      await _tapVisible(tester, find.text('Удалить'));
      expect(bridge.removals, 1);
      expect(find.text('Добавьте первый источник'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('choose-personal-source')),
        findsOneWidget,
      );
    },
  );

  testWidgets('offline active flag cannot claim a connected source', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..running = false
      ..sources = [_source('one', active: true)];
    await _pumpEditor(tester, bridge);
    expect(find.textContaining('Подключён сейчас'), findsNothing);
    expect(find.textContaining('Выбран для подключения'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-order')), findsNothing);
  });

  testWidgets(
    'manual primary is first enabled even when a disabled entry is first',
    (tester) async {
      final bridge = _SourceBridge()
        ..sources = [
          _source('off', disabled: true),
          _source('main'),
          _source('fallback', active: true),
        ];
      await _pumpEditor(tester, bridge);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('vpn-source-main')),
          matching: find.textContaining('Выбран для подключения'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('vpn-source-fallback')),
          matching: find.textContaining('Подключён сейчас'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('vpn-source-first-main')),
            )
            .onPressed,
        isNull,
      );
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
        const captureDirectory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
        if (captureDirectory.isEmpty) {
          throw StateError('Set an external capture directory');
        }
        final directory = Directory(captureDirectory);
        await directory.create(recursive: true);
        await File(
          '${directory.path}/vpn-sources-${configured ? 'configured' : 'empty'}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
