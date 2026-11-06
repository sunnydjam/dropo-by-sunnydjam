part of 'main.dart';

@visibleForTesting
ManagedFreeSourceClient? debugManagedFreeSourceClient;

/// Resolves only the one managed provider, after consent. Subscription URLs
/// never appear in offer metadata, errors, analytics or public build assets.
class ManagedFreeSourceClient {
  ManagedFreeSourceClient({required this.endpoint, this.transport});

  final String endpoint;
  final AccountTransport? transport;

  bool get available => accountEndpointAvailable(endpoint);

  List<PublicVpnProviderInfo> get providers => available
      ? const [
          PublicVpnProviderInfo(
            id: 'dropo-free',
            name: 'Dropo Free',
            description:
                'Бесплатная подписка Dropo. Доступность проверим после вашего согласия; скорость и наличие серверов не гарантируются.',
            website: '',
          ),
        ]
      : const [];

  Future<Map<String, dynamic>> add(
    String id,
    bool consent, {
    required Future<Map<String, dynamic>> Function(
      String id,
      String name,
      String uri,
      bool consent,
    )
    save,
    Future<Map<String, dynamic>> Function(String, int)? verifyCatalog,
  }) async {
    if (!consent || id != 'dropo-free') {
      return {
        'success': false,
        'error': 'Подтвердите добавление бесплатной подписки Dropo.',
      };
    }
    if (!available) return _unavailable();
    final api = transport ?? _AccountApi(endpoint);
    try {
      Map<String, dynamic> capabilities = {};
      try {
        capabilities = await api.request('GET', '/v1/capabilities');
      } catch (error) {
        debugPrint(
          'Dropo capability request failed (${_safeAccountFailure(error)})',
        );
        /* Older compatible service: retain its shared Free endpoint. */
      }
      if (capabilities['individualVPNProfilesAvailable'] == true) {
        if (verifyCatalog == null) return _unavailable();
        return await _ownedVPNForEndpoint(
          endpoint,
        ).enroll(api, save, verifyCatalog);
      }
      final response = await api.request('GET', '/v1/vpn/free-source');
      if (response['available'] != true) return _unavailable();
      final provider = _asMap(response['provider']);
      final raw = provider['subscriptionUrl'];
      if (provider['id'] != 'dropo-free' || raw is! String) {
        return _unavailable();
      }
      final value = raw.trim();
      if (!managedFreeSubscriptionUrlValid(value)) {
        return _unavailable();
      }
      final result = await save('dropo-free', 'Dropo Free', value, true);
      if (result['success'] == true) return result;
      // Native download failures can contain the private subscription URL.
      // Never echo those details for a managed provider.
      return {
        'success': false,
        'error':
            'Не удалось добавить Dropo Free. Источники не изменены; попробуйте позже или добавьте свою подписку.',
      };
    } on OwnedVPNOperationFailure catch (error) {
      // A fixed operation code is safe for local support logs. Never log the
      // underlying exception, URL, session token or subscription contents.
      debugPrint('Dropo managed profile unavailable (${error.code})');
      return _unavailable();
    } catch (error) {
      debugPrint('Dropo source request failed (${_safeAccountFailure(error)})');
      return _unavailable();
    } finally {
      if (transport == null) api.close();
    }
  }

  Map<String, dynamic> _unavailable() => {
    'success': false,
    'error':
        'Dropo Free сейчас недоступен. Можно добавить свою VPN-подписку и использовать оба режима.',
  };
}

String _safeAccountFailure(Object error) {
  if (error is AccountApiException) return 'account_http_${error.status}';
  if (error is HandshakeException) return 'tls_handshake';
  if (error is SocketException) return 'socket';
  if (error is TimeoutException) return 'timeout';
  return 'client_validation';
}

@visibleForTesting
bool managedFreeSubscriptionUrlValid(String value) {
  final uri = Uri.tryParse(value);
  if (value.length > 8192 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  if (host == 'localhost' ||
      ['.localhost', '.local', '.internal', '.lan'].any(host.endsWith)) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  if (address == null) return host.contains('.');
  final bytes = address.rawAddress;
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  if (bytes.length == 16) {
    final mapped =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255;
    if (mapped) return _managedFreeIPv4Public(bytes.sublist(12));
    return !bytes.every((byte) => byte == 0) && (bytes[0] & 0xfe) != 0xfc;
  }
  return _managedFreeIPv4Public(bytes);
}

bool _managedFreeIPv4Public(List<int> bytes) =>
    bytes.length == 4 &&
    bytes[0] != 0 &&
    bytes[0] != 10 &&
    bytes[0] != 127 &&
    bytes[0] < 224 &&
    !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) &&
    !(bytes[0] == 169 && bytes[1] == 254) &&
    !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
    !(bytes[0] == 192 && bytes[1] == 168);

ManagedFreeSourceClient get _managedFreeSourceClient =>
    debugManagedFreeSourceClient ??
    ManagedFreeSourceClient(endpoint: _accountEndpoint);
