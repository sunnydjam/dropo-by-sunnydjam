part of 'main.dart';

/// Classify locally; never retain or transmit the source error text.
String incidentFailureCategory(String error) {
  final text = error.substring(0, math.min(error.length, 1024)).toLowerCase();
  if (text.contains('timeout') ||
      text.contains('timed out') ||
      text.contains('deadline exceeded') ||
      text.contains('таймаут')) {
    return 'timeout';
  }
  if (text.contains('no such host') ||
      text.contains('dns') ||
      text.contains('name resolution')) {
    return 'dns';
  }
  if (text.contains('certificate') || text.contains('tls handshake')) {
    return 'tls';
  }
  if (text.contains('connection reset') || text.contains('broken pipe')) {
    return 'reset';
  }
  if (text.contains('connection refused') ||
      text.contains('network is unreachable') ||
      text.contains('no route to host')) {
    return 'connect';
  }
  return 'unknown';
}

/// A separate allowlisted stream. Raw diagnostic reports never enter this DTO.
class IncidentEvent {
  const IncidentEvent(this.json);
  final Map<String, dynamic> json;
  static const services = {
    'connection',
    'telegram',
    'discord',
    'youtube',
    'meta',
    'twitch',
    'spotify',
    'steam',
    'tiktok',
    'roblox',
  };
  static const categories = {
    'dns',
    'connect',
    'reset',
    'timeout',
    'tls',
    'protocol',
    'no_response',
    'unknown',
    'none',
  };
  static const kinds = {
    'connection_failure',
    'service_probe',
    'recovery',
    'connection_success',
  };
  static const durations = {
    'lt_1s',
    '1_5s',
    '5_15s',
    '15_60s',
    'gte_60s',
    'unknown',
  };
  static const fields = {
    'schemaVersion',
    'eventId',
    'occurredAt',
    'kind',
    'service',
    'platform',
    'appVersion',
    'routingMode',
    'category',
    'result',
    'durationBucket',
    'routeVerified',
  };

  static IncidentEvent? read(Object? raw, DateTime now) {
    if (raw is! Map ||
        raw.keys.toSet().difference(fields).isNotEmpty ||
        raw.length != fields.length) {
      return null;
    }
    final data = Map<String, dynamic>.from(raw);
    final time = DateTime.tryParse(data['occurredAt']?.toString() ?? '');
    if (data['schemaVersion'] != 1 ||
        time == null ||
        now.difference(time) > const Duration(days: 7) ||
        time.difference(now) > const Duration(minutes: 5) ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(data['eventId']?.toString() ?? '') ||
        !kinds.contains(data['kind']) ||
        !services.contains(data['service']) ||
        !{'android', 'windows'}.contains(data['platform']) ||
        !{'all_traffic', 'blocked_only'}.contains(data['routingMode']) ||
        !categories.contains(data['category']) ||
        !{'success', 'failure'}.contains(data['result']) ||
        !durations.contains(data['durationBucket']) ||
        data['routeVerified'] is! bool ||
        data['appVersion'] is! String ||
        _safeSupportVersion(data['appVersion']) != data['appVersion']) {
      return null;
    }
    return IncidentEvent(Map.unmodifiable(data));
  }
}

class IncidentIdentity {
  const IncidentIdentity({
    required this.owner,
    required this.epoch,
    required this.token,
    required this.available,
  });
  final String owner;
  final int epoch;
  final String? token;
  final bool available;
}

class IncidentReporter extends ChangeNotifier {
  IncidentReporter({
    required this.readState,
    required this.writeState,
    required this.identity,
    required this.openTransport,
    required this.platform,
    DateTime Function()? now,
    this.scheduleUploads = true,
  }) : now = now ?? DateTime.now;

  final Future<Map<String, dynamic>?> Function() readState;
  final Future<void> Function(Map<String, dynamic>?) writeState;
  final IncidentIdentity Function() identity;
  final AccountTransport Function() openTransport;
  final String platform;
  final DateTime Function() now;
  final bool scheduleUploads;
  static const maxEvents = 16;
  static const maxQueueBytes = 8 * 1024;
  final List<IncidentEvent> _queue = [];
  final Map<String, DateTime> _lastEvent = {};
  final Map<String, bool> _serviceResults = {};
  Future<void> _writes = Future.value();
  Timer? _timer;
  AccountTransport? _inflight;
  bool enabled = false, ready = false, storageFailed = false;
  bool _disposed = false, _foreground = true;
  int _generation = 0, _attempt = 0, _dailyCount = 0;
  String _owner = '', _day = '';
  int? _identityEpoch;
  DateTime? _nextAttempt;
  bool? _lastConnected, _lastError;
  bool? _lastSourceSuccess;
  int _sourceGeneration = 0;
  int get queuedCount => _queue.length;

  Future<void> initialize() async {
    try {
      final saved = await readState();
      if (_disposed) return;
      if (saved != null && saved['version'] == 1) {
        _owner = saved['owner'] is String ? saved['owner'] as String : '';
        enabled = saved['enabled'] == true;
        _day = saved['day'] is String ? saved['day'] as String : '';
        _dailyCount = saved['dailyCount'] is int
            ? (saved['dailyCount'] as int).clamp(0, 200)
            : 0;
        if (enabled && saved['events'] is List) {
          for (final raw in (saved['events'] as List).take(maxEvents)) {
            final event = IncidentEvent.read(raw, now());
            if (event != null &&
                !_queue.any(
                  (e) => e.json['eventId'] == event.json['eventId'],
                )) {
              _queue.add(event);
            }
          }
        }
        _boundQueue();
      }
      ready = true;
      synchronizeIdentity();
      // Rewrite the sanitized queue even when all saved events have expired.
      if (saved != null) await _persist();
      if (_disposed) return;
      if (scheduleUploads) {
        _timer = Timer.periodic(const Duration(minutes: 1), (_) {
          unawaited(flush());
        });
      }
      _notify();
    } catch (_) {
      if (!_disposed) {
        storageFailed = true;
        enabled = false;
        ready = true;
        _notify();
      }
    }
  }

  void synchronizeIdentity() {
    if (!ready || _disposed) return;
    final current = identity();
    // An unavailable restored identity may be offline. Do not clear its queue
    // until an actual account/epoch transition is observed.
    if (current.owner.isEmpty && _identityEpoch == null) return;
    final changed =
        (_identityEpoch != null && _identityEpoch != current.epoch) ||
        (_owner.isNotEmpty &&
            current.owner.isNotEmpty &&
            _owner != current.owner);
    if (changed) {
      _generation++;
      _inflight?.close();
      _inflight = null;
      _queue.clear();
      _lastEvent.clear();
      _serviceResults.clear();
      _lastConnected = null;
      _lastError = null;
      _lastSourceSuccess = null;
      _sourceGeneration = 0;
      enabled = false;
    }
    _identityEpoch = current.epoch;
    if (current.owner.isNotEmpty || changed) _owner = current.owner;
    if (changed) {
      unawaited(_persist());
      _notify();
    }
  }

  Future<bool> setEnabled(bool value) async {
    if (!ready || _disposed) return false;
    synchronizeIdentity();
    if (value && (storageFailed || !identity().available || _owner.isEmpty)) {
      return false;
    }
    _generation++;
    _inflight?.close();
    _inflight = null;
    enabled = value;
    _queue.clear();
    _lastEvent.clear();
    _serviceResults.clear();
    _lastConnected = null;
    _lastError = null;
    _lastSourceSuccess = null;
    _sourceGeneration = 0;
    final ok = await _persist();
    _notify();
    return ok;
  }

  void setForeground(bool value) {
    _foreground = value;
    if (value) unawaited(flush());
  }

  void observeConnection(CoreStatus status, String mode) {
    if (!enabled || !ready) return;
    if (status.hasError && _lastError != true) {
      record(
        kind: 'connection_failure',
        service: 'connection',
        success: false,
        category: incidentFailureCategory(status.error),
        version: status.version.version,
        mode: mode,
      );
    } else if (status.connected && _lastConnected != true) {
      record(
        kind: _lastError == true ? 'recovery' : 'connection_success',
        service: 'connection',
        success: true,
        category: 'none',
        version: status.version.version,
        mode: mode,
      );
    }
    _lastConnected = status.connected;
    _lastError = status.hasError;
    final source = status.vpnResponse;
    if (!status.connected ||
        status.connecting ||
        status.disconnecting ||
        source.checkedAt == null ||
        source.sessionGeneration <= 0) {
      return;
    }
    final observation = source.observationAt(now());
    if (observation != VpnResponseObservation.available &&
        observation != VpnResponseObservation.failed) {
      return;
    }
    if (_sourceGeneration != source.sessionGeneration) {
      _lastSourceSuccess = null;
      _sourceGeneration = source.sessionGeneration;
    }
    final success = observation == VpnResponseObservation.available;
    record(
      kind: success && _lastSourceSuccess == false
          ? 'recovery'
          : 'service_probe',
      service: 'connection',
      success: success,
      category: success ? 'none' : 'unknown',
      version: status.version.version,
      mode: mode,
      durationMs: source.latencyMs,
    );
    _lastSourceSuccess = success;
  }

  void observeReport(
    ConnectionHealthReport report,
    String version,
    String mode,
  ) {
    final time = report.checkedAt;
    if (!report.sessionValid ||
        report.results.length > 100 ||
        time == null ||
        now().difference(time) > const Duration(seconds: 90) ||
        time.difference(now()) > const Duration(seconds: 5)) {
      return;
    }
    final grouped = <String, List<ConnectionHealthResult>>{};
    for (final result in report.results) {
      final tag = result.serviceTag;
      if (tag == 'connection' || !IncidentEvent.services.contains(tag)) {
        continue;
      }
      (grouped[tag] ??= []).add(result);
    }
    for (final entry in grouped.entries) {
      final tag = entry.key;
      final checks = entry.value;
      final success = checks.every((result) => result.success);
      final recovered = _serviceResults[tag] == false && success;
      final categories = checks
          .where((result) => !result.success)
          .map((result) => incidentFailureCategory(result.error));
      final category = success
          ? 'none'
          : categories.firstWhere(
              (value) => value != 'unknown',
              orElse: () => 'unknown',
            );
      record(
        kind: recovered ? 'recovery' : 'service_probe',
        service: tag,
        success: success,
        category: category,
        version: version,
        mode: mode,
        routeVerified: checks.every((result) => result.routeVerified),
        durationMs: checks.map((result) => result.latencyMs).reduce(math.max),
      );
      if (enabled) _serviceResults[tag] = success;
    }
  }

  void record({
    required String kind,
    required String service,
    required bool success,
    required String category,
    required String version,
    required String mode,
    bool routeVerified = false,
    int? durationMs,
  }) {
    synchronizeIdentity();
    final current = identity();
    if (_disposed ||
        !ready ||
        !enabled ||
        storageFailed ||
        current.owner.isEmpty ||
        current.owner != _owner ||
        !current.available) {
      return;
    }
    final time = now().toUtc();
    final day = time.toIso8601String().substring(0, 10);
    if (_day != day) {
      _day = day;
      _dailyCount = 0;
    }
    if (_dailyCount >= 200) return;
    final fingerprint =
        '$kind:$service:$success:$category:$mode:$routeVerified';
    final last = _lastEvent[fingerprint];
    if (last != null && time.difference(last) < const Duration(minutes: 5)) {
      return;
    }
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final event = IncidentEvent.read({
      'schemaVersion': 1,
      'eventId':
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}',
      'occurredAt': time.toIso8601String(),
      'kind': kind,
      'service': service,
      'platform': platform,
      'appVersion': _safeSupportVersion(version),
      'routingMode': mode,
      'category': category,
      'result': success ? 'success' : 'failure',
      'durationBucket': durationMs == null || durationMs < 0
          ? 'unknown'
          : durationMs < 1000
          ? 'lt_1s'
          : durationMs < 5000
          ? '1_5s'
          : durationMs < 15000
          ? '5_15s'
          : durationMs < 60000
          ? '15_60s'
          : 'gte_60s',
      'routeVerified': routeVerified,
    }, time);
    if (event == null) return;
    _lastEvent[fingerprint] = time;
    _dailyCount++;
    _queue.add(event);
    _boundQueue();
    unawaited(_persist());
    _notify();
  }

  bool _boundQueue() {
    final previousLength = _queue.length;
    _queue.removeWhere((e) => IncidentEvent.read(e.json, now()) == null);
    while (_queue.length > maxEvents ||
        utf8.encode(jsonEncode(_queue.map((e) => e.json).toList())).length >
            maxQueueBytes) {
      _queue.removeAt(0);
    }
    return previousLength != _queue.length;
  }

  Future<bool> _persist() {
    final generation = _generation;
    final snapshot = <String, dynamic>{
      'version': 1,
      'enabled': enabled,
      'owner': _owner,
      'day': _day,
      'dailyCount': _dailyCount,
      'events': _queue.map((e) => e.json).toList(),
    };
    final operation = _writes.then((_) async {
      if (generation != _generation || _disposed) return;
      await writeState(snapshot);
    });
    _writes = operation.catchError((Object _) {});
    return operation.then(
      (_) => true,
      onError: (Object error) {
        if (error is AccountIdentityChanged) return true;
        if (!_disposed) {
          enabled = false;
          storageFailed = true;
          _queue.clear();
          _generation++;
          _inflight?.close();
          _inflight = null;
          _notify();
        }
        return false;
      },
    );
  }

  Future<void> flush() async {
    await _writes;
    synchronizeIdentity();
    if (_boundQueue()) await _persist();
    final current = identity();
    if (_disposed ||
        !ready ||
        !enabled ||
        storageFailed ||
        !_foreground ||
        _inflight != null ||
        _queue.isEmpty ||
        !current.available ||
        current.token == null ||
        current.owner != _owner ||
        (_nextAttempt != null && now().isBefore(_nextAttempt!))) {
      return;
    }
    final generation = _generation;
    final batch = _queue.take(16).toList();
    final client = openTransport();
    _inflight = client;
    try {
      await client.request(
        'POST',
        '/v1/incidents',
        token: current.token,
        body: {
          'consentVersion': 1,
          'events': batch.map((e) => e.json).toList(),
        },
      );
      if (_disposed ||
          generation != _generation ||
          current.epoch != identity().epoch ||
          !enabled) {
        return;
      }
      final ids = batch.map((e) => e.json['eventId']).toSet();
      _queue.removeWhere((e) => ids.contains(e.json['eventId']));
      _attempt = 0;
      _nextAttempt = null;
      await _persist();
      _notify();
    } catch (error) {
      if (_disposed || generation != _generation) return;
      if (error is AccountApiException &&
          {400, 413, 422}.contains(error.status)) {
        final ids = batch.map((e) => e.json['eventId']).toSet();
        _queue.removeWhere((e) => ids.contains(e.json['eventId']));
        await _persist();
      }
      _attempt = math.min(_attempt + 1, 6);
      final delay = error is AccountApiException && error.status == 429
          ? 60
          : math.min(60, 1 << _attempt);
      _nextAttempt = now().add(
        Duration(minutes: delay, seconds: math.Random().nextInt(30)),
      );
      // Upload failures deliberately do not generate telemetry about telemetry.
    } finally {
      client.close();
      if (identical(_inflight, client)) _inflight = null;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _inflight?.close();
    super.dispose();
  }
}

class IncidentScope extends InheritedWidget {
  const IncidentScope({
    super.key,
    required this.reporter,
    required super.child,
  });
  final IncidentReporter reporter;
  static IncidentReporter? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IncidentScope>()?.reporter;
  @override
  bool updateShouldNotify(IncidentScope oldWidget) =>
      reporter != oldWidget.reporter;
}

class IncidentPrivacySetting extends StatelessWidget {
  const IncidentPrivacySetting({super.key});
  @override
  Widget build(BuildContext context) {
    final reporter = IncidentScope.maybeOf(context);
    if (reporter == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: reporter,
      builder: (context, _) => _SwitchSetting(
        title: 'Помогать улучшать подключение',
        description: reporter.storageFailed
            ? 'Отправка выключена: защищённое хранилище недоступно.'
            : 'Отправлять технические сведения о сбоях и результатах проверок. '
                  'Без переписки, посещённых страниц и ключей подписок. По умолчанию выключено.',
        value: reporter.enabled,
        onChanged: !reporter.ready || reporter.storageFailed
            ? null
            : (value) async {
                if (value) {
                  final accepted = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      scrollable: true,
                      title: const Text('Технические сведения о подключении'),
                      content: const Text(
                        'С вашего разрешения Dropo будет отправлять на dropo.fun '
                        'версию приложения, платформу, режим подключения, код проверяемого сервиса, '
                        'категорию сбоя и результат проверки. События связаны с вашим профилем. '
                        'Переписка, содержимое трафика, адреса посещённых страниц, полные журналы '
                        'и ключи подписок не передаются.\n\n'
                        'События хранятся на сервере до 30 дней; очередь на устройстве — до 7 дней. '
                        'Можно отключить отправку в любой момент: очередь будет удалена. '
                        'Это не влияет на работу VPN.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Не сейчас'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Разрешить'),
                        ),
                      ],
                    ),
                  );
                  if (accepted != true) return;
                }
                final saved = await reporter.setEnabled(value);
                if (!saved && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Не удалось сохранить настройку. Отправка выключена.',
                      ),
                    ),
                  );
                }
              },
      ),
    );
  }
}
