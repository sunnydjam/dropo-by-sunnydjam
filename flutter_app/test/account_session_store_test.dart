import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dropo/account_session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dropo/account_session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final store = NativeAccountSessionStore(channel);
  const token = 'test-only.session-token_123';

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('read absent session does not write or create a fallback', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    expect(await store.read(), isNull);
    expect(calls.map((call) => call.method), ['read']);
    expect(calls.single.arguments, isNull);
  });

  test('read returns the protected native token', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => token);
    expect(await store.read(), token);
  });

  test('write and clear use the dedicated channel contract', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await store.write(token);
    await store.clear();
    expect(calls.map((call) => call.method), ['write', 'clear']);
    expect(calls.first.arguments, {'token': token});
    expect(calls.last.arguments, isNull);
  });

  test('compact endpoint-bound session envelope round trips unchanged', () async {
    const record =
        '{"endpoint":"https://accounts.example.test","token":"fake-session_123"}';
    Object? persisted;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'write') {
        persisted = (call.arguments as Map)['token'];
        return null;
      }
      return persisted;
    });
    await store.write(record);
    expect(await store.read(), record);
  });

  for (final (index, invalid) in <String>[
    '',
    ' leading',
    'trailing ',
    'contains space',
    'line\nbreak',
    'null\x00byte',
    'del\x7fbyte',
    'non-ascii-é',
    'x' * (NativeAccountSessionStore.maxTokenBytes + 1),
  ].indexed) {
    test(
      'invalid token rejected before invoking native storage (case $index)',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
        await expectLater(store.write(invalid), throwsFormatException);
        expect(calls, isEmpty);
      },
    );
  }

  test('maximum bounded token remains supported', () async {
    final maximum = 'a' * NativeAccountSessionStore.maxTokenBytes;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'read' ? maximum : null,
    );
    await store.write(maximum);
    expect(await store.read(), maximum);
  });

  for (final (index, invalid) in <Object>[
    42,
    '',
    'bad\nvalue',
    'x' * 16385,
  ].indexed) {
    test('invalid native read fails closed (case $index)', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return invalid;
      });
      await expectLater(store.read(), throwsFormatException);
      expect(calls.map((call) => call.method), ['read']);
    });
  }

  test('native protection failures propagate for every operation', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'ACCOUNT_SESSION_UNAVAILABLE');
    });
    await expectLater(store.read(), throwsA(isA<PlatformException>()));
    await expectLater(store.write(token), throwsA(isA<PlatformException>()));
    await expectLater(store.clear(), throwsA(isA<PlatformException>()));
  });

  test('missing plugin never falls back to plaintext storage', () async {
    await expectLater(store.read(), throwsA(isA<MissingPluginException>()));
    await expectLater(
      store.write(token),
      throwsA(isA<MissingPluginException>()),
    );
    await expectLater(store.clear(), throwsA(isA<MissingPluginException>()));
  });
}
