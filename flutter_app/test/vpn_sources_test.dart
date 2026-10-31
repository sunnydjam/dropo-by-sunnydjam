import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'navigation_helpers.dart';

const _subscription = SubscriptionInfo(
  hasSubscription: false,
  url: '',
  proxyCount: 0,
);
const _provider = PublicVpnProviderInfo(
  id: 'test-public',
  name: 'Dropo Free',
  description:
      'Бесплатная подписка Dropo. Приоритет можно изменить; доступность и скорость не гарантируются.',
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
  int selectedNode = 0,
  String lastError = '',
  bool usingCache = false,
  List<String> favorites = const [],
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
  'selected_node': selectedNode,
  'last_error': lastError,
  'using_cache': usingCache,
  'node_count': count,
  'node_names': [
    for (var i = 0; i < count; i++)
      '${i == 455 ? 'Германия' : 'Сервер'} ${i + 1}',
  ],
  'node_ids': [for (var i = 0; i < count; i++) '$id-stable-$i'],
  'favorite_node_ids': favorites,
  'last_updated': '2026-09-17 12:00:00',
});

class _SourceBridge extends MockCoreBridge {
  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
  };
  @override
  Future<CoreStatus> status() async =>
      (await super.status()).copyWith(connected: running, running: running);
  List<VpnSourceInfo> sources = [];
  int publicAdds = 0;
  int personalTests = 0;
  int personalAdds = 0;
  int autoSelections = 0;
  bool autoSelect = false;
  bool running = true;
  bool androidSourceCapabilities = false;
  bool failMove = false;
  bool failSnapshot = false;
  bool failFavorite = false;
  String favoriteError = 'metadata unavailable';
  int refreshes = 0;
  final List<(String, String)> renames = [];
  final List<(String, String, bool)> favoriteChanges = [];
  final List<(String, int)> nodeChanges = [];
  int removals = 0;

  @override
  Future<Map<String, dynamic>> setVpnSourceNode(String id, int node) async {
    nodeChanges.add((id, node));
    sources = sources
        .map(
          (source) => source.id == id
              ? _copySource(source, selectedNode: node)
              : source,
        )
        .toList();
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<Object?> args = const [],
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (method == 'SetVPNSourceNodeByID') {
      final source = sources.firstWhere((source) => source.id == args[0]);
      final index = source.nodeIds.indexOf(args[1] as String);
      if (index < 0) {
        return {'success': false, 'error': 'node no longer exists'};
      }
      return setVpnSourceNode(args[0] as String, index);
    }
    if (method == 'RenameVPNSource') {
      renames.add((args[0] as String, args[1] as String));
      sources = sources
          .map(
            (source) => source.id == args[0]
                ? _copySource(source, name: args[1] as String)
                : source,
          )
          .toList();
      return {'success': true};
    }
    if (method == 'SetVPNSourceNodeFavorite') {
      favoriteChanges.add((
        args[0] as String,
        args[1] as String,
        args[2] as bool,
      ));
      if (failFavorite) {
        return {'success': false, 'error': favoriteError};
      }
      sources = sources.map((source) {
        if (source.id != args[0]) return source;
        final favorites = source.favoriteNodeIds.toSet();
        if (args[2] == true) {
          favorites.add(args[1] as String);
        } else {
          favorites.remove(args[1]);
        }
        return _copySource(source, favorites: favorites.toList());
      }).toList();
      return {'success': true};
    }
    return super.callMap(method, args: args, timeout: timeout);
  }

  @override
  Future<Map<String, dynamic>> refreshVpnSources() async {
    refreshes++;
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> removeVpnSource(String id) async {
    removals++;
    sources = sources.where((source) => source.id != id).toList();
    return {'success': true};
  }

  @override
  Future<VpnSourcesSnapshot> vpnSourcesSnapshot() async {
    if (failSnapshot) {
      throw StateError('https://provider.invalid/sub/private-credential');
    }
    return VpnSourcesSnapshot(
      sources: await vpnSources(),
      autoSelect: autoSelect,
      running: running,
      autoSelectSupported: !androidSourceCapabilities,
      fallbackSupported: !androidSourceCapabilities,
    );
  }

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
  bool enabled = true,
  bool? connected,
  VpnSourcesSnapshot? sourceSnapshot,
  Future<Map<String, dynamic>> Function(
    Future<Map<String, dynamic>> Function(),
  )?
  onApplyChange,
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
    enabled: enabled,
    sourceSnapshot: sourceSnapshot,
    onApplyChange: onApplyChange,
    connected: connected,
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
        child: captureKey == null
            ? child!
            : RepaintBoundary(key: captureKey, child: child!),
      ),
      home: editor,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  if (openPersonal || openFree && bridge.sources.isNotEmpty) {
    await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
  }
}

VpnSourceInfo _copySource(
  VpnSourceInfo source, {
  String? name,
  int? selectedNode,
  List<String>? favorites,
  List<String>? nodeIds,
  List<String>? nodeNames,
}) => VpnSourceInfo(
  id: source.id,
  name: name ?? source.name,
  kind: source.kind,
  disabled: source.disabled,
  selectedNode: selectedNode ?? source.selectedNode,
  nodeCount: source.nodeCount,
  nodeNames: nodeNames ?? source.nodeNames,
  nodeIds: nodeIds ?? source.nodeIds,
  favoriteNodeIds: favorites ?? source.favoriteNodeIds,
  lastUpdated: source.lastUpdated,
  lastError: source.lastError,
  usingCache: source.usingCache,
  active: source.active,
  publicCatalogId: source.publicCatalogId,
  response: source.response,
);

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
      if (Platform.isWindows) {
        // Headless captures cannot discover the system monospace family.
        final file = File('C:/Windows/Fonts/consola.ttf');
        if (await file.exists()) {
          await (FontLoader(
            'monospace',
          )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
        }
      }
    }
  });

  test(
    'unknown legacy snapshot never invents running state or automatic choice',
    () {
      final legacy = VpnSourcesSnapshot.fromJson({'sources': []});
      expect(legacy.autoSelect, isNull);
      expect(legacy.running, isNull);
      final current = VpnSourcesSnapshot.fromJson({
        'autoSelect': false,
        'running': true,
        'sources': [],
      });
      expect(current.autoSelect, false);
      expect(current.running, true);
    },
  );

  testWidgets(
    'source list has one auto choice and explicit subscription choices',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..autoSelect = true
        ..sources = [_source('one'), _source('two')];
      await _pumpEditor(tester, bridge);
      expect(find.byKey(const ValueKey('source-manual-select')), findsNothing);
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('source-auto-select')))
            .onTap,
        isNull,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-first-two')),
      );
      expect(bridge.moves, [('two', 0)]);
      expect(bridge.autoSelect, false);
      expect(bridge.sources.map((source) => source.id), ['two', 'one']);
      expect(find.text('Выбран для подключения'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('source-auto-select')))
            .onTap,
        isNotNull,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-auto-select')),
      );
      expect(bridge.autoSelections, 1);
      expect(bridge.autoSelect, true);
    },
  );

  testWidgets(
    'connected source choice previews, cancellation never mutates or reconnects',
    (tester) async {
      final bridge = _SourceBridge()
        ..autoSelect = true
        ..sources = [_source('one', active: true), _source('two')];
      var apply = 0;
      await _pumpEditor(
        tester,
        bridge,
        onApplyChange: (operation) async {
          apply++;
          return operation();
        },
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-first-two')),
      );
      expect(
        find.byKey(const ValueKey('source-reconnect-confirm')),
        findsOneWidget,
      );
      expect(bridge.moves, isEmpty);
      expect(apply, 0);
      await _tapVisible(tester, find.text('Отмена'));
      expect(bridge.moves, isEmpty);
      expect(bridge.autoSelect, true);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-first-two')),
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-reconnect-confirm')),
      );
      expect(apply, 1);
      expect(bridge.moves, [('two', 0)]);
    },
  );

  testWidgets(
    'failed manual choice keeps automatic selection and releases controls',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..autoSelect = true
        ..failMove = true
        ..sources = [_source('one')];
      await _pumpEditor(tester, bridge);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-first-one')),
      );
      expect(bridge.autoSelect, true);
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('source-auto-select')))
            .onTap,
        isNull,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Не удалось'), findsOneWidget);
    },
  );

  testWidgets(
    'reconnect wrapper actionable error is shown without an operation',
    (tester) async {
      final bridge = _SourceBridge()
        ..autoSelect = true
        ..sources = [_source('one')];
      await _pumpEditor(
        tester,
        bridge,
        onApplyChange: (_) async => {
          'success': false,
          'userMessage': 'Отключите постоянный VPN в настройках Android.',
        },
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-first-one')),
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-reconnect-confirm')),
      );
      expect(bridge.moves, isEmpty);
      expect(
        find.text('Отключите постоянный VPN в настройках Android.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'snapshot loss disables changes and redacts private source errors',
    (tester) async {
      final bridge = _SourceBridge()
        ..failSnapshot = true
        ..sources = [_source('one')];
      await _pumpEditor(tester, bridge);
      expect(find.textContaining('private-credential'), findsNothing);
      expect(find.text('Повторить загрузку источников'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const ValueKey('add-personal-vpn')));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('submit-personal-vpn')),
            )
            .onPressed,
        isNull,
      );
      expect(bridge.personalAdds, 0);
      bridge.failSnapshot = false;
      await _tapVisible(tester, find.text('Повторить загрузку источников'));
      expect(find.byKey(const ValueKey('vpn-source-one')), findsOneWidget);
    },
  );

  for (final state in ['pending', 'failed', 'stale', 'unavailable']) {
    testWidgets('source response $state never displays invented milliseconds', (
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

  testWidgets(
    'disconnected, disabled and stale active sources do not claim connectivity',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..sources = [
          _source('one', active: true, responseState: 'ok', latency: 42),
          _source('two', disabled: true, responseState: 'ok', latency: 7),
        ];
      await _pumpEditor(tester, bridge);
      expect(find.text('Отклик · После подключения'), findsOneWidget);
      expect(find.text('Отклик · Выключен'), findsOneWidget);
      expect(find.text('Подключён сейчас'), findsNothing);
      expect(find.textContaining('42 мс'), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('vpn-source-first-two')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('active fallback and next manual primary are distinct', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..sources = [
        _source('disabled', disabled: true),
        _source('main'),
        _source('backup', active: true),
      ];
    await _pumpEditor(tester, bridge);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('vpn-source-main')),
        matching: find.text('Выбран для следующего подключения'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('vpn-source-backup')),
        matching: find.text('Подключён сейчас'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('add opens the URL directly and optional name stays secondary', (
    tester,
  ) async {
    final bridge = _SourceBridge()..running = false;
    await _pumpEditor(tester, bridge, openPersonal: true);
    expect(find.byKey(const ValueKey('personal-vpn-uri')), findsOneWidget);
    expect(find.byKey(const ValueKey('personal-vpn-name')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('personal-vpn-uri')),
      'https://example.com/sub',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('source-optional-name')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('personal-vpn-name')),
      'Рабочая подписка',
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('submit-personal-vpn')),
    );
    expect(bridge.personalTests, 1);
    expect(bridge.personalAdds, 1);
    expect(bridge.lastPersonalName, 'Рабочая подписка');
    expect(find.byKey(const ValueKey('personal-vpn-uri')), findsNothing);
  });

  testWidgets(
    'adding never silently switches away from current source or auto mode',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..autoSelect = true
        ..sources = [_source('existing')];
      await _pumpEditor(tester, bridge, openPersonal: true);
      await tester.enterText(
        find.byKey(const ValueKey('personal-vpn-uri')),
        'https://example.com/sub',
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('submit-personal-vpn')),
      );
      expect(bridge.moves, isEmpty);
      expect(bridge.sources.first.id, 'existing');
      expect(bridge.autoSelect, true);
      expect(find.text('Использовать новую подписку'), findsOneWidget);
    },
  );

  testWidgets('Dropo Free is one explicit action with required consent', (
    tester,
  ) async {
    final bridge = _SourceBridge()..running = false;
    await _pumpEditor(tester, bridge);
    expect(find.text('Добавить Dropo Free'), findsOneWidget);
    expect(find.text('Бесплатные источники'), findsNothing);
    expect(bridge.publicAdds, 0);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('add-public-vpn-test-public')),
    );
    await _tapVisible(tester, find.text('Отмена'));
    expect(bridge.publicAdds, 0);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('add-public-vpn-test-public')),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('public-vpn-consent')));
    expect(bridge.publicAdds, 1);
    expect(bridge.consentReceived, true);
    expect(bridge.moves, isEmpty);
  });

  testWidgets(
    'slow or failed optional catalog does not block personal subscription',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..pendingCatalog = Completer<List<PublicVpnProviderInfo>>();
      await _pumpEditor(tester, bridge, openPersonal: true);
      await tester.enterText(
        find.byKey(const ValueKey('personal-vpn-uri')),
        'https://example.com/sub',
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('submit-personal-vpn')),
      );
      expect(bridge.personalAdds, 1);
      bridge.pendingCatalog!.completeError(StateError('unavailable'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final input in [
    '',
    'http://example.com/sub',
    'file:///private.txt',
    'https://user:password@example.com/sub',
  ]) {
    testWidgets(
      'unsafe source is rejected locally: ${input.split(':').first}',
      (tester) async {
        final bridge = _SourceBridge()..running = false;
        await _pumpEditor(tester, bridge, openPersonal: true);
        await tester.enterText(
          find.byKey(const ValueKey('personal-vpn-uri')),
          input,
        );
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('submit-personal-vpn')),
        );
        expect(bridge.personalTests, 0);
        expect(bridge.personalAdds, 0);
      },
    );
  }

  testWidgets(
    'failed add redacts provider URL and preserves entered link for retry',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..failPersonalAdd = true
        ..personalAddError =
            'GET https://provider.example/sub/private-key failed';
      await _pumpEditor(tester, bridge, openPersonal: true);
      await tester.enterText(
        find.byKey(const ValueKey('personal-vpn-uri')),
        'https://example.com/sub',
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('submit-personal-vpn')),
      );
      expect(find.textContaining('private-key'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('personal-vpn-uri')))
            .controller!
            .text,
        'https://example.com/sub',
      );
      bridge.failPersonalAdd = false;
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('submit-personal-vpn')),
      );
      expect(bridge.personalAdds, 2);
    },
  );

  testWidgets(
    'one valid node has no redundant picker while missing node can recover',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..sources = [_source('one', count: 1)];
      await _pumpEditor(tester, bridge);
      expect(find.byKey(const ValueKey('choose-vpn-node-one')), findsNothing);
      expect(find.textContaining('единственный сервер'), findsOneWidget);
      bridge.sources = [
        _source(
          'one',
          count: 1,
          selectedNode: -1,
          lastError: 'Выбранный сервер исчез из подписки.',
        ),
      ];
      await _pumpEditor(
        tester,
        bridge,
        sourceSnapshot: await bridge.vpnSourcesSnapshot(),
      );
      expect(
        find.textContaining('Выбранного сервера больше нет'),
        findsOneWidget,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-recover-one')),
      );
      expect(bridge.nodeChanges, [('one', 0)]);
      expect(find.byType(VpnNodePicker), findsNothing);
    },
  );

  testWidgets(
    'Android connected users can browse and favorite without reconnecting',
    (tester) async {
      debugMobileShellOverride = true;
      addTearDown(() => debugMobileShellOverride = null);
      final bridge = _SourceBridge()
        ..autoSelect = true
        ..sources = [_source('one', active: true, count: 4)];
      var apply = 0;
      await _pumpEditor(
        tester,
        bridge,
        size: const Size(390, 844),
        onApplyChange: (op) async {
          apply++;
          return op();
        },
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-one')),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('vpn-node-search')))
            .autofocus,
        false,
      );
      expect(tester.testTextInput.isVisible, false);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-node-favorite-one-stable-2')),
      );
      expect(bridge.favoriteChanges, [('one', 'one-stable-2', true)]);
      expect(bridge.sources.single.favoriteNodeIds, ['one-stable-2']);
      expect(apply, 0);
      expect(bridge.nodeChanges, isEmpty);
      expect(bridge.moves, isEmpty);
      await _tapVisible(tester, find.byKey(const ValueKey('vpn-node-close')));
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-one')),
      );
      expect(find.text('Избранное'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('vpn-node-2'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('vpn-node-1'))).dy,
        ),
      );
      await _tapVisible(tester, find.byKey(const ValueKey('vpn-node-1')));
      expect(bridge.nodeChanges, isEmpty);
      expect(apply, 0);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-reconnect-confirm')),
      );
      expect(bridge.nodeChanges, [('one', 1)]);
      expect(apply, 1);
      expect(bridge.autoSelect, true);
    },
  );

  testWidgets('rename is metadata only and preserves selected server', (
    tester,
  ) async {
    final bridge = _SourceBridge()..sources = [_source('one', selectedNode: 1)];
    var apply = 0;
    await _pumpEditor(
      tester,
      bridge,
      onApplyChange: (op) async {
        apply++;
        return op();
      },
    );
    await _tapVisible(
      tester,
      find.byKey(const PageStorageKey('source-details-one')),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('rename-source-one')));
    await tester.enterText(
      find.byKey(const ValueKey('source-rename-input')),
      'Домашний',
    );
    await _tapVisible(tester, find.byKey(const ValueKey('source-rename-save')));
    expect(bridge.renames, [('one', 'Домашний')]);
    expect(bridge.sources.single.selectedNode, 1);
    expect(apply, 0);
    expect(bridge.refreshes, 0);
    expect(
      find.byKey(const ValueKey('source-reconnect-confirm')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '600-node search keeps original index and currently chosen node first',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..autoSelect = true
        ..sources = [
          _source(
            'one',
            count: 600,
            selectedNode: 455,
            favorites: ['one-stable-5'],
          ),
        ];
      await _pumpEditor(tester, bridge);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-one')),
      );
      expect(find.byType(ListTile).evaluate().length, lessThan(30));
      expect(
        find.byKey(const ValueKey('vpn-node-455')).hitTestable(),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('vpn-node-search')),
        'Сервер 9',
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.byKey(const ValueKey('vpn-node-8')));
      expect(bridge.nodeChanges, [('one', 8)]);
      expect(bridge.autoSelect, true);
      expect(bridge.moves, isEmpty);
    },
  );

  testWidgets('failed favorite does not show an unsaved star', (tester) async {
    final bridge = _SourceBridge()
      ..failFavorite = true
      ..sources = [_source('one')];
    await _pumpEditor(tester, bridge);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('choose-vpn-node-one')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('vpn-node-favorite-one-stable-1')),
    );
    expect(bridge.sources.single.favoriteNodeIds, isEmpty);
    expect(find.text('Избранное'), findsNothing);
    expect(
      find.textContaining('Не удалось сохранить избранное'),
      findsOneWidget,
    );
  });

  testWidgets('remove needs explicit confirmation and cancel retains data', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..running = false
      ..sources = [_source('one')];
    await _pumpEditor(tester, bridge);
    await _tapVisible(
      tester,
      find.byKey(const PageStorageKey('source-details-one')),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('remove-source-one')));
    await _tapVisible(tester, find.text('Отмена'));
    expect(bridge.removals, 0);
    await _tapVisible(tester, find.byKey(const ValueKey('remove-source-one')));
    await _tapVisible(tester, find.widgetWithText(TextButton, 'Удалить').last);
    expect(bridge.removals, 1);
    expect(bridge.sources, isEmpty);
  });

  testWidgets('reserve reordering stays separate from favorite servers', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..running = false
      ..sources = [_source('one'), _source('two'), _source('three')];
    await _pumpEditor(tester, bridge);
    await _tapVisible(
      tester,
      find.byKey(const PageStorageKey('source-details-one')),
    );
    await _tapVisible(tester, find.byKey(const ValueKey('source-order')));
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('vpn-source-up-three')),
    );
    expect(bridge.moves, [('three', 1)]);
    expect(bridge.sources.map((source) => source.id), ['one', 'three', 'two']);
    expect(bridge.favoriteChanges, isEmpty);
  });

  testWidgets(
    'live connected state requires confirmation despite stale stopped snapshot',
    (tester) async {
      final bridge = _SourceBridge()
        ..running = false
        ..sources = [_source('one'), _source('two')];
      var applies = 0;
      await _pumpEditor(
        tester,
        bridge,
        connected: true,
        onApplyChange: (operation) async {
          applies++;
          return operation();
        },
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('vpn-source-first-two')),
      );
      expect(
        find.byKey(const ValueKey('source-reconnect-confirm')),
        findsOneWidget,
      );
      expect(applies, 0);
      expect(bridge.moves, isEmpty);
    },
  );

  testWidgets(
    'deleting last Android source warns VPN stays off and preserves helper success message',
    (tester) async {
      debugAndroidPlatformOverride = true;
      addTearDown(() => debugAndroidPlatformOverride = null);
      final bridge = _SourceBridge()..sources = [_source('one')];
      var applies = 0;
      const message =
          'Изменения сохранены. VPN отключён: нет включённых источников.';
      await _pumpEditor(
        tester,
        bridge,
        onApplyChange: (operation) async {
          applies++;
          await operation();
          bridge.running = false;
          return {
            'success': true,
            'noEnabledSources': true,
            'userMessage': message,
          };
        },
      );
      await _tapVisible(
        tester,
        find.byKey(const PageStorageKey('source-details-one')),
      );
      Future<void> requestDelete() async {
        await _tapVisible(
          tester,
          find.byKey(const ValueKey('remove-source-one')),
        );
        await _tapVisible(
          tester,
          find.widgetWithText(TextButton, 'Удалить').last,
        );
      }

      await requestDelete();
      expect(find.text('Отключить VPN'), findsOneWidget);
      expect(find.textContaining('останется выключенным'), findsOneWidget);
      expect(find.text('Переподключить'), findsNothing);
      expect(applies, 0);
      expect(bridge.removals, 0);
      await _tapVisible(tester, find.text('Отмена'));
      expect(bridge.sources, hasLength(1));
      await requestDelete();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-reconnect-confirm')),
      );
      expect(applies, 1);
      expect(bridge.removals, 1);
      expect(find.text(message), findsOneWidget);
      expect(bridge.running, false);
    },
  );

  testWidgets('favorite limit explains recovery inside the picker', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..failFavorite = true
      ..favoriteError =
          'В одном источнике можно сохранить до 64 избранных серверов.'
      ..sources = [_source('one')];
    await _pumpEditor(tester, bridge);
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('choose-vpn-node-one')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('vpn-node-favorite-one-stable-1')),
    );
    expect(
      find.descendant(
        of: find.byType(VpnNodePicker),
        matching: find.textContaining('64 избранных серверов'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(VpnNodePicker),
        matching: find.textContaining('Уберите ненужный сервер'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('restart failure reloads the already saved source selection', (
    tester,
  ) async {
    final bridge = _SourceBridge()
      ..autoSelect = true
      ..sources = [_source('one'), _source('two')];
    var changes = 0;
    await _pumpEditor(
      tester,
      bridge,
      onChanged: () => changes++,
      onApplyChange: (operation) async {
        await operation();
        bridge.running = false;
        return {
          'success': false,
          'userMessage': 'Подписка сохранена. Не удалось подключиться.',
        };
      },
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('vpn-source-first-two')),
    );
    await _tapVisible(
      tester,
      find.byKey(const ValueKey('source-reconnect-confirm')),
    );
    expect(bridge.sources.first.id, 'two');
    expect(changes, 1);
    expect(find.text('Выбран для подключения'), findsOneWidget);
    expect(
      find.text('Подписка сохранена. Не удалось подключиться.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('source-auto-select')))
          .onTap,
      isNotNull,
    );
  });

  testWidgets(
    'node selection retains stable ID through stop and pending-node reorder',
    (tester) async {
      final bridge = _SourceBridge()
        ..autoSelect = true
        ..sources = [_source('one')];
      await _pumpEditor(
        tester,
        bridge,
        onApplyChange: (operation) async {
          bridge.sources = [
            _copySource(
              bridge.sources.single,
              nodeIds: ['one-stable-1', 'one-stable-0'],
              nodeNames: ['Сервер 2', 'Сервер 1'],
            ),
          ];
          return operation();
        },
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-one')),
      );
      await _tapVisible(tester, find.byKey(const ValueKey('vpn-node-1')));
      expect(bridge.nodeChanges, isEmpty);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('source-reconnect-confirm')),
      );
      expect(bridge.nodeChanges, [('one', 0)]);
      expect(
        bridge.sources.single.nodeIds[bridge.sources.single.selectedNode],
        'one-stable-1',
      );
      expect(bridge.autoSelect, true);
    },
  );

  testWidgets(
    'legacy nodes without stable IDs never guess an index or disconnect',
    (tester) async {
      final bridge = _SourceBridge()
        ..sources = [_copySource(_source('one'), nodeIds: [])];
      var applies = 0;
      await _pumpEditor(
        tester,
        bridge,
        onApplyChange: (operation) async {
          applies++;
          return operation();
        },
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-one')),
      );
      await _tapVisible(tester, find.byKey(const ValueKey('vpn-node-1')));
      expect(applies, 0);
      expect(bridge.nodeChanges, isEmpty);
      expect(find.textContaining('Обновите список подписок'), findsOneWidget);
    },
  );

  for (final viewport in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(960, 640),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'source editor, direct add and server picker fit $viewport scale $scale',
        (tester) async {
          debugMobileShellOverride = viewport.width < 600;
          addTearDown(() => debugMobileShellOverride = null);
          final bridge = _SourceBridge()
            ..running = false
            ..sources = [_source('one', count: 600), _source('two')];
          await _pumpEditor(tester, bridge, size: viewport, textScale: scale);
          expect(tester.takeException(), isNull);
          await _tapVisible(
            tester,
            find.byKey(const ValueKey('add-personal-vpn')),
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('submit-personal-vpn')),
          );
          expect(tester.takeException(), isNull);
          await _tapVisible(
            tester,
            find.byKey(const ValueKey('add-personal-vpn')),
          );
          await _tapVisible(
            tester,
            find.byKey(const ValueKey('choose-vpn-node-one')),
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('vpn-node-search')));
          tester.view.viewInsets = FakeViewPadding(
            bottom: viewport.width < 600 ? 220 : 0,
          );
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.enterText(
            find.byKey(const ValueKey('vpn-node-search')),
            'Германия',
          );
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byKey(const ValueKey('vpn-node-list'))).height,
            greaterThan(40),
            reason: 'Search results must remain visible with the keyboard open',
          );
          expect(find.byKey(const ValueKey('vpn-node-455')), findsOneWidget);
        },
      );
    }
  }

  testWidgets('capture source editor previews when explicitly requested', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('DROPO_UI_CAPTURE')) return;
    const directory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
    if (directory.isEmpty) {
      throw StateError('Set an external capture directory');
    }
    Future<void> capture(GlobalKey key, String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File(
          '$directory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final size in [const Size(1120, 800), const Size(390, 844)]) {
      debugMobileShellOverride = size.width < 600;
      final bridge = _SourceBridge()
        ..running = true
        ..autoSelect = true
        ..sources = [
          _source(
            'personal',
            active: true,
            responseState: 'ok',
            latency: 42,
            count: 6,
            selectedNode: 2,
            favorites: ['personal-stable-4'],
          ),
          _source('free', public: true, count: 20),
        ];
      final key = GlobalKey();
      await _pumpEditor(tester, bridge, size: size, captureKey: key);
      await capture(key, 'sources-${size.width.toInt()}-dialog');
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('choose-vpn-node-personal')),
      );
      await capture(key, 'sources-${size.width.toInt()}-picker');
      await tester.enterText(
        find.byKey(const ValueKey('vpn-node-search')),
        'Сервер 5',
      );
      await tester.pumpAndSettle();
      await capture(key, 'sources-${size.width.toInt()}-search');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final shellKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF36D399),
              brightness: Brightness.dark,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: RepaintBoundary(key: shellKey, child: child!),
          ),
          home: DropoHomePage(bridge: bridge),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await openSection(tester, 'sources');
      await tester.pump(const Duration(milliseconds: 500));
      await capture(shellKey, 'sources-${size.width.toInt()}-embedded');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    debugMobileShellOverride = null;
  });
}
