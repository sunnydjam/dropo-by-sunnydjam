import 'dart:async';

import 'package:dropo/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SnapshotBridge extends MockCoreBridge {
  bool connected = true;
  int routeReads = 0, statusReads = 0;
  Completer<CoreStatus>? heldStatus;
  Completer<List<RouteService>>? heldRoutes;
  Completer<List<String>>? heldLogs;
  final pushes = StreamController<BridgeEvent>.broadcast(sync: true);

  CoreStatus snapshot() => CoreStatus.fromJson({
    'connected': connected,
    'vpnState': connected ? 'connected' : 'stopped',
  });

  @override
  Stream<BridgeEvent> watchEvents() => pushes.stream;

  @override
  Future<Map<String, dynamic>> appConfig() async => {
    ...await super.appConfig(),
    'autoStartPrompted': true,
    'checkUpdates': false,
    'reduceMotion': true,
  };

  @override
  Future<CoreStatus> status() async {
    statusReads++;
    final pending = heldStatus;
    heldStatus = null;
    return pending == null ? snapshot() : pending.future;
  }

  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    routeReads++;
    final pending = heldRoutes;
    heldRoutes = null;
    return pending == null ? const [] : pending.future;
  }

  @override
  Future<List<String>> logs() async {
    final pending = heldLogs;
    heldLogs = null;
    return pending == null ? const [] : pending.future;
  }
}

Future<dynamic> _pump(WidgetTester tester, _SnapshotBridge bridge) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: DropoHomePage(bridge: bridge),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state(find.byType(DropoHomePage));
}

Future<void> _dispose(WidgetTester tester, _SnapshotBridge bridge) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await bridge.pushes.close();
}

void main() {
  testWidgets(
    'slow diagnostics cannot delay or restore an old connected status',
    (tester) async {
      final bridge = _SnapshotBridge();
      final dynamic state = await _pump(tester, bridge);
      expect(state.status.connected, true);
      final pendingRoutes = Completer<List<RouteService>>();
      bridge.heldRoutes = pendingRoutes;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      bridge.connected = false;
      final pendingLogs = Completer<List<String>>();
      bridge.heldLogs = pendingLogs;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        state.status.connected,
        false,
        reason: 'Status must precede optional logs',
      );
      pendingRoutes.complete(const []);
      pendingLogs.complete(const []);
      await tester.pump();
      expect(state.status.connected, false);
      expect(state.liveRoutesConfirmed, false);
      await _dispose(tester, bridge);
    },
  );

  testWidgets(
    'routine polls coalesce slow routes without starving their result',
    (tester) async {
      final bridge = _SnapshotBridge();
      final dynamic state = await _pump(tester, bridge);
      final pending = Completer<List<RouteService>>();
      bridge.heldRoutes = pending;
      final reads = bridge.routeReads;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(bridge.routeReads, reads + 1);
      const route = RouteService(
        tag: 'youtube',
        name: 'Fresh route',
        method: 'VPN',
        selectedMethod: 'vpn',
        requiresVpn: true,
        delayMs: 20,
        domainSuffixes: [],
      );
      pending.complete([route]);
      await tester.pump();
      expect(state.liveRoutesConfirmed, true);
      expect((state.routes as List<RouteService>).single.name, 'Fresh route');
      await _dispose(tester, bridge);
    },
  );

  testWidgets('routine polls do not starve a slow authoritative status read', (
    tester,
  ) async {
    final bridge = _SnapshotBridge();
    final dynamic state = await _pump(tester, bridge);
    final pending = Completer<CoreStatus>();
    bridge.heldStatus = pending;
    final reads = bridge.statusReads;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 4));
    expect(bridge.statusReads, reads + 1);
    bridge.connected = false;
    pending.complete(bridge.snapshot());
    await tester.pump();
    expect(state.status.connected, false);
    await _dispose(tester, bridge);
  });

  for (final fail in [false, true]) {
    testWidgets(
      'native Stop supersedes an in-flight status ${fail ? 'failure' : 'success'}',
      (tester) async {
        final bridge = _SnapshotBridge();
        final dynamic state = await _pump(tester, bridge);
        final oldStatus = bridge.snapshot();
        final pending = Completer<CoreStatus>();
        bridge.heldStatus = pending;
        await tester.pump(const Duration(seconds: 2));
        bridge.connected = false;
        bridge.pushes.add(
          BridgeEvent(
            id: 1,
            name: 'vpn-status-changed',
            payload: {'state': 'stopped', 'connected': false},
          ),
        );
        await tester.pump();
        expect(state.status.connected, false);
        if (fail) {
          pending.completeError(StateError('old request failed'));
        } else {
          pending.complete(oldStatus);
        }
        await tester.pump();
        expect(state.status.connected, false);
        expect(state.online, true);
        expect(state.refreshFailureCount, 0);
        await _dispose(tester, bridge);
      },
    );
  }

  test(
    'Android timer restores native uptime rather than starting with the UI',
    () {
      final now = DateTime.utc(2026, 11, 14, 12);
      final status = CoreStatus.fromJson({
        'connected': true,
        'uptimeMs': 3600500,
        'connectedAt': 123456789,
      }); // monotonic timestamp must not be interpreted as Unix.
      expect(
        androidSessionStartedAt(status, now: now),
        now.subtract(const Duration(milliseconds: 3600500)),
      );
      final legacy = CoreStatus.fromJson({'connected': true});
      final previous = now.subtract(const Duration(hours: 2));
      expect(
        androidSessionStartedAt(legacy, previous: previous, now: now),
        previous,
      );
      expect(
        androidSessionStartedAt(
          status.copyWith(connected: false),
          previous: previous,
        ),
        isNull,
      );
      expect(
        CoreStatus.fromJson({'connected': true, 'uptimeMs': -1}).vpnUptimeMs,
        isNull,
      );
    },
  );
}
