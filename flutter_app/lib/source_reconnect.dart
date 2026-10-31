part of 'main.dart';

// Android acknowledges a start/stop request before the service has completed
// it. Source edits must wait for that completion, not just an RPC success.
@visibleForTesting
Future<Map<String, dynamic>> applyAndroidSourceChange({
  required CoreBridge bridge,
  required Future<Map<String, dynamic>> Function() operation,
  required bool Function() isCurrent,
  required ValueChanged<String> onPhase,
  Duration stopTimeout = const Duration(seconds: 30),
  Duration startTimeout = const Duration(seconds: 90),
  Duration pollInterval = const Duration(milliseconds: 250),
}) async {
  Map<String, dynamic> failure(String message) => {
    'success': false,
    'error': message,
    'userMessage': message,
  };
  void checkCurrent() {
    if (!isCurrent()) throw const _SourceChangeCancelled();
  }

  Future<void> waitFor(bool connected, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      checkCurrent();
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('VPN state');
      final current = await bridge.status().timeout(
        remaining < const Duration(seconds: 5)
            ? remaining
            : const Duration(seconds: 5),
      );
      checkCurrent();
      if (connected) {
        if (current.hasError || current.vpnState == 'failed') {
          throw StateError('VPN start failed');
        }
        if (current.connected &&
            !current.connecting &&
            !current.disconnecting) {
          return;
        }
      } else if (!current.connected &&
          !current.running &&
          !current.connecting &&
          !current.disconnecting) {
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<bool> restart() async {
    checkCurrent();
    onPhase('Подключаем…');
    try {
      final result = await bridge.setConnected(true);
      checkCurrent();
      if (result['success'] == false) return false;
      await waitFor(true, startTimeout);
      return true;
    } on _SourceChangeCancelled {
      rethrow;
    } catch (_) {
      // Cancel a delayed start as well, so a timed-out action cannot silently
      // turn VPN on after the user was told it did not connect.
      if (isCurrent()) {
        try {
          await bridge.setConnected(false);
        } catch (_) {
          /* Refresh owns the displayed state. */
        }
      }
      return false;
    }
  }

  try {
    checkCurrent();
    onPhase('Переподключаем…');
    final stopped = await bridge.setConnected(false);
    checkCurrent();
    if (stopped['requiresSystemSettings'] == true) {
      return failure(
        'Постоянный VPN включён в настройках Android. Отключите его там, затем повторите выбор.',
      );
    }
    if (stopped['success'] == false) {
      return failure(
        'Не удалось отключить VPN. Выбор не изменён. Проверьте системные настройки VPN.',
      );
    }
    try {
      await waitFor(false, stopTimeout);
    } on _SourceChangeCancelled {
      rethrow;
    } catch (_) {
      return failure(
        'Android не подтвердил отключение. Выбор не изменён. Проверьте состояние VPN и повторите.',
      );
    }
    checkCurrent();
    onPhase('Сохраняем выбор…');
    Map<String, dynamic> result;
    try {
      result = await operation();
    } catch (_) {
      result = failure('Не удалось сохранить выбор. Попробуйте ещё раз.');
    }
    checkCurrent();
    if (result['success'] == true) {
      try {
        final snapshot = await bridge.vpnSourcesSnapshot().timeout(
          const Duration(seconds: 5),
        );
        checkCurrent();
        if (!snapshot.sources.any((source) => !source.disabled)) {
          return {
            ...result,
            'success': true,
            'running': false,
            'noEnabledSources': true,
            'userMessage':
                'Изменения сохранены. VPN отключён: нет включённых источников.',
          };
        }
      } on _SourceChangeCancelled {
        rethrow;
      } catch (_) {
        // An unreadable list is not evidence that every source was removed.
        // Let the normal restart report the actual connection result.
      }
    }
    final connected = await restart();
    if (!connected) {
      return failure(
        result['success'] == false
            ? 'Не удалось сохранить выбор и восстановить VPN. Вернитесь на главную и нажмите «Подключить».'
            : 'Выбор сохранён, но подключиться не удалось. Проверьте источник или повторите подключение с главной.',
      );
    }
    return result;
  } on _SourceChangeCancelled {
    return failure('Смена подключения отменена.');
  } catch (_) {
    return failure(
      'Не удалось переподключиться. Проверьте состояние VPN и повторите.',
    );
  }
}

class _SourceChangeCancelled implements Exception {
  const _SourceChangeCancelled();
}
