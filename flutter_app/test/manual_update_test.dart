import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'navigation_helpers.dart';

class _ManualUpdateBridge extends MockCoreBridge {
  final _events = StreamController<BridgeEvent>.broadcast();
  int _eventId = 100;
  int checkCalls = 0;
  int installCalls = 0;
  int prepareQuitCalls = 0;
  int finalizeQuitCalls = 0;
  final connectionChanges = <bool>[];
  final externalLinks = <String>[];
  Completer<Map<String, dynamic>>? installResult;

  void updateEvent(String name, Map<String, dynamic> payload) =>
      _events.add(BridgeEvent(id: _eventId++, name: name, payload: payload));

  @override
  bool get prefersPushEvents => true;

  @override
  Stream<BridgeEvent> watchEvents() => _events.stream;

  void setConnectionBusy(bool busy) {
    _events.add(
      BridgeEvent(
        id: _eventId++,
        name: 'app-busy',
        payload: {
          'id': 'vpn-connect',
          'active': busy,
          'message': busy ? 'Подключаем VPN' : 'Готово',
        },
      ),
    );
  }

  Future<void> close() => _events.close();

  @override
  Future<CoreStatus> status() async => (await super.status()).copyWith(
    connected: true,
    running: true,
    vpnState: 'connected',
  );

  @override
  Future<UpdateInfo> checkUpdates() async {
    checkCalls++;
    return UpdateInfo.fromJson(const {
      'success': true,
      'hasUpdate': true,
      'currentVersion': '3.0.33',
      'latestVersion': '3.0.34',
      'releaseURL':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/releases/tag/v3.0.34',
      'downloadURL':
          'https://github.com/sunnydjam/dropo-by-sunnydjam/releases/download/v3.0.34/dropo-Windows-Setup-x64.exe',
      'assetName': 'dropo-Windows-Setup-x64.exe',
      'fileSize': 123456,
      'platform': 'windows',
      'selfUpdate': true,
    });
  }

  @override
  Future<Map<String, dynamic>> installUpdate() async {
    installCalls++;
    if (installResult != null) return installResult!.future;
    // Never let the widget test take the production success/exit(0) branch.
    return {'success': false, 'error': 'Test installer did not download files'};
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    connectionChanges.add(value);
    return {'success': true};
  }

  @override
  Future<TelegramExitInfo> prepareQuit() async {
    prepareQuitCalls++;
    return super.prepareQuit();
  }

  @override
  Future<void> finalizeQuit() async => finalizeQuitCalls++;

  @override
  Future<void> openExternal(String link) async => externalLinks.add(link);

  void expectNoInstallOrInterruption() {
    expect(installCalls, 0);
    expect(connectionChanges, isEmpty);
    expect(prepareQuitCalls, 0);
    expect(finalizeQuitCalls, 0);
    expect(externalLinks, isEmpty);
  }
}

Future<_ManualUpdateBridge> _pumpUpdater(
  WidgetTester tester, {
  bool checkUpdates = true,
  bool connectionBusy = false,
}) async {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bridge = _ManualUpdateBridge();
  addTearDown(bridge.close);
  await bridge.saveAppConfig(
    AppConfig.defaults.copyWith(checkUpdates: checkUpdates, reduceMotion: true),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('update-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: DropoHomePage(bridge: bridge),
      ),
    ),
  );
  await tester.pump();
  if (connectionBusy) {
    bridge.setConnectionBusy(true);
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 300));
  return bridge;
}

Future<void> _openUpdateConfirmation(WidgetTester tester) async {
  final update = find.text('Обновить и перезапустить');
  expect(update, findsOneWidget);
  await tester.ensureVisible(update);
  await tester.tap(update);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text('Обновить dropo до 3.0.34?'), findsOneWidget);
}

Finder _confirmationButton(String label) =>
    find.descendant(of: find.byType(Dialog), matching: find.text(label));

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  });
  tearDown(binding.platformDispatcher.clearAccessibilityFeaturesTestValue);

  testWidgets('update overlay shows stages, bytes and actionable failure', (
    tester,
  ) async {
    final bridge = await _pumpUpdater(tester);
    bridge.installResult = Completer<Map<String, dynamic>>();
    await _openUpdateConfirmation(tester);
    await tester.tap(_confirmationButton('Обновить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('update-progress-overlay')),
      findsOneWidget,
    );
    expect(find.text('Проверяем новую версию'), findsOneWidget);
    bridge.updateEvent('update-stage', {'stage': 'downloading'});
    bridge.updateEvent('update-progress', {
      'percent': 50,
      'downloaded': 1048576,
      'total': 2097152,
    });
    await tester.pump();
    expect(find.text('50% · 1.0 из 2.0 МБ'), findsOneWidget);
    for (final size in [const Size(820, 560), const Size(390, 568)]) {
      tester.view.physicalSize = size;
      await tester.pump();
      expect(tester.takeException(), isNull);
      const captureDirectory = String.fromEnvironment('DROPO_UI_CAPTURE_DIR');
      if (captureDirectory.isNotEmpty) {
        await tester.runAsync(() async {
          final picture = await tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('update-capture')),
              )
              .toImage();
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory(captureDirectory).create(recursive: true);
          await File(
            '$captureDirectory/update-${size.width.round()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
      }
    }
    tester.view.physicalSize = const Size(1280, 860);
    for (final stage in ['verifying', 'stopping', 'installing']) {
      bridge.updateEvent('update-stage', {'stage': stage});
      await tester.pump();
      expect(
        find.byKey(const ValueKey('update-progress-overlay')),
        findsOneWidget,
      );
      expect(find.text('50% · 1.0 из 2.0 МБ'), findsNothing);
    }
    bridge.installResult!.complete({'success': false, 'error': 'Файл занят'});
    await tester.pump();
    expect(find.textContaining('Файл занят'), findsWidgets);
    expect(find.text('Понятно'), findsOneWidget);
    bridge.updateEvent('update-progress', {'percent': 100});
    await tester.pump();
    expect(find.text('100%'), findsNothing);
    await tester.tap(find.text('Понятно'));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-progress-overlay')), findsNothing);
    expect(bridge.installCalls, 1);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets(
    'startup checks and notifies without interrupting an active VPN',
    (tester) async {
      final bridge = await _pumpUpdater(tester);
      expect(bridge.checkCalls, 1);
      expect(find.text('Доступна версия 3.0.34'), findsWidgets);
      expect(find.text('Обновить dropo до 3.0.34?'), findsNothing);
      bridge.expectNoInstallOrInterruption();

      await tester.pump(const Duration(seconds: 30));
      bridge.expectNoInstallOrInterruption();
      expect((await bridge.status()).connected, isTrue);
    },
  );

  testWidgets('clearing a busy connection never starts a deferred update', (
    tester,
  ) async {
    final bridge = await _pumpUpdater(tester, connectionBusy: true);
    expect(bridge.checkCalls, 1);
    bridge.expectNoInstallOrInterruption();

    bridge.setConnectionBusy(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    bridge.expectNoInstallOrInterruption();
    expect(find.text('Обновить dropo до 3.0.34?'), findsNothing);
  });

  testWidgets(
    'the update action requires confirmation and cancel does nothing',
    (tester) async {
      final bridge = await _pumpUpdater(tester);
      await _openUpdateConfirmation(tester);
      bridge.expectNoInstallOrInterruption();
      expect(
        find.textContaining('На время установки VPN будет отключён'),
        findsOneWidget,
      );

      await tester.tap(_confirmationButton('Отмена'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Обновить dropo до 3.0.34?'), findsNothing);
      bridge.expectNoInstallOrInterruption();
    },
  );

  testWidgets('explicit confirmation invokes the installer exactly once', (
    tester,
  ) async {
    final bridge = await _pumpUpdater(tester);
    await _openUpdateConfirmation(tester);
    bridge.expectNoInstallOrInterruption();

    await tester.tap(_confirmationButton('Обновить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(bridge.installCalls, 1);
    expect(find.text('Обновить dropo до 3.0.34?'), findsNothing);
    expect(
      find.textContaining('Test installer did not download files'),
      findsWidgets,
    );

    await tester.pump(const Duration(seconds: 30));
    expect(
      bridge.installCalls,
      1,
      reason: 'failed manual updates are not retried',
    );
    expect(bridge.connectionChanges, isEmpty);
    expect(bridge.prepareQuitCalls, 0);
    expect(bridge.finalizeQuitCalls, 0);
    expect(bridge.externalLinks, isEmpty);
  });

  testWidgets('the notification action also waits for explicit confirmation', (
    tester,
  ) async {
    final bridge = await _pumpUpdater(tester);
    await tester.tap(find.widgetWithText(SnackBarAction, 'Обновить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Обновить dropo до 3.0.34?'), findsOneWidget);
    bridge.expectNoInstallOrInterruption();

    await tester.tap(_confirmationButton('Отмена'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    bridge.expectNoInstallOrInterruption();
  });

  testWidgets(
    'manual settings updates remain available with startup checks off',
    (tester) async {
      final bridge = await _pumpUpdater(tester, checkUpdates: false);
      await openSection(tester, 'app-settings');
      expect(bridge.checkCalls, 0);
      final check = find.text('Проверить');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(bridge.checkCalls, 1);
      bridge.expectNoInstallOrInterruption();

      final update = find.descendant(
        of: find.byKey(const ValueKey('app-settings')),
        matching: find.text('Обновить'),
      );
      await tester.ensureVisible(update);
      await tester.tap(update);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Обновить dropo до 3.0.34?'), findsOneWidget);
      bridge.expectNoInstallOrInterruption();
      await tester.tap(_confirmationButton('Отмена'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      bridge.expectNoInstallOrInterruption();
    },
  );

  testWidgets(
    'repeated notifications and check preference changes never install',
    (tester) async {
      final bridge = await _pumpUpdater(tester);
      await openSection(tester, 'app-settings');
      final toggle = find.byKey(
        const ValueKey('setting-switch-Проверять обновления автоматически'),
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect((await bridge.appConfig())['checkUpdates'], isFalse);
      await tester.tap(toggle);
      await tester.pump();
      expect((await bridge.appConfig())['checkUpdates'], isTrue);

      for (var check = 0; check < 2; check++) {
        final action = find.text('Проверить');
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        bridge.expectNoInstallOrInterruption();
      }
      expect(bridge.checkCalls, 3);
      expect(find.text('Обновить dropo до 3.0.34?'), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      bridge.expectNoInstallOrInterruption();
    },
  );

  testWidgets('disabled automatic checks do not run on startup', (
    tester,
  ) async {
    final bridge = await _pumpUpdater(tester, checkUpdates: false);
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.checkCalls, 0);
    expect(find.text('Доступна версия 3.0.34'), findsNothing);
    bridge.expectNoInstallOrInterruption();
  });

  testWidgets(
    'restoring default preferences still grants no install permission',
    (tester) async {
      final bridge = await _pumpUpdater(tester, checkUpdates: false);
      expect(bridge.checkCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await bridge.saveAppConfig(AppConfig.defaults);
      await tester.pumpWidget(MaterialApp(home: DropoHomePage(bridge: bridge)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(bridge.checkCalls, 1);
      expect(find.text('Доступна версия 3.0.34'), findsWidgets);
      await tester.pump(const Duration(seconds: 30));
      bridge.expectNoInstallOrInterruption();
    },
  );
}
