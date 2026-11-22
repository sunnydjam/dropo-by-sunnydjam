import 'dart:async';
import 'package:dropo/main.dart';
import 'package:flutter_test/flutter_test.dart';

VpnSourceInfo _source(String id, {bool disabled = false}) =>
    VpnSourceInfo.fromJson({'id': id, 'disabled': disabled});

class _ServiceBridge extends MockCoreBridge {
  final calls = <String>[];
  final states = <String>[];
  String state = 'connected';
  bool alwaysOn = false;
  bool failStop = false;
  bool failStart = false;
  bool failSnapshot = false;
  int snapshotReads = 0;
  List<VpnSourceInfo> sources = [_source('source-1')];
  Completer<VpnSourcesSnapshot>? pendingSnapshot;
  Completer<CoreStatus>? pendingStatus;

  @override
  Future<VpnSourcesSnapshot> vpnSourcesSnapshot() async {
    snapshotReads++;
    if (pendingSnapshot != null) return pendingSnapshot!.future;
    if (failSnapshot) throw StateError('source list unavailable');
    return VpnSourcesSnapshot(sources: sources);
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    calls.add(value ? 'start' : 'stop');
    if (!value && alwaysOn) {
      return {'success': true, 'requiresSystemSettings': true};
    }
    if (!value && failStop) return {'success': false};
    if (value && failStart) {
      state = 'failed';
      return {'success': false};
    }
    state = value ? 'connected' : 'stopped';
    return {'success': true};
  }

  @override
  Future<CoreStatus> status() async {
    if (pendingStatus != null) return pendingStatus!.future;
    final next = states.isNotEmpty ? states.removeAt(0) : state;
    calls.add('state:$next');
    return CoreStatus.fromJson({
      'vpnState': next,
      'connected': next == 'connected',
      'running': next == 'connected' || next == 'disconnecting',
      'hasError': next == 'failed',
    });
  }
}

void main() {
  test(
    'waits for service stop before saving and for start before success',
    () async {
      final bridge = _ServiceBridge()
        ..states.addAll(['disconnecting', 'stopped', 'starting', 'connected']);
      final result = await applyAndroidSourceChange(
        bridge: bridge,
        isCurrent: () => true,
        onPhase: (_) {},
        pollInterval: Duration.zero,
        operation: () async {
          bridge.calls.add('save');
          return {'success': true};
        },
      );
      expect(result['success'], true);
      expect(bridge.calls, [
        'stop',
        'state:disconnecting',
        'state:stopped',
        'save',
        'start',
        'state:starting',
        'state:connected',
      ]);
    },
  );

  for (final alwaysOn in [true, false]) {
    test('rejected stop never changes a source (alwaysOn=$alwaysOn)', () async {
      final bridge = _ServiceBridge()
        ..alwaysOn = alwaysOn
        ..failStop = !alwaysOn;
      final result = await applyAndroidSourceChange(
        bridge: bridge,
        isCurrent: () => true,
        onPhase: (_) {},
        operation: () async {
          fail('must not write while connected');
        },
      );
      expect(result['success'], false);
      expect(bridge.calls, ['stop']);
    });
  }

  test('unconfirmed stop leaves source unchanged', () async {
    final bridge = _ServiceBridge();
    final result = await applyAndroidSourceChange(
      bridge: bridge,
      isCurrent: () => true,
      onPhase: (_) {},
      stopTimeout: Duration.zero,
      operation: () async {
        fail('must not write without confirmed stop');
      },
    );
    expect(result['success'], false);
    expect(bridge.calls, ['stop']);
  });

  for (final throws in [true, false]) {
    test(
      'failed source edit restores connection and reports failure (throws=$throws)',
      () async {
        final bridge = _ServiceBridge();
        final result = await applyAndroidSourceChange(
          bridge: bridge,
          isCurrent: () => true,
          onPhase: (_) {},
          operation: () async {
            if (throws) throw StateError('save error');
            return {'success': false, 'userMessage': 'Не удалось сохранить'};
          },
        );
        expect(result['success'], false);
        expect(bridge.state, 'connected');
        expect(bridge.snapshotReads, 0);
        expect(bridge.calls, [
          'stop',
          'state:stopped',
          'start',
          'state:connected',
        ]);
      },
    );
  }

  test(
    'failed restart says selection saved but does not report connected',
    () async {
      final bridge = _ServiceBridge()..failStart = true;
      final result = await applyAndroidSourceChange(
        bridge: bridge,
        isCurrent: () => true,
        onPhase: (_) {},
        operation: () async => {'success': true},
      );
      expect(result['success'], false);
      expect(result['userMessage'], contains('Выбор сохранён'));
      expect(bridge.state, 'failed');
    },
  );

  test('timed out restart cancels the pending start', () async {
    final bridge = _ServiceBridge();
    final result = await applyAndroidSourceChange(
      bridge: bridge,
      isCurrent: () => true,
      onPhase: (_) {},
      startTimeout: Duration.zero,
      operation: () async => {'success': true},
    );
    expect(result['success'], false);
    expect(bridge.calls, ['stop', 'state:stopped', 'start', 'stop']);
    expect(bridge.state, 'stopped');
  });

  test(
    'leaving the session during stop cannot save or restart afterwards',
    () async {
      final bridge = _ServiceBridge()..pendingStatus = Completer<CoreStatus>();
      bool current = true;
      final resultFuture = applyAndroidSourceChange(
        bridge: bridge,
        isCurrent: () => current,
        onPhase: (_) {},
        operation: () async {
          fail('stale session cannot write');
        },
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      bridge.pendingStatus!.complete(
        CoreStatus.fromJson({'vpnState': 'stopped'}),
      );
      final result = await resultFuture;
      expect(result['success'], false);
      expect(bridge.calls, ['stop']);
    },
  );

  test(
    'cancellation during a source edit never starts a stale connection',
    () async {
      final bridge = _ServiceBridge();
      bool current = true;
      final result = await applyAndroidSourceChange(
        bridge: bridge,
        isCurrent: () => current,
        onPhase: (_) {},
        operation: () async {
          current = false;
          return {'success': true};
        },
      );
      expect(result['success'], false);
      expect(bridge.calls, ['stop', 'state:stopped']);
    },
  );

  for (final disable in [false, true]) {
    test('last source edit leaves VPN stopped (disable=$disable)', () async {
      final bridge = _ServiceBridge();
      final phases = <String>[];
      final result = await applyAndroidSourceChange(
        bridge: bridge,
        isCurrent: () => true,
        onPhase: phases.add,
        operation: () async {
          bridge.sources = disable ? [_source('source-1', disabled: true)] : [];
          return {'success': true, 'sourceCount': bridge.sources.length};
        },
      );
      expect(result['success'], true);
      expect(result['running'], false);
      expect(result['noEnabledSources'], true);
      expect(result['sourceCount'], disable ? 1 : 0);
      expect(
        result['userMessage'],
        'Изменения сохранены. VPN отключён: нет включённых источников.',
      );
      expect(bridge.calls, ['stop', 'state:stopped']);
      expect(bridge.state, 'stopped');
      expect(phases, isNot(contains('Подключаем…')));
      expect(bridge.snapshotReads, 1);
    });
  }

  test('remaining enabled fallback restores the connection', () async {
    final bridge = _ServiceBridge();
    final result = await applyAndroidSourceChange(
      bridge: bridge,
      isCurrent: () => true,
      onPhase: (_) {},
      operation: () async {
        bridge.sources = [
          _source('source-1', disabled: true),
          _source('source-2'),
        ];
        return {'success': true};
      },
    );
    expect(result['success'], true);
    expect(result['noEnabledSources'], isNull);
    expect(bridge.calls, ['stop', 'state:stopped', 'start', 'state:connected']);
    expect(bridge.state, 'connected');
  });

  for (final failStart in [false, true]) {
    test(
      'failed snapshot uses actual restart result (failStart=$failStart)',
      () async {
        final bridge = _ServiceBridge()
          ..failSnapshot = true
          ..failStart = failStart;
        final result = await applyAndroidSourceChange(
          bridge: bridge,
          isCurrent: () => true,
          onPhase: (_) {},
          operation: () async => {'success': true},
        );
        expect(result['success'], !failStart);
        expect(result['noEnabledSources'], isNull);
        expect(bridge.calls, contains('start'));
        if (failStart) {
          expect(result['userMessage'], contains('Выбор сохранён'));
        }
      },
    );
  }

  test('cancellation during source snapshot never restarts', () async {
    final bridge = _ServiceBridge()
      ..pendingSnapshot = Completer<VpnSourcesSnapshot>();
    bool current = true;
    final future = applyAndroidSourceChange(
      bridge: bridge,
      isCurrent: () => current,
      onPhase: (_) {},
      operation: () async => {'success': true},
    );
    await Future<void>.delayed(Duration.zero);
    expect(bridge.snapshotReads, 1);
    current = false;
    bridge.pendingSnapshot!.complete(
      VpnSourcesSnapshot(sources: bridge.sources),
    );
    expect((await future)['success'], false);
    expect(bridge.calls, ['stop', 'state:stopped']);
  });
}
