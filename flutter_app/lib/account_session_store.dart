import 'package:flutter/services.dart';

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
