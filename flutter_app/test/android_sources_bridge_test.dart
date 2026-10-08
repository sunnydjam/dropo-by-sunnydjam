import 'dart:convert';

import 'package:dropo/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android source operations reach the native API without single-source emulation',
    () async {
      const channel = MethodChannel('dropo/test-android-sources');
      final calls = <(String, List<dynamic>)>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'call');
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final method = args['method'] as String;
            calls.add((
              method,
              jsonDecode(args['argsJson'] as String) as List<dynamic>,
            ));
            return jsonEncode(
              method == 'GetVPNSources'
                  ? {
                      'success': true,
                      'running': false,
                      'autoSelect': true,
                      'autoSelectSupported': true,
                      'fallbackSupported': true,
                      'sources': [
                        {
                          'id': 'one',
                          'name': 'First',
                          'node_count': 2,
                          'node_names': ['A', 'B'],
                          'selected_node': 1,
                        },
                        {'id': 'two', 'name': 'Second', 'disabled': true},
                      ],
                    }
                  : method == 'GetPublicVPNProviders'
                  ? {
                      'success': true,
                      'providers': [
                        {'id': 'public', 'name': 'Public'},
                      ],
                    }
                  : {'success': true},
            );
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final bridge = ChannelCoreBridge(channel: channel);
      final snapshot = await bridge.vpnSourcesSnapshot();
      expect(snapshot.sources.length, 2);
      expect(snapshot.sources.first.selectedNode, 1);
      expect(snapshot.autoSelect, isTrue);
      expect(snapshot.autoSelectSupported, isTrue);
      expect(snapshot.fallbackSupported, isTrue);
      expect((await bridge.publicVpnProviders()).single.id, 'public');
      await bridge.addVpnSource(' Test ', ' https://example.test/sub ');
      await bridge.addPublicVpnSource('public', true);
      await bridge.setVpnSourceNode('one', 1);
      await bridge.setVpnSourceEnabled('two', true);
      await bridge.moveVpnSource('two', 0);
      await bridge.removeVpnSource('one');
      await bridge.refreshVpnSources();
      await bridge.enableVpnSourceAutoSelect();
      await bridge.setReduceMotion(true);
      expect(calls.map((call) => [call.$1, call.$2]).toList(), [
        ['GetVPNSources', []],
        ['GetPublicVPNProviders', []],
        [
          'AddVPNSource',
          ['Test', 'https://example.test/sub'],
        ],
        [
          'AddPublicVPNSource',
          ['public', true],
        ],
        [
          'SetVPNSourceNode',
          ['one', 1],
        ],
        [
          'SetVPNSourceEnabled',
          ['two', true],
        ],
        [
          'MoveVPNSource',
          ['two', 0],
        ],
        [
          'RemoveVPNSource',
          ['one'],
        ],
        ['RefreshVPNSources', []],
        ['EnableVPNSourceAutoSelect', []],
        [
          'SetReduceMotion',
          [true],
        ],
      ]);
    },
  );

  test('Android source API failure is not an empty successful list', () async {
    const channel = MethodChannel('dropo/test-android-sources-failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {'success': false, 'error': 'unavailable'},
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final bridge = ChannelCoreBridge(channel: channel);
    await expectLater(bridge.vpnSourcesSnapshot(), throwsStateError);
    await expectLater(bridge.publicVpnProviders(), throwsStateError);
  });
}
