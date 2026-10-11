import 'dart:async';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _freeProvider = PublicVpnProviderInfo(
  id: 'dropo-free',
  name: 'Dropo Free',
  description: '',
  website: '',
);

class _OnboardingBridge extends MockCoreBridge {
  int catalogReads = 0;
  int freeImports = 0;
  bool? acceptedConsent;
  bool failCatalog = false;
  bool failImport = false;
  Completer<List<PublicVpnProviderInfo>>? pendingCatalog;
  Completer<Map<String, dynamic>>? pendingImport;

  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async {
    catalogReads++;
    if (pendingCatalog != null) return pendingCatalog!.future;
    if (failCatalog) throw StateError('offline');
    return const [_freeProvider];
  }

  @override
  Future<Map<String, dynamic>> addPublicVpnSource(
    String id,
    bool consent,
  ) async {
    freeImports++;
    acceptedConsent = consent;
    expect(id, 'dropo-free');
    if (pendingImport != null) return pendingImport!.future;
    return failImport
        ? {'success': false, 'error': 'Dropo Free временно недоступен'}
        : {'success': true};
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _show(
  WidgetTester tester,
  _OnboardingBridge bridge, {
  bool disabledSources = false,
  bool mobile = true,
  bool android = true,
  Size size = const Size(390, 844),
  double textScale = 1,
  void Function(Object? result)? onResult,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            key: const ValueKey('open-onboarding'),
            onPressed: () async {
              final result = await showDialog<Object>(
                context: context,
                barrierDismissible: false,
                builder: (context) => vpnOnboardingDialogForTest(
                  bridge: bridge,
                  hasDisabledSources: disabledSources,
                  isMobile: mobile,
                  isAndroid: android,
                ),
              );
              onResult?.call(result);
            },
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(_key('open-onboarding'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'Android explains both modes, optional login and system consent',
    (tester) async {
      final bridge = _OnboardingBridge();
      await _show(tester, bridge);
      expect(
        find.textContaining('Источник нужен в обоих режимах'),
        findsOneWidget,
      );
      expect(
        find.textContaining('выбор режима останется прежним'),
        findsOneWidget,
      );
      expect(_key('onboarding-no-registration'), findsOneWidget);
      expect(_key('onboarding-android-permission'), findsOneWidget);
      expect(_key('onboarding-services-mode'), findsNothing);
      expect(
        find.textContaining(
          'Доступность Dropo Free проверяется после согласия',
        ),
        findsOneWidget,
      );
      expect(bridge.catalogReads, 1);
      expect(bridge.freeImports, 0);
      await _tap(tester, 'onboarding-cancel');
      expect(_key('full-vpn-onboarding'), findsNothing);
      expect(bridge.freeImports, 0);
    },
  );

  testWidgets('free consent starts one import and blocks actions and back', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final bridge = _OnboardingBridge()..pendingImport = pending;
    Object? result;
    await _show(tester, bridge, onResult: (value) => result = value);
    await _tap(tester, 'onboarding-free-dropo-free');
    expect(bridge.acceptedConsent, isTrue);
    expect(bridge.freeImports, 1);
    expect(
      tester.widget<FilledButton>(_key('onboarding-free-dropo-free')).onPressed,
      isNull,
    );
    expect(
      tester.widget<OutlinedButton>(_key('onboarding-own-source')).onPressed,
      isNull,
    );
    expect(
      tester.widget<TextButton>(_key('onboarding-cancel')).onPressed,
      isNull,
    );
    await Navigator.of(tester.element(_key('full-vpn-onboarding'))).maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_key('full-vpn-onboarding'), findsOneWidget);
    expect(bridge.freeImports, 1);
    pending.complete({'success': true});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_key('full-vpn-onboarding'), findsNothing);
    expect(result.toString(), endsWith('.ready'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle system back cancels without adding a source', (
    tester,
  ) async {
    final bridge = _OnboardingBridge();
    await _show(tester, bridge);
    await Navigator.of(tester.element(_key('full-vpn-onboarding'))).maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_key('full-vpn-onboarding'), findsNothing);
    expect(bridge.freeImports, 0);
  });

  testWidgets(
    'disabled sources stay disabled and never load the free catalog',
    (tester) async {
      final bridge = _OnboardingBridge();
      Object? result;
      await _show(
        tester,
        bridge,
        disabledSources: true,
        onResult: (value) => result = value,
      );
      expect(find.textContaining('не включаем отключённые'), findsOneWidget);
      expect(_key('onboarding-free-dropo-free'), findsNothing);
      expect(_key('onboarding-services-mode'), findsNothing);
      expect(bridge.catalogReads, 0);
      await _tap(tester, 'onboarding-own-source');
      expect(result.toString(), endsWith('.manage'));
      expect(bridge.freeImports, 0);
    },
  );

  testWidgets('own subscription remains available while catalog is pending', (
    tester,
  ) async {
    final pending = Completer<List<PublicVpnProviderInfo>>();
    final bridge = _OnboardingBridge()..pendingCatalog = pending;
    Object? result;
    await _show(tester, bridge, onResult: (value) => result = value);
    await _tap(tester, 'onboarding-own-source');
    expect(result.toString(), endsWith('.manage'));
    pending.complete(const [_freeProvider]);
    await tester.pump();
    expect(bridge.freeImports, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed import can retry without silently changing modes', (
    tester,
  ) async {
    final bridge = _OnboardingBridge()..failImport = true;
    Object? result;
    await _show(tester, bridge, onResult: (value) => result = value);
    await _tap(tester, 'onboarding-free-dropo-free');
    expect(find.text('Dropo Free временно недоступен'), findsOneWidget);
    expect(_key('full-vpn-onboarding'), findsOneWidget);
    expect(result, isNull);
    expect(_key('onboarding-services-mode'), findsNothing);
    bridge.failImport = false;
    await _tap(tester, 'onboarding-free-dropo-free');
    expect(bridge.freeImports, 2);
    expect(result.toString(), endsWith('.ready'));
  });

  testWidgets('unavailable free catalog offers retry and own source', (
    tester,
  ) async {
    final bridge = _OnboardingBridge()..failCatalog = true;
    await _show(tester, bridge);
    expect(_key('onboarding-retry-catalog'), findsOneWidget);
    expect(_key('onboarding-own-source'), findsOneWidget);
    expect(bridge.freeImports, 0);
    bridge.failCatalog = false;
    await _tap(tester, 'onboarding-retry-catalog');
    expect(_key('onboarding-free-dropo-free'), findsOneWidget);
    expect(bridge.catalogReads, 2);
    expect(bridge.freeImports, 0);
  });

  testWidgets(
    'late import result after disposal cannot navigate or set state',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final bridge = _OnboardingBridge()..pendingImport = pending;
      await _show(tester, bridge);
      await _tap(tester, 'onboarding-free-dropo-free');
      await tester.pumpWidget(const MaterialApp(home: Text('Другой экран')));
      pending.complete({'success': true});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Другой экран'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final disabled in [false, true]) {
    testWidgets('Android dialog fits 320px at 200% text, disabled=$disabled', (
      tester,
    ) async {
      final bridge = _OnboardingBridge();
      await _show(
        tester,
        bridge,
        disabledSources: disabled,
        size: const Size(320, 568),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      if (disabled) {
        await _tap(tester, 'onboarding-own-source');
      } else {
        await _tap(tester, 'onboarding-free-dropo-free');
      }
      expect(tester.takeException(), isNull);
      expect(bridge.freeImports, disabled ? 0 : 1);
    });
  }

  testWidgets('Windows keeps its explicit source-free selective alternative', (
    tester,
  ) async {
    final bridge = _OnboardingBridge();
    Object? result;
    await _show(
      tester,
      bridge,
      mobile: false,
      android: false,
      size: const Size(820, 560),
      onResult: (value) => result = value,
    );
    expect(_key('onboarding-android-permission'), findsNothing);
    expect(_key('onboarding-services-mode'), findsOneWidget);
    await _tap(tester, 'onboarding-services-mode');
    expect(result.toString(), endsWith('.services'));
    expect(bridge.freeImports, 0);
  });
}
