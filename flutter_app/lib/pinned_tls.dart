import 'dart:io';
import 'dart:async';

final _pendingHandshakes = <String, int>{};

/// HttpClient.connectionFactory takes ownership of TLS as well as dialing.
/// Dial only the numeric address, then verify TLS against the original host.
Future<ConnectionTask<Socket>> createPinnedTlsConnection(
  Uri uri,
  InternetAddress address, {
  SecurityContext? context,
}) async {
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('Invalid protected transport.');
  }
  final target = '${uri.host}:${uri.port}';
  if ((_pendingHandshakes[target] ?? 0) >= 2 ||
      _pendingHandshakes.values.fold(0, (a, b) => a + b) >= 8) {
    throw const SocketException('Protected transport is busy.');
  }
  _pendingHandshakes[target] = (_pendingHandshakes[target] ?? 0) + 1;
  ConnectionTask<Socket> tcp;
  try {
    tcp = await Socket.startConnect(address, uri.port);
  } catch (_) {
    _releaseHandshake(target);
    rethrow;
  }
  final result = Completer<Socket>();
  Socket? connected;
  var cancelled = false;
  Timer? deadline;
  void cancel() {
    cancelled = true;
    tcp.cancel();
    connected?.destroy();
    if (!result.isCompleted) {
      result.completeError(
        const SocketException('Protected connection cancelled.'),
      );
    }
  }

  deadline = Timer(const Duration(seconds: 6), cancel);
  tcp.socket.then(
    (socket) async {
      if (cancelled) {
        socket.destroy();
        deadline?.cancel();
        _releaseHandshake(target);
        return;
      }
      connected = socket;
      try {
        // Dart detaches the raw Socket during TLS. Abandoning the caller must
        // reject promptly and dispose any late TLS result. Keep the permit
        // until the SDK handshake actually ends, bounding stalled SDK futures.
        final tls = await SecureSocket.secure(
          socket,
          host: uri.host,
          context: context,
        );
        connected = tls;
        if (cancelled) {
          tls.destroy();
          return;
        }
        result.complete(tls);
      } catch (error, stack) {
        connected?.destroy();
        if (!result.isCompleted) result.completeError(error, stack);
      } finally {
        deadline?.cancel();
        _releaseHandshake(target);
      }
    },
    onError: (Object error, StackTrace stack) {
      deadline?.cancel();
      _releaseHandshake(target);
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  return ConnectionTask.fromSocket(result.future, cancel);
}

void _releaseHandshake(String target) {
  final pending = (_pendingHandshakes[target] ?? 1) - 1;
  if (pending <= 0) {
    _pendingHandshakes.remove(target);
  } else {
    _pendingHandshakes[target] = pending;
  }
}
