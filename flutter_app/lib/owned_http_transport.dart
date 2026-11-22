import 'dart:async';
import 'dart:io';

import 'pinned_tls.dart';

enum OwnedHttpResource { account, subscription }

bool ownedAccountMirrorPathAllowed(String path, String method) {
  const paths = <String, Set<String>>{
    'GET': {
      '/public/v1/catalog',
      '/v1/capabilities',
      '/v1/products',
      '/v1/me',
      '/v1/sessions',
      '/v1/vpn/free-source',
      '/v1/vpn/profile',
    },
    'POST': {
      '/v1/auth/password',
      '/v1/auth/guest',
      '/v1/auth/guest/play',
      '/v1/auth/challenges',
      '/v1/installations/bind',
      '/v1/guest/link',
      '/v1/guest/deletion-status',
      '/v1/vpn/profile',
      '/v1/incidents',
      '/v1/orders',
      '/v1/action-confirmations',
      '/v1/action-confirmations/password',
    },
    'PUT': {'/v1/guest/deletion-key'},
    'DELETE': {'/v1/sessions/current', '/v1/guest/account'},
  };
  if (paths[method]?.contains(path) ?? false) return true;
  if (method == 'GET') {
    return RegExp(
      r'^/v1/(?:auth/challenges|action-confirmations|orders)/[A-Za-z0-9_-]{8,256}$',
    ).hasMatch(path);
  }
  if (method == 'POST') {
    return RegExp(
          r'^/v1/auth/challenges/[A-Za-z0-9_-]{8,256}/exchange$',
        ).hasMatch(path) ||
        RegExp(
          r'^/v1/action-confirmations/[A-Za-z0-9_-]{8,256}/consume$',
        ).hasMatch(path);
  }
  return false;
}

/// These routes are compiled trust, never URLs supplied by a capability reply.
/// The logical issuer and protected-vault origin remain the canonical service.
class OwnedHttpRoute {
  const OwnedHttpRoute(this.uri, this.address, {this.reserve = false});
  final Uri uri;
  final InternetAddress? address;
  final bool reserve;
}

List<OwnedHttpRoute> ownedHttpRoutes(
  Uri canonical,
  OwnedHttpResource resource, {
  String method = 'GET',
}) {
  if (canonical.userInfo.isNotEmpty || canonical.hasFragment) {
    throw const FormatException('Invalid protected request.');
  }
  final account =
      resource == OwnedHttpResource.account &&
      canonical.origin == 'https://api.droponevedimka.ru' &&
      ownedAccountMirrorPathAllowed(canonical.path, method.toUpperCase()) &&
      (canonical.path != '/public/v1/catalog' || !canonical.hasQuery);
  final subscription =
      resource == OwnedHttpResource.subscription &&
      method.toUpperCase() == 'GET' &&
      canonical.origin == 'https://app.droponevedimka.ru' &&
      !canonical.hasQuery &&
      canonical.path.startsWith('/managed/v1/subscription/') &&
      RegExp(r'^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$').hasMatch(
        canonical.path.substring('/managed/v1/subscription/'.length),
      ) &&
      canonical.path.length <= '/managed/v1/subscription/'.length + 320;
  if (!account && !subscription) {
    if (resource == OwnedHttpResource.subscription ||
        canonical.origin == 'https://api.droponevedimka.ru') {
      throw const FormatException('Untrusted protected request.');
    }
    // Explicit custom deployments retain their own origin and transport.
    return [OwnedHttpRoute(canonical, null)];
  }
  final prefix = account ? '/dropo-api' : '/dropo-subscription';
  return [
    OwnedHttpRoute(canonical, InternetAddress('109.120.152.117')),
    OwnedHttpRoute(
      canonical.replace(
        host: 'ms-api.ordaflow.net',
        path: '$prefix${canonical.path}',
      ),
      InternetAddress('91.229.239.99'),
      reserve: true,
    ),
  ];
}

typedef OwnedHttpDial =
    Future<ConnectionTask<Socket>> Function(Uri uri, InternetAddress address);

/// An acquired request is never replayed. Its owner writes authentication/body
/// exactly once, reads the response and releases the per-attempt HTTP client.
class OwnedHttpRequest {
  OwnedHttpRequest(this.request, this.close);
  final HttpClientRequest request;
  final void Function() close;
}

class OwnedHttpTransport {
  OwnedHttpTransport({
    required this.resource,
    this.connectTimeout = const Duration(seconds: 4),
    this.reserveAffinity = const Duration(minutes: 5),
    OwnedHttpDial? dial,
    DateTime Function()? clock,
  }) : _dial = dial ?? createPinnedTlsConnection,
       _clock = clock ?? DateTime.now;

  final OwnedHttpResource resource;
  final Duration connectTimeout, reserveAffinity;
  final OwnedHttpDial _dial;
  final DateTime Function() _clock;
  final _clients = <HttpClient>{};
  DateTime? _reserveUntil;
  bool _closed = false;

  Future<OwnedHttpRequest> open(String method, Uri canonical) async {
    if (_closed) throw const SocketException('Protected transport is closed.');
    final routes = ownedHttpRoutes(canonical, resource, method: method);
    if (routes.length == 2 && (_reserveUntil?.isAfter(_clock()) ?? false)) {
      final first = routes.removeAt(0);
      routes.add(first);
    }
    for (var index = 0; index < routes.length; index++) {
      final route = routes[index];
      final client = HttpClient()..connectionTimeout = connectTimeout;
      _clients.add(client);
      var abandoned = false;
      void dispose() {
        abandoned = true;
        _clients.remove(client);
        client.close(force: true);
      }

      if (route.address != null) {
        client.findProxy = (_) => 'DIRECT';
        client.connectionFactory = (uri, proxyHost, proxyPort) {
          if (proxyHost != null || uri.origin != route.uri.origin) {
            throw const FormatException('Untrusted protected transport.');
          }
          // TLS SNI, HTTP Host and certificate verification all use route.uri.
          return _dial(uri, route.address!);
        };
      }
      try {
        final pending = client.openUrl(method, route.uri);
        // A timed-out/opening socket must not leak a late request or survive
        // caller cancellation. No application bytes have been written here.
        unawaited(
          pending.then<void>((request) {
            if (abandoned || _closed) request.abort();
          }, onError: (Object _, StackTrace _) {}),
        );
        final request = await pending.timeout(connectTimeout);
        if (_closed || abandoned) {
          request.abort();
          throw const SocketException('Protected transport is closed.');
        }
        request.followRedirects = false;
        _reserveUntil = route.reserve ? _clock().add(reserveAffinity) : null;
        return OwnedHttpRequest(request, dispose);
      } catch (error) {
        dispose();
        if (_closed) {
          throw const SocketException('Protected transport is closed.');
        }
        final connectionFailure =
            error is SocketException ||
            error is HandshakeException ||
            error is TimeoutException;
        if (connectionFailure && index + 1 < routes.length) continue;
        // Never include the canonical subscription token or request URL.
        if (error is HandshakeException) {
          throw const HandshakeException(
            'Protected TLS connection unavailable.',
          );
        }
        if (error is TimeoutException) {
          throw TimeoutException(
            'Protected connection timed out.',
            connectTimeout,
          );
        }
        if (error is SocketException) {
          throw const SocketException('Protected connection unavailable.');
        }
        rethrow;
      }
    }
    throw const SocketException('Protected connection unavailable.');
  }

  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
