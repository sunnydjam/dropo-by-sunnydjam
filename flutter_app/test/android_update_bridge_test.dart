import 'dart:async';
import 'dart:convert';

import 'package:dropo/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dropo/test-native-update');

  tearDown(() {
    debugAndroidPlatformOverride = null;
    debugPlayDistributionOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Play bridge refuses APK download without calling native installer',
    () async {
      debugAndroidPlatformOverride = true;
      debugPlayDistributionOverride = true;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return jsonEncode({'success': true});
          });
      final result = await ChannelCoreBridge(channel: channel).installUpdate();
      expect(result['success'], isFalse);
      expect(result['error'], contains('Google Play'));
      expect(calls, isEmpty);
    },
  );

  test(
    'Android installation calls native downloader without caller-supplied URL',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return jsonEncode({'success': true, 'installerOpened': true});
          });
      final bridge = ChannelCoreBridge(channel: channel);
      final result = await bridge.installUpdate();
      expect(result['success'], isTrue);
      expect(result['installerOpened'], isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'androidInstallUpdate');
      expect(calls.single.arguments, isEmpty);
    },
  );

  test(
    'Android native installer errors are surfaced, not browser fallbacks',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            throw PlatformException(
              code: 'UPDATE_FAILED',
              message: 'Signature mismatch',
            );
          });
      final bridge = ChannelCoreBridge(channel: channel);
      await expectLater(
        bridge.installUpdate(),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, ['androidInstallUpdate']);
    },
  );

  testWidgets('Android bridge timeout cancels the native pending request', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'androidInstallUpdate') {
            return Completer<String>().future;
          }
          return jsonEncode({'success': true});
        });
    final result = ChannelCoreBridge(channel: channel).installUpdate();
    final expectation = expectLater(result, throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(minutes: 16));
    await expectation;
    expect(calls.map((call) => call.method), ['androidInstallUpdate', 'call']);
    final arguments = calls.last.arguments as Map;
    expect(arguments['method'], 'CancelAndroidUpdate');
  });
}
