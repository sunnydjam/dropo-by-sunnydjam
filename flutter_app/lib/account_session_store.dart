import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// A private-state write belonged to an identity that has already changed.
/// This is cancellation, not failure of the native protected storage.
class AccountIdentityChanged implements Exception {
  const AccountIdentityChanged();
}

/// Stores opaque account tokens using the current platform's protected storage.
///
/// Missing native support or a protection failure is deliberately surfaced to
/// the caller. There is no file, preferences, or plaintext fallback here.
class NativeAccountSessionStore {
  NativeAccountSessionStore([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('dropo/account_session');

  static const int maxTokenBytes = 16 * 1024;
  final MethodChannel _channel;

  static bool _validToken(String token) =>
      token.isNotEmpty &&
      token.length <= maxTokenBytes &&
      token.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);

  Future<String?> read() async {
    final value = await _channel.invokeMethod<Object?>('read');
    if (value == null) return null;
    if (value is! String || !_validToken(value)) {
      throw const FormatException('Invalid protected account session.');
    }
    return value;
  }

  Future<void> write(String token) async {
    // Account sessions are opaque printable-ASCII tokens, never user text.
    if (!_validToken(token)) {
      throw const FormatException('Invalid account session token.');
    }
    await _channel.invokeMethod<void>('write', <String, Object>{
      'token': token,
    });
  }

  Future<void> clear() => _channel.invokeMethod<void>('clear');
}

/// Atomic, endpoint-bound protected identity plus small private feature state.
/// All writers share one transaction queue because the native vault is one slot.
/// Read errors propagate: an unreadable credential is never an absent identity.
class ProtectedAccountIdentityStore {
  ProtectedAccountIdentityStore({
    required this.endpoint,
    NativeAccountSessionStore? native,
  }) : _native = native ?? NativeAccountSessionStore();

  final String endpoint;
  final NativeAccountSessionStore _native;
  static Future<void>? _pending;

  Future<T> _transaction<T>(Future<T> Function() operation) {
    final previous = _pending;
    final result = previous == null
        ? Future<T>.sync(operation)
        : previous.then((_) => operation());
    final pending = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending = pending;
    unawaited(
      pending.then((_) {
        if (identical(_pending, pending)) _pending = null;
      }),
    );
    return result;
  }

  Future<Map<String, dynamic>> _read() async {
    final raw = await _native.read();
    if (raw == null) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['endpoint'] != endpoint ||
        (decoded['version'] != null && decoded['version'] != 2) ||
        (decoded['token'] != null &&
            (decoded['token'] is! String ||
                !(decoded['token'] as String).codeUnits.every(
                  (c) => c >= 0x21 && c <= 0x7e,
                ) ||
                (decoded['token'] as String).isEmpty ||
                (decoded['token'] as String).length > 256)) ||
        (decoded['accountKind'] != null &&
            !const {'guest', 'registered'}.contains(decoded['accountKind'])) ||
        (decoded['installationId'] != null &&
            (decoded['installationId'] is! String ||
                !RegExp(
                  r'^[A-Za-z0-9_-]{1,128}$',
                ).hasMatch(decoded['installationId'] as String))) ||
        (decoded['expiresAt'] != null &&
            (decoded['expiresAt'] is! String ||
                DateTime.tryParse(decoded['expiresAt'] as String) == null)) ||
        (decoded['pendingDeletion'] != null &&
            decoded['pendingDeletion'] is! Map) ||
        (decoded['installationSecret'] != null &&
            (decoded['installationSecret'] is! String ||
                !RegExp(
                  r'^[A-Za-z0-9_-]{43}$',
                ).hasMatch(decoded['installationSecret'] as String))) ||
        (decoded['suppressed'] != null && decoded['suppressed'] is! bool) ||
        (decoded['privateState'] != null && decoded['privateState'] is! Map)) {
      throw const FormatException('Protected identity is unavailable.');
    }
    final record = Map<String, dynamic>.from(decoded);
    // The original envelope held a registered account session only.
    if (record['version'] == null && record['token'] != null) {
      record['accountKind'] = 'registered';
    }
    final kind = record['accountKind'];
    if ((record['token'] != null && kind == null) ||
        (kind != null && record['token'] == null) ||
        (kind == 'guest' &&
            (record['installationSecret'] == null ||
                record['installationId'] == null ||
                record['expiresAt'] == null))) {
      throw const FormatException('Incomplete protected identity.');
    }
    final pending = record['pendingDeletion'];
    if (pending is Map &&
        (record['suppressed'] != true ||
            pending['token'] is! String ||
            (pending['token'] as String).isEmpty ||
            (pending['token'] as String).length > 256 ||
            !(pending['token'] as String).codeUnits.every(
              (c) => c >= 0x21 && c <= 0x7e,
            ) ||
            (pending['installationSecret'] != null &&
                (pending['installationSecret'] is! String ||
                    !RegExp(
                      r'^[A-Za-z0-9_-]{43}$',
                    ).hasMatch(pending['installationSecret'] as String))))) {
      throw const FormatException('Invalid protected deletion intent.');
    }
    return record;
  }

  Future<Map<String, dynamic>> read() => _transaction(_read);

  Future<Map<String, dynamic>> update(
    void Function(Map<String, dynamic>) change,
  ) => _transaction(() async {
    final record = await _read();
    change(record);
    record['version'] = 2;
    record['endpoint'] = endpoint;
    // Native storage rejects oversized envelopes before any persisted write.
    await _native.write(jsonEncode(record));
    return record;
  });

  Future<Map<String, dynamic>?> readPrivateState(String namespace) async {
    _validateNamespace(namespace);
    final record = await read();
    final states = record['privateState'];
    final value = states is Map ? states[namespace] : null;
    if (value == null) return null;
    if (value is! Map) throw const FormatException('Invalid private state.');
    return Map<String, dynamic>.from(value);
  }

  Future<void> writePrivateState(
    String namespace,
    Map<String, dynamic>? value, {
    bool Function()? canWrite,
  }) async {
    _validateNamespace(namespace);
    final frozen = value == null ? null : jsonDecode(jsonEncode(value));
    if (frozen != null && utf8.encode(jsonEncode(frozen)).length > 8 * 1024) {
      throw const FormatException('Private state exceeds storage bounds.');
    }
    await update((record) {
      if (canWrite?.call() == false ||
          (frozen != null && record['suppressed'] == true)) {
        throw const AccountIdentityChanged();
      }
      final states = Map<String, dynamic>.from(
        record['privateState'] as Map? ?? const {},
      );
      if (frozen == null) {
        states.remove(namespace);
      } else {
        states[namespace] = frozen;
      }
      record['privateState'] = states;
    });
  }

  static void _validateNamespace(String namespace) {
    if (!RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(namespace)) {
      throw const FormatException('Invalid private state namespace.');
    }
  }
}
