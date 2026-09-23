import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

part 'vpn_sources.dart';
part 'vpn_onboarding.dart';
part 'home_dashboard.dart';
part 'atlas_dashboard.dart';
part 'compact_shell.dart';
part 'planet_animation.dart';
part 'service_routes.dart';
part 'minimal_settings.dart';
part 'connection_health.dart';
part 'android_vpn_protection.dart';

const String _coreEndpoint = String.fromEnvironment(
  'DROPO_CORE_ENDPOINT',
  defaultValue: 'http://127.0.0.1:17890',
);
const String _bridgeMode = String.fromEnvironment(
  'BRIDGE',
  defaultValue: 'auto',
);
const String _bundledAppVersion = String.fromEnvironment(
  'DROPO_APP_VERSION',
  defaultValue: 'dev',
);
const String _bundledBuildHash = String.fromEnvironment(
  'DROPO_BUILD_HASH',
  defaultValue: '',
);

@visibleForTesting
String? coreCompatibilityError(
  Map<String, dynamic> info, {
  required String expectedVersion,
  required String expectedBuildHash,
}) {
  if (info['bridge']?.toString() != 'dropo-core') {
    return 'локальный порт занят другим приложением';
  }
  final version = _asMap(info['version']);
  final actualVersion = version['version']?.toString().trim() ?? '';
  final actualBuildHash = version['buildHash']?.toString().trim() ?? '';
  final normalizedVersion = expectedVersion.trim();
  final normalizedBuildHash = expectedBuildHash.trim();
  if (normalizedVersion.isNotEmpty &&
      normalizedVersion != 'dev' &&
      actualVersion != normalizedVersion) {
    return 'запущена версия ${actualVersion.isEmpty ? 'без номера' : actualVersion}, '
        'ожидалась $normalizedVersion';
  }
  if (normalizedBuildHash.isNotEmpty &&
      actualBuildHash != normalizedBuildHash) {
    return 'запущена сборка '
        '${actualBuildHash.isEmpty ? 'без хеша' : actualBuildHash}, '
        'ожидалась $normalizedBuildHash';
  }
  return null;
}

@visibleForTesting
bool isConnectionBlockingBusyTask(String id) {
  return id == 'vpn-connect' || id == 'vpn-disconnect';
}

@visibleForTesting
bool? debugMobileShellOverride;

bool get _isMobileShell =>
    debugMobileShellOverride ?? (Platform.isAndroid || Platform.isIOS);

@visibleForTesting
bool? debugAndroidPlatformOverride;

bool get _isAndroidPlatform =>
    debugAndroidPlatformOverride ?? Platform.isAndroid;

@visibleForTesting
bool shouldAutomaticallyInstallUpdate(
  UpdateInfo update, {
  required bool enabled,
}) {
  return enabled && update.success && update.hasUpdate && update.selfUpdate;
}

ButtonStyle _withClickCursor(ButtonStyle style) {
  return style.copyWith(
    mouseCursor: WidgetStateProperty.resolveWith<MouseCursor?>((states) {
      if (states.contains(WidgetState.disabled)) {
        return SystemMouseCursors.basic;
      }
      return SystemMouseCursors.click;
    }),
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DropoApp());
}

final ValueNotifier<ThemeMode> _dropoThemeMode = ValueNotifier(
  ThemeMode.system,
);

@visibleForTesting
ThemeMode themeModeFromSetting(String value) {
  switch (value) {
    case 'dark':
      return ThemeMode.dark;
    case 'light':
      return ThemeMode.light;
    default:
      return ThemeMode.system;
  }
}

ThemeData _dropoTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final clickStyle = _withClickCursor(const ButtonStyle());
  return ThemeData(
    brightness: brightness,
    fontFamily: 'Inter',
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF36D399),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: dark
        ? const Color(0xFF101617)
        : const Color(0xFFF4F8F6),
    useMaterial3: true,
    filledButtonTheme: FilledButtonThemeData(style: clickStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: clickStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: clickStyle),
    textButtonTheme: TextButtonThemeData(style: clickStyle),
    iconButtonTheme: IconButtonThemeData(style: clickStyle),
    listTileTheme: const ListTileThemeData(
      mouseCursor: WidgetStateMouseCursor.clickable,
    ),
    switchTheme: SwitchThemeData(mouseCursor: clickStyle.mouseCursor),
    checkboxTheme: CheckboxThemeData(mouseCursor: clickStyle.mouseCursor),
    radioTheme: RadioThemeData(mouseCursor: clickStyle.mouseCursor),
  );
}

SystemUiOverlayStyle _systemOverlayFor(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: dark
        ? const Color(0xFF101617)
        : const Color(0xFFF4F8F6),
    systemNavigationBarDividerColor: dark
        ? const Color(0xFF101617)
        : const Color(0xFFE2E8E4),
    systemNavigationBarIconBrightness: dark
        ? Brightness.light
        : Brightness.dark,
  );
}

class DropoApp extends StatelessWidget {
  const DropoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _dropoThemeMode,
      builder: (context, themeMode, _) => MaterialApp(
        title: 'dropo',
        debugShowCheckedModeBanner: false,
        // Atlas is a dark shell on both platforms. Apply the same brightness
        // to dialogs and Android system bars, not only the home subtree.
        themeMode: ThemeMode.dark,
        theme: _dropoTheme(Brightness.light),
        darkTheme: _dropoTheme(Brightness.dark),
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: _systemOverlayFor(Theme.of(context).brightness),
          child: child ?? const SizedBox.shrink(),
        ),
        home: DropoHomePage(bridge: createCoreBridge()),
      ),
    );
  }
}

CoreBridge createCoreBridge() {
  final mode = _bridgeMode.toLowerCase();
  if (mode == 'mock') {
    return MockCoreBridge();
  }
  if (mode != 'http' && Platform.isAndroid) {
    return ChannelCoreBridge();
  }
  return HttpCoreBridge(_coreEndpoint);
}

abstract class CoreBridge {
  bool get prefersPushEvents;
  Stream<BridgeEvent> watchEvents();
  Future<void> ensureStarted();
  Future<void> dispose();
  Future<CoreStatus> status();
  Future<SubscriptionInfo> subscription();
  Future<Map<String, dynamic>> appConfig();
  Future<ProfileListInfo> profiles();
  Future<Map<String, dynamic>> setActiveProfile(int id);
  Future<Map<String, dynamic>> createProfile(String name);
  Future<Map<String, dynamic>> updateProfile(int id, String name);
  Future<Map<String, dynamic>> deleteProfile(int id);
  Future<Map<String, dynamic>> saveAppConfig(AppConfig config);
  Future<Map<String, dynamic>> resolveAutoStartPrompt(bool enable);
  Future<Map<String, dynamic>> routingMode();
  Future<Map<String, dynamic>> setRoutingMode(String mode);
  Future<Map<String, dynamic>> networkMode();
  Future<Map<String, dynamic>> setNetworkMode(String mode);
  Future<Map<String, dynamic>> hideRuTraffic();
  Future<Map<String, dynamic>> setHideRuTraffic(
    bool enabled,
    String proxyAddress,
  );
  Future<Map<String, dynamic>> freeAccessConfig();
  Future<Map<String, dynamic>> setDisableFreeAccess(bool disabled);
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  );
  Future<Map<String, dynamic>> setZapretServiceStrategy(
    String tag,
    String mode,
    String strategyTag,
  );
  Future<Map<String, dynamic>> setHomeRouteServiceVisible(
    String tag,
    bool visible,
  );
  Future<List<RouteService>> routes({bool live = false});
  Future<List<String>> logs();
  Future<List<BridgeEvent>> events({required int since});
  Future<UpdateInfo> checkUpdates();
  Future<Map<String, dynamic>> installUpdate();
  Future<TrafficStatsInfo> trafficStats();
  Future<Map<String, dynamic>> resetTrafficStats();
  Future<List<WireGuardInfo>> wireGuards();
  Future<WireGuardInfo?> wireGuardConfig(String tag);
  Future<Map<String, dynamic>> parseWireGuard(String config);
  Future<Map<String, dynamic>> addWireGuard(
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  );
  Future<Map<String, dynamic>> updateWireGuard(
    String oldTag,
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  );
  Future<Map<String, dynamic>> deleteWireGuard(String tag);
  Future<Map<String, dynamic>> testSubscription(String value);
  Future<Map<String, dynamic>> runQuickCheck();
  Future<Map<String, dynamic>> captureFingerprint();
  Future<void> openFingerprintFolder();
  Future<void> openConfigFolder();
  Future<Map<String, dynamic>> setConnected(bool value);
  Future<VpnConflictInfo> externalVpnConflicts();
  Future<Map<String, dynamic>> downloadDependencies();
  Future<List<VpnSourceInfo>> vpnSources();
  Future<List<PublicVpnProviderInfo>> publicVpnProviders();
  Future<Map<String, dynamic>> addPublicVpnSource(String id, bool consent);
  Future<Map<String, dynamic>> addVpnSource(String name, String uri);
  Future<Map<String, dynamic>> removeVpnSource(String id);
  Future<Map<String, dynamic>> setVpnSourceNode(String id, int nodeIndex);
  Future<Map<String, dynamic>> setVpnSourceEnabled(String id, bool enabled);
  Future<Map<String, dynamic>> moveVpnSource(String id, int newIndex);
  Future<Map<String, dynamic>> refreshVpnSources();
  Future<Map<String, dynamic>> saveSubscription(String value);
  Future<TelegramExitInfo> telegramProxyStatus();
  Future<Map<String, dynamic>> openTelegramProxySettings();
  Future<Map<String, dynamic>> acknowledgeTelegramProxyRemoved();
  Future<TelegramExitInfo> prepareQuit();
  Future<void> finalizeQuit();
  Future<String> diagnostics();
  Future<void> openLogsFolder();
  Future<void> showWindow();
  Future<void> hideWindow();
  Future<void> openExternal(String link);
  Future<AndroidCompatibilityInfo> androidCompatibility();
  Future<AndroidVpnProtection> androidVpnProtection();
  Future<Map<String, dynamic>> androidOpenVpnSettings();
  Future<Map<String, dynamic>> setAndroidCompatibilityPromptDismissed(
    bool dismissed,
  );
  Future<Map<String, dynamic>> createDropoSpace();
  Future<Map<String, dynamic>> moveAppToDropoSpace(String packageName);
  Future<Map<String, dynamic>> openDropoSpaceMarket(String packageName);
  Future<Map<String, dynamic>> requestDropoSpaceShortcut(String packageName);
  Future<Map<String, dynamic>> openCloneHelpSearch();
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<Object?> args = const [],
    Duration timeout = const Duration(seconds: 12),
  });
}

class HttpCoreBridge implements CoreBridge {
  HttpCoreBridge(String endpoint) : baseUri = _normalizeEndpoint(endpoint);

  final Uri baseUri;
  // Bridge token written by dropo-core next to its executable. Required on
  // state-changing (POST) endpoints; loaded lazily and cached once found.
  String? _token;

  @override
  bool get prefersPushEvents => false;

  @override
  Stream<BridgeEvent> watchEvents() => const Stream<BridgeEvent>.empty();

  @override
  Future<void> ensureStarted() async {
    var info = await _probeInfo();
    if (info == null) {
      if (!Platform.isWindows) {
        return;
      }

      final exeDir = File(Platform.resolvedExecutable).parent;
      final launcher = await _findLauncherExecutable(exeDir);
      if (!await launcher.exists()) {
        throw const HttpException('dropo launcher was not found');
      }
      final result = await Process.run(launcher.path, const [
        '--start-core',
      ], workingDirectory: launcher.parent.path);
      if (result.exitCode != 0) {
        throw HttpException(
          'failed to start elevated dropo core: ${result.stderr}',
        );
      }

      for (var i = 0; i < 80; i++) {
        info = await _probeInfo();
        if (info != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    info ??= await _probeInfo();
    if (info != null) {
      final compatibilityError = coreCompatibilityError(
        info,
        expectedVersion: _bundledAppVersion,
        expectedBuildHash: _bundledBuildHash,
      );
      if (compatibilityError != null) {
        throw HttpException(
          'Уже запущено другое ядро Dropo: $compatibilityError. '
          'Полностью закройте предыдущую Dropo и запустите эту сборку снова.',
        );
      }
      unawaited(
        _postMap(
          '/api/tray/ensure',
          timeout: const Duration(seconds: 3),
        ).catchError((_) => <String, dynamic>{}),
      );
      return;
    }
    throw const HttpException('dropo-core не ответил на локальном bridge');
  }

  @override
  Future<void> dispose() async {
    try {
      await finalizeQuit();
    } catch (_) {}
  }

  Future<File> _findLauncherExecutable(Directory exeDir) async {
    final sep = Platform.pathSeparator;
    final candidates = <File>[
      File('${exeDir.parent.path}${sep}dropo.exe'),
      File('${exeDir.parent.parent.path}${sep}dropo.exe'),
    ];
    final current = File(
      Platform.resolvedExecutable,
    ).absolute.path.toLowerCase();
    for (final candidate in candidates) {
      if (candidate.absolute.path.toLowerCase() != current &&
          await candidate.exists()) {
        return candidate;
      }
    }
    return candidates.first;
  }

  // _ensureToken reads the bridge token file (written by dropo-core next to its
  // executable) once it is available. It is safe to call repeatedly: it retries
  // until the file exists, then caches the value.
  Future<void> _ensureToken({Duration wait = Duration.zero}) async {
    if (_token != null) {
      return;
    }
    final deadline = DateTime.now().add(wait);
    do {
      try {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final sep = Platform.pathSeparator;
        final candidates = <File>[
          if (Platform.environment['LOCALAPPDATA'] case final local?)
            File('$local${sep}dropo${sep}bridge-token'),
          File('${exeDir.path}${sep}bridge-token'),
          File('${exeDir.path}${sep}resources${sep}bridge-token'),
          File('${exeDir.path}${sep}resources${sep}app${sep}bridge-token'),
        ];
        for (final candidate in candidates) {
          if (await candidate.exists()) {
            final value = (await candidate.readAsString()).trim();
            if (value.isNotEmpty) {
              _token = value;
              return;
            }
          }
        }
      } catch (_) {
        // The elevated core may be restoring the hand-off file. Retry below
        // while the caller's bounded wait remains.
      }
      if (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } while (_token == null && DateTime.now().isBefore(deadline));
  }

  @override
  Future<CoreStatus> status() async {
    return CoreStatus.fromJson(
      await _getMap('/api/status', timeout: const Duration(seconds: 8)),
    );
  }

  @override
  Future<SubscriptionInfo> subscription() async {
    return SubscriptionInfo.fromJson(await callMap('GetCurrentSubscription'));
  }

  @override
  Future<Map<String, dynamic>> appConfig() {
    return callMap('GetAppConfig');
  }

  @override
  Future<ProfileListInfo> profiles() async {
    return ProfileListInfo.fromJson(await callMap('GetProfiles'));
  }

  @override
  Future<Map<String, dynamic>> setActiveProfile(int id) {
    return callMap('SetActiveProfile', args: [id]);
  }

  @override
  Future<Map<String, dynamic>> createProfile(String name) {
    return callMap('CreateProfile', args: [name.trim()]);
  }

  @override
  Future<Map<String, dynamic>> updateProfile(int id, String name) {
    return callMap('UpdateProfile', args: [id, name.trim()]);
  }

  @override
  Future<Map<String, dynamic>> deleteProfile(int id) {
    return callMap('DeleteProfile', args: [id]);
  }

  @override
  Future<Map<String, dynamic>> saveAppConfig(AppConfig config) {
    return callMap(
      'SaveAppConfig',
      args: [
        config.autoStart,
        config.enableLogging,
        config.checkUpdates,
        config.notifications,
        config.autoUpdateSub,
        config.theme,
        config.language,
        config.logLevel,
        config.subUpdateInterval,
      ],
    );
  }

  // resolveAutoStartPrompt records the user's answer to the first-run autostart
  // dialog. enable=true keeps launch-at-logon on and registers it; enable=false
  // flips the stored default off and unregisters it. Either way the choice is
  // remembered so the dialog is not shown again.
  @override
  Future<Map<String, dynamic>> resolveAutoStartPrompt(bool enable) {
    return callMap('ResolveAutoStartPrompt', args: [enable]);
  }

  @override
  Future<Map<String, dynamic>> routingMode() {
    return callMap('GetRoutingMode');
  }

  @override
  Future<Map<String, dynamic>> setRoutingMode(String mode) {
    return callMap('SetRoutingMode', args: [mode]);
  }

  @override
  Future<Map<String, dynamic>> networkMode() {
    return callMap('GetNetworkMode');
  }

  @override
  Future<Map<String, dynamic>> setNetworkMode(String mode) {
    return callMap('SetNetworkMode', args: [mode]);
  }

  @override
  Future<Map<String, dynamic>> hideRuTraffic() {
    return callMap('GetHideRuTraffic');
  }

  @override
  Future<Map<String, dynamic>> setHideRuTraffic(
    bool enabled,
    String proxyAddress,
  ) {
    return callMap('SetHideRuTraffic', args: [enabled, proxyAddress]);
  }

  @override
  Future<Map<String, dynamic>> freeAccessConfig() {
    return callMap('GetFreeAccessConfig');
  }

  @override
  Future<Map<String, dynamic>> setDisableFreeAccess(bool disabled) {
    return callMap('SetDisableFreeAccess', args: [disabled]);
  }

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) {
    return callMap('SetFreeAccessServiceMethod', args: [tag, method]);
  }

  @override
  Future<Map<String, dynamic>> setZapretServiceStrategy(
    String tag,
    String mode,
    String strategyTag,
  ) {
    return callMap('SetZapretServiceStrategy', args: [tag, mode, strategyTag]);
  }

  @override
  Future<Map<String, dynamic>> setHomeRouteServiceVisible(
    String tag,
    bool visible,
  ) {
    return callMap('SetHomeRouteServiceVisible', args: [tag, visible]);
  }

  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    final data = await callMap(
      live ? 'GetBypassRouteSummary' : 'GetFreeAccessConfig',
    );
    return routeServicesFromPayload(data, live: live);
  }

  @override
  Future<List<String>> logs() async {
    final data = await _getMap('/api/logs', query: {'lastN': '260'});
    final raw = data['logs'];
    if (raw is! List) {
      return const [];
    }
    return raw.map((item) => item.toString()).toList(growable: false);
  }

  @override
  Future<List<BridgeEvent>> events({required int since}) async {
    final data = await _getMap('/api/events', query: {'since': '$since'});
    final raw = data['events'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(BridgeEvent.fromJson)
        .toList(growable: false);
  }

  @override
  Future<UpdateInfo> checkUpdates() async {
    return UpdateInfo.fromJson(
      await callMap('CheckForUpdates', timeout: const Duration(seconds: 40)),
    );
  }

  @override
  Future<Map<String, dynamic>> installUpdate() {
    return callMap(
      'DownloadAndInstallUpdate',
      timeout: const Duration(minutes: 15),
    );
  }

  @override
  Future<TrafficStatsInfo> trafficStats() async {
    return TrafficStatsInfo.fromJson(await callMap('GetTrafficStats'));
  }

  @override
  Future<Map<String, dynamic>> resetTrafficStats() {
    return callMap('ResetTrafficStats');
  }

  @override
  Future<List<WireGuardInfo>> wireGuards() async {
    final data = await callMap('GetWireGuardList');
    final raw = data['configs'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(WireGuardInfo.fromJson)
        .toList(growable: false);
  }

  @override
  Future<WireGuardInfo?> wireGuardConfig(String tag) async {
    final data = await callMap('GetWireGuardConfig', args: [tag]);
    if (data['success'] == false) {
      return null;
    }
    return WireGuardInfo.fromJson(data);
  }

  @override
  Future<Map<String, dynamic>> parseWireGuard(String config) {
    return callMap('ParseWireGuardConfigAPI', args: [config]);
  }

  @override
  Future<Map<String, dynamic>> addWireGuard(
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  ) {
    return callMap(
      'AddWireGuard',
      args: [tag, name, config, camouflageEnabled],
    );
  }

  @override
  Future<Map<String, dynamic>> updateWireGuard(
    String oldTag,
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  ) {
    return callMap(
      'UpdateWireGuard',
      args: [oldTag, tag, name, config, camouflageEnabled],
    );
  }

  @override
  Future<Map<String, dynamic>> deleteWireGuard(String tag) {
    return callMap('DeleteWireGuard', args: [tag]);
  }

  @override
  Future<Map<String, dynamic>> testSubscription(String value) {
    return callMap(
      'TestVPNConnection',
      args: [value.trim()],
      timeout: const Duration(minutes: 2),
    );
  }

  @override
  Future<Map<String, dynamic>> runQuickCheck() {
    return callMap(
      'RunClientQuickCheck',
      args: [false],
      timeout: const Duration(minutes: 2),
    );
  }

  @override
  Future<Map<String, dynamic>> captureFingerprint() {
    return callMap(
      'CaptureDPIFingerprint',
      timeout: const Duration(minutes: 4),
    );
  }

  @override
  Future<void> openFingerprintFolder() async {
    await callMap('OpenFingerprintFolder');
  }

  @override
  Future<void> openConfigFolder() async {
    await callMap('OpenConfigFolder');
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    return _postMap(
      value ? '/api/connect' : '/api/disconnect',
      timeout: value
          ? const Duration(seconds: 90)
          : const Duration(seconds: 45),
    );
  }

  @override
  Future<VpnConflictInfo> externalVpnConflicts() async {
    return VpnConflictInfo.fromJson(
      await callMap(
        'CheckExternalVPNConflicts',
        timeout: const Duration(seconds: 7),
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> downloadDependencies() async {
    return _postMap(
      '/api/dependencies/download',
      timeout: const Duration(minutes: 11),
    );
  }

  @override
  Future<List<VpnSourceInfo>> vpnSources() async {
    final result = await callMap('GetVPNSources');
    if (result['success'] == false || result['sources'] is! List) {
      throw StateError('Не удалось получить источники VPN');
    }
    final raw = result['sources'];
    return raw is List
        ? raw.map(_asMap).map(VpnSourceInfo.fromJson).toList(growable: false)
        : const <VpnSourceInfo>[];
  }

  @override
  Future<Map<String, dynamic>> addVpnSource(String name, String uri) {
    return callMap(
      'AddVPNSource',
      args: [name.trim(), uri.trim()],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async {
    final result = await callMap('GetPublicVPNProviders');
    if (result['success'] == false) {
      throw StateError(result['error']?.toString() ?? 'Каталог недоступен');
    }
    final raw = result['providers'];
    return raw is List
        ? raw
              .map(_asMap)
              .map(PublicVpnProviderInfo.fromJson)
              .toList(growable: false)
        : const [];
  }

  @override
  Future<Map<String, dynamic>> addPublicVpnSource(String id, bool consent) {
    return callMap(
      'AddPublicVPNSource',
      args: [id, consent],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<Map<String, dynamic>> removeVpnSource(String id) {
    return callMap(
      'RemoveVPNSource',
      args: [id],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<Map<String, dynamic>> setVpnSourceNode(String id, int nodeIndex) {
    return callMap(
      'SetVPNSourceNode',
      args: [id, nodeIndex],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<Map<String, dynamic>> setVpnSourceEnabled(String id, bool enabled) {
    return callMap(
      'SetVPNSourceEnabled',
      args: [id, enabled],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<Map<String, dynamic>> moveVpnSource(String id, int newIndex) {
    return callMap(
      'MoveVPNSource',
      args: [id, newIndex],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<Map<String, dynamic>> refreshVpnSources() {
    return callMap('RefreshVPNSources', timeout: const Duration(minutes: 3));
  }

  @override
  Future<Map<String, dynamic>> saveSubscription(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return callMap(
        'RemoveVPNSubscription',
        timeout: const Duration(minutes: 2),
      );
    }
    return callMap(
      'SetVPNSubscription',
      args: [trimmed],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<TelegramExitInfo> telegramProxyStatus() async {
    return TelegramExitInfo.fromJson(await callMap('TelegramProxyStatus'));
  }

  @override
  Future<Map<String, dynamic>> openTelegramProxySettings() {
    return callMap('OpenTelegramProxySettings');
  }

  @override
  Future<Map<String, dynamic>> acknowledgeTelegramProxyRemoved() {
    return callMap('AcknowledgeTelegramProxyRemoved');
  }

  @override
  Future<TelegramExitInfo> prepareQuit() async {
    return TelegramExitInfo.fromJson(
      await _postMap('/api/quit', timeout: const Duration(seconds: 15)),
    );
  }

  @override
  Future<void> finalizeQuit() async {
    await _postMap('/api/quit/finalize', timeout: const Duration(seconds: 3));
  }

  @override
  Future<String> diagnostics() async {
    try {
      final data = await callMap(
        'AndroidDiagnostics',
        timeout: const Duration(seconds: 8),
      );
      final text = data['text']?.toString() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    } catch (_) {}
    return (await logs()).join('\n');
  }

  @override
  Future<void> openLogsFolder() async {
    await callMap('OpenLogs');
  }

  @override
  Future<void> showWindow() async {
    await callMap('ShowWindow', timeout: const Duration(seconds: 2));
  }

  @override
  Future<void> hideWindow() async {
    await callMap('HideWindow', timeout: const Duration(seconds: 2));
  }

  @override
  Future<void> openExternal(String link) async {
    await callMap('OpenExternalLink', args: [link]);
  }

  @override
  Future<AndroidCompatibilityInfo> androidCompatibility() async {
    return AndroidCompatibilityInfo.unsupported();
  }

  @override
  Future<AndroidVpnProtection> androidVpnProtection() async {
    return AndroidVpnProtection.unknown();
  }

  @override
  Future<Map<String, dynamic>> androidOpenVpnSettings() async {
    return {
      'success': false,
      'unsupported': true,
      'error': 'Системные настройки VPN доступны только на Android',
    };
  }

  @override
  Future<Map<String, dynamic>> setAndroidCompatibilityPromptDismissed(
    bool dismissed,
  ) async {
    return {'success': true, 'dismissed': dismissed};
  }

  @override
  Future<Map<String, dynamic>> createDropoSpace() async {
    return {
      'success': false,
      'error': 'Dropo Space доступен только в Android-версии',
    };
  }

  @override
  Future<Map<String, dynamic>> moveAppToDropoSpace(String packageName) async {
    return {
      'success': false,
      'error': 'Dropo Space доступен только в Android-версии',
    };
  }

  @override
  Future<Map<String, dynamic>> openDropoSpaceMarket(String packageName) async {
    return {
      'success': false,
      'error': 'Dropo Space доступен только в Android-версии',
    };
  }

  @override
  Future<Map<String, dynamic>> requestDropoSpaceShortcut(
    String packageName,
  ) async {
    return {
      'success': false,
      'error': 'Ярлыки Dropo Space доступны только в Android-версии',
    };
  }

  @override
  Future<Map<String, dynamic>> openCloneHelpSearch() async {
    return {
      'success': false,
      'error': 'Поиск инструкции доступен только в Android-версии',
    };
  }

  @override
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<Object?> args = const [],
    Duration timeout = const Duration(seconds: 12),
  }) async {
    return _postMap(
      '/api/call',
      body: {'method': method, 'args': args},
      timeout: timeout,
    );
  }

  Future<Map<String, dynamic>?> _probeInfo() async {
    try {
      return await _getMap('/api/info');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _getMap(
    String path, {
    Map<String, String> query = const {},
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final uri = baseUri.replace(
        path: path,
        queryParameters: query.isEmpty ? null : query,
      );
      // Attach the bridge token when available: some GET endpoints (e.g.
      // /api/logs) are guarded because they can expose sensitive detail. Open
      // health-probe GETs simply ignore the header. Retry once with a fresh
      // token if a guarded endpoint rejects a stale one (core was relaunched).
      for (var attempt = 0; attempt < 2; attempt++) {
        await _ensureToken();
        final request = await client.getUrl(uri);
        if (_token != null) {
          request.headers.set('X-Dropo-Token', _token!);
        }
        try {
          final response = await request.close().timeout(timeout);
          return await _decodeResponse(response);
        } on HttpException catch (error) {
          final tokenRejected =
              error.message.contains('X-Dropo-Token') ||
              error.message.contains('missing or invalid');
          if (attempt == 0 && tokenRejected) {
            _token = null;
            await Future<void>.delayed(const Duration(milliseconds: 150));
            continue;
          }
          rethrow;
        }
      }
      throw const HttpException('dropo-core bridge GET failed');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postMap(
    String path, {
    Map<String, dynamic> body = const {},
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        await _ensureToken(wait: const Duration(seconds: 2));
        final request = await client.postUrl(baseUri.replace(path: path));
        request.headers.contentType = ContentType.json;
        if (_token != null) {
          request.headers.set('X-Dropo-Token', _token!);
        }
        request.write(jsonEncode(body));
        try {
          final response = await request.close().timeout(timeout);
          return await _decodeResponse(response);
        } on HttpException catch (error) {
          final tokenRejected =
              error.message.contains('X-Dropo-Token') ||
              error.message.contains('missing or invalid');
          if (attempt == 0 && tokenRejected) {
            _token = null;
            await Future<void>.delayed(const Duration(milliseconds: 150));
            continue;
          }
          rethrow;
        }
      }
      throw const HttpException('dropo-core bridge request failed');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _decodeResponse(
    HttpClientResponse response,
  ) async {
    final text = await response.transform(utf8.decoder).join();
    final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    final data = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'data': decoded};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        data['error']?.toString() ?? 'HTTP ${response.statusCode}',
      );
    }
    return data;
  }

  static Uri _normalizeEndpoint(String endpoint) {
    final uri = Uri.parse(endpoint);
    if (uri.scheme == 'ws') {
      return uri.replace(scheme: 'http');
    }
    if (uri.scheme == 'wss') {
      return uri.replace(scheme: 'https');
    }
    return uri;
  }
}

class ChannelCoreBridge implements CoreBridge {
  ChannelCoreBridge({MethodChannel? channel, EventChannel? events})
    : _channel = channel ?? const MethodChannel('dropo/core'),
      _events = events ?? const EventChannel('dropo/core/events');

  final MethodChannel _channel;
  final EventChannel _events;
  Stream<BridgeEvent>? _eventStream;

  @override
  bool get prefersPushEvents => true;

  @override
  Stream<BridgeEvent> watchEvents() {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map((raw) {
          return BridgeEvent.fromJson(_asMap(raw));
        })
        .where((event) => event.name.isNotEmpty);
  }

  @override
  Future<void> ensureStarted() async {
    await _invokeMap('ensureStarted', timeout: const Duration(seconds: 8));
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<CoreStatus> status() async {
    return CoreStatus.fromJson(
      await _invokeMap('status', timeout: const Duration(seconds: 8)),
    );
  }

  @override
  Future<SubscriptionInfo> subscription() async {
    return SubscriptionInfo.fromJson(await callMap('GetCurrentSubscription'));
  }

  @override
  Future<Map<String, dynamic>> appConfig() {
    return callMap('GetAppConfig');
  }

  @override
  Future<ProfileListInfo> profiles() async {
    return ProfileListInfo.fromJson(await callMap('GetProfiles'));
  }

  @override
  Future<Map<String, dynamic>> setActiveProfile(int id) {
    return callMap('SetActiveProfile', args: [id]);
  }

  @override
  Future<Map<String, dynamic>> createProfile(String name) {
    return callMap('CreateProfile', args: [name.trim()]);
  }

  @override
  Future<Map<String, dynamic>> updateProfile(int id, String name) {
    return callMap('UpdateProfile', args: [id, name.trim()]);
  }

  @override
  Future<Map<String, dynamic>> deleteProfile(int id) {
    return callMap('DeleteProfile', args: [id]);
  }

  @override
  Future<Map<String, dynamic>> saveAppConfig(AppConfig config) {
    return callMap(
      'SaveAppConfig',
      args: [
        config.autoStart,
        config.enableLogging,
        config.checkUpdates,
        config.notifications,
        config.autoUpdateSub,
        config.theme,
        config.language,
        config.logLevel,
        config.subUpdateInterval,
      ],
    );
  }

  @override
  Future<Map<String, dynamic>> resolveAutoStartPrompt(bool enable) {
    return callMap('ResolveAutoStartPrompt', args: [enable]);
  }

  @override
  Future<Map<String, dynamic>> routingMode() {
    return callMap('GetRoutingMode');
  }

  @override
  Future<Map<String, dynamic>> setRoutingMode(String mode) {
    return callMap('SetRoutingMode', args: [mode]);
  }

  @override
  Future<Map<String, dynamic>> networkMode() {
    return callMap('GetNetworkMode');
  }

  @override
  Future<Map<String, dynamic>> setNetworkMode(String mode) {
    return callMap('SetNetworkMode', args: [mode]);
  }

  @override
  Future<Map<String, dynamic>> hideRuTraffic() {
    return callMap('GetHideRuTraffic');
  }

  @override
  Future<Map<String, dynamic>> setHideRuTraffic(
    bool enabled,
    String proxyAddress,
  ) {
    return callMap('SetHideRuTraffic', args: [enabled, proxyAddress]);
  }

  @override
  Future<Map<String, dynamic>> freeAccessConfig() {
    return callMap('GetFreeAccessConfig');
  }

  @override
  Future<Map<String, dynamic>> setDisableFreeAccess(bool disabled) {
    return callMap('SetDisableFreeAccess', args: [disabled]);
  }

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) {
    return callMap('SetFreeAccessServiceMethod', args: [tag, method]);
  }

  @override
  Future<Map<String, dynamic>> setZapretServiceStrategy(
    String tag,
    String mode,
    String strategyTag,
  ) {
    return callMap('SetZapretServiceStrategy', args: [tag, mode, strategyTag]);
  }

  @override
  Future<Map<String, dynamic>> setHomeRouteServiceVisible(
    String tag,
    bool visible,
  ) {
    return callMap('SetHomeRouteServiceVisible', args: [tag, visible]);
  }

  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    final data = await callMap(
      live ? 'GetBypassRouteSummary' : 'GetFreeAccessConfig',
    );
    return routeServicesFromPayload(data, live: live);
  }

  @override
  Future<List<String>> logs() async {
    final data = await _invokeMap('logs', timeout: const Duration(seconds: 4));
    final raw = data['logs'];
    if (raw is! List) {
      return const [];
    }
    return raw.map((item) => item.toString()).toList(growable: false);
  }

  @override
  Future<List<BridgeEvent>> events({required int since}) async {
    final data = await _invokeMap(
      'events',
      arguments: {'since': since},
      timeout: const Duration(seconds: 4),
    );
    final raw = data['events'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .map(_asMap)
        .where((item) => item.isNotEmpty)
        .map(BridgeEvent.fromJson)
        .toList(growable: false);
  }

  @override
  Future<UpdateInfo> checkUpdates() async {
    return UpdateInfo.fromJson(
      await callMap('CheckForUpdates', timeout: const Duration(seconds: 40)),
    );
  }

  @override
  Future<Map<String, dynamic>> installUpdate() async {
    return {
      'success': false,
      'error':
          'Android устанавливает обновление через системный установщик APK',
    };
  }

  @override
  Future<TrafficStatsInfo> trafficStats() async {
    return TrafficStatsInfo.fromJson(await callMap('GetTrafficStats'));
  }

  @override
  Future<Map<String, dynamic>> resetTrafficStats() {
    return callMap('ResetTrafficStats');
  }

  @override
  Future<List<WireGuardInfo>> wireGuards() async {
    final data = await callMap('GetWireGuardList');
    final raw = data['configs'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .map(_asMap)
        .where((item) => item.isNotEmpty)
        .map(WireGuardInfo.fromJson)
        .toList(growable: false);
  }

  @override
  Future<WireGuardInfo?> wireGuardConfig(String tag) async {
    final data = await callMap('GetWireGuardConfig', args: [tag]);
    if (data['success'] == false) {
      return null;
    }
    return WireGuardInfo.fromJson(data);
  }

  @override
  Future<Map<String, dynamic>> parseWireGuard(String config) {
    return callMap('ParseWireGuardConfigAPI', args: [config]);
  }

  @override
  Future<Map<String, dynamic>> addWireGuard(
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  ) {
    return callMap(
      'AddWireGuard',
      args: [tag, name, config, camouflageEnabled],
    );
  }

  @override
  Future<Map<String, dynamic>> updateWireGuard(
    String oldTag,
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  ) {
    return callMap(
      'UpdateWireGuard',
      args: [oldTag, tag, name, config, camouflageEnabled],
    );
  }

  @override
  Future<Map<String, dynamic>> deleteWireGuard(String tag) {
    return callMap('DeleteWireGuard', args: [tag]);
  }

  @override
  Future<Map<String, dynamic>> testSubscription(String value) {
    return callMap(
      'TestVPNConnection',
      args: [value.trim()],
      timeout: const Duration(minutes: 2),
    );
  }

  @override
  Future<Map<String, dynamic>> runQuickCheck() {
    return callMap(
      'RunClientQuickCheck',
      args: [false],
      timeout: const Duration(minutes: 2),
    );
  }

  @override
  Future<Map<String, dynamic>> captureFingerprint() {
    return callMap(
      'CaptureDPIFingerprint',
      timeout: const Duration(minutes: 4),
    );
  }

  @override
  Future<void> openFingerprintFolder() async {
    await callMap('OpenFingerprintFolder');
  }

  @override
  Future<void> openConfigFolder() async {
    await callMap('OpenConfigFolder');
  }

  @override
  Future<Map<String, dynamic>> setConnected(bool value) {
    return _invokeMap(
      'setConnected',
      arguments: {'connected': value},
      timeout: value
          ? const Duration(seconds: 90)
          : const Duration(seconds: 45),
    );
  }

  @override
  Future<VpnConflictInfo> externalVpnConflicts() async {
    return VpnConflictInfo.fromJson(
      await callMap(
        'CheckExternalVPNConflicts',
        timeout: const Duration(seconds: 7),
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> downloadDependencies() async {
    return {'success': true, 'dependencies': _androidDepsJson};
  }

  @override
  Future<List<VpnSourceInfo>> vpnSources() async {
    final current = await subscription();
    if (!current.hasSubscription) return const [];
    return [
      VpnSourceInfo(
        id: 'source-1',
        name: 'Primary',
        kind: 'subscription',
        disabled: false,
        selectedNode: 0,
        nodeCount: current.proxyCount,
        nodeNames: const [],
        lastUpdated: '',
        lastError: '',
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>> addVpnSource(String name, String uri) =>
      saveSubscription(uri);

  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async => const [];

  @override
  Future<Map<String, dynamic>> addPublicVpnSource(
    String id,
    bool consent,
  ) async => {
    'success': false,
    'error': 'Каталог бесплатных источников пока доступен на Windows',
  };

  @override
  Future<Map<String, dynamic>> removeVpnSource(String id) =>
      saveSubscription('');

  @override
  Future<Map<String, dynamic>> setVpnSourceNode(
    String id,
    int nodeIndex,
  ) async => {
    'success': nodeIndex == 0,
    'error': 'Выбор узла доступен на Windows',
  };

  @override
  Future<Map<String, dynamic>> setVpnSourceEnabled(
    String id,
    bool enabled,
  ) async => {
    'success': false,
    'error': 'Управление источниками доступно на Windows',
  };

  @override
  Future<Map<String, dynamic>> moveVpnSource(String id, int newIndex) async => {
    'success': false,
    'error': 'Порядок источников доступен на Windows',
  };

  @override
  Future<Map<String, dynamic>> refreshVpnSources() async => {'success': true};

  @override
  Future<Map<String, dynamic>> saveSubscription(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return callMap(
        'RemoveVPNSubscription',
        timeout: const Duration(minutes: 2),
      );
    }
    return callMap(
      'SetVPNSubscription',
      args: [trimmed],
      timeout: const Duration(minutes: 3),
    );
  }

  @override
  Future<TelegramExitInfo> telegramProxyStatus() async {
    if (!Platform.isWindows) {
      return TelegramExitInfo.fromJson(const {});
    }
    return TelegramExitInfo.fromJson(await callMap('TelegramProxyStatus'));
  }

  @override
  Future<Map<String, dynamic>> openTelegramProxySettings() async => {
    'success': false,
    'error': 'Очистка старого proxy требуется только на Windows',
  };

  @override
  Future<Map<String, dynamic>> acknowledgeTelegramProxyRemoved() async => {
    'success': true,
    'unchanged': true,
  };

  @override
  Future<TelegramExitInfo> prepareQuit() async {
    return TelegramExitInfo.fromJson(await callMap('PrepareQuit'));
  }

  @override
  Future<void> finalizeQuit() async {
    await _invokeMap('shutdown', timeout: const Duration(seconds: 3));
  }

  @override
  Future<String> diagnostics() async {
    final data = await _invokeMap(
      'diagnostics',
      timeout: const Duration(seconds: 10),
    );
    final text = data['text']?.toString() ?? '';
    if (text.isNotEmpty) {
      return text;
    }
    return (await logs()).join('\n');
  }

  @override
  Future<void> openLogsFolder() async {
    await callMap('OpenLogs');
  }

  @override
  Future<void> showWindow() async {
    await callMap('ShowWindow', timeout: const Duration(seconds: 2));
  }

  @override
  Future<void> hideWindow() async {
    await callMap('HideWindow', timeout: const Duration(seconds: 2));
  }

  @override
  Future<void> openExternal(String link) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final result = await _invokeMap(
      'androidOpenExternal',
      arguments: {'url': trimmed},
      timeout: const Duration(seconds: 5),
    );
    if (result['success'] == false) {
      throw Exception(
        result['error']?.toString() ?? 'Не удалось открыть ссылку',
      );
    }
  }

  @override
  Future<AndroidCompatibilityInfo> androidCompatibility() async {
    return AndroidCompatibilityInfo.fromJson(
      await _invokeMap(
        'androidCompatibility',
        timeout: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Future<AndroidVpnProtection> androidVpnProtection() async {
    final response = await _invokeMap(
      'androidVpnProtection',
      timeout: const Duration(seconds: 5),
    );
    if (response['success'] == false) {
      final message = response['error']?.toString().trim() ?? '';
      throw StateError(
        message.isEmpty ? 'Android не вернул состояние защиты VPN' : message,
      );
    }
    return AndroidVpnProtection.fromJson(response);
  }

  @override
  Future<Map<String, dynamic>> androidOpenVpnSettings() {
    return _invokeMap(
      'androidOpenVpnSettings',
      timeout: const Duration(seconds: 5),
    );
  }

  @override
  Future<Map<String, dynamic>> setAndroidCompatibilityPromptDismissed(
    bool dismissed,
  ) {
    return _invokeMap(
      'androidSetCompatibilityPromptDismissed',
      arguments: {'dismissed': dismissed},
      timeout: const Duration(seconds: 3),
    );
  }

  @override
  Future<Map<String, dynamic>> createDropoSpace() {
    return _invokeMap(
      'androidCreateDropoSpace',
      timeout: const Duration(seconds: 5),
    );
  }

  @override
  Future<Map<String, dynamic>> moveAppToDropoSpace(String packageName) {
    return _invokeMap(
      'androidMoveToDropoSpace',
      arguments: {'packageName': packageName},
      timeout: const Duration(seconds: 8),
    );
  }

  @override
  Future<Map<String, dynamic>> openDropoSpaceMarket(String packageName) {
    return _invokeMap(
      'androidOpenDropoSpaceMarket',
      arguments: {'packageName': packageName},
      timeout: const Duration(seconds: 8),
    );
  }

  @override
  Future<Map<String, dynamic>> requestDropoSpaceShortcut(String packageName) {
    return _invokeMap(
      'androidRequestDropoSpaceShortcut',
      arguments: {'packageName': packageName},
      timeout: const Duration(seconds: 5),
    );
  }

  @override
  Future<Map<String, dynamic>> openCloneHelpSearch() {
    return _invokeMap(
      'androidOpenCloneHelpSearch',
      timeout: const Duration(seconds: 5),
    );
  }

  @override
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<Object?> args = const [],
    Duration timeout = const Duration(seconds: 12),
  }) {
    return _invokeMap(
      'call',
      arguments: {'method': method, 'argsJson': jsonEncode(args)},
      timeout: timeout,
    );
  }

  Future<Map<String, dynamic>> _invokeMap(
    String method, {
    Map<String, Object?> arguments = const {},
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final raw = await _channel
        .invokeMethod<Object?>(method, arguments)
        .timeout(timeout);
    return _decodeChannelMap(raw);
  }

  Map<String, dynamic> _decodeChannelMap(Object? raw) {
    if (raw == null) {
      return <String, dynamic>{'success': true};
    }
    if (raw is String) {
      final decoded = raw.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return <String, dynamic>{'success': true, 'data': decoded};
    }
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{'success': true, 'data': raw};
  }

  static const Map<String, dynamic> _androidDepsJson = {
    'managed': false,
    'ready': true,
    'required': '',
    'installed': 'android-vpn-service',
    'sizeMB': 0,
  };
}

class MockCoreBridge implements CoreBridge {
  @override
  Future<List<PublicVpnProviderInfo>> publicVpnProviders() async => const [
    PublicVpnProviderInfo(
      id: 'demo-public',
      name: 'Бесплатный резерв · демо',
      description: 'Тестовый каталог без подключения к реальным серверам.',
      website: 'https://example.com',
    ),
  ];

  @override
  Future<Map<String, dynamic>> addPublicVpnSource(
    String id,
    bool consent,
  ) async => {
    'success': false,
    'error': 'В деморежиме подключение к публичным серверам недоступно',
  };
  bool _connected = false;
  String _subscriptionUrl = '';
  final Map<String, String> _routeMethods = <String, String>{};
  final Map<String, bool> _homeRouteVisibility = <String, bool>{};
  AppConfig _config = AppConfig.defaults.copyWith(
    autoStart: false,
    autoStartPrompted: true,
    logLevel: 'info',
  );
  int _nextEventId = 1;
  final List<BridgeEvent> _events = <BridgeEvent>[];

  Map<String, dynamic> get _versionJson => const {
    'version': 'dev',
    'fullVersion': 'dev-android-mock',
    'singboxVersion': 'libbox pending',
  };

  Map<String, dynamic> get _depsJson => const {
    'managed': false,
    'ready': true,
    'required': '',
    'installed': '',
    'sizeMB': 0,
  };

  Map<String, dynamic> get _profileJson => {
    'id': 1,
    'name': 'Android mock',
    'subscription': _subscriptionUrl,
    'wireguardCount': 0,
    'proxyCount': _subscriptionUrl.isEmpty ? 0 : 3,
    'isActive': true,
    'createdAt': DateTime(2026, 7, 4).toIso8601String(),
  };

  void _emit(String name, Map<String, dynamic> payload) {
    _events.add(BridgeEvent(id: _nextEventId++, name: name, payload: payload));
    if (_events.length > 128) {
      _events.removeAt(0);
    }
  }

  @override
  bool get prefersPushEvents => false;

  @override
  Stream<BridgeEvent> watchEvents() => const Stream<BridgeEvent>.empty();

  Map<String, dynamic> _appConfigJson() => {
    'success': true,
    'autoStart': _config.autoStart,
    'autoStartPrompted': _config.autoStartPrompted,
    'enableLogging': _config.enableLogging,
    'checkUpdates': _config.checkUpdates,
    'notifications': _config.notifications,
    'autoUpdateSub': _config.autoUpdateSub,
    'theme': _config.theme,
    'language': _config.language,
    'logLevel': _config.logLevel,
    'subUpdateInterval': _config.subUpdateInterval,
    'hideRuTraffic': _config.hideRuTraffic,
    'ruProxyAddress': _config.ruProxyAddress,
    'disableFreeAccess': _config.disableFreeAccess,
    'routingMode': _config.routingMode,
    'networkMode': _config.networkMode,
    'githubRepo': _config.githubRepo,
    'githubURL': _config.githubUrl,
    'telegramName': _config.telegramName,
    'telegramURL': _config.telegramUrl,
    'appVersion': _versionJson['version'],
    'appFullVersion': _versionJson['fullVersion'],
    'singboxVersion': _versionJson['singboxVersion'],
    'networkModeStatus': {
      'requested': _config.networkMode,
      'active': 'android_mock',
      'fallback': false,
      'label': 'Android mock',
      'description': 'UI-only Android bridge until gomobile core is ready.',
    },
  };

  @override
  Future<void> ensureStarted() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<CoreStatus> status() async {
    return CoreStatus.fromJson({
      'success': true,
      'connected': _connected,
      'running': _connected,
      'connecting': false,
      'hasError': false,
      'configExists': true,
      'singboxExists': true,
      'networkMode': 'android_mock',
      'networkModeLabel': 'Android mock',
      'networkModeDescription':
          'Мок-режим Android UI до подключения gomobile-core.',
      'dependencies': _depsJson,
      'version': _versionJson,
    });
  }

  @override
  Future<SubscriptionInfo> subscription() async {
    return SubscriptionInfo(
      hasSubscription: _subscriptionUrl.isNotEmpty,
      url: _subscriptionUrl,
      proxyCount: _subscriptionUrl.isEmpty ? 0 : 3,
    );
  }

  @override
  Future<Map<String, dynamic>> appConfig() async => _appConfigJson();

  @override
  Future<ProfileListInfo> profiles() async {
    return ProfileListInfo.fromJson({
      'success': true,
      'activeProfile': 1,
      'profiles': [_profileJson],
    });
  }

  @override
  Future<Map<String, dynamic>> setActiveProfile(int id) async {
    return {'success': id == 1, 'message': 'Mock profile is active'};
  }

  @override
  Future<Map<String, dynamic>> createProfile(String name) async {
    return {'success': false, 'error': 'Профили в Android mock не сохраняются'};
  }

  @override
  Future<Map<String, dynamic>> updateProfile(int id, String name) async {
    return {'success': false, 'error': 'Профили в Android mock не сохраняются'};
  }

  @override
  Future<Map<String, dynamic>> deleteProfile(int id) async {
    return {'success': false, 'error': 'Профили в Android mock не сохраняются'};
  }

  @override
  Future<Map<String, dynamic>> saveAppConfig(AppConfig config) async {
    _config = config;
    return {'success': true, 'message': 'Mock settings saved'};
  }

  @override
  Future<Map<String, dynamic>> resolveAutoStartPrompt(bool enable) async {
    _config = _config.copyWith(autoStart: enable, autoStartPrompted: true);
    return {'success': true, 'autoStart': enable, 'autoStartPrompted': true};
  }

  @override
  Future<Map<String, dynamic>> routingMode() async {
    return {'success': true, 'mode': _config.routingMode};
  }

  @override
  Future<Map<String, dynamic>> setRoutingMode(String mode) async {
    _config = _config.copyWith(routingMode: mode);
    return {'success': true, 'mode': mode};
  }

  @override
  Future<Map<String, dynamic>> networkMode() async {
    return {'success': true, 'mode': _config.networkMode};
  }

  @override
  Future<Map<String, dynamic>> setNetworkMode(String mode) async {
    _config = _config.copyWith(networkMode: mode);
    return {'success': true, 'mode': mode};
  }

  @override
  Future<Map<String, dynamic>> hideRuTraffic() async {
    return {
      'success': true,
      'enabled': _config.hideRuTraffic,
      'proxyAddress': _config.ruProxyAddress,
    };
  }

  @override
  Future<Map<String, dynamic>> setHideRuTraffic(
    bool enabled,
    String proxyAddress,
  ) async {
    _config = _config.copyWith(
      hideRuTraffic: enabled,
      ruProxyAddress: proxyAddress,
    );
    return {'success': true, 'enabled': enabled};
  }

  @override
  Future<Map<String, dynamic>> freeAccessConfig() async {
    return {
      'success': true,
      'enabled': !_config.disableFreeAccess,
      'disableFreeAccess': _config.disableFreeAccess,
      'freeMethodsAllowed': !_config.disableFreeAccess,
      'services': fallbackRoutes
          .map(
            (route) => {
              'tag': route.tag,
              'name': route.name,
              'effectiveMethodLabel': route.method,
              'requiresVpn': route.requiresVpn,
              'domainSuffixes': route.domainSuffixes,
              'ipCidrs': route.ipCidrs,
            },
          )
          .toList(growable: false),
      'methodOptions': const [
        {'tag': 'direct', 'label': 'Напрямую'},
        {'tag': 'vpn', 'label': 'Через VPN'},
        {'tag': 'zapret', 'label': 'Обход (Zapret)'},
      ],
      'methodCache': const {
        'openai': 'vpn',
        'youtube': 'vpn',
        'discord': 'vpn',
        'google': 'direct',
        'gosuslugi': 'direct',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> setDisableFreeAccess(bool disabled) async {
    _config = _config.copyWith(disableFreeAccess: disabled);
    return {'success': true, 'disableFreeAccess': disabled};
  }

  @override
  Future<Map<String, dynamic>> setFreeAccessServiceMethod(
    String tag,
    String method,
  ) async {
    final normalized = switch (method.trim().toLowerCase()) {
      'direct' => 'direct',
      'vpn' => 'vpn',
      'zapret' => 'zapret',
      _ => 'direct',
    };
    _routeMethods[tag] = normalized;
    return {'success': true, 'tag': tag, 'method': normalized};
  }

  @override
  Future<Map<String, dynamic>> setZapretServiceStrategy(
    String tag,
    String mode,
    String strategyTag,
  ) async {
    return {
      'success': true,
      'tag': tag,
      'mode': mode == 'manual' ? 'manual' : 'auto',
      'zapretSelectedStrategy': strategyTag,
    };
  }

  @override
  Future<Map<String, dynamic>> setHomeRouteServiceVisible(
    String tag,
    bool visible,
  ) async {
    final index = fallbackRoutes.indexWhere((route) => route.tag == tag);
    if (index < 0) {
      return {'success': false, 'error': 'Unknown route service: $tag'};
    }
    _homeRouteVisibility[tag] = visible;
    return {'success': true, 'tag': tag, 'visible': visible};
  }

  @override
  Future<List<RouteService>> routes({bool live = false}) async {
    if (!live) {
      return fallbackRoutes
          .map(
            (route) => route.copyWith(
              selectedMethod: _routeMethods[route.tag] ?? route.selectedMethod,
              homeVisible:
                  _homeRouteVisibility[route.tag] ??
                  isPrimaryHomeRouteService(route.tag),
            ),
          )
          .toList(growable: false);
    }
    return fallbackRoutes
        .map(
          (route) => RouteService(
            tag: route.tag,
            name: route.name,
            method: _connected ? route.method : 'Mock standby',
            selectedMethod: _routeMethods[route.tag] ?? route.selectedMethod,
            requiresVpn: route.requiresVpn,
            delayMs: _connected ? 24 + route.tag.length : 0,
            domainSuffixes: route.domainSuffixes,
            ipCidrs: route.ipCidrs,
            homeVisible:
                _homeRouteVisibility[route.tag] ??
                isPrimaryHomeRouteService(route.tag),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<String>> logs() async {
    return [
      'Android mock bridge ready',
      _connected ? 'Mock VPN session is connected' : 'Mock VPN session is idle',
      'gomobile-core integration pending',
    ];
  }

  @override
  Future<List<BridgeEvent>> events({required int since}) async {
    return _events.where((event) => event.id > since).toList(growable: false);
  }

  @override
  Future<UpdateInfo> checkUpdates() async {
    return UpdateInfo.fromJson(const {
      'success': true,
      'hasUpdate': false,
      'currentVersion': 'dev',
      'latestVersion': 'dev',
      'releaseURL': '',
      'downloadURL': '',
      'assetName': '',
      'fileSize': 0,
      'platform': 'android',
      'selfUpdate': false,
    });
  }

  @override
  Future<Map<String, dynamic>> installUpdate() async {
    return {'success': true, 'message': 'Mock update installer started'};
  }

  @override
  Future<TrafficStatsInfo> trafficStats() async => TrafficStatsInfo.empty;

  @override
  Future<Map<String, dynamic>> resetTrafficStats() async => {'success': true};

  @override
  Future<List<WireGuardInfo>> wireGuards() async => const [];

  @override
  Future<WireGuardInfo?> wireGuardConfig(String tag) async => null;

  @override
  Future<Map<String, dynamic>> parseWireGuard(String config) async {
    return {'success': true, 'tag': 'mock-wg', 'name': 'Mock WireGuard'};
  }

  @override
  Future<Map<String, dynamic>> addWireGuard(
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  ) async {
    return {'success': true, 'tag': tag, 'name': name};
  }

  @override
  Future<Map<String, dynamic>> updateWireGuard(
    String oldTag,
    String tag,
    String name,
    String config,
    bool camouflageEnabled,
  ) async {
    return {'success': true, 'tag': tag, 'name': name};
  }

  @override
  Future<Map<String, dynamic>> deleteWireGuard(String tag) async {
    return {'success': true, 'tag': tag};
  }

  @override
  Future<Map<String, dynamic>> testSubscription(String value) async {
    return {
      'success': value.trim().isNotEmpty,
      'count': value.trim().isEmpty ? 0 : 3,
      'isDirectLink': value.contains('://'),
      'proxies': const [],
      if (value.trim().isEmpty) 'error': 'Введите ссылку подписки',
    };
  }

  @override
  Future<Map<String, dynamic>> runQuickCheck() async {
    return {'success': true, 'mock': true};
  }

  @override
  Future<Map<String, dynamic>> captureFingerprint() async {
    return {'success': true, 'mock': true};
  }

  @override
  Future<void> openFingerprintFolder() async {}

  @override
  Future<void> openConfigFolder() async {}

  @override
  Future<Map<String, dynamic>> setConnected(bool value) async {
    _connected = value;
    _emit('vpn-status-changed', {'running': value, 'connected': value});
    return {'success': true, 'running': value};
  }

  @override
  Future<VpnConflictInfo> externalVpnConflicts() async {
    return VpnConflictInfo.fromJson(const {
      'supported': true,
      'hasConflicts': false,
      'conflicts': [],
      'warning': '',
    });
  }

  @override
  Future<Map<String, dynamic>> downloadDependencies() async {
    return {'success': true, 'dependencies': _depsJson};
  }

  @override
  Future<List<VpnSourceInfo>> vpnSources() async {
    if (_subscriptionUrl.isEmpty) return const [];
    return const [
      VpnSourceInfo(
        id: 'source-1',
        name: 'Demo source',
        kind: 'subscription',
        disabled: false,
        selectedNode: 0,
        nodeCount: 3,
        nodeNames: ['Provider node 1', 'Provider node 2', 'Provider node 3'],
        lastUpdated: '',
        lastError: '',
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>> addVpnSource(String name, String uri) =>
      saveSubscription(uri);

  @override
  Future<Map<String, dynamic>> removeVpnSource(String id) =>
      saveSubscription('');

  @override
  Future<Map<String, dynamic>> setVpnSourceNode(
    String id,
    int nodeIndex,
  ) async => {'success': true};

  @override
  Future<Map<String, dynamic>> setVpnSourceEnabled(
    String id,
    bool enabled,
  ) async => {'success': true};

  @override
  Future<Map<String, dynamic>> moveVpnSource(String id, int newIndex) async => {
    'success': true,
  };

  @override
  Future<Map<String, dynamic>> refreshVpnSources() async => {'success': true};

  @override
  Future<Map<String, dynamic>> saveSubscription(String value) async {
    _subscriptionUrl = value.trim();
    return {
      'success': true,
      'proxyCount': _subscriptionUrl.isEmpty ? 0 : 3,
      'wasRunning': _connected,
    };
  }

  @override
  Future<TelegramExitInfo> telegramProxyStatus() async {
    return TelegramExitInfo.fromJson(const {});
  }

  @override
  Future<Map<String, dynamic>> openTelegramProxySettings() async => {
    'success': true,
  };

  @override
  Future<Map<String, dynamic>> acknowledgeTelegramProxyRemoved() async => {
    'success': true,
  };

  @override
  Future<TelegramExitInfo> prepareQuit() async {
    return TelegramExitInfo.fromJson(const {
      'showNotice': false,
      'injected': false,
      'recommendRemove': false,
    });
  }

  @override
  Future<void> finalizeQuit() async {}

  @override
  Future<String> diagnostics() async {
    return [
      'dropo mock diagnostics',
      'connected: $_connected',
      'subscription: ${_subscriptionUrl.isEmpty ? 'empty' : 'configured'}',
      ...await logs(),
    ].join('\n');
  }

  @override
  Future<void> openLogsFolder() async {}

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> hideWindow() async {}

  @override
  Future<void> openExternal(String link) async {}

  @override
  Future<AndroidCompatibilityInfo> androidCompatibility() async {
    return AndroidCompatibilityInfo.fromJson(const {
      'success': true,
      'supported': true,
      'manufacturer': 'Google',
      'model': 'Pixel Mock',
      'deviceLabel': 'Google Pixel Mock',
      'androidVersion': '16',
      'sdk': 36,
      'dropoSpaceSupported': true,
      'dropoSpaceReady': false,
      'dropoSpacePaused': false,
      'dropoSpaceCanCreate': true,
      'privateSpaceSupported': true,
      'promptDismissed': false,
      'searchUrl':
          'https://www.google.com/search?q=Google+Pixel+Mock+Android+16+как+клонировать+приложение',
      'riskApps': [
        {
          'packageName': 'ru.oneme.app',
          'name': 'MAX',
          'installed': true,
          'inDropoSpace': false,
          'status': 'installed',
        },
        {
          'packageName': 'ru.rostel',
          'name': 'Госуслуги',
          'installed': false,
          'inDropoSpace': false,
          'status': 'not_installed',
        },
      ],
    });
  }

  @override
  Future<AndroidVpnProtection> androidVpnProtection() async {
    return AndroidVpnProtection.unknown();
  }

  @override
  Future<Map<String, dynamic>> androidOpenVpnSettings() async {
    return {
      'success': false,
      'unsupported': true,
      'error': 'Системные настройки VPN недоступны в деморежиме',
    };
  }

  @override
  Future<Map<String, dynamic>> setAndroidCompatibilityPromptDismissed(
    bool dismissed,
  ) async {
    return {'success': true, 'dismissed': dismissed};
  }

  @override
  Future<Map<String, dynamic>> createDropoSpace() async {
    return {
      'success': true,
      'action': 'provisioning_started',
      'message': 'Mock Dropo Space setup opened',
    };
  }

  @override
  Future<Map<String, dynamic>> moveAppToDropoSpace(String packageName) async {
    return {
      'success': true,
      'action': 'open_market',
      'packageName': packageName,
      'message': 'Mock app profile install opened',
    };
  }

  @override
  Future<Map<String, dynamic>> openDropoSpaceMarket(String packageName) async {
    return {
      'success': true,
      'action': 'open_market',
      'packageName': packageName,
    };
  }

  @override
  Future<Map<String, dynamic>> requestDropoSpaceShortcut(
    String packageName,
  ) async {
    return {
      'success': true,
      'action': 'shortcut_requested',
      'packageName': packageName,
    };
  }

  @override
  Future<Map<String, dynamic>> openCloneHelpSearch() async {
    return {
      'success': true,
      'url':
          'https://www.google.com/search?q=Google+Pixel+Mock+Android+16+как+клонировать+приложение',
    };
  }

  @override
  Future<Map<String, dynamic>> callMap(
    String method, {
    List<Object?> args = const [],
    Duration timeout = const Duration(seconds: 12),
  }) async {
    return {'success': true, 'mock': true, 'method': method};
  }
}

class BridgeEvent {
  const BridgeEvent({
    required this.id,
    required this.name,
    required this.payload,
  });

  final int id;
  final String name;
  final Map<String, dynamic> payload;

  factory BridgeEvent.fromJson(Map<String, dynamic> json) {
    return BridgeEvent(
      id: _asInt(json['id']),
      name: json['name']?.toString() ?? '',
      payload: _asMap(json['payload']),
    );
  }
}

class CoreStatus {
  const CoreStatus({
    required this.connected,
    required this.running,
    required this.connecting,
    required this.disconnecting,
    required this.vpnState,
    required this.hasError,
    required this.error,
    required this.serviceMessage,
    required this.hasConfig,
    required this.singboxExists,
    required this.networkMode,
    required this.networkLabel,
    required this.networkDescription,
    required this.dependencies,
    required this.version,
  });

  final bool connected;
  final bool running;
  final bool connecting;
  final bool disconnecting;
  final String vpnState;
  final bool hasError;
  final String error;
  final String serviceMessage;
  final bool hasConfig;
  final bool singboxExists;
  final String networkMode;
  final String networkLabel;
  final String networkDescription;
  final DepsStatus dependencies;
  final VersionInfo version;

  factory CoreStatus.fromJson(Map<String, dynamic> json) {
    final rawState = json['vpnState']?.toString() ?? json['state']?.toString();
    final state = rawState == null || rawState.isEmpty
        ? (json['connected'] == true
              ? 'connected'
              : (json['connecting'] == true ? 'starting' : 'stopped'))
        : rawState;
    final connected = json['connected'] == true;
    final connecting =
        json['connecting'] == true ||
        state == 'starting' ||
        state == 'reconnecting';
    final disconnecting =
        json['disconnecting'] == true || state == 'disconnecting';
    return CoreStatus(
      connected: connected,
      running: json['running'] == true || connected,
      connecting: connecting,
      disconnecting: disconnecting,
      vpnState: state,
      hasError: json['hasError'] == true,
      error: json['error']?.toString() ?? '',
      serviceMessage:
          json['serviceMessage']?.toString() ??
          json['message']?.toString() ??
          '',
      hasConfig: json['configExists'] == true,
      singboxExists: json['singboxExists'] == true,
      networkMode: json['networkMode']?.toString() ?? 'auto',
      networkLabel: json['networkModeLabel']?.toString() ?? 'Auto',
      networkDescription: json['networkModeDescription']?.toString() ?? '',
      dependencies: DepsStatus.fromJson(_asMap(json['dependencies'])),
      version: VersionInfo.fromJson(_asMap(json['version'])),
    );
  }

  CoreStatus copyWith({
    bool? connected,
    bool? running,
    bool? connecting,
    bool? disconnecting,
    String? vpnState,
    bool? hasError,
    String? error,
    String? serviceMessage,
  }) {
    return CoreStatus(
      connected: connected ?? this.connected,
      running: running ?? this.running,
      connecting: connecting ?? this.connecting,
      disconnecting: disconnecting ?? this.disconnecting,
      vpnState: vpnState ?? this.vpnState,
      hasError: hasError ?? this.hasError,
      error: error ?? this.error,
      serviceMessage: serviceMessage ?? this.serviceMessage,
      hasConfig: hasConfig,
      singboxExists: singboxExists,
      networkMode: networkMode,
      networkLabel: networkLabel,
      networkDescription: networkDescription,
      dependencies: dependencies,
      version: version,
    );
  }
}

class DepsStatus {
  const DepsStatus({
    required this.managed,
    required this.bundled,
    required this.ready,
    required this.degraded,
    required this.required,
    required this.installed,
    required this.sizeMb,
    required this.blockedComponents,
    required this.warning,
  });

  final bool managed;
  final bool bundled;
  final bool ready;
  final bool degraded;
  final String required;
  final String installed;
  final int sizeMb;
  final List<String> blockedComponents;
  final String warning;

  factory DepsStatus.fromJson(Map<String, dynamic> json) {
    return DepsStatus(
      managed: json['managed'] == true,
      bundled: json['bundled'] == true,
      ready: json['ready'] == true,
      degraded: json['degraded'] == true,
      required: json['required']?.toString() ?? '',
      installed: json['installed']?.toString() ?? '',
      sizeMb: _asInt(json['sizeMB']),
      blockedComponents: _asStringList(json['blockedComponents']),
      warning: json['warning']?.toString() ?? '',
    );
  }
}

class VersionInfo {
  const VersionInfo({
    required this.version,
    required this.fullVersion,
    required this.singboxVersion,
  });

  final String version;
  final String fullVersion;
  final String singboxVersion;

  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    final reportedVersion = json['version']?.toString().trim() ?? '';
    final version = reportedVersion.isEmpty || reportedVersion == 'dev'
        ? _bundledAppVersion
        : reportedVersion;
    final reportedFullVersion = json['fullVersion']?.toString().trim() ?? '';
    final fullVersion =
        reportedFullVersion.isEmpty ||
            reportedFullVersion == 'dev' ||
            reportedFullVersion.startsWith('dev-')
        ? version
        : reportedFullVersion;
    return VersionInfo(
      version: version,
      fullVersion: fullVersion,
      singboxVersion: json['singboxVersion']?.toString() ?? '',
    );
  }
}

class SubscriptionInfo {
  const SubscriptionInfo({
    required this.hasSubscription,
    required this.url,
    required this.proxyCount,
  });

  final bool hasSubscription;
  final String url;
  final int proxyCount;

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    return SubscriptionInfo(
      hasSubscription: json['hasSubscription'] == true,
      url: json['url']?.toString() ?? '',
      proxyCount: _asInt(json['proxyCount']),
    );
  }
}

class VpnSourceInfo {
  const VpnSourceInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.disabled,
    required this.selectedNode,
    required this.nodeCount,
    required this.nodeNames,
    required this.lastUpdated,
    required this.lastError,
    this.publicCatalogId = '',
    this.usingCache = false,
    this.active = false,
  });

  final String id;
  final String name;
  final String kind;
  final bool disabled;
  final int selectedNode;
  final int nodeCount;
  final List<String> nodeNames;
  final String lastUpdated;
  final String lastError;
  final String publicCatalogId;
  final bool usingCache;
  final bool active;
  bool get isPublic => publicCatalogId.isNotEmpty;

  factory VpnSourceInfo.fromJson(Map<String, dynamic> json) {
    return VpnSourceInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'VPN-источник',
      kind: json['kind']?.toString() ?? 'subscription',
      disabled: json['disabled'] == true,
      selectedNode: _asInt(json['selected_node']),
      nodeCount: _asInt(json['node_count']),
      nodeNames: _asStringList(json['node_names']),
      lastUpdated: json['last_updated']?.toString() ?? '',
      lastError: json['last_error']?.toString() ?? '',
      publicCatalogId: json['public_catalog_id']?.toString() ?? '',
      usingCache: json['using_cache'] == true,
      active: json['active'] == true,
    );
  }
}

class ProfileListInfo {
  const ProfileListInfo({
    required this.success,
    required this.activeProfileId,
    required this.profiles,
    required this.error,
  });

  final bool success;
  final int activeProfileId;
  final List<ProfileInfo> profiles;
  final String error;

  factory ProfileListInfo.fromJson(Map<String, dynamic> json) {
    final activeId = _asInt(json['activeProfile']);
    final rawProfiles = json['profiles'];
    final profiles = rawProfiles is List
        ? rawProfiles
              .map(_asMap)
              .map((item) => ProfileInfo.fromJson(item, activeId))
              .where((item) => item.id > 0)
              .toList(growable: false)
        : const <ProfileInfo>[];
    return ProfileListInfo(
      success: json['success'] != false,
      activeProfileId: activeId,
      profiles: profiles,
      error: json['error']?.toString() ?? '',
    );
  }
}

class ProfileInfo {
  const ProfileInfo({
    required this.id,
    required this.name,
    required this.subscription,
    required this.wireguardCount,
    required this.proxyCount,
    required this.isActive,
    required this.createdAt,
  });

  final int id;
  final String name;
  final String subscription;
  final int wireguardCount;
  final int proxyCount;
  final bool isActive;
  final String createdAt;

  bool get isDefault => id == 1;
  bool get hasSubscription => subscription.trim().isNotEmpty || proxyCount > 0;

  factory ProfileInfo.fromJson(Map<String, dynamic> json, int activeId) {
    final id = _asInt(json['id']);
    return ProfileInfo(
      id: id,
      name: json['name']?.toString() ?? 'Профиль $id',
      subscription: json['subscription']?.toString() ?? '',
      wireguardCount: _asInt(json['wireguardCount']),
      proxyCount: _asInt(json['proxyCount']),
      isActive: json['isActive'] == true || (activeId > 0 && id == activeId),
      createdAt: json['createdAt']?.toString() ?? '',
    );
  }
}

class AppConfig {
  const AppConfig({
    required this.autoStart,
    required this.autoStartPrompted,
    required this.enableLogging,
    required this.checkUpdates,
    required this.notifications,
    required this.autoUpdateSub,
    required this.theme,
    required this.language,
    required this.logLevel,
    required this.subUpdateInterval,
    required this.hideRuTraffic,
    required this.ruProxyAddress,
    required this.disableFreeAccess,
    required this.routingMode,
    required this.networkMode,
    required this.githubRepo,
    required this.githubUrl,
    required this.telegramName,
    required this.telegramUrl,
  });

  final bool autoStart;
  final bool autoStartPrompted;
  final bool enableLogging;
  final bool checkUpdates;
  final bool notifications;
  final bool autoUpdateSub;
  final String theme;
  final String language;
  final String logLevel;
  final int subUpdateInterval;
  final bool hideRuTraffic;
  final String ruProxyAddress;
  final bool disableFreeAccess;
  final String routingMode;
  final String networkMode;
  final String githubRepo;
  final String githubUrl;
  final String telegramName;
  final String telegramUrl;

  static const defaults = AppConfig(
    autoStart: true,
    autoStartPrompted: true,
    enableLogging: true,
    checkUpdates: true,
    notifications: true,
    autoUpdateSub: true,
    theme: 'system',
    language: 'ru',
    logLevel: 'trace',
    subUpdateInterval: 24,
    hideRuTraffic: false,
    ruProxyAddress: '',
    disableFreeAccess: false,
    routingMode: 'blocked_only',
    networkMode: 'auto',
    githubRepo: 'sunnydjam/dropo-by-sunnydjam',
    githubUrl: 'https://github.com/sunnydjam/dropo-by-sunnydjam',
    telegramName: 'GitHub Releases',
    telegramUrl: 'https://github.com/sunnydjam/dropo-by-sunnydjam/releases',
  );

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final networkStatus = _asMap(json['networkModeStatus']);
    return AppConfig(
      autoStart: json['autoStart'] != false,
      // Missing (older core) => treat as already answered so we never prompt
      // spuriously; a fresh core sends an explicit false on first launch.
      autoStartPrompted: json['autoStartPrompted'] != false,
      enableLogging: json['enableLogging'] != false,
      checkUpdates: json['checkUpdates'] != false,
      notifications: json['notifications'] != false,
      autoUpdateSub: json['autoUpdateSub'] != false,
      theme: json['theme']?.toString() ?? 'system',
      language: json['language']?.toString() ?? 'ru',
      logLevel: json['logLevel']?.toString() ?? 'trace',
      subUpdateInterval: _asInt(json['subUpdateInterval']) == 0
          ? 24
          : _asInt(json['subUpdateInterval']),
      hideRuTraffic: json['hideRuTraffic'] == true,
      ruProxyAddress: json['ruProxyAddress']?.toString() ?? '',
      disableFreeAccess: json['disableFreeAccess'] == true,
      routingMode: json['routingMode']?.toString() ?? 'blocked_only',
      networkMode:
          json['networkMode']?.toString() ??
          networkStatus['requested']?.toString() ??
          'auto',
      githubRepo: json['githubRepo']?.toString() ?? defaults.githubRepo,
      githubUrl: json['githubURL']?.toString() ?? defaults.githubUrl,
      telegramName: json['telegramName']?.toString() ?? defaults.telegramName,
      telegramUrl: json['telegramURL']?.toString() ?? defaults.telegramUrl,
    );
  }

  AppConfig copyWith({
    bool? autoStart,
    bool? autoStartPrompted,
    bool? enableLogging,
    bool? checkUpdates,
    bool? notifications,
    bool? autoUpdateSub,
    String? theme,
    String? language,
    String? logLevel,
    int? subUpdateInterval,
    bool? hideRuTraffic,
    String? ruProxyAddress,
    bool? disableFreeAccess,
    String? routingMode,
    String? networkMode,
    String? githubRepo,
    String? githubUrl,
    String? telegramName,
    String? telegramUrl,
  }) {
    return AppConfig(
      autoStart: autoStart ?? this.autoStart,
      autoStartPrompted: autoStartPrompted ?? this.autoStartPrompted,
      enableLogging: enableLogging ?? this.enableLogging,
      checkUpdates: checkUpdates ?? this.checkUpdates,
      notifications: notifications ?? this.notifications,
      autoUpdateSub: autoUpdateSub ?? this.autoUpdateSub,
      theme: theme ?? this.theme,
      language: language ?? this.language,
      logLevel: logLevel ?? this.logLevel,
      subUpdateInterval: subUpdateInterval ?? this.subUpdateInterval,
      hideRuTraffic: hideRuTraffic ?? this.hideRuTraffic,
      ruProxyAddress: ruProxyAddress ?? this.ruProxyAddress,
      disableFreeAccess: disableFreeAccess ?? this.disableFreeAccess,
      routingMode: routingMode ?? this.routingMode,
      networkMode: networkMode ?? this.networkMode,
      githubRepo: githubRepo ?? this.githubRepo,
      githubUrl: githubUrl ?? this.githubUrl,
      telegramName: telegramName ?? this.telegramName,
      telegramUrl: telegramUrl ?? this.telegramUrl,
    );
  }
}

const Set<String> primaryHomeRouteServiceTags = <String>{
  'youtube',
  'discord',
  'meta',
  'openai',
};

bool isPrimaryHomeRouteService(String tag) =>
    primaryHomeRouteServiceTags.contains(tag.trim().toLowerCase());

String _homeRouteName(RouteService service) {
  switch (service.tag) {
    case 'meta':
      return 'Instagram';
    case 'openai':
      return 'ChatGPT';
    default:
      return service.name;
  }
}

String _normalizedHomeRoutePolicy(RouteService service) {
  switch (service.selectedMethod.trim().toLowerCase()) {
    case 'auto':
      return _isMobileShell ? 'auto' : 'direct';
    case 'vpn':
      return 'vpn';
    case 'zapret':
      return !_isMobileShell && service.zapretSupported ? 'zapret' : 'direct';
    case 'direct':
      return 'direct';
  }
  return service.requiresVpn || service.method.toLowerCase().contains('vpn')
      ? 'vpn'
      : 'direct';
}

class RouteService {
  const RouteService({
    required this.tag,
    required this.name,
    required this.method,
    this.actualOutbound = '',
    this.selectedMethod = 'auto',
    required this.requiresVpn,
    required this.delayMs,
    this.domainSuffixes = const [],
    this.ipCidrs = const [],
    this.zapretSupported = false,
    this.zapretStrategyMode = 'auto',
    this.zapretSelectedStrategy = '',
    this.zapretEffectiveStrategy = '',
    this.zapretEffectiveStrategyLabel = '',
    this.zapretStrategySource = '',
    this.zapretStrategyNotFound = false,
    this.zapretStrategyOptions = const [],
    this.homeVisible = false,
  });

  final String tag;
  final String name;
  final String method;
  final String actualOutbound;
  final String selectedMethod;
  final bool requiresVpn;
  final int delayMs;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;
  final bool zapretSupported;
  final String zapretStrategyMode;
  final String zapretSelectedStrategy;
  final String zapretEffectiveStrategy;
  final String zapretEffectiveStrategyLabel;
  final String zapretStrategySource;
  final bool zapretStrategyNotFound;
  final List<ZapretStrategyOption> zapretStrategyOptions;
  final bool homeVisible;

  factory RouteService.fromFreeAccessJson(Map<String, dynamic> json) {
    return RouteService(
      tag: json['tag']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Service',
      method:
          json['effectiveMethodLabel']?.toString() ??
          json['methodLabel']?.toString() ??
          json['selectedMethod']?.toString() ??
          'Auto',
      actualOutbound: json['outbound']?.toString() ?? '',
      selectedMethod: _routePolicyFromJson(json),
      requiresVpn: json['requiresVpn'] == true,
      domainSuffixes: _asStringList(
        json['domainSuffixes'] ?? json['domain_suffixes'],
      ),
      ipCidrs: _asStringList(json['ipCidrs'] ?? json['ip_cidrs']),
      zapretSupported: json['zapretSupported'] == true,
      zapretStrategyMode: json['zapretStrategyMode']?.toString() ?? 'auto',
      zapretSelectedStrategy: json['zapretSelectedStrategy']?.toString() ?? '',
      zapretEffectiveStrategy:
          json['zapretEffectiveStrategy']?.toString() ?? '',
      zapretEffectiveStrategyLabel:
          json['zapretEffectiveStrategyLabel']?.toString() ?? '',
      zapretStrategySource: json['zapretStrategySource']?.toString() ?? '',
      zapretStrategyNotFound: json['zapretStrategyNotFound'] == true,
      zapretStrategyOptions: _zapretOptions(json['zapretStrategyOptions']),
      homeVisible:
          json['homeVisible'] == true ||
          isPrimaryHomeRouteService(json['tag']?.toString() ?? ''),
      delayMs: _asInt(json['delay']) == 0
          ? _asInt(
              json['delayMs'] ??
                  json['latencyMs'] ??
                  json['latencyMS'] ??
                  json['ping'],
            )
          : _asInt(json['delay']),
    );
  }

  factory RouteService.fromBypassSummaryJson(Map<String, dynamic> json) {
    return RouteService(
      tag: json['tag']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Service',
      method:
          json['method']?.toString() ??
          json['methodLabel']?.toString() ??
          json['outbound']?.toString() ??
          'Auto',
      actualOutbound: json['outbound']?.toString() ?? '',
      selectedMethod: _routePolicyFromJson(json),
      requiresVpn:
          json['requiresVpn'] == true ||
          json['method']?.toString().toLowerCase().contains('vpn') == true ||
          json['outbound']?.toString() == 'auto-select',
      domainSuffixes: _asStringList(
        json['domainSuffixes'] ?? json['domain_suffixes'],
      ),
      ipCidrs: _asStringList(json['ipCidrs'] ?? json['ip_cidrs']),
      zapretSupported: json['zapretSupported'] == true,
      zapretStrategyMode: json['zapretStrategyMode']?.toString() ?? 'auto',
      zapretSelectedStrategy: json['zapretSelectedStrategy']?.toString() ?? '',
      zapretEffectiveStrategy:
          json['zapretEffectiveStrategy']?.toString() ?? '',
      zapretEffectiveStrategyLabel:
          json['zapretEffectiveStrategyLabel']?.toString() ?? '',
      zapretStrategySource: json['zapretStrategySource']?.toString() ?? '',
      zapretStrategyNotFound: json['zapretStrategyNotFound'] == true,
      zapretStrategyOptions: _zapretOptions(json['zapretStrategyOptions']),
      homeVisible:
          json['homeVisible'] == true ||
          isPrimaryHomeRouteService(json['tag']?.toString() ?? ''),
      delayMs: _asInt(json['delay']) == 0
          ? _asInt(
              json['delayMs'] ??
                  json['latencyMs'] ??
                  json['latencyMS'] ??
                  json['ping'],
            )
          : _asInt(json['delay']),
    );
  }

  RouteService copyWith({
    String? tag,
    String? name,
    String? method,
    String? actualOutbound,
    String? selectedMethod,
    bool? requiresVpn,
    int? delayMs,
    List<String>? domainSuffixes,
    List<String>? ipCidrs,
    bool? zapretSupported,
    String? zapretStrategyMode,
    String? zapretSelectedStrategy,
    String? zapretEffectiveStrategy,
    String? zapretEffectiveStrategyLabel,
    String? zapretStrategySource,
    bool? zapretStrategyNotFound,
    List<ZapretStrategyOption>? zapretStrategyOptions,
    bool? homeVisible,
  }) {
    return RouteService(
      tag: tag ?? this.tag,
      name: name ?? this.name,
      method: method ?? this.method,
      actualOutbound: actualOutbound ?? this.actualOutbound,
      selectedMethod: selectedMethod ?? this.selectedMethod,
      requiresVpn: requiresVpn ?? this.requiresVpn,
      delayMs: delayMs ?? this.delayMs,
      domainSuffixes: domainSuffixes ?? this.domainSuffixes,
      ipCidrs: ipCidrs ?? this.ipCidrs,
      zapretSupported: zapretSupported ?? this.zapretSupported,
      zapretStrategyMode: zapretStrategyMode ?? this.zapretStrategyMode,
      zapretSelectedStrategy:
          zapretSelectedStrategy ?? this.zapretSelectedStrategy,
      zapretEffectiveStrategy:
          zapretEffectiveStrategy ?? this.zapretEffectiveStrategy,
      zapretEffectiveStrategyLabel:
          zapretEffectiveStrategyLabel ?? this.zapretEffectiveStrategyLabel,
      zapretStrategySource: zapretStrategySource ?? this.zapretStrategySource,
      zapretStrategyNotFound:
          zapretStrategyNotFound ?? this.zapretStrategyNotFound,
      zapretStrategyOptions:
          zapretStrategyOptions ?? this.zapretStrategyOptions,
      homeVisible: homeVisible ?? this.homeVisible,
    );
  }
}

@visibleForTesting
List<RouteService> routeServicesFromPayload(
  Map<String, dynamic> data, {
  required bool live,
}) {
  final raw = data['services'];
  if (live && data['success'] == false) {
    final error = data['error']?.toString().trim() ?? '';
    throw StateError(
      error.isEmpty ? 'Live route summary is unavailable' : error,
    );
  }
  if (raw is! List) {
    if (live) {
      throw StateError('Live route summary does not contain services');
    }
    return fallbackRoutes;
  }
  return raw
      .map(_asMap)
      .where((item) => item.isNotEmpty)
      .map(
        live
            ? RouteService.fromBypassSummaryJson
            : RouteService.fromFreeAccessJson,
      )
      .toList(growable: false);
}

class ZapretStrategyOption {
  const ZapretStrategyOption({required this.tag, required this.label});

  final String tag;
  final String label;
}

List<ZapretStrategyOption> _zapretOptions(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .map(_asMap)
      .where((item) => item['tag']?.toString().isNotEmpty == true)
      .map(
        (item) => ZapretStrategyOption(
          tag: item['tag'].toString(),
          label: item['label']?.toString() ?? item['tag'].toString(),
        ),
      )
      .toList(growable: false);
}

class RouteProbeProgress {
  const RouteProbeProgress({
    required this.tag,
    required this.name,
    this.method = '',
    this.status = 'waiting',
    this.error = '',
    this.attempt = 0,
    this.attemptTotal = 0,
    this.strategyIndex = 0,
    this.strategyTotal = 0,
    this.cycle = 0,
    this.cycleTotal = 0,
  });

  final String tag;
  final String name;
  final String method;
  final String status;
  final String error;
  final int attempt;
  final int attemptTotal;
  final int strategyIndex;
  final int strategyTotal;
  final int cycle;
  final int cycleTotal;

  bool get done => status == 'done';
  bool get failed => status == 'failed';
  bool get pending =>
      status == 'checking' || status == 'retrying' || status == 'voice-check';

  RouteProbeProgress copyWith({
    String? name,
    String? method,
    String? status,
    String? error,
    int? attempt,
    int? attemptTotal,
    int? strategyIndex,
    int? strategyTotal,
    int? cycle,
    int? cycleTotal,
  }) {
    return RouteProbeProgress(
      tag: tag,
      name: name ?? this.name,
      method: method ?? this.method,
      status: status ?? this.status,
      error: error ?? this.error,
      attempt: attempt ?? this.attempt,
      attemptTotal: attemptTotal ?? this.attemptTotal,
      strategyIndex: strategyIndex ?? this.strategyIndex,
      strategyTotal: strategyTotal ?? this.strategyTotal,
      cycle: cycle ?? this.cycle,
      cycleTotal: cycleTotal ?? this.cycleTotal,
    );
  }
}

class AndroidCompatibilityInfo {
  const AndroidCompatibilityInfo({
    required this.supported,
    required this.manufacturer,
    required this.model,
    required this.deviceLabel,
    required this.androidVersion,
    required this.sdk,
    required this.dropoSpaceSupported,
    required this.dropoSpaceReady,
    required this.dropoSpacePaused,
    required this.dropoSpaceCanCreate,
    required this.privateSpaceSupported,
    required this.promptDismissed,
    required this.searchUrl,
    required this.riskApps,
  });

  final bool supported;
  final String manufacturer;
  final String model;
  final String deviceLabel;
  final String androidVersion;
  final int sdk;
  final bool dropoSpaceSupported;
  final bool dropoSpaceReady;
  final bool dropoSpacePaused;
  final bool dropoSpaceCanCreate;
  final bool privateSpaceSupported;
  final bool promptDismissed;
  final String searchUrl;
  final List<AndroidRiskApp> riskApps;

  List<AndroidRiskApp> get installedRiskApps =>
      riskApps.where((app) => app.installed).toList(growable: false);

  List<AndroidRiskApp> get inDropoSpaceApps =>
      riskApps.where((app) => app.inDropoSpace).toList(growable: false);

  bool get hasInstalledRiskApps => installedRiskApps.isNotEmpty;

  bool get canOfferDropoSpace =>
      dropoSpaceReady || dropoSpaceCanCreate || dropoSpaceSupported;

  factory AndroidCompatibilityInfo.fromJson(Map<String, dynamic> json) {
    final rawApps = json['riskApps'];
    final apps = rawApps is List
        ? rawApps
              .map(_asMap)
              .where((item) => item.isNotEmpty)
              .map(AndroidRiskApp.fromJson)
              .toList(growable: false)
        : const <AndroidRiskApp>[];
    return AndroidCompatibilityInfo(
      supported: json['supported'] != false,
      manufacturer: json['manufacturer']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      deviceLabel:
          json['deviceLabel']?.toString() ??
          [json['manufacturer'], json['model']]
              .whereType<Object>()
              .map((value) => value.toString())
              .where((value) => value.trim().isNotEmpty)
              .join(' '),
      androidVersion: json['androidVersion']?.toString() ?? '',
      sdk: _asInt(json['sdk']),
      dropoSpaceSupported: json['dropoSpaceSupported'] == true,
      dropoSpaceReady: json['dropoSpaceReady'] == true,
      dropoSpacePaused: json['dropoSpacePaused'] == true,
      dropoSpaceCanCreate: json['dropoSpaceCanCreate'] == true,
      privateSpaceSupported: json['privateSpaceSupported'] == true,
      promptDismissed: json['promptDismissed'] == true,
      searchUrl: json['searchUrl']?.toString() ?? '',
      riskApps: apps,
    );
  }

  factory AndroidCompatibilityInfo.unsupported() {
    return const AndroidCompatibilityInfo(
      supported: false,
      manufacturer: '',
      model: '',
      deviceLabel: '',
      androidVersion: '',
      sdk: 0,
      dropoSpaceSupported: false,
      dropoSpaceReady: false,
      dropoSpacePaused: false,
      dropoSpaceCanCreate: false,
      privateSpaceSupported: false,
      promptDismissed: true,
      searchUrl: '',
      riskApps: [],
    );
  }
}

class AndroidRiskApp {
  const AndroidRiskApp({
    required this.packageName,
    required this.name,
    required this.installed,
    required this.inDropoSpace,
    required this.status,
  });

  final String packageName;
  final String name;
  final bool installed;
  final bool inDropoSpace;
  final String status;

  bool get actionable => installed && !inDropoSpace;

  String get statusText {
    if (inDropoSpace) {
      return 'в Dropo Space';
    }
    if (installed) {
      return 'установлено';
    }
    return 'не установлено';
  }

  factory AndroidRiskApp.fromJson(Map<String, dynamic> json) {
    return AndroidRiskApp(
      packageName: json['packageName']?.toString() ?? '',
      name: json['name']?.toString() ?? json['packageName']?.toString() ?? '',
      installed: json['installed'] == true,
      inDropoSpace: json['inDropoSpace'] == true,
      status: json['status']?.toString() ?? '',
    );
  }
}

class TrafficDataInfo {
  const TrafficDataInfo({
    required this.uploaded,
    required this.downloaded,
    required this.duration,
    required this.uploadedStr,
    required this.downloadedStr,
    required this.durationStr,
  });

  final int uploaded;
  final int downloaded;
  final int duration;
  final String uploadedStr;
  final String downloadedStr;
  final String durationStr;

  factory TrafficDataInfo.fromJson(Map<String, dynamic> json) {
    return TrafficDataInfo(
      uploaded: _asInt(json['uploaded']),
      downloaded: _asInt(json['downloaded']),
      duration: _asInt(json['duration']),
      uploadedStr: json['uploadedStr']?.toString() ?? '0 B',
      downloadedStr: json['downloadedStr']?.toString() ?? '0 B',
      durationStr: json['durationStr']?.toString() ?? '0 сек',
    );
  }
}

class TrafficStatsInfo {
  const TrafficStatsInfo({
    required this.success,
    required this.current,
    required this.last,
    required this.total,
    required this.sessions,
  });

  final bool success;
  final TrafficDataInfo current;
  final TrafficDataInfo last;
  final TrafficDataInfo total;
  final int sessions;

  static final empty = TrafficStatsInfo.fromJson(const {});

  factory TrafficStatsInfo.fromJson(Map<String, dynamic> json) {
    final total = _asMap(json['total']);
    return TrafficStatsInfo(
      success: json['success'] != false,
      current: TrafficDataInfo.fromJson(_asMap(json['current'])),
      last: TrafficDataInfo.fromJson(_asMap(json['last'])),
      total: TrafficDataInfo.fromJson(total),
      sessions: _asInt(total['sessions']),
    );
  }
}

class WireGuardInfo {
  const WireGuardInfo({
    required this.tag,
    required this.name,
    required this.endpoint,
    required this.allowedIps,
    required this.config,
    required this.privateKey,
    required this.localAddress,
    required this.dns,
    required this.mtu,
    required this.publicKey,
    required this.presharedKey,
    required this.persistentKeepalive,
    required this.camouflageEnabled,
  });

  final String tag;
  final String name;
  final String endpoint;
  final List<String> allowedIps;
  final String config;
  final String privateKey;
  final String localAddress;
  final List<String> dns;
  final int mtu;
  final String publicKey;
  final String presharedKey;
  final int persistentKeepalive;
  final bool camouflageEnabled;

  factory WireGuardInfo.fromJson(Map<String, dynamic> json) {
    final info = WireGuardInfo(
      tag: json['tag']?.toString() ?? '',
      name: json['name']?.toString() ?? json['tag']?.toString() ?? '',
      endpoint: json['endpoint']?.toString() ?? '',
      allowedIps: _asStringList(json['allowed_ips'] ?? json['allowedIPs']),
      config:
          json['config']?.toString() ?? json['configText']?.toString() ?? '',
      privateKey: json['private_key']?.toString() ?? '',
      localAddress: json['local_address']?.toString() ?? '',
      dns: _asStringList(json['dns']),
      mtu: _asInt(json['mtu']),
      publicKey: json['public_key']?.toString() ?? '',
      presharedKey: json['preshared_key']?.toString() ?? '',
      persistentKeepalive: _asInt(json['persistent_keepalive']),
      camouflageEnabled: json['camouflage_enabled'] == true,
    );
    if (info.config.isNotEmpty || info.privateKey.isEmpty) {
      return info;
    }
    return WireGuardInfo(
      tag: info.tag,
      name: info.name,
      endpoint: info.endpoint,
      allowedIps: info.allowedIps,
      config: info.toConfigText(),
      privateKey: info.privateKey,
      localAddress: info.localAddress,
      dns: info.dns,
      mtu: info.mtu,
      publicKey: info.publicKey,
      presharedKey: info.presharedKey,
      persistentKeepalive: info.persistentKeepalive,
      camouflageEnabled: info.camouflageEnabled,
    );
  }

  String toConfigText() {
    final lines = <String>[
      '[Interface]',
      if (privateKey.isNotEmpty) 'PrivateKey = $privateKey',
      if (localAddress.isNotEmpty) 'Address = $localAddress',
      if (dns.isNotEmpty) 'DNS = ${dns.join(', ')}',
      if (mtu > 0) 'MTU = $mtu',
      '',
      '[Peer]',
      if (publicKey.isNotEmpty) 'PublicKey = $publicKey',
      if (presharedKey.isNotEmpty) 'PresharedKey = $presharedKey',
      if (allowedIps.isNotEmpty) 'AllowedIPs = ${allowedIps.join(', ')}',
      if (endpoint.isNotEmpty) 'Endpoint = $endpoint',
      if (persistentKeepalive > 0) 'PersistentKeepalive = $persistentKeepalive',
    ];
    return lines.join('\n');
  }
}

class UpdateInfo {
  const UpdateInfo({
    required this.success,
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    required this.downloadUrl,
    required this.assetName,
    required this.fileSize,
    required this.platform,
    required this.selfUpdate,
    required this.distributionMode,
    required this.error,
  });

  final bool success;
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;
  final String releaseUrl;
  final String downloadUrl;
  final String assetName;
  final int fileSize;
  final String platform;
  final bool selfUpdate;
  final String distributionMode;
  final String error;

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      success: json['success'] == true,
      hasUpdate: json['hasUpdate'] == true,
      currentVersion: json['currentVersion']?.toString() ?? '',
      latestVersion: json['latestVersion']?.toString() ?? '',
      releaseUrl: json['releaseURL']?.toString() ?? '',
      downloadUrl: json['downloadURL']?.toString() ?? '',
      assetName: json['assetName']?.toString() ?? '',
      fileSize: _asInt(json['fileSize']),
      platform: json['platform']?.toString() ?? '',
      selfUpdate: json['selfUpdate'] == true,
      distributionMode: json['distributionMode']?.toString() ?? '',
      error: json['error']?.toString() ?? '',
    );
  }
}

class TelegramExitInfo {
  const TelegramExitInfo({
    required this.showNotice,
    required this.injected,
    required this.recommendRemove,
  });

  final bool showNotice;
  final bool injected;
  final bool recommendRemove;

  factory TelegramExitInfo.fromJson(Map<String, dynamic> json) {
    return TelegramExitInfo(
      showNotice: json['showNotice'] == true,
      injected: json['injected'] == true,
      recommendRemove: json['recommendRemove'] == true,
    );
  }
}

class VpnConflictInfo {
  const VpnConflictInfo({
    required this.supported,
    required this.hasConflicts,
    required this.conflicts,
    required this.warning,
  });

  final bool supported;
  final bool hasConflicts;
  final List<VpnConflictItem> conflicts;
  final String warning;

  factory VpnConflictInfo.fromJson(Map<String, dynamic> json) {
    final rawConflicts = json['conflicts'];
    final conflicts = rawConflicts is List
        ? rawConflicts
              .map(_asMap)
              .map(VpnConflictItem.fromJson)
              .where((item) => item.name.isNotEmpty)
              .toList(growable: false)
        : const <VpnConflictItem>[];
    return VpnConflictInfo(
      supported: json['supported'] == true,
      hasConflicts: json['hasConflicts'] == true || conflicts.isNotEmpty,
      conflicts: conflicts,
      warning: json['warning']?.toString() ?? '',
    );
  }
}

class VpnConflictItem {
  const VpnConflictItem({
    required this.name,
    required this.kind,
    required this.detail,
  });

  final String name;
  final String kind;
  final String detail;

  factory VpnConflictItem.fromJson(Map<String, dynamic> json) {
    return VpnConflictItem(
      name: json['name']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
    );
  }
}

class DropoHomePage extends StatefulWidget {
  const DropoHomePage({super.key, required this.bridge});

  final CoreBridge bridge;

  @override
  State<DropoHomePage> createState() => _DropoHomePageState();
}

class _DropoHomePageState extends State<DropoHomePage>
    with WidgetsBindingObserver {
  CoreStatus status = CoreStatus.fromJson(const {});
  SubscriptionInfo subscription = const SubscriptionInfo(
    hasSubscription: false,
    url: '',
    proxyCount: 0,
  );
  UpdateInfo? updateInfo;
  TelegramExitInfo legacyTelegramProxy = const TelegramExitInfo(
    showNotice: false,
    injected: false,
    recommendRemove: false,
  );
  AppConfig appConfig = AppConfig.defaults;
  List<RouteService> routes = fallbackRoutes;
  bool liveRoutesConfirmed = false;
  List<WireGuardInfo> wireGuards = const [];
  List<VpnSourceInfo> homeSources = const [];
  bool homeSourcesLoaded = false;
  bool homeSourcesFailed = false;
  bool homeSourcesLoading = false;
  DateTime? homeSourcesCheckedAt;
  int homeSourcesRequest = 0;
  List<ProfileInfo> profiles = const [];
  List<String> logs = const [];
  TrafficStatsInfo menuStats = TrafficStatsInfo.empty;
  bool booting = true;
  bool online = false;
  bool uiBusy = false;
  bool sectionBusy = false;
  bool quitting = false;
  String quitProgressMessage = '';
  int lastEventId = 0;
  int refreshFailureCount = 0;
  bool autoStartPromptShown = false;
  String activeMenuSection = 'home';
  String statusMessage = 'Запускаем dropo-core...';
  String connectionHint = 'Поднимаем локальный bridge и готовим компоненты.';
  String routeHint = '';
  String depsProgress = '';
  bool externalVpnConflictBlocked = false;
  bool connectionHintDanger = false;
  bool routeProbeActive = false;
  bool routeProbeFailed = false;
  int routeProbeExpectedCount = 0;
  bool windowVisible = true;
  String strategyTransitionNotice = '';
  String lastPublicSourceNoticeId = '';
  bool depsFailureDialogShowing = false;
  String lastDepsFailureDialogMessage = '';
  DateTime? lastDepsFailureDialogAt;
  final Map<String, String> busyTasks = <String, String>{};
  Map<String, RouteProbeProgress> routeProbeProgress =
      <String, RouteProbeProgress>{};
  final subscriptionController = TextEditingController();
  Timer? refreshTimer;
  Timer? eventsTimer;
  Timer? strategyTransitionTimer;
  StreamSubscription<BridgeEvent>? pushEventsSubscription;
  bool startupUpdateCheckScheduled = false;
  bool compatibilityNoticeShowing = false;
  double? updateProgressPercent;
  bool homeRoutesExpanded = true;
  bool preparingFullVpnSource = false;
  final List<String> _sectionHistory = [];

  bool get connectionBusy {
    return busyTasks.keys.any(isConnectionBlockingBusyTask) ||
        status.connecting ||
        status.disconnecting;
  }

  bool get _usesPushEvents => widget.bridge.prefersPushEvents;

  bool get controlsDisabled =>
      booting ||
      uiBusy ||
      sectionBusy ||
      quitting ||
      !online ||
      preparingFullVpnSource;

  bool get _mobileNeedsSubscription =>
      _isMobileShell && !status.connected && !subscription.hasSubscription;

  ProfileInfo? get activeProfile {
    for (final profile in profiles) {
      if (profile.isActive) {
        return profile;
      }
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pushEventsSubscription = widget.bridge.watchEvents().listen(
      _handlePushEvent,
      onError: (_) {},
    );
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    refreshTimer?.cancel();
    eventsTimer?.cancel();
    strategyTransitionTimer?.cancel();
    pushEventsSubscription?.cancel();
    subscriptionController.dispose();
    if (!quitting) {
      unawaited(widget.bridge.dispose());
    }
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (quitting) {
      return AppExitResponse.exit;
    }
    if (Platform.isWindows) {
      try {
        await widget.bridge.hideWindow();
      } catch (error) {
        if (mounted) {
          setState(() {
            statusMessage = 'dropo работает в трее';
            connectionHint =
                'Не удалось свернуть окно автоматически: ${_cleanError(error)}';
            connectionHintDanger = true;
          });
        }
      }
      return AppExitResponse.cancel;
    }
    unawaited(_quitApp());
    return AppExitResponse.cancel;
  }

  // Pause the polling timers while the window is hidden (minimized to tray) or
  // paused and resume them when the UI is shown again. There is nothing to render
  // while hidden, so the 0.8s/2s HTTP+JSON polling would only burn CPU and wake
  // the machine on battery. See review.md §2.1.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        if (!windowVisible && mounted) {
          setState(() => windowVisible = true);
        }
        if (online && !quitting && refreshTimer == null) {
          _startPolling();
          unawaited(_refresh(all: true));
        }
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (windowVisible && mounted) {
          setState(() => windowVisible = false);
        }
        _stopPolling();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _startPolling() {
    if (!_usesPushEvents) {
      eventsTimer ??= Timer.periodic(const Duration(milliseconds: 800), (_) {
        unawaited(_pollEvents());
      });
    }
    refreshTimer ??= Timer.periodic(
      _usesPushEvents
          ? const Duration(seconds: 20)
          : const Duration(seconds: 2),
      (_) {
        unawaited(_refresh());
      },
    );
  }

  void _stopPolling() {
    refreshTimer?.cancel();
    refreshTimer = null;
    eventsTimer?.cancel();
    eventsTimer = null;
  }

  Future<void> _bootstrap() async {
    setState(() {
      booting = true;
      statusMessage = 'Запускаем dropo-core...';
      connectionHint =
          'Окно откроется сразу, а ядро продолжит инициализацию в фоне.';
    });
    try {
      await widget.bridge.ensureStarted();
      setState(() {
        online = true;
        statusMessage = 'dropo-core запущен';
        connectionHint = 'Загружаем настройки и состояние VPN...';
      });

      _startPolling();

      await _refresh(all: true);
      _scheduleStartupUpdateCheck();
      if (!mounted) {
        return;
      }
      setState(() {
        booting = false;
        connectionHint = '';
      });
      unawaited(_maybeShowAutoStartPrompt());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        booting = false;
        online = false;
        statusMessage = 'Ядро не запустилось';
        connectionHint = error.toString();
      });
    }
  }

  // _maybeShowAutoStartPrompt shows the one-time first-run dialog that tells the
  // user dropo will launch at system startup. "OK" keeps autostart on and
  // registers it; "Нет, не надо" flips the default off and leaves it unregistered.
  // The backend records the answer so this never shows again.
  Future<void> _maybeShowAutoStartPrompt() async {
    if (!mounted || autoStartPromptShown) {
      return;
    }
    // Autostart is only wired on Windows today; skip the prompt elsewhere.
    if (!Platform.isWindows) {
      return;
    }
    if (appConfig.autoStartPrompted) {
      return;
    }
    autoStartPromptShown = true;

    final enable = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _AutoStartPromptDialog(
        onDecision: (value) => Navigator.of(dialogContext).pop(value),
      ),
    );
    if (!mounted || enable == null) {
      // Dismissed without a choice (should not happen — barrier is disabled);
      // leave it unanswered so we can ask again next launch.
      autoStartPromptShown = false;
      return;
    }

    final result = await widget.bridge.resolveAutoStartPrompt(enable);
    if (!mounted) {
      return;
    }
    final ok = result['success'] != false;
    setState(() {
      appConfig = appConfig.copyWith(
        autoStart: ok ? enable : appConfig.autoStart,
        autoStartPrompted: true,
      );
      statusMessage = ok
          ? (enable
                ? 'dropo будет запускаться при входе в систему'
                : 'Автозапуск отключён')
          : (result['error']?.toString() ?? 'Не удалось применить автозапуск');
    });
  }

  Future<void> _refresh({bool all = false}) async {
    try {
      final loadedStatus = await widget.bridge.status();
      List<String> loadedLogs = logs;
      if (all || activeMenuSection == 'logs' || !_usesPushEvents) {
        try {
          loadedLogs = await widget.bridge.logs();
        } catch (_) {
          // Status is the authoritative health signal; keep the last log snapshot
          // if the optional log request is slow during startup or shutdown.
        }
      }
      SubscriptionInfo loadedSubscription = subscription;
      List<RouteService> loadedRoutes = routes;
      var loadedRoutesConfirmed = liveRoutesConfirmed;
      if (loadedStatus.connected != status.connected ||
          !loadedStatus.connected) {
        loadedRoutesConfirmed = false;
      }
      AppConfig loadedAppConfig = appConfig;
      List<WireGuardInfo> loadedWireGuards = wireGuards;
      List<ProfileInfo> loadedProfiles = profiles;
      TelegramExitInfo loadedLegacyTelegramProxy = legacyTelegramProxy;
      if (all || loadedStatus.connected) {
        // A previous snapshot must not stay "confirmed" after the live API
        // becomes unavailable. Keep its rows only as stale UI data while the
        // diagnostics panel explicitly waits for a new core confirmation.
        loadedRoutesConfirmed = false;
        try {
          loadedRoutes = await widget.bridge.routes(
            live: loadedStatus.connected,
          );
          loadedRoutesConfirmed =
              loadedStatus.connected && loadedRoutes.isNotEmpty;
        } catch (_) {}
      }
      if (all) {
        try {
          loadedSubscription = await widget.bridge.subscription();
          loadedAppConfig = AppConfig.fromJson(await widget.bridge.appConfig());
          _dropoThemeMode.value = themeModeFromSetting(loadedAppConfig.theme);
          loadedWireGuards = await widget.bridge.wireGuards();
          loadedProfiles = (await widget.bridge.profiles()).profiles;
          loadedLegacyTelegramProxy = await widget.bridge.telegramProxyStatus();
        } catch (error) {
          if (!booting) {
            routeHint = 'Настройки ещё загружаются: ${_cleanError(error)}';
          }
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        if ((status.hasError && !loadedStatus.hasError) || !online) {
          connectionHint = '';
          connectionHintDanger = false;
        }
        refreshFailureCount = 0;
        online = true;
        if (status.connected != loadedStatus.connected) {
          homeSourcesLoaded = false;
          homeSourcesCheckedAt = null;
          homeSourcesLoading = false;
          homeSourcesRequest++;
        }
        status = loadedStatus;
        logs = loadedLogs;
        subscription = loadedSubscription;
        routes = loadedRoutes.isEmpty ? fallbackRoutes : loadedRoutes;
        liveRoutesConfirmed = loadedRoutesConfirmed;
        appConfig = loadedAppConfig;
        wireGuards = loadedWireGuards;
        profiles = loadedProfiles;
        legacyTelegramProxy = loadedLegacyTelegramProxy;
        if (all && !connectionBusy && !uiBusy) {
          routeHint = '';
        }
        if (all) {
          subscriptionController.text = loadedSubscription.url;
        }
        if (externalVpnConflictBlocked &&
            !loadedStatus.connected &&
            !connectionBusy &&
            !booting) {
          statusMessage = 'Другой VPN активен';
          connectionHint =
              'Отключите найденные VPN-подключения и запустите dropo снова.';
        } else {
          statusMessage = _statusLabel();
          if (!connectionBusy && !booting) {
            if (loadedStatus.hasError && loadedStatus.error.trim().isNotEmpty) {
              connectionHint = loadedStatus.error.trim();
              connectionHintDanger = true;
            } else if (!connectionHintDanger) {
              connectionHint = '';
              connectionHintDanger = loadedStatus.hasError;
            }
          }
        }
      });
      // Optional presentation data must not delay the connection-ready gate.
      unawaited(_refreshHomeSources(force: all));
    } catch (error) {
      if (!mounted) {
        return;
      }
      final transient = booting || connectionBusy || uiBusy || quitting;
      final message = _cleanError(error);
      setState(() {
        refreshFailureCount += 1;
        // A failed status read revokes the previous live snapshot
        // immediately. We may still show the last rows elsewhere, but never
        // label them as current core state while the core is unreachable.
        liveRoutesConfirmed = false;
        if ((transient && online) || (online && refreshFailureCount < 3)) {
          connectionHint = transient
              ? 'Ждём ответ dropo-core: $message'
              : 'dropo-core отвечает медленно: $message';
          return;
        }
        online = false;
        statusMessage = 'Нет связи с dropo-core';
        connectionHint = message;
        connectionHintDanger = true;
      });
    }
  }

  Future<void> _refreshHomeSources({bool force = false}) async {
    if (!mounted || quitting || !online) return;
    if (!force &&
        (homeSourcesLoading ||
            (homeSourcesCheckedAt != null &&
                DateTime.now().difference(homeSourcesCheckedAt!) <
                    const Duration(seconds: 10)))) {
      return;
    }
    final request = ++homeSourcesRequest;
    final requestedProfile = activeProfile?.id;
    final requestedConnected = status.connected;
    setState(() {
      homeSourcesLoading = true;
      if (force) homeSourcesLoaded = false;
    });
    try {
      final loaded = await widget.bridge.vpnSources().timeout(
        const Duration(seconds: 3),
      );
      if (!mounted || quitting || request != homeSourcesRequest) return;
      if (requestedProfile != activeProfile?.id ||
          requestedConnected != status.connected) {
        homeSourcesCheckedAt = null;
        return;
      }
      setState(() {
        homeSources = loaded;
        homeSourcesLoaded = true;
        homeSourcesFailed = false;
        homeSourcesCheckedAt = DateTime.now();
        final activePublic = requestedConnected
            ? loaded
                  .where(
                    (source) =>
                        source.active && !source.disabled && source.isPublic,
                  )
                  .firstOrNull
            : null;
        if (activePublic != null &&
            activePublic.id != lastPublicSourceNoticeId) {
          _showStrategyTransition(
            'Бесплатный публичный источник. Скорость и доступность зависят от оператора и нагрузки.',
          );
        }
        lastPublicSourceNoticeId = activePublic?.id ?? '';
      });
    } catch (_) {
      if (!mounted || quitting || request != homeSourcesRequest) return;
      setState(() {
        homeSourcesLoaded = false;
        homeSourcesFailed = true;
        homeSourcesCheckedAt = DateTime.now();
      });
    } finally {
      if (mounted && request == homeSourcesRequest) {
        setState(() => homeSourcesLoading = false);
      }
    }
  }

  Future<void> _pollEvents() async {
    if (!online || quitting) {
      return;
    }
    try {
      final events = await widget.bridge.events(since: lastEventId);
      if (events.isEmpty || !mounted) {
        return;
      }
      var quitRequested = false;
      TelegramExitInfo? preparedQuitInfo;
      setState(() {
        for (final event in events) {
          if (event.id > lastEventId) {
            lastEventId = event.id;
          }
          if (event.name == 'request-app-quit') {
            quitRequested = true;
            continue;
          }
          if (event.name == 'show-telegram-exit-notice') {
            preparedQuitInfo = TelegramExitInfo.fromJson(event.payload);
            continue;
          }
          _applyEvent(event);
        }
      });
      if (preparedQuitInfo != null) {
        unawaited(_finishPreparedQuit(preparedQuitInfo!));
      } else if (quitRequested) {
        unawaited(_quitApp());
      }
    } catch (_) {
      // Status polling will surface offline state; event polling stays quiet.
    }
  }

  void _handlePushEvent(BridgeEvent event) {
    if (!mounted || quitting) {
      return;
    }
    setState(() => _applyEvent(event));
    if (event.name == 'android-service-status' ||
        event.name == 'vpn-status-changed') {
      final state =
          event.payload['vpnState']?.toString() ??
          event.payload['state']?.toString() ??
          '';
      final terminal =
          state == 'connected' || state == 'stopped' || state == 'failed';
      if (online && terminal) {
        unawaited(_refresh());
      }
    }
  }

  void _scheduleStartupUpdateCheck() {
    if (startupUpdateCheckScheduled || !appConfig.checkUpdates) {
      return;
    }
    startupUpdateCheckScheduled = true;
    Future<void>.delayed(const Duration(seconds: 1), () async {
      if (!mounted || quitting) {
        return;
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        UpdateInfo? result;
        try {
          result = await widget.bridge.checkUpdates();
        } catch (_) {
          result = null;
        }
        if (!mounted || quitting) {
          return;
        }
        final checked = result;
        if (checked != null && checked.success) {
          final autoInstall = shouldAutomaticallyInstallUpdate(
            checked,
            enabled: appConfig.checkUpdates,
          );
          setState(() {
            updateInfo = checked;
            if (checked.hasUpdate && !connectionBusy && !uiBusy) {
              statusMessage = autoInstall
                  ? 'Автоматически обновляем до ${checked.latestVersion}'
                  : 'Доступна версия ${checked.latestVersion}';
              connectionHint = autoInstall
                  ? 'Сначала загрузим и проверим установщик, затем перезапустим dropo.'
                  : checked.selfUpdate
                  ? 'Нажмите «Обновить и перезапустить».'
                  : checked.platform.toLowerCase() == 'windows'
                  ? 'Скачайте portable-архив и замените папку приложения.'
                  : 'Нажмите «Скачать APK» для установки обновления.';
            }
          });
          if (autoInstall) {
            await _performAutomaticUpdate(checked);
            return;
          }
          if (checked.hasUpdate) {
            _showUpdateSnackBar(checked, manual: false);
          }
          return;
        }
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(seconds: 15));
        }
      }
    });
  }

  void _applyEvent(BridgeEvent event) {
    switch (event.name) {
      case 'update-progress':
        final value = event.payload['percent'];
        updateProgressPercent = value is num
            ? value.toDouble().clamp(0, 100).toDouble()
            : null;
        if (updateProgressPercent != null) {
          statusMessage =
              'Загружаем обновление: ${updateProgressPercent!.round()}%';
          connectionHint = 'После проверки целостности dropo перезапустится.';
        }
        break;
      case 'android-service-status':
      case 'vpn-status-changed':
        _applyServiceStatePayload(event.payload);
        break;
      case 'android-log':
        final line = event.payload['line']?.toString() ?? '';
        if (line.trim().isNotEmpty) {
          final nextLogs = [...logs, line];
          logs = nextLogs
              .skip(math.max(0, nextLogs.length - 320))
              .toList(growable: false);
        }
        break;
      case 'app-busy':
        final id = event.payload['id']?.toString() ?? 'core';
        final active = event.payload['active'] == true;
        final message = event.payload['message']?.toString() ?? '';
        if (active) {
          busyTasks[id] = message;
          if (id == 'app-exit' && message.trim().isNotEmpty) {
            quitProgressMessage = message;
          }
          if (id == 'discord-realtime-connect') {
            // Discord media proof is ongoing health maintenance. It may take a
            // full realtime observation window and must never make an already
            // usable VPN look like it is still connecting or disable controls.
            connectionHintDanger = false;
            connectionHint = message;
          } else if (id == 'vpn-connect' || id == 'vpn-disconnect') {
            connectionHintDanger = false;
            connectionHint = id == 'vpn-disconnect'
                ? (message.isEmpty ? 'Выполняется операция...' : message)
                : '';
            statusMessage = id == 'vpn-disconnect'
                ? 'Отключаем VPN'
                : 'Подключаем VPN';
          }
        } else {
          busyTasks.remove(id);
          if (id == 'app-exit' && quitting) {
            quitProgressMessage = 'Завершаем работу приложения...';
          }
          if (!status.hasError &&
              !connectionBusy &&
              !uiBusy &&
              !booting &&
              (message.isEmpty ||
                  message.toLowerCase() == 'done' ||
                  message.toLowerCase() == 'ready' ||
                  message == 'Готово')) {
            connectionHint = '';
          }
        }
        break;
      case 'route-probe-start':
        routeProbeActive = true;
        routeProbeFailed = false;
        connectionHintDanger = false;
        routeProbeExpectedCount = _asInt(event.payload['serviceCount']);
        routeProbeProgress = _routeProbeStartItems(event.payload['services']);
        routeHint = event.payload['extendedSearch'] == true
            ? 'Подбираем Zapret по всему списку. Проверка может занять продолжительное время...'
            : 'Подбираем рабочие методы обхода для сервисов...';
        break;
      case 'route-probe-service':
        _updateRouteProbeService(event.payload);
        final name =
            event.payload['name']?.toString() ??
            event.payload['tag']?.toString() ??
            'сервис';
        final method =
            event.payload['methodLabel']?.toString() ??
            event.payload['methodTag']?.toString() ??
            'метод';
        final success = event.payload['success'] == true;
        final retrying = event.payload['retrying'] == true;
        final attempt = _asInt(event.payload['attempt']);
        final attemptTotal = _asInt(event.payload['attemptTotal']);
        routeHint = success
            ? '$name: выбран $method'
            : retrying
            ? '$name: стратегия ${attempt > 0 ? attempt : ''}${attemptTotal > 0 ? '/$attemptTotal' : ''} не сработала, пробуем следующую'
            : '$name: рабочая стратегия не найдена';
        if (!success && retrying && windowVisible) {
          _showStrategyTransition(
            '$name: ${method == 'метод' ? 'текущая стратегия' : method} не сработала. '
            'Пробуем следующую${attempt > 0 ? ' · попытка $attempt${attemptTotal > 0 ? '/$attemptTotal' : ''}' : ''}.',
          );
        }
        break;
      case 'route-probe-candidate':
        _updateRouteProbeCandidate(event.payload);
        final service =
            event.payload['service']?.toString() ??
            event.payload['serviceName']?.toString() ??
            event.payload['tag']?.toString() ??
            'сервис';
        final method =
            event.payload['methodLabel']?.toString() ??
            event.payload['label']?.toString() ??
            'метод';
        final attempt = _asInt(event.payload['attempt']);
        final attemptTotal = _asInt(event.payload['attemptTotal']);
        routeHint =
            'Проверяем $service через $method${attempt > 0 ? ' · попытка $attempt${attemptTotal > 0 ? '/$attemptTotal' : ''}' : ''}...';
        break;
      case 'route-probe-complete':
        _finishRouteProbe(event.payload);
        break;
      case 'vpn-starting':
        statusMessage = 'Подключаем VPN';
        connectionHint = 'Android VpnService запускает sing-box...';
        connectionHintDanger = false;
        routeProbeActive = true;
        routeProbeFailed = false;
        break;
      case 'vpn-error':
        final message =
            event.payload['error']?.toString().trim() ??
            'Android VPN не запустился';
        busyTasks.remove('vpn-connect');
        statusMessage = 'Ошибка запуска VPN';
        connectionHint = message.isEmpty
            ? 'Android VPN не запустился'
            : message;
        connectionHintDanger = true;
        routeProbeActive = false;
        routeProbeFailed = true;
        break;
      case 'deps-progress':
        final phase = event.payload['phase']?.toString() ?? 'Загрузка';
        final percent = _asInt(event.payload['percent']);
        final done =
            percent >= 100 ||
            phase.toLowerCase() == 'done' ||
            phase.toLowerCase() == 'ready' ||
            phase == 'Готово';
        if (done) {
          depsProgress = '';
          if (!booting && !connectionBusy && !uiBusy && !status.hasError) {
            connectionHint = '';
          }
        } else {
          depsProgress = percent > 0 ? '$phase $percent%' : phase;
          connectionHint = depsProgress;
        }
        break;
      case 'deps-error':
        final message =
            event.payload['error']?.toString().trim() ??
            'Не удалось восстановить встроенные компоненты';
        depsProgress = '';
        connectionHint = message;
        connectionHintDanger = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_showDependenciesFailureDialog(message));
          }
        });
        break;
    }
  }

  void _applyServiceStatePayload(Map<String, dynamic> payload) {
    final state =
        payload['vpnState']?.toString() ??
        payload['state']?.toString() ??
        (payload['connected'] == true ? 'connected' : 'stopped');
    final connected = payload['connected'] == true || state == 'connected';
    final reconnecting = state == 'reconnecting';
    final connecting =
        payload['connecting'] == true || state == 'starting' || reconnecting;
    final disconnecting =
        payload['disconnecting'] == true || state == 'disconnecting';
    final hasError = payload['hasError'] == true || state == 'failed';
    final errorText = payload['error']?.toString() ?? '';
    final message = payload['message']?.toString() ?? '';

    if (status.connected != connected || connecting || disconnecting) {
      homeSourcesRequest++;
      homeSourcesLoaded = false;
      homeSourcesLoading = false;
      homeSourcesCheckedAt = null;
    }
    status = status.copyWith(
      connected: connected,
      running: payload['running'] == true || connected,
      connecting: connecting,
      disconnecting: disconnecting,
      vpnState: state,
      hasError: hasError,
      error: errorText,
      serviceMessage: message,
    );

    if (connecting) {
      busyTasks['vpn-connect'] = message.isEmpty
          ? reconnecting
                ? 'Восстанавливаем соединение…'
                : 'Android VpnService is starting sing-box'
          : message;
      busyTasks.remove('vpn-disconnect');
      statusMessage = reconnecting ? 'Переподключаем VPN' : 'Подключаем VPN';
      connectionHint = reconnecting
          ? (message.isEmpty ? 'Восстанавливаем соединение…' : message)
          : 'Android VpnService запускает sing-box...';
      connectionHintDanger = false;
      routeProbeActive = true;
      routeProbeFailed = false;
      return;
    }

    if (disconnecting) {
      busyTasks['vpn-disconnect'] = message.isEmpty
          ? 'Android VPN is stopping'
          : message;
      busyTasks.remove('vpn-connect');
      statusMessage = 'Отключаем VPN';
      connectionHint = message;
      connectionHintDanger = false;
      return;
    }

    busyTasks.remove('vpn-connect');
    busyTasks.remove('vpn-disconnect');

    if (state == 'failed' || hasError) {
      statusMessage = 'Ошибка запуска VPN';
      connectionHint = errorText.isEmpty
          ? (message.isEmpty ? 'Android VPN failed' : message)
          : errorText;
      connectionHintDanger = true;
      routeProbeActive = false;
      routeProbeFailed = true;
      return;
    }

    if (connected) {
      statusMessage = 'Подключено';
      connectionHint = '';
      connectionHintDanger = false;
      routeProbeActive = false;
      routeProbeFailed = false;
      return;
    }

    statusMessage = 'Отключено';
    connectionHint = '';
    connectionHintDanger = false;
    routeProbeActive = false;
    routeProbeFailed = false;
  }

  Map<String, RouteProbeProgress> _routeProbeStartItems(Object? raw) {
    final result = <String, RouteProbeProgress>{};
    if (raw is List) {
      for (final item in raw) {
        final data = _asMap(item);
        final tag = data['tag']?.toString() ?? '';
        if (tag.isEmpty) {
          continue;
        }
        result[tag] = RouteProbeProgress(
          tag: tag,
          name: data['name']?.toString() ?? tag,
        );
      }
    }
    return result;
  }

  void _updateRouteProbeCandidate(Map<String, dynamic> payload) {
    final tag =
        payload['serviceTag']?.toString() ??
        payload['service']?.toString() ??
        payload['tag']?.toString() ??
        '';
    if (tag.isEmpty) {
      return;
    }
    final current =
        routeProbeProgress[tag] ??
        RouteProbeProgress(
          tag: tag,
          name: payload['serviceName']?.toString() ?? tag,
        );
    routeProbeProgress =
        Map<String, RouteProbeProgress>.from(routeProbeProgress)
          ..[tag] = current.copyWith(
            name: payload['serviceName']?.toString(),
            method:
                payload['methodLabel']?.toString() ??
                payload['label']?.toString() ??
                current.method,
            status: payload['status']?.toString() ?? 'checking',
            error: payload['error']?.toString() ?? '',
            attempt: _asInt(payload['attempt']),
            attemptTotal: _asInt(payload['attemptTotal']),
            strategyIndex: _asInt(payload['strategyIndex']),
            strategyTotal: _asInt(payload['strategyTotal']),
            cycle: _asInt(payload['cycle']),
            cycleTotal: _asInt(payload['cycleTotal']),
          );
    routeProbeActive = true;
  }

  void _updateRouteProbeService(Map<String, dynamic> payload) {
    final tag = payload['tag']?.toString() ?? '';
    if (tag.isEmpty) {
      return;
    }
    final success = payload['success'] == true;
    final finalResult = payload['final'] != false;
    final retrying = payload['retrying'] == true;
    final current =
        routeProbeProgress[tag] ??
        RouteProbeProgress(tag: tag, name: payload['name']?.toString() ?? tag);
    if (!success && finalResult) {
      routeProbeFailed = true;
    }
    routeProbeProgress =
        Map<String, RouteProbeProgress>.from(routeProbeProgress)
          ..[tag] = current.copyWith(
            name: payload['name']?.toString(),
            method:
                payload['methodLabel']?.toString() ??
                payload['methodTag']?.toString() ??
                current.method,
            status:
                payload['status']?.toString() ??
                (success
                    ? 'done'
                    : retrying && !finalResult
                    ? 'retrying'
                    : 'failed'),
            error: payload['error']?.toString() ?? '',
            attempt: _asInt(payload['attempt']),
            attemptTotal: _asInt(payload['attemptTotal']),
            strategyIndex: _asInt(payload['strategyIndex']),
            strategyTotal: _asInt(payload['strategyTotal']),
            cycle: _asInt(payload['cycle']),
            cycleTotal: _asInt(payload['cycleTotal']),
          );
    routeProbeActive = routeProbeProgress.values.any((item) => item.pending);
  }

  void _finishRouteProbe(Map<String, dynamic> payload) {
    final services = payload['services'];
    if (services is List) {
      for (final item in services) {
        _updateRouteProbeService(_asMap(item));
      }
    }
    final completionError = payload['error']?.toString().trim() ?? '';
    if (completionError.isNotEmpty) {
      routeProbeFailed = true;
      routeProbeProgress =
          Map<String, RouteProbeProgress>.from(routeProbeProgress).map(
            (tag, item) => MapEntry(
              tag,
              item.pending || item.status == 'waiting'
                  ? item.copyWith(status: 'failed', error: completionError)
                  : item,
            ),
          );
    }
    routeProbeActive = routeProbeProgress.values.any((item) => item.pending);
    routeHint = routeProbeFailed
        ? 'Не для всех сервисов удалось подобрать стратегию обхода.'
        : routeProbeActive
        ? 'Часть стратегий ещё проверяется в фоне.'
        : 'Стратегии обхода подобраны.';
  }

  void _showStrategyTransition(String message) {
    strategyTransitionTimer?.cancel();
    strategyTransitionNotice = message;
    strategyTransitionTimer = Timer(const Duration(seconds: 7), () {
      if (!mounted) {
        return;
      }
      setState(() => strategyTransitionNotice = '');
    });
  }

  void _setConnectionPrimed(bool target) {
    busyTasks[target ? 'vpn-connect' : 'vpn-disconnect'] = target
        ? 'Подключаем VPN...'
        : 'Останавливаем VPN...';
    statusMessage = target ? 'Подключаем VPN' : 'Отключаем VPN';
    connectionHint = target
        ? 'Проверяем окружение и запускаем безопасный начальный маршрут.'
        : 'Останавливаем сетевые процессы и возвращаем системные настройки.';
    connectionHintDanger = false;
    if (target) {
      routeProbeActive = true;
      routeProbeFailed = false;
      routeProbeExpectedCount = 0;
      routeProbeProgress = <String, RouteProbeProgress>{};
      routeHint = 'Ожидаем список сервисов для подбора стратегий...';
    } else {
      routeProbeActive = false;
      routeProbeFailed = false;
      routeProbeExpectedCount = 0;
      routeProbeProgress = <String, RouteProbeProgress>{};
      routeHint = '';
    }
  }

  Future<void> _toggleConnection() async {
    if (controlsDisabled || connectionBusy) {
      return;
    }
    final target = !status.connected;
    if (target && _mobileNeedsSubscription) {
      _showMobileSubscriptionRequiredNotice();
      return;
    }
    if (target &&
        !_isMobileShell &&
        appConfig.routingMode == 'all_traffic' &&
        !await _ensureFullVpnSource()) {
      return;
    }
    if (!mounted || quitting) return;
    setState(() => _setConnectionPrimed(target));
    await _runBusy(() async {
      if (target) {
        final canStart = await _ensureNoExternalVpnConflict();
        if (!canStart) {
          return;
        }
      }
      setState(() {
        busyTasks[target ? 'vpn-connect' : 'vpn-disconnect'] = target
            ? 'Запускаем VPN и безопасные маршруты...'
            : 'Останавливаем VPN...';
        statusMessage = target ? 'Подключаем VPN' : 'Отключаем VPN';
        connectionHint = target
            ? 'Проверяем конфиг и запускаем VPN; стратегии сервисов проверятся в фоне.'
            : 'Останавливаем сетевые процессы и возвращаем системные настройки.';
        connectionHintDanger = false;
      });
      Map<String, dynamic> result;
      try {
        result = await widget.bridge.setConnected(target);
      } on TimeoutException catch (error) {
        if (target) {
          await widget.bridge
              .setConnected(false)
              .catchError((_) => <String, dynamic>{});
        }
        if (mounted) {
          setState(() {
            statusMessage = 'Ошибка запуска VPN';
            connectionHint =
                'Запуск занял слишком много времени. Фоновые процессы остановлены, попробуйте снова. ${_cleanError(error)}';
            connectionHintDanger = true;
            routeProbeActive = false;
            routeProbeFailed = true;
          });
        }
        await _refresh(all: true);
        return;
      }
      final ok = result['success'] != false;
      if (!ok) {
        if (target) {
          await widget.bridge
              .setConnected(false)
              .catchError((_) => <String, dynamic>{});
        }
        setState(() {
          statusMessage = 'Ошибка';
          connectionHint =
              result['error']?.toString() ?? 'Операция не выполнена';
          connectionHintDanger = true;
          routeProbeActive = false;
          routeProbeFailed = target;
        });
      }
      await _refresh(all: true);
      if (target && ok) {
        unawaited(_maybeShowAndroidCompatibilityNotice());
      }
    }, clearConnectionBusy: true);
  }

  Future<bool> _ensureFullVpnSource() async {
    setState(() => preparingFullVpnSource = true);
    try {
      // Read the authoritative enabled list, not an old home-card snapshot.
      final sources = await widget.bridge.vpnSources().timeout(
        const Duration(seconds: 10),
      );
      if (!mounted || quitting) return false;
      if (sources.any((source) => !source.disabled)) return true;
      final action = await showDialog<_VpnOnboardingAction>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _VpnOnboardingDialog(
          bridge: widget.bridge,
          hasDisabledSources: sources.isNotEmpty,
        ),
      );
      if (!mounted || quitting) return false;
      if (action == _VpnOnboardingAction.manage) {
        await _openSubscription();
        return false;
      }
      if (action == _VpnOnboardingAction.services) {
        await _setHomeRoutingMode('blocked_only');
        return false;
      }
      if (action != _VpnOnboardingAction.ready) return false;
      await _refresh(all: true);
      final enabled = await widget.bridge.vpnSources();
      if (!enabled.any((source) => !source.disabled)) {
        throw StateError(
          'Источник не готов. Откройте «Источники VPN» и повторите добавление.',
        );
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          statusMessage = 'Не удалось подготовить VPN-источник';
          connectionHint = _cleanError(error);
          connectionHintDanger = true;
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => preparingFullVpnSource = false);
    }
  }

  void _showMobileSubscriptionRequiredNotice() {
    if (!_mobileNeedsSubscription) {
      return;
    }
    setState(() {
      statusMessage = 'Нужна VPN-подписка';
      connectionHint =
          'На Android запуск доступен после добавления VPN-подписки. Бесплатные методы без подписки сейчас не используются.';
      connectionHintDanger = true;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('Добавьте VPN-подписку для запуска на Android.'),
        action: SnackBarAction(
          label: 'Добавить',
          onPressed: () => unawaited(_openSubscription()),
        ),
      ),
    );
  }

  Future<void> _maybeShowAndroidCompatibilityNotice() async {
    if (!_isMobileShell || !Platform.isAndroid || compatibilityNoticeShowing) {
      return;
    }
    compatibilityNoticeShowing = true;
    try {
      final info = await widget.bridge.androidCompatibility();
      if (!mounted ||
          !info.supported ||
          info.promptDismissed ||
          !info.hasInstalledRiskApps) {
        return;
      }
      // Persist before opening the dialog so an app restart or process kill
      // cannot make the first-run instruction appear again.
      await widget.bridge.setAndroidCompatibilityPromptDismissed(true);
      if (!mounted) {
        return;
      }
      final result = await showDialog<_CompatibilityNoticeAction>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _AndroidCompatibilityNoticeDialog(
          info: info,
          onDecision: (action) => Navigator.of(dialogContext).pop(action),
        ),
      );
      if (!mounted || result == null) {
        return;
      }
      if (result.openDropoSpace) {
        setState(() => activeMenuSection = 'dropo_space');
      }
    } catch (_) {
      // Compatibility help should never block the VPN start flow.
    } finally {
      compatibilityNoticeShowing = false;
    }
  }

  Future<bool> _ensureNoExternalVpnConflict() async {
    setState(() {
      externalVpnConflictBlocked = false;
      statusMessage = 'Подключаем VPN';
      connectionHint =
          'Перед запуском проверяем активные VPN, packet-filter и туннельные адаптеры.';
      connectionHintDanger = false;
    });

    try {
      final info = await widget.bridge.externalVpnConflicts();
      if (!mounted) {
        return false;
      }
      if (!info.hasConflicts) {
        return true;
      }

      setState(() {
        externalVpnConflictBlocked = true;
        statusMessage = 'Обнаружен сетевой конфликт';
        connectionHint =
            'Закройте найденные VPN или сторонние packet-filter процессы и запустите dropo снова.';
        routeProbeActive = false;
      });
      final continueAnyway = await _showExternalVpnConflictDialog(info);
      if (continueAnyway) {
        if (mounted) {
          setState(() {
            externalVpnConflictBlocked = false;
          });
        }
        return true;
      }
      if (mounted) {
        setState(() {
          externalVpnConflictBlocked = true;
          statusMessage = 'Обнаружен сетевой конфликт';
          connectionHint =
              'Закройте найденные VPN или сторонние packet-filter процессы и запустите dropo снова.';
          routeProbeActive = false;
        });
      }
      return false;
    } catch (error) {
      if (mounted) {
        setState(() {
          externalVpnConflictBlocked = false;
          statusMessage = 'Проверка VPN недоступна';
          connectionHint =
              'Не удалось проверить другие VPN: ${_cleanError(error)}. Продолжаем запуск.';
        });
      }
      return true;
    }
  }

  Future<bool> _showExternalVpnConflictDialog(VpnConflictInfo info) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return _AppDialog(
          width: 560,
          centered: true,
          title: 'Работает другой VPN или packet-filter',
          icon: Icons.warning_amber_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Найдены активные VPN-подключения, туннельные адаптеры или сторонние packet-filter/WinDivert-процессы. При одновременном запуске могут конфликтовать маршруты, DNS, TUN и фильтры пакетов.',
                style: TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
              ),
              const SizedBox(height: 12),
              ...info.conflicts.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _VpnConflictTile(item: item),
                ),
              ),
              const SizedBox(height: 6),
              const _InfoBand(
                icon: Icons.power_settings_new,
                title: 'Рекомендуем',
                body:
                    'Нажмите «Отмена», закройте сторонний VPN или packet-filter и затем включите dropo заново. Продолжайте только если понимаете риск конфликта.',
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Отмена',
                      icon: Icons.close,
                      secondary: true,
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      label: 'Понятно, включить',
                      icon: Icons.power_settings_new,
                      danger: true,
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    return result == true;
  }

  Future<void> _downloadDependencies() async {
    await _runBusy(() async {
      setState(() {
        statusMessage = 'Проверяем компоненты';
        connectionHint =
            'Проверяем и при необходимости восстанавливаем встроенный runtime...';
        connectionHintDanger = false;
      });
      Map<String, dynamic> result;
      try {
        result = await widget.bridge.downloadDependencies();
      } catch (error) {
        await _handleDependenciesFailure(_cleanError(error));
        await _refresh(all: true);
        return;
      }
      if (result['success'] != true) {
        await _handleDependenciesFailure(
          result['error']?.toString() ??
              'Не удалось восстановить встроенные компоненты',
        );
        await _refresh(all: true);
        return;
      }
      final dependencyResult = DepsStatus.fromJson(
        _asMap(result['dependencies']),
      );
      setState(() {
        statusMessage = dependencyResult.ready
            ? 'VPN-ядро готово'
            : 'VPN-ядро не установлено';
        connectionHint = dependencyResult.ready
            ? 'Все встроенные компоненты проверены и готовы.'
            : 'Не удалось восстановить встроенные компоненты; переустановите приложение из официального пакета.';
        connectionHintDanger = !dependencyResult.ready;
        depsProgress = '';
      });
      await _refresh(all: true);
    });
  }

  Future<void> _handleDependenciesFailure(String message) async {
    final clean = message.trim().isEmpty
        ? 'Не удалось восстановить встроенные компоненты'
        : message.trim();
    if (!mounted) {
      return;
    }
    setState(() {
      statusMessage = 'Ошибка восстановления';
      connectionHint = clean;
      connectionHintDanger = true;
      depsProgress = '';
    });
    await _showDependenciesFailureDialog(clean);
  }

  Future<void> _showDependenciesFailureDialog(String details) async {
    if (!mounted || depsFailureDialogShowing) {
      return;
    }
    final now = DateTime.now();
    final lastShownAt = lastDepsFailureDialogAt;
    if (details == lastDepsFailureDialogMessage &&
        lastShownAt != null &&
        now.difference(lastShownAt) < const Duration(seconds: 10)) {
      return;
    }
    lastDepsFailureDialogMessage = details;
    lastDepsFailureDialogAt = now;
    depsFailureDialogShowing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return _AppDialog(
            title: 'Ошибка компонентов',
            icon: Icons.error_outline,
            width: 500,
            centered: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Не удалось проверить или локально восстановить встроенные компоненты. Переустановите приложение из официального пакета; если ошибка повторяется, обратитесь к администратору.',
                  style: TextStyle(color: Color(0xFFD8E4E0), height: 1.4),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  details,
                  style: const TextStyle(
                    color: Color(0xFF9FB2AE),
                    height: 1.35,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  appConfig.telegramName,
                  style: const TextStyle(
                    color: Color(0xFF7DD3FC),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        label: 'Закрыть',
                        icon: Icons.close,
                        secondary: true,
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ActionButton(
                        label: 'Открыть Telegram',
                        icon: Icons.open_in_new,
                        onPressed: () {
                          unawaited(
                            widget.bridge
                                .openExternal(appConfig.telegramUrl)
                                .catchError((_) {}),
                          );
                          Navigator.of(dialogContext).pop();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    } finally {
      depsFailureDialogShowing = false;
    }
  }

  Future<void> _checkUpdates() async {
    await _runBusy(() async {
      final result = await widget.bridge.checkUpdates();
      if (!mounted) {
        return;
      }
      setState(() {
        updateInfo = result;
        statusMessage = result.success
            ? (result.hasUpdate
                  ? 'Доступна версия ${result.latestVersion}'
                  : 'Версия актуальна')
            : 'Ошибка обновления';
        connectionHint = result.success
            ? (result.hasUpdate
                  ? (result.selfUpdate
                        ? 'Нажмите «Обновить и перезапустить».'
                        : result.platform.toLowerCase() == 'windows'
                        ? 'Скачайте portable-архив и замените папку приложения.'
                        : 'Нажмите «Скачать APK» для установки обновления.')
                  : 'Вы используете последнюю опубликованную версию.')
            : result.error;
      });
      _showUpdateSnackBar(result, manual: true);
    });
  }

  void _showUpdateSnackBar(UpdateInfo result, {required bool manual}) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger.hideCurrentSnackBar();
    if (!result.success) {
      if (manual) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              result.error.isEmpty
                  ? 'Не удалось проверить обновления.'
                  : result.error,
            ),
          ),
        );
      }
      return;
    }
    if (!result.hasUpdate) {
      if (manual) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              result.latestVersion.isEmpty
                  ? 'Версия актуальна.'
                  : 'Версия актуальна: ${result.latestVersion}.',
            ),
          ),
        );
      }
      return;
    }
    final asset = result.assetName.isEmpty ? 'новую сборку' : result.assetName;
    messenger.showSnackBar(
      SnackBar(
        content: Text('Доступна версия ${result.latestVersion}: $asset'),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: result.selfUpdate
              ? 'Обновить'
              : result.platform.toLowerCase() == 'windows'
              ? 'Скачать portable'
              : 'Скачать APK',
          onPressed: () => unawaited(_performUpdate(result)),
        ),
      ),
    );
  }

  String _updateDownloadLink(UpdateInfo result) {
    if (result.downloadUrl.isNotEmpty) {
      return result.downloadUrl;
    }
    return '';
  }

  Future<void> _performAutomaticUpdate(UpdateInfo result) async {
    // A settings save or another short UI operation can overlap the delayed
    // startup check. Wait for that operation instead of silently dropping the
    // automatic update. The release remains visible for a manual retry if the
    // UI stays busy for an unusually long time.
    for (var attempt = 0; attempt < 60; attempt++) {
      if (!mounted || quitting || !appConfig.checkUpdates) {
        return;
      }
      if (!uiBusy) {
        await _performUpdate(result, requireConfirmation: false);
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (mounted) {
      setState(() {
        statusMessage = 'Доступна версия ${result.latestVersion}';
        connectionHint = 'Нажмите «Обновить и перезапустить».';
      });
      _showUpdateSnackBar(result, manual: false);
    }
  }

  Future<void> _performUpdate(
    UpdateInfo result, {
    bool requireConfirmation = true,
  }) async {
    if (!result.success || !result.hasUpdate || uiBusy || quitting) {
      return;
    }
    if (!result.selfUpdate) {
      final link = _updateDownloadLink(result);
      if (link.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Ссылка на APK отсутствует. Повторите проверку обновлений.',
            ),
          ),
        );
        return;
      }
      if (result.platform.toLowerCase() == 'windows') {
        final download = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => _AppDialog(
            title: 'Обновление portable-версии',
            icon: Icons.folder_zip_outlined,
            width: 540,
            centered: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Portable-версия не заменяет собственные запущенные файлы. Скачайте новый архив, закройте dropo и распакуйте его в новую папку.',
                  style: TextStyle(color: Color(0xFFD8E4E0), height: 1.4),
                ),
                const SizedBox(height: 12),
                const _InfoBand(
                  icon: Icons.verified_user_outlined,
                  title: 'Настройки сохранятся',
                  body:
                      'Профили и настройки хранятся отдельно в AppData. Сначала запустите новую версию, убедитесь, что всё работает, и только потом удалите старую папку.',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        label: 'Отмена',
                        icon: Icons.close,
                        secondary: true,
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ActionButton(
                        label: 'Скачать архив',
                        icon: Icons.download,
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        if (download != true || !mounted) {
          return;
        }
      }
      await widget.bridge.openExternal(link);
      return;
    }

    if (requireConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _AppDialog(
          title: 'Обновить dropo до ${result.latestVersion}?',
          icon: Icons.system_update_alt,
          width: 520,
          centered: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Приложение скачает установщик из GitHub Releases, проверит размер и SHA-256, запустит обновление и перезапустится.',
                style: TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Отмена',
                      icon: Icons.close,
                      secondary: true,
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      label: 'Обновить',
                      icon: Icons.restart_alt,
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }

    await _runBusy(() async {
      setState(() {
        updateProgressPercent = 0;
        statusMessage = 'Загружаем обновление';
        connectionHint = 'Не закрывайте dropo до завершения проверки.';
      });
      final response = await widget.bridge.installUpdate();
      if (response['success'] != true) {
        throw StateError(
          response['error']?.toString() ?? 'Не удалось установить обновление',
        );
      }
      if (mounted) {
        setState(() {
          quitting = true;
          quitProgressMessage =
              'Устанавливаем обновление и перезапускаем dropo...';
          statusMessage = 'Перезапускаем dropo';
          connectionHint = 'Новая версия уже загружена и проверена.';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      exit(0);
    });
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    bool clearConnectionBusy = false,
  }) async {
    if (uiBusy) {
      return;
    }
    setState(() => uiBusy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          statusMessage = 'Ошибка';
          connectionHint = _cleanError(error);
          connectionHintDanger = true;
          if (clearConnectionBusy) {
            routeProbeActive = false;
            routeProbeFailed = true;
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          uiBusy = false;
          if (clearConnectionBusy) {
            busyTasks.remove('vpn-connect');
            busyTasks.remove('vpn-disconnect');
          }
        });
      }
    }
  }

  Future<void> _quitApp() async {
    if (quitting) {
      return;
    }
    setState(() {
      quitting = true;
      quitProgressMessage =
          'Останавливаем VPN, WinDivert и фоновые процессы...';
      statusMessage = 'Закрываем dropo';
      connectionHint = 'Останавливаем VPN, WinDivert и фоновые процессы...';
    });
    try {
      final info = await widget.bridge.prepareQuit();
      if (!mounted) {
        return;
      }
      if (info.showNotice) {
        await widget.bridge.showWindow().catchError((_) {});
        if (!mounted) {
          return;
        }
        setState(() {
          quitProgressMessage =
              'Показываем уведомление Telegram перед выходом...';
          connectionHint = 'Перед выходом проверьте proxy в Telegram.';
        });
        await _showTelegramExitNotice(info);
      } else {
        await _finalizeQuit();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        quitting = false;
        quitProgressMessage = '';
        statusMessage = 'Не удалось закрыть приложение';
        connectionHint = _cleanError(error);
      });
    }
  }

  Future<void> _openLegacyTelegramProxySettings() async {
    try {
      final result = await widget.bridge.openTelegramProxySettings();
      if (result['success'] == false) {
        throw StateError(
          result['error']?.toString() ??
              'Не удалось открыть настройки Telegram',
        );
      }
      if (!mounted) return;
      setState(() {
        statusMessage = 'Открыты настройки Telegram';
        connectionHint =
            'Удалите старый локальный proxy dropo, затем вернитесь и подтвердите очистку.';
        connectionHintDanger = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Не удалось открыть Telegram';
        connectionHint = _cleanError(error);
        connectionHintDanger = true;
      });
    }
  }

  Future<void> _acknowledgeLegacyTelegramProxyRemoved() async {
    if (uiBusy) return;
    setState(() => uiBusy = true);
    try {
      final result = await widget.bridge.acknowledgeTelegramProxyRemoved();
      if (result['success'] == false) {
        throw StateError(
          result['error']?.toString() ??
              'Не удалось сохранить подтверждение очистки proxy',
        );
      }
      if (!mounted) return;
      setState(() {
        legacyTelegramProxy = const TelegramExitInfo(
          showNotice: false,
          injected: false,
          recommendRemove: false,
        );
        statusMessage = 'Старый proxy Telegram отключён';
        connectionHint = '';
        connectionHintDanger = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Подтверждение не сохранено';
        connectionHint = _cleanError(error);
        connectionHintDanger = true;
      });
    } finally {
      if (mounted) setState(() => uiBusy = false);
    }
  }

  Future<void> _finishPreparedQuit(TelegramExitInfo info) async {
    if (quitting) {
      return;
    }
    final quitMessage = info.showNotice
        ? 'Показываем уведомление Telegram перед выходом...'
        : 'Завершаем работу приложения...';
    setState(() {
      quitting = true;
      quitProgressMessage = quitMessage;
      statusMessage = 'Закрываем dropo';
      connectionHint = info.showNotice
          ? 'Перед выходом проверьте proxy в Telegram.'
          : 'Завершаем работу приложения...';
    });
    if (info.showNotice) {
      await widget.bridge.showWindow().catchError((_) {});
      if (!mounted) {
        return;
      }
      await _showTelegramExitNotice(info);
      return;
    }
    await _finalizeQuit();
  }

  Future<void> _finalizeQuit() async {
    try {
      await widget.bridge.finalizeQuit();
    } catch (_) {
      // The core is expected to disappear here.
    }
    exit(0);
  }

  Future<void> _showTelegramExitNotice(TelegramExitInfo info) async {
    var remaining = 15;
    Timer? timer;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
              if (!context.mounted) {
                return;
              }
              if (remaining <= 1) {
                timer?.cancel();
                Navigator.of(dialogContext).pop();
                unawaited(_finalizeQuit());
                return;
              }
              setDialogState(() => remaining -= 1);
            });
            return _AppDialog(
              width: 640,
              centered: true,
              heightFactor: 0.88,
              title: 'Проверьте proxy в Telegram',
              icon: Icons.telegram,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Если Telegram уже подключался к локальному proxy dropo, он может сохранить его после выхода. Удалите proxy в Telegram, если он больше не нужен.',
                    style: TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  const Row(
                    children: [
                      Expanded(
                        child: _TelegramAssetShot(
                          title: '1. Тип соединения',
                          asset: 'assets/telegram-proxy-step1.png',
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: _TelegramAssetShot(
                          title: '2. Удалить proxy',
                          asset: 'assets/telegram-proxy-step2.png',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: remaining / 15,
                      minHeight: 6,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      color: const Color(0xFF36D399),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    'Автоматическое закрытие через $remaining сек.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF8A9B97),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: 'Я проверю Telegram',
                          icon: Icons.open_in_new,
                          onPressed: () async {
                            timer?.cancel();
                            Navigator.of(dialogContext).pop();
                            await _finalizeQuit();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ActionButton(
                          label: 'Закрыть сейчас',
                          icon: Icons.logout,
                          danger: true,
                          onPressed: () async {
                            timer?.cancel();
                            Navigator.of(dialogContext).pop();
                            await _finalizeQuit();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() => timer?.cancel());
  }

  Future<void> _setHomeRoutePolicy(RouteService service, String policy) async {
    if (uiBusy || policy == service.selectedMethod) {
      return;
    }
    setState(() {
      uiBusy = true;
      statusMessage = 'Сохраняем маршрут для ${_homeRouteName(service)}';
      connectionHint = '';
    });
    try {
      final result = await widget.bridge.setFreeAccessServiceMethod(
        service.tag,
        policy,
      );
      if (result['success'] == false) {
        throw StateError(result['error']?.toString() ?? 'Маршрут не сохранён');
      }
      List<RouteService>? refreshed;
      try {
        refreshed = await widget.bridge.routes(live: false);
      } catch (_) {}
      if (!mounted) {
        return;
      }
      setState(() {
        liveRoutesConfirmed = false;
        if (refreshed != null && refreshed.isNotEmpty) {
          routes = refreshed;
        } else {
          routes = routes
              .map(
                (route) => route.tag == service.tag
                    ? route.copyWith(selectedMethod: policy)
                    : route,
              )
              .toList(growable: false);
        }
        statusMessage = 'Маршрут для ${_homeRouteName(service)} сохранён';
        connectionHint = result['restarted'] == true
            ? 'Соединение автоматически переподключено.'
            : '';
        connectionHintDanger = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          statusMessage = 'Не удалось изменить маршрут';
          connectionHint = _cleanError(error);
          connectionHintDanger = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => uiBusy = false);
      }
    }
  }

  Future<void> _setHomeZapretStrategy(
    RouteService service,
    String mode,
    String strategyTag,
  ) async {
    if (uiBusy) return;
    final experimentalDiscordAuto = service.tag == 'discord' && mode == 'auto';
    setState(() {
      uiBusy = true;
      statusMessage = experimentalDiscordAuto
          ? 'Запускаем экспериментальный автоподбор Discord'
          : mode == 'auto'
          ? 'Запускаем автоподбор Zapret для ${_homeRouteName(service)}'
          : 'Сохраняем стратегию Zapret для ${_homeRouteName(service)}';
      connectionHint = '';
    });
    try {
      final result = await widget.bridge.setZapretServiceStrategy(
        service.tag,
        mode,
        strategyTag,
      );
      if (result['success'] == false) {
        throw StateError(
          result['error']?.toString() ?? 'Стратегия Zapret не сохранена',
        );
      }
      final refreshed = await widget.bridge.routes(live: false);
      if (!mounted) return;
      setState(() {
        routes = refreshed;
        liveRoutesConfirmed = false;
        statusMessage = experimentalDiscordAuto
            ? 'Экспериментальный автоподбор Discord включён'
            : mode == 'auto'
            ? 'Автоподбор Zapret для ${_homeRouteName(service)} включён'
            : 'Стратегия Zapret для ${_homeRouteName(service)} сохранена';
        connectionHint = result['searchStarted'] == true
            ? experimentalDiscordAuto
                  ? 'Discord Zapret экспериментален: web/API не подтверждают voice/video. Для стабильного голосового чата выберите VPN.'
                  : 'Проверка стратегий идёт в фоне; рабочий вариант сохранится для текущей сети.'
            : result['restarted'] == true
            ? 'Подключение автоматически переподключено.'
            : mode == 'auto'
            ? 'Подбор начнётся при следующем подключении.'
            : '';
        connectionHintDanger = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          statusMessage = 'Не удалось изменить стратегию Zapret';
          connectionHint = _cleanError(error);
          connectionHintDanger = true;
        });
      }
    } finally {
      if (mounted) setState(() => uiBusy = false);
    }
  }

  Future<void> _setHomeRoutingMode(String mode) async {
    if (uiBusy || mode == appConfig.routingMode) {
      return;
    }
    if (mode == 'all_traffic' &&
        !subscription.hasSubscription &&
        _isMobileShell) {
      setState(() {
        statusMessage = 'Для режима «Всё через VPN» нужна VPN-подписка';
        connectionHint = 'Добавьте подписку, затем включите общий VPN-режим.';
        connectionHintDanger = true;
      });
      await _openSubscription();
      return;
    }

    setState(() {
      uiBusy = true;
      statusMessage = mode == 'all_traffic'
          ? 'Переключаем весь трафик на VPN'
          : 'Включаем выборочные маршруты';
      connectionHint = status.connected
          ? 'VPN будет автоматически переподключён.'
          : '';
      connectionHintDanger = false;
    });
    try {
      final result = await widget.bridge.setRoutingMode(mode);
      if (result['success'] == false) {
        throw StateError(
          result['error']?.toString() ?? 'Режим маршрутизации не сохранён',
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        appConfig = appConfig.copyWith(routingMode: mode);
        liveRoutesConfirmed = false;
        statusMessage = mode == 'all_traffic'
            ? 'Сохранён режим «Всё через VPN»'
            : 'Сохранён режим «По сервисам»';
        connectionHint = result['restarted'] == true
            ? 'Соединение автоматически переподключено.'
            : '';
        connectionHintDanger = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          statusMessage = 'Не удалось изменить режим маршрутизации';
          connectionHint = _cleanError(error);
          connectionHintDanger = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => uiBusy = false);
      }
    }
  }

  Future<void> _setHomeRouteVisibility(
    RouteService service,
    bool visible,
  ) async {
    if (uiBusy || isPrimaryHomeRouteService(service.tag)) {
      return;
    }
    setState(() => uiBusy = true);
    try {
      final result = await widget.bridge.setHomeRouteServiceVisible(
        service.tag,
        visible,
      );
      if (result['success'] == false) {
        throw StateError(result['error']?.toString() ?? 'Выбор не сохранён');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        routes = routes
            .map(
              (route) => route.tag == service.tag
                  ? route.copyWith(homeVisible: visible)
                  : route,
            )
            .toList(growable: false);
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          statusMessage = 'Не удалось изменить список сервисов';
          connectionHint = _cleanError(error);
          connectionHintDanger = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => uiBusy = false);
      }
    }
  }

  Future<void> _openAddHomeRouteService() async {
    final available =
        routes
            .where(
              (route) =>
                  !route.homeVisible && !isPrimaryHomeRouteService(route.tag),
            )
            .toList(growable: false)
          ..sort((left, right) => left.name.compareTo(right.name));
    if (available.isEmpty) {
      return;
    }
    final selected = await showModalBottomSheet<RouteService>(
      context: context,
      backgroundColor: const Color(0xFF12201D),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _AddHomeRouteServiceSheet(services: available),
    );
    if (selected != null && mounted) {
      await _setHomeRouteVisibility(selected, true);
    }
  }

  String _statusLabel() {
    if (!online) {
      return 'Нет связи с ядром';
    }
    if (status.hasError) {
      return status.error.trim().isEmpty ? 'Требуется внимание' : 'Ошибка VPN';
    }
    if (busyTasks.containsKey('vpn-disconnect')) {
      return 'Отключаем VPN';
    }
    if (status.vpnState == 'reconnecting') {
      return 'Переподключаем VPN';
    }
    if (busyTasks.containsKey('vpn-connect')) {
      return 'Подключаем VPN';
    }
    if (connectionBusy) {
      return status.connected ? 'Подключение активно' : 'Подключаем VPN';
    }
    if (status.connected) {
      return 'Подключено';
    }
    return 'Отключено';
  }

  Widget _buildHomeDashboard(bool isBusy, String hintMessage) {
    final normalizedHint = hintMessage.trim().isNotEmpty
        ? hintMessage.trim()
        : status.hasError
        ? (status.error.trim().isEmpty
              ? 'Откройте диагностику подключения для подробностей.'
              : status.error.trim())
        : '';
    final mobileNeedsSubscription = _mobileNeedsSubscription;
    final powerEnabled =
        !controlsDisabled && !connectionBusy && !mobileNeedsSubscription;
    final disabledPowerAction =
        mobileNeedsSubscription && !controlsDisabled && !connectionBusy
        ? _showMobileSubscriptionRequiredNotice
        : null;
    final hintDanger =
        connectionHintDanger ||
        status.hasError ||
        (!online && !booting) ||
        statusMessage.toLowerCase().contains('ошибка');
    final showHint =
        normalizedHint.isNotEmpty &&
        (booting ||
            uiBusy ||
            connectionBusy ||
            quitting ||
            status.hasError ||
            connectionHintDanger ||
            !online ||
            externalVpnConflictBlocked ||
            depsProgress.trim().isNotEmpty);
    return _AtlasHomeLayout(
      connection: _HomeConnectionPanel(
        atlas: true,
        status: status,
        online: online,
        booting: booting,
        busy: isBusy,
        disconnecting: busyTasks.containsKey('vpn-disconnect'),
        routingMode: appConfig.routingMode,
        enabled: powerEnabled,
        onPressed: _toggleConnection,
        onDisabledPressed: disabledPowerAction,
        operationError: connectionHintDanger && !status.connected,
      ),
      source: _HomeSourcePanel(
        atlas: true,
        sources: homeSources,
        loaded: homeSourcesLoaded,
        failed: homeSourcesFailed,
        connected:
            online && status.connected && !connectionBusy && !status.hasError,
        online: online,
        hasSubscription: subscription.hasSubscription,
        onManage: controlsDisabled ? null : _openSubscription,
      ),
      notices:
          !(strategyTransitionNotice.isNotEmpty ||
              showHint ||
              routeProbeActive ||
              routeProbeFailed ||
              (legacyTelegramProxy.injected &&
                  legacyTelegramProxy.recommendRemove) ||
              updateInfo?.hasUpdate == true ||
              (!booting &&
                  status.dependencies.managed &&
                  !status.dependencies.bundled &&
                  (!status.dependencies.ready || status.dependencies.degraded)))
          ? null
          : Column(
              key: ValueKey(
                '$strategyTransitionNotice/$normalizedHint/$hintDanger/$routeProbeFailed/${updateInfo?.latestVersion}/${legacyTelegramProxy.recommendRemove}/${status.dependencies.ready}',
              ),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (strategyTransitionNotice.isNotEmpty && windowVisible)
                  _StrategySearchBanner(
                    message: strategyTransitionNotice,
                    transitionNotice: true,
                  ),
                if (legacyTelegramProxy.injected &&
                    legacyTelegramProxy.recommendRemove)
                  _LegacyTelegramProxyStrip(
                    onOpenSettings: controlsDisabled
                        ? null
                        : _openLegacyTelegramProxySettings,
                    onAcknowledge: controlsDisabled
                        ? null
                        : _acknowledgeLegacyTelegramProxyRemoved,
                  ),
                _ConnectionHint(
                  visible: showHint,
                  title: _hintTitle(),
                  message: normalizedHint,
                  danger: hintDanger,
                ),
                _RouteProbePanel(
                  visible: routeProbeActive || routeProbeFailed,
                  active: routeProbeActive,
                  failed: routeProbeFailed,
                  expectedCount: routeProbeExpectedCount,
                  items: routeProbeProgress.values.toList(growable: false),
                ),
                if (hintDanger && !booting && !online && !quitting)
                  TextButton.icon(
                    key: const ValueKey('home-retry-core'),
                    onPressed: () => unawaited(_bootstrap()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Повторить подключение к ядру'),
                  ),
                if (updateInfo?.hasUpdate == true)
                  _UpdateStrip(
                    info: updateInfo!,
                    progressPercent: updateProgressPercent,
                    onUpdate: controlsDisabled || uiBusy
                        ? null
                        : () => unawaited(_performUpdate(updateInfo!)),
                  ),
                if (!booting &&
                    status.dependencies.managed &&
                    !status.dependencies.bundled &&
                    (!status.dependencies.ready ||
                        status.dependencies.degraded))
                  _DependencyStrip(
                    status: status.dependencies,
                    onDownload: controlsDisabled ? null : _downloadDependencies,
                  ),
              ],
            ),
      routes: _buildRouteControls(summaryOnly: true),
    );
  }

  Widget _buildRouteControls({bool summaryOnly = false}) => _HomeRouteControls(
    atlas: true,
    summaryOnly: summaryOnly,
    services: routes
        .where(
          (route) => route.homeVisible || isPrimaryHomeRouteService(route.tag),
        )
        .toList(growable: false),
    enabled: !controlsDisabled && (!_isMobileShell || !status.connected),
    expanded: homeRoutesExpanded,
    routingMode: appConfig.routingMode,
    hasSubscription: subscription.hasSubscription,
    connected: online && status.connected,
    onExpandedChanged: (expanded) =>
        setState(() => homeRoutesExpanded = expanded),
    onRoutingModeChanged: _setHomeRoutingMode,
    onPolicyChanged: _setHomeRoutePolicy,
    onZapretStrategyChanged: _setHomeZapretStrategy,
    onAdd: controlsDisabled ? null : _openAddHomeRouteService,
    onRemove: _setHomeRouteVisibility,
    onAllServices: quitting || sectionBusy
        ? null
        : () => unawaited(_selectMenuSection('service-settings')),
  );

  Widget _buildMenuSection() {
    switch (activeMenuSection) {
      case 'service-settings':
        return SingleChildScrollView(
          key: const ValueKey('service-settings-section'),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ConnectionHint(
                    visible: connectionHint.trim().isNotEmpty,
                    title: _hintTitle(),
                    message: connectionHint,
                    danger: connectionHintDanger,
                  ),
                  _buildRouteControls(),
                  const SizedBox(height: 12),
                  _SettingsLink(
                    section: 'services',
                    title: 'Все сервисы',
                    detail: 'Полный каталог и поиск по доменам',
                    icon: Icons.search,
                    onPressed: quitting || sectionBusy
                        ? null
                        : () => unawaited(_selectMenuSection('services')),
                  ),
                ],
              ),
            ),
          ),
        );
      case 'settings':
      case 'advanced':
      case 'help':
        return _MinimalSettingsPage(
          section: activeMenuSection,
          disabled: quitting || sectionBusy,
          onSelect: (section) => unawaited(_selectMenuSection(section)),
          onWorkNetworks: controlsDisabled ? null : _openWireGuard,
          onExit: quitting ? null : _quitApp,
        );
      case 'services':
        return ServiceRoutesPage(
          key: const ValueKey('services-section'),
          bridge: widget.bridge,
          routeSnapshot: online ? routes : null,
          connected: status.connected,
          enabled: online && !quitting && !uiBusy && !connectionBusy,
          routingMode: appConfig.routingMode,
          onBusyChanged: _setSectionBusy,
          onChanged: () => unawaited(_refresh(all: true)),
        );
      case 'sources':
        return VpnSourcesDialog(
          key: const ValueKey('sources-section'),
          bridge: widget.bridge,
          subscription: subscription,
          embedded: true,
          enabled:
              online &&
              !quitting &&
              !uiBusy &&
              !connectionBusy &&
              (!_isMobileShell || !status.connected),
          sourceSnapshot: homeSourcesLoaded && online ? homeSources : null,
          onBusyChanged: _setSectionBusy,
          onChanged: () => unawaited(_refresh(all: true)),
          onReadyToConnect: () => unawaited(_selectMenuSection('home')),
        );
      case 'profiles':
        return _ProfilesDialog(
          key: const ValueKey('profiles-section'),
          bridge: widget.bridge,
          initialProfiles: profiles,
          activeProfileId: activeProfile?.id ?? 1,
          vpnRunning: status.connected || connectionBusy,
          embedded: true,
          onChanged: () => unawaited(_refresh(all: true)),
        );
      case 'app-settings':
      case 'technical-settings':
        return _SettingsDialog(
          key: ValueKey(activeMenuSection),
          advanced: activeMenuSection == 'technical-settings',
          bridge: widget.bridge,
          initialConfig: appConfig,
          currentStatus: status,
          updateInfo: updateInfo,
          embedded: true,
          onChanged: (updated) => setState(() => appConfig = updated),
          onCheckUpdates: () => unawaited(_checkUpdates()),
          onInstallUpdate: () {
            final info = updateInfo;
            if (info != null) {
              unawaited(_performUpdate(info));
            }
          },
          onDownloadDependencies: () => unawaited(_downloadDependencies()),
          onOpenServices: () => unawaited(_selectMenuSection('services')),
        );
      case 'dropo_space':
        return _AndroidCompatibilityPage(
          key: const ValueKey('dropo-space-section'),
          bridge: widget.bridge,
        );
      case 'stats':
        return _StatsDialog(
          key: const ValueKey('stats-section'),
          bridge: widget.bridge,
          initialStats: menuStats,
          status: status,
          subscription: subscription,
          embedded: true,
        );
      case 'logs':
        return _LogsDialog(
          key: const ValueKey('logs-section'),
          bridge: widget.bridge,
          connected: online && status.connected,
          routingMode: appConfig.routingMode,
          routes: routes,
          routesAreLive: online && liveRoutesConfirmed,
          logs: logs,
          onOpenFolder: () => widget.bridge.openLogsFolder(),
          onCopyDiagnostics: () => widget.bridge.diagnostics(),
          embedded: true,
        );
      case 'about':
        return _AboutSection(
          key: const ValueKey('about-section'),
          status: status,
          appConfig: appConfig,
          onOpenExternal: widget.bridge.openExternal,
        );
      default:
        return _buildHomeDashboard(
          connectionBusy || uiBusy || booting || quitting,
          connectionHint.trim().isNotEmpty ? connectionHint : depsProgress,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = connectionBusy || uiBusy || booting || quitting;
    final hintMessage = connectionHint.trim().isNotEmpty
        ? connectionHint
        : depsProgress;
    final strategyBannerMessage = strategyTransitionNotice.trim();
    return _AtlasDesktopShell(
      activeSection: activeMenuSection,
      disabled: quitting || sectionBusy,
      onSelect: (section) => unawaited(_selectMenuSection(section)),
      onBack: _sectionHistory.isEmpty
          ? null
          : () {
              final previous = _sectionHistory.removeLast();
              unawaited(_selectMenuSection(previous, remember: false));
            },
      onWorkNetworks: controlsDisabled ? null : _openWireGuard,
      onExit: quitting ? null : _quitApp,
      version: status.version.fullVersion,
      notice:
          activeMenuSection == 'home' ||
              strategyBannerMessage.isEmpty ||
              !windowVisible
          ? null
          : _StrategySearchBanner(
              key: ValueKey(strategyBannerMessage),
              message: strategyBannerMessage,
              transitionNotice: true,
            ),
      overlay: quitting
          ? _QuitProgressOverlay(message: quitProgressMessage)
          : null,
      child: activeMenuSection == 'home'
          ? _buildHomeDashboard(isBusy, hintMessage)
          : _buildMenuSection(),
    );
  }

  String _hintTitle() {
    if (quitting) {
      return 'Выход';
    }
    if (booting) {
      return 'Запуск';
    }
    if (busyTasks.containsKey('vpn-disconnect')) {
      return 'Отключение';
    }
    if (busyTasks.containsKey('vpn-connect')) {
      return 'Подключение';
    }
    if (busyTasks.containsKey('discord-realtime-connect')) {
      return 'Фоновая проверка Discord';
    }
    if (connectionBusy) {
      return status.connected ? 'Отключение' : 'Подключение';
    }
    if (!online) {
      return 'Связь с ядром';
    }
    if (status.hasError || connectionHintDanger) return 'Требуется внимание';
    return 'Готово';
  }

  void _setSectionBusy(bool value) {
    if (mounted) setState(() => sectionBusy = value);
  }

  Future<void> _selectMenuSection(
    String section, {
    bool remember = true,
  }) async {
    if (!mounted || quitting || sectionBusy) {
      return;
    }
    setState(() {
      if (remember && section != activeMenuSection) {
        if (section == 'home' || section == 'settings') {
          _sectionHistory.clear();
        } else {
          _sectionHistory.add(activeMenuSection);
        }
      }
      activeMenuSection = section;
    });
    if (section == 'profiles') {
      try {
        final loaded = await widget.bridge.profiles();
        if (mounted) {
          setState(() => profiles = loaded.profiles);
        }
      } catch (_) {}
    } else if (section == 'stats') {
      try {
        final loaded = await widget.bridge.trafficStats();
        if (mounted) {
          setState(() => menuStats = loaded);
        }
      } catch (_) {}
    } else if (section == 'home') {
      await _refresh(all: true);
    } else if (section == 'logs') {
      await _refresh();
    }
  }

  Future<void> _openSubscription() async {
    await _selectMenuSection('sources');
  }

  Future<void> _openWireGuard() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _WireGuardDialog(
        bridge: widget.bridge,
        initialConfigs: wireGuards,
        vpnRunning: status.connected || connectionBusy,
      ),
    );
    if (changed == true) {
      await _refresh(all: true);
    }
  }

  // ignore: unused_element
  Future<void> _openAbout() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _AppDialog(
        title: 'О приложении',
        icon: Icons.info_outline,
        child: Column(
          children: [
            const _HomeBrand(),
            const SizedBox(height: 12),
            _FactRow(label: 'Версия', value: status.version.fullVersion),
            _LinkFactRow(
              label: 'Telegram',
              value: appConfig.telegramName,
              onPressed: () =>
                  widget.bridge.openExternal(appConfig.telegramUrl),
            ),
            _LinkFactRow(
              label: 'GitHub',
              value: appConfig.githubRepo,
              onPressed: () => widget.bridge.openExternal(appConfig.githubUrl),
            ),
            const SizedBox(height: 8),
            const Text(
              'Официальная сборка Dropo by sunnydjam. Скачивайте приложение только из GitHub Releases основного репозитория.',
              style: TextStyle(color: Color(0xFF9BB0AB), height: 1.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegacyTelegramProxyStrip extends StatelessWidget {
  const _LegacyTelegramProxyStrip({
    required this.onOpenSettings,
    required this.onAcknowledge,
  });

  final VoidCallback? onOpenSettings;
  final VoidCallback? onAcknowledge;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('legacy-telegram-proxy-strip'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2218).withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.telegram, color: Color(0xFFF8D38B), size: 20),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Старый proxy Telegram требует проверки',
                  style: TextStyle(
                    color: Color(0xFFF8D38B),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Предыдущая версия dropo могла сохранить локальный proxy в Telegram. Новая версия его не запускает. Откройте настройки Telegram и удалите этот proxy вручную.',
            style: TextStyle(
              color: Color(0xFFD8E4E0),
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('open-telegram-proxy-settings'),
                onPressed: onOpenSettings,
                icon: const Icon(Icons.open_in_new, size: 17),
                label: const Text('Открыть настройки Telegram'),
              ),
              FilledButton.icon(
                key: const ValueKey('ack-telegram-proxy-removed'),
                onPressed: onAcknowledge,
                icon: const Icon(Icons.check, size: 17),
                label: const Text('Proxy уже удалён'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectionHint extends StatelessWidget {
  const _ConnectionHint({
    required this.visible,
    required this.title,
    required this.message,
    required this.danger,
  });

  final bool visible;
  final String title;
  final String message;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final background = danger
        ? const Color(0xFF3A1518)
        : const Color(0xFF2A2218);
    final border = danger ? const Color(0xFFEF4444) : const Color(0xFFF59E0B);
    final titleColor = danger
        ? const Color(0xFFFCA5A5)
        : const Color(0xFFF8D38B);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: !visible
          ? const SizedBox(height: 0)
          : Container(
              key: ValueKey('$title$message'),
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: background.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: border.withValues(alpha: danger ? 0.42 : 0.22),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.toUpperCase(),
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFFD8E4E0),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _StrategySearchBanner extends StatelessWidget {
  const _StrategySearchBanner({
    super.key,
    required this.message,
    required this.transitionNotice,
  });

  final String message;
  final bool transitionNotice;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFCD34D);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF33270E).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: accent.withValues(alpha: 0.65)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.18),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(strokeWidth: 2, color: accent),
              ),
              const SizedBox(width: 10),
              Icon(
                transitionNotice
                    ? Icons.swap_horiz_rounded
                    : Icons.warning_amber_rounded,
                size: 19,
                color: accent,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFFF1C2),
                    fontSize: 12,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteProbePanel extends StatelessWidget {
  const _RouteProbePanel({
    required this.visible,
    required this.active,
    required this.failed,
    required this.expectedCount,
    required this.items,
  });

  final bool visible;
  final bool active;
  final bool failed;
  final int expectedCount;
  final List<RouteProbeProgress> items;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return const SizedBox.shrink();
    }
    final doneCount = items.where((item) => item.done).length;
    final total = expectedCount > 0 ? expectedCount : items.length;
    final accent = failed
        ? const Color(0xFFEF4444)
        : active
        ? const Color(0xFFF59E0B)
        : const Color(0xFF36D399);
    final background = failed
        ? const Color(0xFF3A1518)
        : const Color(0xFF111B24);
    final title = failed
        ? 'Подбор стратегий требует внимания'
        : active
        ? 'Подбор стратегий'
        : 'Стратегии подобраны';
    final subtitle = total > 0
        ? '$doneCount из $total сервисов готовы'
        : 'Ждём список сервисов от ядра';
    final sortedItems = List<RouteProbeProgress>.from(items)
      ..sort((left, right) {
        if (left.pending != right.pending) {
          return left.pending ? -1 : 1;
        }
        return left.name.compareTo(right.name);
      });
    final rows = items.isEmpty
        ? const <Widget>[
            _RouteProbeRow(
              icon: Icons.hourglass_top,
              name: 'Подготовка',
              detail: 'Ядро готовит список сервисов для проверки',
              color: Color(0xFFF59E0B),
            ),
          ]
        : sortedItems.map(_buildRow).toList(growable: false);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: background.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accent.withValues(alpha: failed ? 0.48 : 0.26),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                failed
                    ? Icons.error_outline
                    : active
                    ? Icons.manage_search
                    : Icons.check_circle,
                color: accent,
                size: 16,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.58),
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 8),
          ...rows,
        ],
      ),
    );
  }

  Widget _buildRow(RouteProbeProgress item) {
    final color = item.failed
        ? const Color(0xFFFCA5A5)
        : item.done
        ? const Color(0xFF86EFAC)
        : item.pending
        ? const Color(0xFFFCD34D)
        : const Color(0xFF9CB0AD);
    final icon = item.failed
        ? Icons.close
        : item.done
        ? Icons.check
        : item.pending
        ? Icons.sync
        : Icons.more_horiz;
    final detail = item.failed
        ? _failedDetail(item)
        : item.done
        ? (item.method.isEmpty ? 'Готово' : item.method)
        : item.pending
        ? _pendingDetail(item)
        : 'Ожидает проверки';
    return _RouteProbeRow(
      icon: icon,
      name: item.name,
      detail: detail,
      color: color,
      busy: item.pending,
    );
  }

  String _pendingDetail(RouteProbeProgress item) {
    final attempt = item.attempt > 0
        ? 'попытка ${item.attempt}${item.attemptTotal > 0 ? '/${item.attemptTotal}' : ''}'
        : '';
    final method = item.method.isEmpty ? 'подбираем стратегию' : item.method;
    final strategy = item.strategyIndex > 0
        ? 'стратегия ${item.strategyIndex}${item.strategyTotal > 0 ? '/${item.strategyTotal}' : ''}'
        : '';
    if (item.status == 'voice-check') {
      return [
        attempt,
        strategy,
        'проверяем voice',
        method,
      ].where((part) => part.isNotEmpty).join(' · ');
    }
    return [
      attempt,
      strategy,
      method,
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  String _failedDetail(RouteProbeProgress item) {
    final attempt = item.attempt > 0
        ? 'попытка ${item.attempt}${item.attemptTotal > 0 ? '/${item.attemptTotal}' : ''}'
        : '';
    final error = item.error.isEmpty ? 'Стратегия не найдена' : item.error;
    return [attempt, error].where((part) => part.isNotEmpty).join(' · ');
  }
}

class _RouteProbeRow extends StatelessWidget {
  const _RouteProbeRow({
    required this.icon,
    required this.name,
    required this.detail,
    required this.color,
    this.busy = false,
  });

  final IconData icon;
  final String name;
  final String detail;
  final Color color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (busy)
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
            )
          else
            Icon(icon, size: 13, color: color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFE5EEF8),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(color: color, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _DependencyStrip extends StatelessWidget {
  const _DependencyStrip({required this.status, required this.onDownload});

  final DepsStatus status;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    if (!status.managed || status.bundled) {
      return const SizedBox.shrink();
    }
    if (status.ready && !status.degraded) {
      return const SizedBox.shrink();
    }
    if (status.degraded) {
      final warning = status.warning.trim();
      return MouseRegion(
        cursor: onDownload == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onDownload,
          child: _MiniStrip(
            icon: Icons.security,
            color: const Color(0xFFF59E0B),
            text: warning.isEmpty
                ? 'Часть встроенного runtime недоступна. Нажмите для проверки и локального восстановления.'
                : '$warning Нажмите для повторной проверки.',
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: onDownload == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onDownload,
        child: _MiniStrip(
          icon: Icons.download,
          color: const Color(0xFFF59E0B),
          text: 'Нужны компоненты ${status.sizeMb} MB. Нажмите, чтобы скачать.',
        ),
      ),
    );
  }
}

class _UpdateStrip extends StatelessWidget {
  const _UpdateStrip({
    required this.info,
    required this.progressPercent,
    required this.onUpdate,
  });

  final UpdateInfo info;
  final double? progressPercent;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final progress = progressPercent;
    final actionLabel = info.selfUpdate
        ? 'Обновить и перезапустить'
        : info.platform.toLowerCase() == 'windows'
        ? 'Скачать portable'
        : 'Скачать APK';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_alt, color: Color(0xFFFBBF24)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Доступна версия ${info.latestVersion}',
                  style: const TextStyle(
                    color: Color(0xFFF8FAFC),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            progress == null
                ? 'Обновление готово к загрузке и проверке.'
                : 'Загружено ${progress.round()}%',
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 10.5),
          ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress <= 0 ? null : progress / 100,
              minHeight: 3,
              color: const Color(0xFFFBBF24),
              backgroundColor: Colors.white.withValues(alpha: 0.08),
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onUpdate, child: Text(actionLabel)),
          ),
        ],
      ),
    );
  }
}

class _MiniStrip extends StatelessWidget {
  const _MiniStrip({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB7CAC5), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuPageSurface extends StatefulWidget {
  const _MenuPageSurface({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  State<_MenuPageSurface> createState() => _MenuPageSurfaceState();
}

class _MenuPageSurfaceState extends State<_MenuPageSurface> {
  final ScrollController scrollController = ScrollController();

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = _isMobileShell;
    return Container(
      key: ValueKey(widget.title),
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: isMobile ? 720 : 640),
      padding: EdgeInsets.all(isMobile ? 14 : 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xE8142121), Color(0xE811181A), Color(0xE8211921)],
          stops: [0, 0.58, 1],
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.11)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.42),
            blurRadius: 42,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(widget.icon, color: const Color(0xFFBAF7D0), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFE8F3EF),
                    fontSize: 18,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Flexible(
            child: Scrollbar(
              controller: scrollController,
              thumbVisibility: !isMobile,
              child: SingleChildScrollView(
                controller: scrollController,
                primary: false,
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuitProgressOverlay extends StatelessWidget {
  const _QuitProgressOverlay({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final body = message.trim().isEmpty
        ? 'Останавливаем VPN, WinDivert и фоновые процессы...'
        : message.trim();
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.58),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Container(
            margin: const EdgeInsets.all(18),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            decoration: BoxDecoration(
              color: const Color(0xFF111B1D).withValues(alpha: 0.98),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.42),
                  blurRadius: 34,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.8),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Завершение работы',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFE5EEF8),
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  body,
                  style: const TextStyle(
                    color: Color(0xFFBDD0CB),
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    color: const Color(0xFF36D399),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Окно закроется автоматически после остановки фоновых процессов.',
                  style: TextStyle(color: Color(0xFF7F918C), fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppDialog extends StatelessWidget {
  const _AppDialog({
    required this.title,
    required this.icon,
    required this.child,
    this.width = 460,
    this.centered = false,
    this.heightFactor = 0.9,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final double width;
  final bool centered;
  final double heightFactor;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableWidth = centered
        ? math.max(0.0, media.size.width - 44)
        : media.size.width;
    return Dialog(
      alignment: centered ? Alignment.center : Alignment.centerLeft,
      backgroundColor: Colors.transparent,
      insetPadding: centered
          ? const EdgeInsets.symmetric(horizontal: 22, vertical: 24)
          : EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: centered
              ? media.size.height * heightFactor.clamp(0.45, 0.96)
              : media.size.height,
        ),
        child: Container(
          width: math.min(width, availableWidth),
          height: centered ? null : media.size.height,
          padding: EdgeInsets.fromLTRB(
            22,
            centered ? 20 : media.padding.top + 18,
            22,
            centered ? 20 : media.padding.bottom + 18,
          ),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFA142121), Color(0xFA11181A), Color(0xFA211921)],
              stops: [0, 0.58, 1],
            ),
            borderRadius: centered
                ? BorderRadius.circular(18)
                : const BorderRadius.horizontal(right: Radius.circular(18)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.58),
                blurRadius: centered ? 52 : 70,
                offset: centered ? const Offset(0, 18) : const Offset(18, 0),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, color: const Color(0xFFBAF7D0)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFE8F3EF),
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    color: const Color(0xFFCDE7DE),
                    icon: const Icon(Icons.close),
                    tooltip: 'Закрыть',
                    mouseCursor: SystemMouseCursors.click,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(child: child),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogsDialog extends StatefulWidget {
  const _LogsDialog({
    super.key,
    required this.bridge,
    required this.connected,
    required this.routingMode,
    required this.routes,
    required this.routesAreLive,
    required this.logs,
    required this.onOpenFolder,
    this.onCopyDiagnostics,
    this.embedded = false,
  });

  final CoreBridge bridge;
  final bool connected;
  final String routingMode;
  final List<RouteService> routes;
  final bool routesAreLive;
  final List<String> logs;
  final Future<void> Function() onOpenFolder;
  final Future<String> Function()? onCopyDiagnostics;
  final bool embedded;

  @override
  State<_LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<_LogsDialog> {
  final scrollController = ScrollController();

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = widget.logs;
    final onOpenFolder = widget.onOpenFolder;
    final onCopyDiagnostics = widget.onCopyDiagnostics;
    final embedded = widget.embedded;
    final isMobile = _isMobileShell;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final logHeight = isMobile
        ? math.max(300.0, math.min(560.0, viewportHeight * 0.58))
        : 420.0;
    final text = logs.isEmpty ? 'Логи пока пустые' : logs.join('\n');
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ConnectionHealthPanel(
          bridge: widget.bridge,
          connected: widget.connected,
          routingMode: widget.routingMode,
          routes: widget.routes,
          routesAreLive: widget.routesAreLive,
        ),
        const SizedBox(height: 18),
        const Row(
          children: [
            Icon(Icons.article_outlined, color: Color(0xFFBAF7D0), size: 20),
            SizedBox(width: 9),
            Text(
              'Технический журнал',
              style: TextStyle(
                color: Color(0xFFE8F3EF),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                isMobile
                    ? 'Android core, VpnService и sing-box.'
                    : 'Текст можно выделять мышью и копировать.',
                style: const TextStyle(color: Color(0xFF9BB0AB), fontSize: 12),
              ),
            ),
            _ActionButton(
              label: 'Копировать всё',
              icon: Icons.copy,
              compact: true,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Логи скопированы')),
                  );
                }
              },
            ),
          ],
        ),
        if (onCopyDiagnostics != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: _ActionButton(
              label: 'Копировать диагностику',
              icon: Icons.bug_report,
              compact: true,
              onPressed: () async {
                final diagnostics = await onCopyDiagnostics();
                await Clipboard.setData(ClipboardData(text: diagnostics));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Диагностика скопирована')),
                  );
                }
              },
            ),
          ),
        ],
        const SizedBox(height: 10),
        Container(
          height: logHeight,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Scrollbar(
            thumbVisibility: !isMobile,
            controller: scrollController,
            child: SingleChildScrollView(
              controller: scrollController,
              primary: false,
              child: SelectionArea(
                child: SelectableText(
                  text,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.35,
                    color: Color(0xFFC8D8D5),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (!isMobile) ...[
          const SizedBox(height: 12),
          if (embedded)
            _ActionButton(
              label: 'Открыть папку с логами',
              icon: Icons.folder_open,
              onPressed: () async {
                await onOpenFolder();
              },
            )
          else
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: 'Открыть папку с логами',
                    icon: Icons.folder_open,
                    onPressed: () async {
                      await onOpenFolder();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionButton(
                    label: 'Закрыть',
                    icon: Icons.close,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
        ] else if (!embedded) ...[
          const SizedBox(height: 12),
          _ActionButton(
            label: 'Закрыть',
            icon: Icons.close,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ],
    );
    if (embedded) {
      return _MenuPageSurface(
        title: 'Диагностика',
        icon: Icons.health_and_safety_outlined,
        child: content,
      );
    }
    return _AppDialog(
      width: 760,
      title: 'Диагностика',
      icon: Icons.health_and_safety_outlined,
      child: content,
    );
  }
}

// autoStartPromptDialogForTest exposes the private first-run dialog to widget
// tests without widening the app's public surface.
@visibleForTesting
Widget autoStartPromptDialogForTest({
  required void Function(bool enable) onDecision,
}) {
  return _AutoStartPromptDialog(onDecision: onDecision);
}

@visibleForTesting
Widget androidCompatibilityNoticeDialogForTest({
  required AndroidCompatibilityInfo info,
  required void Function(bool openDropoSpace) onDecision,
}) {
  return _AndroidCompatibilityNoticeDialog(
    info: info,
    onDecision: (action) => onDecision(action.openDropoSpace),
  );
}

// _AutoStartPromptDialog is the one-time first-run notification about launch at
// system startup. "ОК" (right) enables autostart; the red "Нет, не надо"
// (bottom-left) declines it and flips the default off.
class _AutoStartPromptDialog extends StatelessWidget {
  const _AutoStartPromptDialog({required this.onDecision});

  final void Function(bool enable) onDecision;

  @override
  Widget build(BuildContext context) {
    return _AppDialog(
      title: 'Автозапуск',
      icon: Icons.power_settings_new,
      width: 480,
      centered: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'dropo будет автоматически запускаться при входе в систему, чтобы '
            'обход блокировок и VPN были готовы сразу.',
            style: TextStyle(color: Color(0xFFD8E4E0), height: 1.4),
          ),
          const SizedBox(height: 8),
          const Text(
            'Нажмите «ОК», чтобы добавить dropo в автозагрузку. Если выберете '
            '«Нет, не надо», автозапуск останется выключенным — включить его '
            'можно позже в настройках.',
            style: TextStyle(
              color: Color(0xFF9FB2AE),
              height: 1.35,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Нет, не надо',
                  icon: Icons.block,
                  danger: true,
                  onPressed: () => onDecision(false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'ОК',
                  icon: Icons.check,
                  onPressed: () => onDecision(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.danger = false,
    this.compact = false,
    this.secondary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;
  final bool compact;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onPressed == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: FilledButton(
        onPressed: onPressed,
        style: _withClickCursor(
          FilledButton.styleFrom(
            backgroundColor: danger
                ? const Color(0xFF7F1D1D)
                : secondary
                ? const Color(0xFF2B3C38)
                : const Color(0xFF176B5D),
            foregroundColor: secondary ? const Color(0xFFE8F3EF) : Colors.white,
            disabledBackgroundColor: const Color(0xFF24312F),
            disabledForegroundColor: const Color(0xFFA3B5AF),
            side: BorderSide(
              color: secondary ? const Color(0xFF48615A) : Colors.transparent,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 14,
              vertical: compact ? 8 : 13,
            ),
            textStyle: TextStyle(
              fontSize: compact ? 12 : 13,
              fontWeight: FontWeight.w400,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: compact ? 15 : 18),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    super.key,
    required this.status,
    required this.appConfig,
    required this.onOpenExternal,
  });

  final CoreStatus status;
  final AppConfig appConfig;
  final Future<void> Function(String link) onOpenExternal;

  @override
  Widget build(BuildContext context) {
    return _MenuPageSurface(
      title: 'О приложении',
      icon: Icons.info_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: _HomeBrand()),
          const SizedBox(height: 14),
          _FactRow(label: 'Версия', value: status.version.fullVersion),
          _LinkFactRow(
            label: 'Telegram',
            value: appConfig.telegramName,
            onPressed: () => onOpenExternal(appConfig.telegramUrl),
          ),
          _LinkFactRow(
            label: 'GitHub',
            value: appConfig.githubRepo,
            onPressed: () => onOpenExternal(appConfig.githubUrl),
          ),
          const SizedBox(height: 10),
          const _InfoBand(
            icon: Icons.verified_user_outlined,
            title: 'Официальная сборка',
            body:
                'Скачивайте приложение только из GitHub Releases основного репозитория.',
          ),
        ],
      ),
    );
  }
}

class _InfoBand extends StatelessWidget {
  const _InfoBand({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF36D399)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(body, style: const TextStyle(color: Color(0xFF9CB0AD))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VpnConflictTile extends StatelessWidget {
  const _VpnConflictTile({required this.item});

  final VpnConflictItem item;

  @override
  Widget build(BuildContext context) {
    final detail = item.detail.trim();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2218).withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.vpn_lock, color: Color(0xFFF8D38B), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFFFF7DE),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFBBAF96),
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (item.kind.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              item.kind,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFF8D38B),
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfilesDialog extends StatefulWidget {
  const _ProfilesDialog({
    super.key,
    required this.bridge,
    required this.initialProfiles,
    required this.activeProfileId,
    required this.vpnRunning,
    this.embedded = false,
    this.onChanged,
  });

  final CoreBridge bridge;
  final List<ProfileInfo> initialProfiles;
  final int activeProfileId;
  final bool vpnRunning;
  final bool embedded;
  final VoidCallback? onChanged;

  @override
  State<_ProfilesDialog> createState() => _ProfilesDialogState();
}

class _ProfilesDialogState extends State<_ProfilesDialog> {
  List<ProfileInfo> profiles = const [];
  int activeProfileId = 0;
  bool busy = false;
  String statusText = '';
  String statusKind = '';

  bool get canEdit => !busy && !widget.vpnRunning;

  @override
  void initState() {
    super.initState();
    profiles = widget.initialProfiles;
    activeProfileId = widget.activeProfileId;
    if (profiles.isEmpty) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    setState(() => busy = true);
    try {
      final data = await widget.bridge.profiles();
      if (!mounted) {
        return;
      }
      setState(() {
        profiles = data.profiles;
        activeProfileId = data.activeProfileId;
        statusText = data.error;
        statusKind = data.error.isEmpty ? '' : 'error';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        statusText = _cleanError(error);
        statusKind = 'error';
      });
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  String _nextProfileName() {
    final names = profiles.map((profile) => profile.name).toSet();
    for (var i = profiles.length + 1; i < profiles.length + 20; i++) {
      final candidate = 'Профиль $i';
      if (!names.contains(candidate)) {
        return candidate;
      }
    }
    return 'Профиль';
  }

  Future<void> _create() async {
    final name = await _askProfileName(
      title: 'Новый профиль',
      initialValue: _nextProfileName(),
    );
    if (name == null) {
      return;
    }
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = 'Создаём профиль...';
    });
    final result = await widget.bridge.createProfile(name);
    if (!mounted) {
      return;
    }
    if (result['success'] == false) {
      setState(() {
        busy = false;
        statusKind = 'error';
        statusText = result['error']?.toString() ?? 'Не удалось создать';
      });
      return;
    }
    await _load();
    widget.onChanged?.call();
    if (mounted) {
      setState(() {
        statusKind = 'success';
        statusText = 'Профиль создан.';
      });
    }
  }

  Future<void> _rename(ProfileInfo profile) async {
    final name = await _askProfileName(
      title: 'Переименовать профиль',
      initialValue: profile.name,
    );
    if (name == null || name == profile.name) {
      return;
    }
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = 'Переименовываем профиль...';
    });
    final result = await widget.bridge.updateProfile(profile.id, name);
    if (!mounted) {
      return;
    }
    if (result['success'] == false) {
      setState(() {
        busy = false;
        statusKind = 'error';
        statusText = result['error']?.toString() ?? 'Не удалось сохранить';
      });
      return;
    }
    await _load();
    widget.onChanged?.call();
    if (mounted) {
      setState(() {
        statusKind = 'success';
        statusText = 'Профиль переименован.';
      });
    }
  }

  Future<void> _delete(ProfileInfo profile) async {
    if (profile.isDefault) {
      setState(() {
        statusKind = 'warning';
        statusText = 'Профиль «Мой» нельзя удалить.';
      });
      return;
    }
    final confirmed = await _confirmDelete(profile);
    if (confirmed != true) {
      return;
    }
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = 'Удаляем профиль...';
    });
    final result = await widget.bridge.deleteProfile(profile.id);
    if (!mounted) {
      return;
    }
    if (result['success'] == false) {
      setState(() {
        busy = false;
        statusKind = 'error';
        statusText = result['error']?.toString() ?? 'Не удалось удалить';
      });
      return;
    }
    await _load();
    widget.onChanged?.call();
    if (mounted) {
      setState(() {
        statusKind = 'success';
        statusText = 'Профиль удалён.';
      });
    }
  }

  Future<void> _activate(ProfileInfo profile) async {
    if (profile.isActive || profile.id == activeProfileId) {
      return;
    }
    if (widget.vpnRunning) {
      setState(() {
        statusKind = 'warning';
        statusText = 'Отключите VPN перед сменой профиля.';
      });
      return;
    }
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = 'Переключаем профиль...';
    });
    final result = await widget.bridge.setActiveProfile(profile.id);
    if (!mounted) {
      return;
    }
    if (result['success'] == false) {
      setState(() {
        busy = false;
        statusKind = 'error';
        statusText = result['error']?.toString() ?? 'Не удалось переключить';
      });
      return;
    }
    if (widget.embedded) {
      await _load();
      widget.onChanged?.call();
      if (mounted) {
        setState(() {
          statusKind = 'success';
          statusText = 'Профиль переключён.';
        });
      }
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<String?> _askProfileName({
    required String title,
    required String initialValue,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (context) =>
          _ProfileNameDialog(title: title, initialValue: initialValue),
    );
  }

  Future<bool?> _confirmDelete(ProfileInfo profile) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => _AppDialog(
        title: 'Удалить профиль',
        icon: Icons.delete_outline,
        width: 480,
        centered: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              profile.isActive
                  ? 'Активный профиль «${profile.name}» будет удалён, после этого включится профиль «Мой».'
                  : 'Профиль «${profile.name}» будет удалён вместе с подпиской и WireGuard-настройками внутри него.',
              style: const TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: 'Отмена',
                    icon: Icons.close,
                    secondary: true,
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionButton(
                    label: 'Удалить',
                    icon: Icons.delete,
                    danger: true,
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = _isMobileShell;
    var activeId = activeProfileId;
    if (activeId == 0) {
      for (final profile in profiles) {
        if (profile.isActive) {
          activeId = profile.id;
          break;
        }
      }
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.vpnRunning) ...[
          const _InfoBand(
            icon: Icons.lock,
            title: 'VPN активен',
            body:
                'Список можно открыть, но менять профиль и редактировать его безопаснее после отключения VPN.',
          ),
          const SizedBox(height: 12),
        ],
        if (profiles.isEmpty)
          const _EmptyState(text: 'Профилей пока нет')
        else
          ...profiles.map(
            (profile) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ProfileTile(
                profile: profile,
                active: profile.id == activeId || profile.isActive,
                busy: busy,
                editable: canEdit,
                showEditActions: !isMobile,
                onActivate:
                    canEdit && !(profile.id == activeId || profile.isActive)
                    ? () => _activate(profile)
                    : null,
                onRename: canEdit ? () => _rename(profile) : null,
                onDelete: canEdit && !profile.isDefault
                    ? () => _delete(profile)
                    : null,
              ),
            ),
          ),
        if (statusText.isNotEmpty) ...[
          const SizedBox(height: 4),
          _StatusBox(kind: statusKind, text: statusText),
        ],
        const SizedBox(height: 14),
        if (widget.embedded && !isMobile)
          _ActionButton(
            label: 'Новый',
            icon: Icons.add,
            onPressed: canEdit ? _create : null,
          )
        else if (widget.embedded && isMobile)
          const _InfoBand(
            icon: Icons.info_outline,
            title: 'Android профиль',
            body: 'На Android используется активная VPN-подписка.',
          )
        else
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Новый',
                  icon: Icons.add,
                  onPressed: canEdit ? _create : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'Закрыть',
                  icon: Icons.close,
                  secondary: true,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
            ],
          ),
      ],
    );
    if (widget.embedded) {
      return _MenuPageSurface(
        title: 'Профили',
        icon: Icons.account_circle,
        child: content,
      );
    }
    return _AppDialog(
      title: 'Профили',
      icon: Icons.account_circle,
      width: 560,
      centered: true,
      child: content,
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.active,
    required this.busy,
    required this.editable,
    required this.showEditActions,
    required this.onActivate,
    required this.onRename,
    required this.onDelete,
  });

  final ProfileInfo profile;
  final bool active;
  final bool busy;
  final bool editable;
  final bool showEditActions;
  final VoidCallback? onActivate;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final accent = active ? const Color(0xFF36D399) : const Color(0xFF8EA2A0);
    final details = <String>[
      profile.hasSubscription ? '${profile.proxyCount} proxy' : 'без подписки',
      if (profile.wireguardCount > 0) 'WG ${profile.wireguardCount}',
    ].join(' · ');
    return MouseRegion(
      cursor: onActivate == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onActivate,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF10352B).withValues(alpha: 0.76)
                : Colors.white.withValues(alpha: 0.055),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active
                  ? const Color(0xFF36D399).withValues(alpha: 0.42)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: Row(
            children: [
              Icon(
                active ? Icons.check_circle : Icons.account_circle,
                color: accent,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFE8F5F1),
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 8),
                          const Text(
                            'АКТИВЕН',
                            style: TextStyle(
                              color: Color(0xFFBAF7D0),
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8EA2A0),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (showEditActions) ...[
                IconButton(
                  onPressed: busy || !editable ? null : onRename,
                  icon: const Icon(Icons.edit, size: 17),
                  tooltip: 'Переименовать',
                  mouseCursor: busy || !editable
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.click,
                ),
                IconButton(
                  onPressed: busy || !editable ? null : onDelete,
                  icon: const Icon(Icons.delete, size: 17),
                  tooltip: profile.isDefault
                      ? 'Профиль по умолчанию'
                      : 'Удалить',
                  mouseCursor: busy || !editable || onDelete == null
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.click,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileNameDialog extends StatefulWidget {
  const _ProfileNameDialog({required this.title, required this.initialValue});

  final String title;
  final String initialValue;

  @override
  State<_ProfileNameDialog> createState() => _ProfileNameDialogState();
}

class _ProfileNameDialogState extends State<_ProfileNameDialog> {
  late final controller = TextEditingController(text: widget.initialValue);
  String error = '';

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = controller.text.trim();
    if (name.isEmpty) {
      setState(() => error = 'Введите название профиля.');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return _AppDialog(
      title: widget.title,
      icon: Icons.edit,
      width: 440,
      centered: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            decoration: _fieldDecoration(hint: 'Мой'),
            onSubmitted: (_) => _submit(),
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 10),
            _StatusBox(kind: 'error', text: error),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Отмена',
                  icon: Icons.close,
                  secondary: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'Сохранить',
                  icon: Icons.check,
                  onPressed: _submit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompatibilityNoticeAction {
  const _CompatibilityNoticeAction({required this.openDropoSpace});

  final bool openDropoSpace;
}

class _AndroidCompatibilityNoticeDialog extends StatefulWidget {
  const _AndroidCompatibilityNoticeDialog({
    required this.info,
    required this.onDecision,
  });

  final AndroidCompatibilityInfo info;
  final ValueChanged<_CompatibilityNoticeAction> onDecision;

  @override
  State<_AndroidCompatibilityNoticeDialog> createState() =>
      _AndroidCompatibilityNoticeDialogState();
}

class _AndroidCompatibilityNoticeDialogState
    extends State<_AndroidCompatibilityNoticeDialog>
    with SingleTickerProviderStateMixin {
  static const _displayDuration = Duration(seconds: 8);
  late final AnimationController _countdownController;
  bool _decisionSent = false;

  @override
  void initState() {
    super.initState();
    _countdownController =
        AnimationController(vsync: this, duration: _displayDuration)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _finish(openDropoSpace: false);
            }
          })
          ..forward();
  }

  @override
  void dispose() {
    _countdownController.dispose();
    super.dispose();
  }

  void _finish({required bool openDropoSpace}) {
    if (_decisionSent || !mounted) {
      return;
    }
    _decisionSent = true;
    _countdownController.stop();
    widget.onDecision(
      _CompatibilityNoticeAction(openDropoSpace: openDropoSpace),
    );
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.info.installedRiskApps
        .take(4)
        .map((app) => app.name)
        .join(', ');
    final extra = widget.info.installedRiskApps.length - 4;
    final appText = extra > 0 ? '$names и ещё $extra' : names;
    final canUseSpace = widget.info.canOfferDropoSpace;
    return _AppDialog(
      title: 'Совместимость приложений',
      icon: Icons.privacy_tip_outlined,
      width: 560,
      centered: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'На устройстве найдены приложения, которые могут видеть включённый системный VPN: $appText.',
            style: const TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
          ),
          const SizedBox(height: 12),
          _InfoBand(
            icon: canUseSpace ? Icons.work_outline : Icons.copy_all_outlined,
            title: canUseSpace
                ? 'Можно использовать Dropo Space'
                : 'Используйте клон приложения',
            body: canUseSpace
                ? 'Создайте отдельное пространство для прямого запуска выбранных приложений без VPN основного профиля.'
                : 'На этой версии Android Dropo Space недоступен. Создайте клон приложения штатными средствами телефона и запускайте клон.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Пропустить',
                  icon: Icons.close,
                  secondary: true,
                  onPressed: () => _finish(openDropoSpace: false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'В Dropo Space',
                  icon: Icons.work_outline,
                  onPressed: () => _finish(openDropoSpace: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AnimatedBuilder(
            animation: _countdownController,
            builder: (context, child) {
              final secondsLeft = math.max(
                0,
                ((_displayDuration.inMilliseconds *
                            (1 - _countdownController.value)) /
                        1000)
                    .ceil(),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: 1 - _countdownController.value,
                    minHeight: 3,
                    backgroundColor: const Color(0xFF24312E),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF52D6A4),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Окно закроется через $secondsLeft сек.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF91A8A1),
                      fontSize: 11,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AndroidCompatibilityPanel extends StatelessWidget {
  const _AndroidCompatibilityPanel({
    required this.info,
    required this.loading,
    required this.error,
    required this.saving,
    required this.onRefresh,
    required this.onCreateSpace,
    required this.onOpenSearch,
    required this.onMoveApp,
    required this.onShortcut,
  });

  final AndroidCompatibilityInfo? info;
  final bool loading;
  final bool saving;
  final String error;
  final VoidCallback onRefresh;
  final VoidCallback onCreateSpace;
  final VoidCallback onOpenSearch;
  final ValueChanged<AndroidRiskApp> onMoveApp;
  final ValueChanged<AndroidRiskApp> onShortcut;

  @override
  Widget build(BuildContext context) {
    final data = info;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.work_outline,
                size: 17,
                color: Color(0xFFBAF7D0),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Dropo Space',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 9),
          if (error.isNotEmpty)
            Text(
              'Статус не загрузился: $error',
              style: const TextStyle(
                color: Color(0xFFFCA5A5),
                fontSize: 11,
                height: 1.25,
              ),
            )
          else if (data == null)
            const Text(
              'Загружаем статус совместимости...',
              style: TextStyle(color: Color(0xFF8EA19D), fontSize: 11),
            )
          else ...[
            _DropoSpaceStatusBand(info: data),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _CompactActionChip(
                  icon: Icons.refresh,
                  label: 'Обновить',
                  onPressed: saving ? null : onRefresh,
                ),
                if (!data.dropoSpaceReady && data.dropoSpaceCanCreate)
                  _CompactActionChip(
                    icon: Icons.work_outline,
                    label: 'Создать Dropo Space',
                    onPressed: saving ? null : onCreateSpace,
                  ),
                _CompactActionChip(
                  icon: Icons.search,
                  label: 'Искать инструкцию',
                  onPressed: saving ? null : onOpenSearch,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Приложения',
              style: TextStyle(
                color: Color(0xFF9DB4AE),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 290),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: Column(
                    children: data.riskApps
                        .map(
                          (app) => _AndroidRiskAppRow(
                            app: app,
                            saving: saving,
                            dropoSpaceReady: data.dropoSpaceReady,
                            dropoSpacePaused: data.dropoSpacePaused,
                            dropoSpaceCanCreate: data.dropoSpaceCanCreate,
                            onMoveApp: onMoveApp,
                            onShortcut: onShortcut,
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const _InfoBand(
              icon: Icons.info_outline,
              title: 'Что делает этот раздел',
              body:
                  'Рабочие копии работают отдельно от VPN основного профиля. Добавляйте сюда только приложения, которым нужен прямой доступ без системного флага VPN.',
            ),
          ],
        ],
      ),
    );
  }
}

class _DropoSpaceStatusBand extends StatelessWidget {
  const _DropoSpaceStatusBand({required this.info});

  final AndroidCompatibilityInfo info;

  @override
  Widget build(BuildContext context) {
    final color = info.dropoSpacePaused
        ? const Color(0xFFFBBF24)
        : info.dropoSpaceReady
        ? const Color(0xFF36D399)
        : info.dropoSpaceCanCreate
        ? const Color(0xFFFBBF24)
        : const Color(0xFF93A3A0);
    final title = info.dropoSpacePaused
        ? 'Dropo Space приостановлен'
        : info.dropoSpaceReady
        ? 'Dropo Space создан'
        : info.dropoSpaceCanCreate
        ? 'Dropo Space доступен'
        : 'Dropo Space недоступен';
    final body = info.dropoSpacePaused
        ? 'Включите рабочий профиль в системной панели Android, затем нажмите «Обновить».'
        : info.dropoSpaceReady
        ? 'Можно добавлять отдельные копии приложений. Готово приложений: ${info.inDropoSpaceApps.length}.'
        : info.dropoSpaceCanCreate
        ? 'Устройство ${info.deviceLabel} поддерживает создание рабочего профиля. Нажмите «Создать Dropo Space».'
        : 'Используйте штатное клонирование приложений в настройках телефона. Для Android 15+ можно проверить Private Space.';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            info.dropoSpaceReady && !info.dropoSpacePaused
                ? Icons.verified_user_outlined
                : Icons.info_outline,
            size: 17,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(
                    color: Color(0xFFD8E4E0),
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AndroidRiskAppRow extends StatelessWidget {
  const _AndroidRiskAppRow({
    required this.app,
    required this.saving,
    required this.dropoSpaceReady,
    required this.dropoSpacePaused,
    required this.dropoSpaceCanCreate,
    required this.onMoveApp,
    required this.onShortcut,
  });

  final AndroidRiskApp app;
  final bool saving;
  final bool dropoSpaceReady;
  final bool dropoSpacePaused;
  final bool dropoSpaceCanCreate;
  final ValueChanged<AndroidRiskApp> onMoveApp;
  final ValueChanged<AndroidRiskApp> onShortcut;

  @override
  Widget build(BuildContext context) {
    final color = app.inDropoSpace
        ? const Color(0xFF36D399)
        : app.installed
        ? const Color(0xFFFBBF24)
        : const Color(0xFF71837F);
    final icon = app.inDropoSpace
        ? Icons.check_circle
        : app.installed
        ? Icons.phone_android
        : Icons.radio_button_unchecked;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: app.installed
            ? Colors.black.withValues(alpha: 0.18)
            : Colors.black.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: app.installed
                        ? const Color(0xFFF5FFFC)
                        : const Color(0xFF71837F),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  app.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (app.inDropoSpace)
            _IconMiniButton(
              icon: Icons.add_to_home_screen,
              tooltip: 'Создать ярлык dropo',
              onPressed: saving ? null : () => onShortcut(app),
            )
          else if (app.installed)
            _CompactActionChip(
              icon: dropoSpaceReady ? Icons.work_outline : Icons.start,
              label: dropoSpaceReady ? 'Добавить' : 'Настроить',
              onPressed:
                  saving ||
                      dropoSpacePaused ||
                      (!dropoSpaceReady && !dropoSpaceCanCreate)
                  ? null
                  : () => onMoveApp(app),
            ),
        ],
      ),
    );
  }
}

class _CompactActionChip extends StatelessWidget {
  const _CompactActionChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: _withClickCursor(
        OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: const Size(0, 34),
          foregroundColor: const Color(0xFFBAF7D0),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

class _IconMiniButton extends StatelessWidget {
  const _IconMiniButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 17),
        color: const Color(0xFFBAF7D0),
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

class _ShortcutComparison extends StatelessWidget {
  const _ShortcutComparison({required this.appName});

  final String appName;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ShortcutPreview(
            title: appName,
            subtitle: 'обычный ярлык',
            icon: Icons.apps,
            active: false,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ShortcutPreview(
            title: '$appName Dropo',
            subtitle: 'ярлык dropo',
            icon: Icons.shield_outlined,
            active: true,
          ),
        ),
      ],
    );
  }
}

class _ShortcutPreview extends StatelessWidget {
  const _ShortcutPreview({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.active,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF36D399) : const Color(0xFF8EA19D);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.24)),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(color: color, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _AndroidCompatibilityPage extends StatefulWidget {
  const _AndroidCompatibilityPage({super.key, required this.bridge});

  final CoreBridge bridge;

  @override
  State<_AndroidCompatibilityPage> createState() =>
      _AndroidCompatibilityPageState();
}

class _AndroidCompatibilityPageState extends State<_AndroidCompatibilityPage> {
  AndroidCompatibilityInfo? androidCompatibility;
  bool androidCompatibilityLoading = false;
  String androidCompatibilityError = '';
  String statusText = '';
  bool saving = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      unawaited(_loadAndroidCompatibility());
    }
  }

  Future<void> _loadAndroidCompatibility() async {
    setState(() {
      androidCompatibilityLoading = true;
      androidCompatibilityError = '';
    });
    try {
      final info = await widget.bridge.androidCompatibility();
      if (!mounted) {
        return;
      }
      setState(() {
        androidCompatibility = info;
        androidCompatibilityLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        androidCompatibilityLoading = false;
        androidCompatibilityError = _cleanError(error);
      });
    }
  }

  Future<void> _createDropoSpace() async {
    setState(() {
      saving = true;
      statusText = 'Открываем системный мастер Dropo Space...';
    });
    final Map<String, dynamic> result;
    try {
      result = await widget.bridge.createDropoSpace();
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = _cleanError(error);
      setState(() {
        saving = false;
        statusText = message;
      });
      await _showDropoSpaceFallbackNotice(
        title: 'Dropo Space не открылся',
        body:
            'Android не вернул ответ от системного мастера. Создайте клон приложения штатными средствами телефона или попробуйте открыть раздел ещё раз.',
        details: message,
      );
      return;
    }
    if (!mounted) {
      return;
    }
    final action = result['action']?.toString() ?? '';
    setState(() {
      saving = false;
      statusText = result['success'] == false
          ? result['error']?.toString() ?? 'Dropo Space недоступен'
          : result['message']?.toString() ?? 'Мастер Dropo Space открыт';
    });
    if (result['success'] == false ||
        action == 'unsupported' ||
        action == 'provisioning_failed') {
      await _showDropoSpaceFallbackNotice(
        title: 'Dropo Space недоступен',
        body:
            'Эта прошивка не дала dropo создать рабочий профиль. Используйте встроенное клонирование приложений в настройках телефона.',
        details:
            result['diagnostic']?.toString() ??
            result['error']?.toString() ??
            '',
      );
    } else if (action == 'provisioning_started') {
      await _showDropoSpaceProvisioningNotice();
    }
    unawaited(_loadAndroidCompatibility());
  }

  Future<void> _moveRiskAppToDropoSpace(AndroidRiskApp app) async {
    setState(() {
      saving = true;
      statusText = 'Готовим ${app.name} для Dropo Space...';
    });
    final Map<String, dynamic> result;
    try {
      result = await widget.bridge.moveAppToDropoSpace(app.packageName);
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = _cleanError(error);
      setState(() {
        saving = false;
        statusText = message;
      });
      await _showDropoSpaceFallbackNotice(
        title: 'Не удалось настроить ${app.name}',
        body:
            'Android не выполнил действие для Dropo Space. Создайте клон приложения штатными средствами телефона и запускайте клон при включённом VPN.',
        details: message,
      );
      return;
    }
    if (!mounted) {
      return;
    }
    final action = result['action']?.toString() ?? '';
    setState(() {
      saving = false;
      statusText = result['success'] == false
          ? result['error']?.toString() ?? 'Не удалось открыть Dropo Space'
          : result['message']?.toString() ??
                'Действие для ${app.name} выполнено';
    });
    if (result['success'] != false && action == 'already_in_space') {
      await _requestRiskAppShortcut(app);
    } else if (result['success'] != false && action == 'shortcut_requested') {
      await _showDropoSpaceShortcutNotice(app);
    } else if (result['success'] != false &&
        action == 'profile_install_requested') {
      final installedApp = await _waitForRiskAppInDropoSpace(app.packageName);
      if (!mounted) {
        return;
      }
      if (installedApp != null) {
        setState(() {
          statusText = '${app.name} добавлено в Dropo Space.';
        });
        await _requestRiskAppShortcut(installedApp);
      } else {
        await _offerManualDropoSpaceInstall(
          app,
          details:
              'Android не подтвердил появление приложения после автоматической установки.',
        );
      }
    } else if (result['success'] != false && action == 'open_market') {
      await _showDropoSpaceInstallNotice(app);
    } else if (result['success'] != false &&
        action == 'provisioning_started_for_app') {
      await _showDropoSpaceProvisioningNotice(app: app);
    } else if (action == 'profile_paused') {
      await _showDropoSpaceFallbackNotice(
        title: 'Dropo Space приостановлен',
        body:
            'Разверните системную панель Android, включите рабочий профиль кнопкой с портфелем, затем вернитесь в dropo и нажмите «Обновить».',
        details: result['error']?.toString() ?? '',
        offerSearch: false,
      );
    } else if (result['success'] != false &&
        action == 'manual_install_required') {
      await _offerManualDropoSpaceInstall(
        app,
        details: result['error']?.toString() ?? '',
      );
    } else if (result['success'] == false ||
        action == 'unsupported' ||
        action == 'not_installed' ||
        action == 'provisioning_failed') {
      await _showDropoSpaceFallbackNotice(
        title: 'Нужна ручная настройка',
        body:
            'dropo не смог автоматически открыть установку ${app.name} внутри Dropo Space. Создайте клон приложения штатными средствами телефона или установите копию вручную в рабочем профиле.',
        details:
            result['error']?.toString() ??
            result['diagnostic']?.toString() ??
            '',
      );
    }
    unawaited(_loadAndroidCompatibility());
  }

  Future<AndroidRiskApp?> _waitForRiskAppInDropoSpace(
    String packageName,
  ) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) {
        return null;
      }
      try {
        final info = await widget.bridge.androidCompatibility();
        if (!mounted) {
          return null;
        }
        setState(() {
          androidCompatibility = info;
          androidCompatibilityLoading = false;
          androidCompatibilityError = '';
        });
        for (final candidate in info.riskApps) {
          if (candidate.packageName == packageName && candidate.inDropoSpace) {
            return candidate;
          }
        }
      } catch (_) {
        // The managed-profile activity briefly pauses the parent app. Retry
        // until Android has published the package state through LauncherApps.
      }
    }
    return null;
  }

  Future<void> _offerManualDropoSpaceInstall(
    AndroidRiskApp app, {
    String details = '',
  }) async {
    final proceed = await _showDropoSpaceManualInstallPrompt(
      app,
      details: details,
    );
    if (!mounted) {
      return;
    }
    if (!proceed) {
      setState(() {
        statusText = 'Ручная установка ${app.name} отменена.';
      });
      return;
    }

    final market = await widget.bridge.openDropoSpaceMarket(app.packageName);
    if (!mounted) {
      return;
    }
    if (market['success'] != false &&
        market['action']?.toString() == 'open_market') {
      setState(() {
        statusText = 'Открыта ручная установка ${app.name} в рабочем профиле.';
      });
      return;
    }
    await _showDropoSpaceFallbackNotice(
      title: 'Не удалось открыть ручную установку',
      body:
          'Откройте вкладку «Рабочие» в списке приложений Android, запустите магазин с портфелем и установите ${app.name}. Затем вернитесь в dropo и нажмите «Обновить».',
      details: market['error']?.toString() ?? '',
      offerSearch: false,
    );
  }

  Future<bool> _showDropoSpaceManualInstallPrompt(
    AndroidRiskApp app, {
    String details = '',
  }) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => _AppDialog(
            title: 'Нужна ручная установка',
            icon: Icons.install_mobile_outlined,
            width: 560,
            centered: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Прошивка запретила dropo автоматически добавить ${app.name}. '
                  'Можно перейти к установке внутри рабочего профиля.',
                  style: const TextStyle(
                    color: Color(0xFFD8E4E0),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                const _InfoBand(
                  icon: Icons.work_outline,
                  title: 'Что нужно сделать',
                  body:
                      'Нажмите «Перейти к установке», выберите магазин со значком портфеля, установите приложение и вернитесь в dropo. После этого нажмите «Обновить».',
                ),
                if (details.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _InfoBand(
                    icon: Icons.info_outline,
                    title: 'Причина',
                    body: details.trim(),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        label: 'Отмена',
                        icon: Icons.close,
                        secondary: true,
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ActionButton(
                        label: 'Перейти к установке',
                        icon: Icons.open_in_new,
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<void> _requestRiskAppShortcut(AndroidRiskApp app) async {
    setState(() {
      saving = true;
      statusText = 'Создаём ярлык Dropo Space для ${app.name}...';
    });
    final Map<String, dynamic> result;
    try {
      result = await widget.bridge.requestDropoSpaceShortcut(app.packageName);
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = _cleanError(error);
      setState(() {
        saving = false;
        statusText = message;
      });
      await _showDropoSpaceFallbackNotice(
        title: 'Ярлык не создан',
        body:
            'Лаунчер не подтвердил создание ярлыка. Откройте копию приложения из списка приложений рабочего профиля или закрепите ярлык вручную.',
        details: message,
        offerSearch: false,
      );
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      saving = false;
      statusText = result['success'] == false
          ? result['error']?.toString() ?? 'Не удалось создать ярлык'
          : result['message']?.toString() ??
                'Android запросил закрепление ярлыка';
    });
    if (result['success'] != false) {
      await _showDropoSpaceShortcutNotice(app);
    } else {
      await _showDropoSpaceFallbackNotice(
        title: 'Ярлык не создан',
        body:
            'Лаунчер на этом устройстве не поддержал запрос dropo. Откройте копию приложения из рабочего профиля или закрепите ярлык вручную.',
        details: result['error']?.toString() ?? '',
        offerSearch: false,
      );
    }
  }

  Future<void> _openCloneHelpSearch() async {
    setState(() {
      saving = true;
      statusText = 'Открываем поиск инструкции...';
    });
    final Map<String, dynamic> result;
    try {
      result = await widget.bridge.openCloneHelpSearch();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        saving = false;
        statusText = _cleanError(error);
      });
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      saving = false;
      statusText = result['success'] == false
          ? result['error']?.toString() ?? 'Не удалось открыть поиск'
          : 'Открыт поиск инструкции для вашего устройства.';
    });
  }

  Future<void> _showDropoSpaceProvisioningNotice({AndroidRiskApp? app}) {
    final appText = app == null
        ? 'После завершения вернитесь в dropo и нажмите «Обновить».'
        : 'После завершения вернитесь в dropo и нажмите «Настроить» для ${app.name} ещё раз.';
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _AppDialog(
        title: 'Завершите мастер Android',
        icon: Icons.work_outline,
        width: 540,
        centered: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Android должен открыть системный мастер создания рабочего профиля. $appText',
              style: const TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
            ),
            const SizedBox(height: 12),
            const _InfoBand(
              icon: Icons.info_outline,
              title: 'Если мастер не появился',
              body:
                  'Значит прошивка или политика устройства не разрешает создать рабочий профиль из приложения. Используйте штатное клонирование приложений в настройках телефона.',
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    label: 'Искать инструкцию',
                    icon: Icons.search,
                    secondary: true,
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                      unawaited(_openCloneHelpSearch());
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionButton(
                    label: 'Понятно',
                    icon: Icons.check,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDropoSpaceFallbackNotice({
    required String title,
    required String body,
    String details = '',
    bool offerSearch = true,
  }) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _AppDialog(
        title: title,
        icon: Icons.info_outline,
        width: 540,
        centered: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              body,
              style: const TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
            ),
            if (details.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              _InfoBand(
                icon: Icons.bug_report_outlined,
                title: 'Диагностика',
                body: details.trim(),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                if (offerSearch) ...[
                  Expanded(
                    child: _ActionButton(
                      label: 'Искать инструкцию',
                      icon: Icons.search,
                      secondary: true,
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        unawaited(_openCloneHelpSearch());
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: _ActionButton(
                    label: 'Понятно',
                    icon: Icons.check,
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDropoSpaceInstallNotice(AndroidRiskApp app) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _AppDialog(
        title: 'Установка в Dropo Space',
        icon: Icons.work_outline,
        width: 520,
        centered: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Android открыл установку ${app.name} внутри Dropo Space. После установки вернитесь в dropo и нажмите «Обновить».',
              style: const TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
            ),
            const SizedBox(height: 12),
            const _InfoBand(
              icon: Icons.info_outline,
              title: 'Важно',
              body:
                  'Это будет отдельная копия приложения. Данные и вход в аккаунт не переносятся автоматически.',
            ),
            const SizedBox(height: 14),
            _ActionButton(
              label: 'Понятно',
              icon: Icons.check,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDropoSpaceShortcutNotice(AndroidRiskApp app) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _AppDialog(
        title: 'Две иконки приложения',
        icon: Icons.apps,
        width: 540,
        centered: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${app.name} теперь может быть доступен как обычное приложение и как копия/ярлык Dropo Space.',
              style: const TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
            ),
            const SizedBox(height: 12),
            _ShortcutComparison(appName: app.name),
            const SizedBox(height: 12),
            const _InfoBand(
              icon: Icons.touch_app_outlined,
              title: 'Чтобы не запутаться',
              body:
                  'Уберите старый ярлык с рабочего стола вручную и запускайте копию в Dropo Space или ярлык с иконкой dropo.',
            ),
            const SizedBox(height: 14),
            _ActionButton(
              label: 'Понятно',
              icon: Icons.check,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Platform.isAndroid;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Отдельное пространство для приложений, которые могут проверять системный VPN.',
          style: TextStyle(color: Color(0xFF8892B0), fontSize: 12),
        ),
        const SizedBox(height: 14),
        if (!isAndroid)
          const _InfoBand(
            icon: Icons.info_outline,
            title: 'Только Android',
            body:
                'Dropo Space доступен в Android-версии. На этой платформе раздел оставлен как справка.',
          )
        else ...[
          _AndroidCompatibilityPanel(
            info: androidCompatibility,
            loading: androidCompatibilityLoading,
            error: androidCompatibilityError,
            saving: saving,
            onRefresh: _loadAndroidCompatibility,
            onCreateSpace: _createDropoSpace,
            onOpenSearch: _openCloneHelpSearch,
            onMoveApp: _moveRiskAppToDropoSpace,
            onShortcut: _requestRiskAppShortcut,
          ),
          if (statusText.isNotEmpty) ...[
            const SizedBox(height: 6),
            _InfoBand(
              icon: saving ? Icons.hourglass_top : Icons.info_outline,
              title: saving ? 'Выполняется' : 'Статус',
              body: statusText,
            ),
          ],
        ],
      ],
    );
    return _MenuPageSurface(
      title: 'Dropo Space',
      icon: Icons.work_outline,
      child: content,
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    super.key,
    required this.bridge,
    required this.initialConfig,
    required this.currentStatus,
    required this.updateInfo,
    required this.onCheckUpdates,
    required this.onInstallUpdate,
    required this.onDownloadDependencies,
    required this.onOpenServices,
    this.embedded = false,
    this.advanced = false,
    this.onChanged,
  });

  final CoreBridge bridge;
  final AppConfig initialConfig;
  final CoreStatus currentStatus;
  final UpdateInfo? updateInfo;
  final VoidCallback onCheckUpdates;
  final VoidCallback onInstallUpdate;
  final VoidCallback onDownloadDependencies;
  final VoidCallback onOpenServices;
  final bool embedded;
  final bool advanced;
  final ValueChanged<AppConfig>? onChanged;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog>
    with WidgetsBindingObserver {
  late AppConfig config = widget.initialConfig;
  String statusText = '';
  bool saving = false;
  AndroidVpnProtection androidVpnProtection = AndroidVpnProtection.unknown();
  bool androidVpnProtectionLoading = false;
  String androidVpnProtectionError = '';
  bool androidVpnSettingsOpening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isAndroidPlatform && !widget.advanced) {
      unawaited(_loadAndroidVpnProtection());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _isAndroidPlatform &&
        !widget.advanced) {
      unawaited(_loadAndroidVpnProtection());
    }
  }

  Future<void> _loadAndroidVpnProtection() async {
    if (androidVpnProtectionLoading) {
      return;
    }
    setState(() {
      androidVpnProtectionLoading = true;
      androidVpnProtectionError = '';
    });
    try {
      final protection = await widget.bridge.androidVpnProtection();
      if (!mounted) {
        return;
      }
      setState(() {
        androidVpnProtection = protection;
        androidVpnProtectionLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        androidVpnProtectionLoading = false;
        androidVpnProtectionError = _cleanError(error);
        statusText =
            'Не удалось проверить защиту Android: $androidVpnProtectionError';
      });
    }
  }

  Future<void> _openAndroidVpnSettings() async {
    setState(() {
      androidVpnSettingsOpening = true;
      statusText = 'Открываем системные настройки VPN...';
    });
    final result = await _settingAction(widget.bridge.androidOpenVpnSettings);
    if (!mounted) {
      return;
    }
    setState(() {
      androidVpnSettingsOpening = false;
      statusText = result['success'] == false
          ? result['error']?.toString() ??
                'Не удалось открыть системные настройки VPN'
          : 'Включите для Dropo Always-on VPN и «Блокировать подключения без VPN».';
    });
  }

  Future<Map<String, dynamic>> _settingAction(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    try {
      return await action();
    } catch (error) {
      return {'success': false, 'error': _cleanError(error)};
    }
  }

  Future<void> _saveGeneral(AppConfig updated) async {
    final previous = config;
    setState(() {
      config = updated;
      saving = true;
      statusText = 'Сохраняем настройки...';
    });
    final result = await _settingAction(
      () => widget.bridge.saveAppConfig(updated),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      saving = false;
      if (result['success'] == false) {
        config = previous;
      }
      statusText = result['success'] == false
          ? result['error']?.toString() ?? 'Не удалось сохранить настройки'
          : 'Настройки применены';
    });
    if (result['success'] != false) {
      _dropoThemeMode.value = themeModeFromSetting(updated.theme);
      widget.onChanged?.call(updated);
    }
  }

  Future<void> _applySpecial(
    Future<Map<String, dynamic>> Function() action,
    AppConfig updated,
  ) async {
    setState(() {
      saving = true;
      statusText = 'Применяем настройки...';
    });
    final result = await _settingAction(action);
    if (!mounted) {
      return;
    }
    setState(() {
      saving = false;
      if (result['success'] == false) {
        statusText = result['error']?.toString() ?? 'Не удалось применить';
      } else {
        config = updated;
        statusText = result['message']?.toString() ?? 'Настройки применены';
      }
    });
    if (result['success'] != false) {
      widget.onChanged?.call(updated);
    }
  }

  Future<void> _runQuickCheck() async {
    setState(() {
      saving = true;
      statusText = 'Запускаем встроенную проверку сервисов...';
    });
    final result = await _settingAction(widget.bridge.runQuickCheck);
    if (!mounted) {
      return;
    }
    final total = _asInt(result['total']);
    final failed = _asInt(result['failedCount']);
    setState(() {
      saving = false;
      statusText = result['error'] != null
          ? _cleanError(result['error']!)
          : result['android'] == true
          ? result['success'] == true
                ? 'Проверка Android завершена: $total сервисов доступны.'
                : 'Проверка Android завершена с предупреждениями: ошибок $failed из $total.'
          : result['success'] == true
          ? 'Проверка завершена: $total сервисов доступны.'
          : 'Проверка завершена с предупреждениями: ошибок $failed из $total.';
    });
  }

  Future<void> _captureFingerprint() async {
    setState(() {
      saving = true;
      statusText = 'Снимаем отпечаток блокировок. VPN должен быть отключён...';
    });
    final result = await _settingAction(widget.bridge.captureFingerprint);
    if (!mounted) {
      return;
    }
    setState(() {
      saving = false;
      statusText = result['success'] == true
          ? 'Отпечаток сохранён: ${result['path'] ?? 'файл создан'}.'
          : result['error']?.toString() ?? 'Не удалось снять отпечаток.';
    });
  }

  Future<void> _openConfigFolder() async {
    await widget.bridge.openConfigFolder();
    if (mounted) {
      setState(() => statusText = 'Открыта папка конфигурации.');
    }
  }

  Future<void> _openFingerprintFolder() async {
    await widget.bridge.openFingerprintFolder();
    if (mounted) {
      setState(() => statusText = 'Открыта папка отпечатков.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = _isMobileShell;
    final vpnRunning =
        widget.currentStatus.connected || widget.currentStatus.connecting;
    final canUseLiveSafe = !saving;
    final canChangeRuntime = !saving && !vpnRunning;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (vpnRunning && widget.advanced) ...[
          _InfoBand(
            icon: Icons.lock_outline,
            title: 'VPN активен',
            body: isMobile
                ? 'Остановите Android VPN, чтобы изменить маршруты, режим сети или логирование.'
                : 'Режим сети и логирование требуют остановки VPN. Маршрут отдельного сервиса можно изменить: dropo безопасно переподключит VPN автоматически.',
          ),
          const SizedBox(height: 14),
        ],
        if (widget.advanced || !isMobile)
          _SettingsGroup(
            title: 'Общие',
            children: [
              if (!isMobile && !widget.advanced)
                _SwitchSetting(
                  title: 'Автозапуск',
                  description: 'Запускать при входе в систему',
                  value: config.autoStart,
                  onChanged: canUseLiveSafe
                      ? (value) =>
                            _saveGeneral(config.copyWith(autoStart: value))
                      : null,
                ),
              if (widget.advanced)
                _SwitchSetting(
                  title: 'Логирование sing-box',
                  description: 'Записывать логи в файл',
                  value: config.enableLogging,
                  onChanged: canChangeRuntime
                      ? (value) =>
                            _saveGeneral(config.copyWith(enableLogging: value))
                      : null,
                ),
              if (widget.advanced)
                _SelectSetting(
                  title: 'Уровень логирования',
                  description: 'Детализация логов sing-box',
                  value: config.logLevel,
                  options: const {
                    'error': 'Error',
                    'warn': 'Warn',
                    'info': 'Info',
                    'debug': 'Debug',
                    'trace': 'Trace',
                  },
                  onChanged: canChangeRuntime
                      ? (value) =>
                            _saveGeneral(config.copyWith(logLevel: value))
                      : null,
                ),
            ],
          ),
        if (!widget.advanced)
          _SettingsGroup(
            title: 'Подписка',
            children: [
              _SwitchSetting(
                title: 'Авто-обновление',
                description: 'Обновлять подписку автоматически',
                value: config.autoUpdateSub,
                onChanged: canUseLiveSafe
                    ? (value) =>
                          _saveGeneral(config.copyWith(autoUpdateSub: value))
                    : null,
              ),
            ],
          ),
        if (!widget.advanced && _isAndroidPlatform)
          _SettingsGroup(
            title: 'Защита соединения',
            children: [
              _AndroidVpnProtectionCard(
                protection: androidVpnProtection,
                loading: androidVpnProtectionLoading,
                error: androidVpnProtectionError,
                openingSettings: androidVpnSettingsOpening,
                onOpenSettings: () => unawaited(_openAndroidVpnSettings()),
              ),
            ],
          ),
        if (!widget.advanced)
          _SettingsGroup(
            title: 'Обновления',
            children: [
              _SwitchSetting(
                title: 'Автоматические обновления',
                description:
                    'Установленная Windows-версия скачивает проверенные стабильные релизы из GitHub и перезапускается автоматически',
                value: config.checkUpdates,
                onChanged: canUseLiveSafe
                    ? (value) =>
                          _saveGeneral(config.copyWith(checkUpdates: value))
                    : null,
              ),
              if (widget.updateInfo?.hasUpdate == true)
                _ButtonSetting(
                  title: 'Доступна версия ${widget.updateInfo!.latestVersion}',
                  description: widget.updateInfo!.selfUpdate
                      ? 'Скачать, проверить и перезапустить dropo'
                      : widget.updateInfo!.platform.toLowerCase() == 'windows'
                      ? 'Скачать portable-архив из GitHub Releases'
                      : 'Скачать APK из GitHub Releases',
                  label: widget.updateInfo!.selfUpdate
                      ? 'Обновить'
                      : widget.updateInfo!.platform.toLowerCase() == 'windows'
                      ? 'Скачать portable'
                      : 'Скачать APK',
                  icon: Icons.restart_alt,
                  onPressed: canUseLiveSafe ? widget.onInstallUpdate : null,
                ),
              _ButtonSetting(
                title: 'Проверить сейчас',
                description: 'Проверить стабильные релизы GitHub',
                label: 'Проверить',
                icon: Icons.system_update_alt,
                onPressed: canUseLiveSafe ? widget.onCheckUpdates : null,
              ),
            ],
          ),
        if (widget.advanced && !isMobile)
          _SettingsGroup(
            title: 'Компоненты',
            children: [
              _ButtonSetting(
                title: 'Встроенный runtime',
                description: widget.currentStatus.dependencies.ready
                    ? 'Компоненты из установленного пакета проверены и готовы'
                    : 'Нарушена целостность локальных компонентов',
                label: widget.currentStatus.dependencies.ready
                    ? 'Готово'
                    : 'Восстановить',
                icon: Icons.verified_user_outlined,
                onPressed:
                    canChangeRuntime && !widget.currentStatus.dependencies.ready
                    ? widget.onDownloadDependencies
                    : null,
              ),
            ],
          ),
        if (!widget.advanced)
          _SettingsGroup(
            title: 'Внешний вид',
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Atlas'),
                subtitle: Text(
                  'Компактное зелёное оформление. Размер текста и уменьшение движения задаются в настройках устройства.',
                ),
              ),
            ],
          ),
        if (widget.advanced)
          _SettingsGroup(
            title: 'Маршрутизация',
            children: [
              _SelectSetting(
                title: 'Режим маршрутизации',
                description: _routingModeDescription(config.routingMode),
                value: config.routingMode,
                stacked: true,
                options: const {
                  'blocked_only': 'Выбранные сервисы',
                  'all_traffic': 'Весь трафик',
                },
                onChanged: canChangeRuntime
                    ? (value) => _applySpecial(
                        () => widget.bridge.setRoutingMode(value),
                        config.copyWith(routingMode: value),
                      )
                    : null,
              ),
              _SwitchSetting(
                title: 'Скрывать RU-трафик от провайдера',
                description:
                    'Российские сайты по умолчанию идут напрямую. Включите, чтобы завернуть их в VPN/прокси.',
                value: config.hideRuTraffic,
                onChanged: canChangeRuntime
                    ? (value) => _applySpecial(
                        () => widget.bridge.setHideRuTraffic(
                          value,
                          config.ruProxyAddress,
                        ),
                        config.copyWith(hideRuTraffic: value),
                      )
                    : null,
              ),
              if (config.hideRuTraffic)
                _TextSetting(
                  title: 'Адрес прокси для RU-трафика',
                  description: 'Необязательно: vless://, trojan:// или ss://',
                  initialValue: config.ruProxyAddress,
                  onSubmitted: canChangeRuntime
                      ? (value) => _applySpecial(
                          () => widget.bridge.setHideRuTraffic(true, value),
                          config.copyWith(ruProxyAddress: value),
                        )
                      : null,
                ),
              if (isMobile)
                const _InfoBand(
                  icon: Icons.vpn_lock,
                  title: 'Android VPN',
                  body: 'Сетевой режим: Android VpnService + sing-box libbox.',
                )
              else
                const _InfoBand(
                  icon: Icons.hub,
                  title: 'Windows Unified',
                  body:
                      'В режиме «По сервисам» применяются выбранные маршруты; остальное идёт напрямую. В режиме «Всё через VPN» используется TUN. Встроенный движок обхода работает только для выбранных сервисов.',
                ),
            ],
          ),
        if (widget.advanced)
          _SettingsGroup(
            title: 'Сервисы',
            children: [
              _ButtonSetting(
                title: 'Сервисы и маршруты',
                description:
                    'Полный каталог, выбор маршрутов и быстрый список сервисов.',
                label: 'Открыть',
                icon: Icons.apps_outlined,
                onPressed: saving ? null : widget.onOpenServices,
              ),
            ],
          ),
        if (widget.advanced)
          _SettingsGroup(
            title: 'Диагностика',
            children: [
              _ButtonSetting(
                title: 'Проверить сервисы',
                description:
                    'Быстрая проверка доступности заблокированных и прямых сервисов.',
                label: 'Проверить',
                icon: Icons.search,
                onPressed: canUseLiveSafe
                    ? () => unawaited(_runQuickCheck())
                    : null,
              ),
              if (!isMobile) ...[
                _ButtonSetting(
                  title: 'Отпечаток блокировки',
                  description:
                      'Снимает RST/таймаут/IP/DNS-поведение провайдера. Запускайте при отключённом VPN.',
                  label: 'Снять',
                  icon: Icons.fingerprint,
                  onPressed: canUseLiveSafe
                      ? () => unawaited(_captureFingerprint())
                      : null,
                ),
                _ButtonSetting(
                  title: 'Папка отпечатков',
                  description: 'Открыть файлы DPI-отпечатков для отправки.',
                  label: 'Открыть',
                  icon: Icons.folder_special,
                  onPressed: () => unawaited(_openFingerprintFolder()),
                ),
              ],
            ],
          ),
        if (widget.advanced && !isMobile)
          _SettingsGroup(
            title: 'Конфигурация',
            children: [
              _ButtonSetting(
                title: 'Папка конфигурации',
                description: 'Открыть runtime-файлы, настройки и шаблоны.',
                label: 'Открыть',
                icon: Icons.folder_open,
                onPressed: () => unawaited(_openConfigFolder()),
              ),
            ],
          ),
        if (statusText.isNotEmpty) ...[
          const SizedBox(height: 6),
          _InfoBand(
            icon: saving ? Icons.hourglass_top : Icons.info_outline,
            title: saving ? 'Выполняется' : 'Статус',
            body: statusText,
          ),
        ],
        if (!widget.embedded) ...[
          const SizedBox(height: 12),
          _ActionButton(
            label: 'Закрыть',
            icon: Icons.close,
            onPressed: () => Navigator.of(context).pop(config),
          ),
        ],
      ],
    );
    if (widget.embedded) {
      return _MenuPageSurface(
        title: widget.advanced ? 'Сеть и диагностика' : 'Приложение',
        icon: Icons.settings,
        child: content,
      );
    }
    return _AppDialog(
      title: 'Настройки',
      icon: Icons.settings,
      width: 612,
      child: content,
    );
  }
}

class _RequestServiceDialog extends StatelessWidget {
  const _RequestServiceDialog({required this.bridge});

  static const requestServiceUrl =
      'https://github.com/sunnydjam/dropo-by-sunnydjam/issues/new';

  final CoreBridge bridge;

  @override
  Widget build(BuildContext context) {
    return _AppDialog(
      title: 'Добавить сервис',
      icon: Icons.add_link,
      centered: true,
      width: 520,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Если нужного сервиса нет в списке, создайте запрос в GitHub Issues и укажите домены и приложение, которые требуется добавить.',
            style: TextStyle(color: Color(0xFFD8E4E0), height: 1.35),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: const Row(
              children: [
                Icon(Icons.code, size: 18, color: Color(0xFF93C5FD)),
                SizedBox(width: 9),
                Expanded(
                  child: SelectableText(
                    'github.com/sunnydjam/dropo-by-sunnydjam/issues',
                    style: TextStyle(
                      color: Color(0xFFBBD7FF),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Открыть GitHub Issues',
                  icon: Icons.open_in_new,
                  onPressed: () async {
                    await bridge.openExternal(requestServiceUrl);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'Закрыть',
                  icon: Icons.close,
                  secondary: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ServiceRoutePolicyButton extends StatelessWidget {
  const _ServiceRoutePolicyButton({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
    this.comfortable = false,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;
  final bool comfortable;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? const Color(0xFFF1FFF8)
        : enabled
        ? const Color(0xFFD3E5DF)
        : const Color(0xFF82958F);
    final background = selected
        ? const Color(0xFF246448)
        : enabled
        ? const Color(0xFF172824)
        : const Color(0xFF111C1A);
    final border = selected
        ? const Color(0xFF5DE0A3)
        : enabled
        ? const Color(0xFF45645B)
        : const Color(0xFF2A3B36);
    return OutlinedButton(
      onPressed: enabled && !selected ? onPressed : null,
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, comfortable ? 44 : 30)),
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            horizontal: comfortable ? 12 : 9,
            vertical: comfortable ? 10 : 5,
          ),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: comfortable
            ? VisualDensity.standard
            : VisualDensity.compact,
        foregroundColor: WidgetStatePropertyAll(foreground),
        backgroundColor: WidgetStatePropertyAll(background),
        side: WidgetStatePropertyAll(BorderSide(color: border)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: comfortable ? 13 : 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: Color(0xFFA9BDB7),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _SettingShell extends StatelessWidget {
  const _SettingShell({
    required this.title,
    required this.description,
    required this.trailing,
    this.stacked = false,
  });

  final String title;
  final String description;
  final Widget trailing;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFFE8F3EF),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          description,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFFA3B5AF),
            fontSize: 10,
            height: 1.25,
          ),
        ),
      ],
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [label, const SizedBox(height: 8), trailing],
            )
          : Row(
              children: [
                Expanded(child: label),
                const SizedBox(width: 12),
                trailing,
              ],
            ),
    );
  }
}

class _SwitchSetting extends StatelessWidget {
  const _SwitchSetting({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingShell(
      title: title,
      description: description,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

class _SelectSetting extends StatelessWidget {
  const _SelectSetting({
    required this.title,
    required this.description,
    required this.value,
    required this.options,
    required this.onChanged,
    this.stacked = false,
  });

  final String title;
  final String description;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String>? onChanged;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final field = DropdownButtonFormField<String>(
      initialValue: options.containsKey(value) ? value : options.keys.first,
      isExpanded: true,
      isDense: true,
      dropdownColor: const Color(0xFF14211F),
      iconEnabledColor: const Color(0xFFCDE7DE),
      iconDisabledColor: const Color(0xFF82958F),
      style: TextStyle(
        color: onChanged == null
            ? const Color(0xFFA3B5AF)
            : const Color(0xFFE8F3EF),
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      decoration: _fieldDecoration(enabled: onChanged != null),
      items: [
        for (final entry in options.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged == null ? null : (value) => onChanged!(value!),
    );
    return _SettingShell(
      title: title,
      description: description,
      stacked: stacked,
      trailing: stacked ? field : SizedBox(width: 178, child: field),
    );
  }
}

class _TextSetting extends StatefulWidget {
  const _TextSetting({
    required this.title,
    required this.description,
    required this.initialValue,
    required this.onSubmitted,
  });

  final String title;
  final String description;
  final String initialValue;
  final ValueChanged<String>? onSubmitted;

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final controller = TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SettingShell(
      title: widget.title,
      description: widget.description,
      stacked: true,
      trailing: TextField(
        controller: controller,
        enabled: widget.onSubmitted != null,
        style: const TextStyle(color: Color(0xFFE8F3EF)),
        decoration: _fieldDecoration(
          hint: 'vless://...',
          enabled: widget.onSubmitted != null,
        ),
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}

class _ButtonSetting extends StatelessWidget {
  const _ButtonSetting({
    required this.title,
    required this.description,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String title;
  final String description;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return _SettingShell(
      title: title,
      description: description,
      trailing: _ActionButton(
        label: label,
        icon: icon,
        compact: true,
        onPressed: onPressed,
      ),
    );
  }
}

class _StatsDialog extends StatefulWidget {
  const _StatsDialog({
    super.key,
    required this.bridge,
    required this.initialStats,
    required this.status,
    required this.subscription,
    this.embedded = false,
  });

  final CoreBridge bridge;
  final TrafficStatsInfo initialStats;
  final CoreStatus status;
  final SubscriptionInfo subscription;
  final bool embedded;

  @override
  State<_StatsDialog> createState() => _StatsDialogState();
}

class _StatsDialogState extends State<_StatsDialog> {
  late TrafficStatsInfo stats = widget.initialStats;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final loaded = await widget.bridge.trafficStats();
      if (mounted) {
        setState(() => stats = loaded);
      }
    } catch (_) {}
  }

  Future<void> _reset() async {
    await widget.bridge.resetTrafficStats();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Статистика использования VPN',
          style: TextStyle(color: Color(0xFF8892B0), fontSize: 12),
        ),
        const SizedBox(height: 14),
        _ChartPlaceholder(
          title: 'Скорость (последние 30 сек)',
          upload: stats.current.uploaded,
          download: stats.current.downloaded,
        ),
        const SizedBox(height: 10),
        _ChartPlaceholder(
          title: 'Трафик за сессию',
          upload: stats.current.uploaded,
          download: stats.current.downloaded,
          compact: true,
        ),
        const SizedBox(height: 14),
        const _StatsSectionTitle('Текущая сессия'),
        _StatsGrid(
          children: [
            _StatCard(
              icon: Icons.arrow_upward,
              value: stats.current.uploadedStr,
              label: 'Отправлено',
              color: const Color(0xFF36D399),
            ),
            _StatCard(
              icon: Icons.arrow_downward,
              value: stats.current.downloadedStr,
              label: 'Получено',
              color: const Color(0xFF60A5FA),
            ),
            _StatCard(
              icon: Icons.timer,
              value: stats.current.durationStr,
              label: 'Длительность',
              color: const Color(0xFFF59E0B),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const _StatsSectionTitle('Всего'),
        _StatsGrid(
          children: [
            _StatCard(
              icon: Icons.arrow_upward,
              value: stats.total.uploadedStr,
              label: 'Отправлено',
              color: const Color(0xFF36D399),
            ),
            _StatCard(
              icon: Icons.arrow_downward,
              value: stats.total.downloadedStr,
              label: 'Получено',
              color: const Color(0xFF60A5FA),
            ),
            _StatCard(
              icon: Icons.timer,
              value: stats.total.durationStr,
              label: 'Время онлайн',
              color: const Color(0xFFF59E0B),
            ),
            _StatCard(
              icon: Icons.repeat,
              value: '${stats.sessions}',
              label: 'Сессий',
              color: const Color(0xFFA855F7),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _InfoBand(
          icon: widget.status.connected ? Icons.shield : Icons.shield_outlined,
          title: widget.status.connected ? 'VPN активен' : 'Отключено',
          body:
              '${widget.status.networkLabel} • ${widget.subscription.hasSubscription ? '${widget.subscription.proxyCount} proxy' : 'подписка не настроена'}',
        ),
        const SizedBox(height: 12),
        if (widget.embedded)
          _ActionButton(
            label: 'Сбросить',
            icon: Icons.restart_alt,
            danger: true,
            onPressed: _reset,
          )
        else
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Сбросить',
                  icon: Icons.restart_alt,
                  danger: true,
                  onPressed: _reset,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'Закрыть',
                  icon: Icons.close,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
      ],
    );
    if (widget.embedded) {
      return _MenuPageSurface(
        title: 'Статистика',
        icon: Icons.query_stats,
        child: content,
      );
    }
    return _AppDialog(
      title: 'Статистика',
      icon: Icons.query_stats,
      width: 520,
      child: content,
    );
  }
}

class _WireGuardDialog extends StatefulWidget {
  const _WireGuardDialog({
    required this.bridge,
    required this.initialConfigs,
    required this.vpnRunning,
  });

  final CoreBridge bridge;
  final List<WireGuardInfo> initialConfigs;
  final bool vpnRunning;

  @override
  State<_WireGuardDialog> createState() => _WireGuardDialogState();
}

class _WireGuardDialogState extends State<_WireGuardDialog> {
  late List<WireGuardInfo> configs = widget.initialConfigs;
  bool changed = false;

  Future<void> _reload() async {
    final loaded = await widget.bridge.wireGuards();
    if (mounted) {
      setState(() => configs = loaded);
    }
  }

  Future<void> _edit([WireGuardInfo? item]) async {
    WireGuardInfo? full = item;
    if (item != null) {
      full = await widget.bridge.wireGuardConfig(item.tag) ?? item;
    }
    if (!mounted) {
      return;
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _WireGuardEditDialog(
        bridge: widget.bridge,
        config: full,
        vpnRunning: widget.vpnRunning,
      ),
    );
    if (saved == true) {
      changed = true;
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AppDialog(
      title: 'Рабочие сети (WireGuard)',
      icon: Icons.hub,
      width: 580,
      centered: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Все конфиги активны одновременно. Трафик направляется по AllowedIPs.',
            style: TextStyle(color: Color(0xFF8892B0), fontSize: 12),
          ),
          const SizedBox(height: 14),
          if (configs.isEmpty)
            const _EmptyState(text: 'Нет добавленных рабочих сетей')
          else
            for (final item in configs)
              _WireGuardTile(
                item: item,
                onEdit: widget.vpnRunning ? null : () => _edit(item),
              ),
          if (widget.vpnRunning) ...[
            const SizedBox(height: 10),
            const _StatusBox(
              kind: 'warning',
              text: 'Редактирование WireGuard доступно после отключения VPN.',
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  label: 'Закрыть',
                  icon: Icons.close,
                  onPressed: () => Navigator.of(context).pop(changed),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  label: 'Добавить',
                  icon: Icons.add,
                  onPressed: widget.vpnRunning ? null : () => _edit(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WireGuardEditDialog extends StatefulWidget {
  const _WireGuardEditDialog({
    required this.bridge,
    required this.config,
    required this.vpnRunning,
  });

  final CoreBridge bridge;
  final WireGuardInfo? config;
  final bool vpnRunning;

  @override
  State<_WireGuardEditDialog> createState() => _WireGuardEditDialogState();
}

class _WireGuardEditDialogState extends State<_WireGuardEditDialog> {
  late final tagController = TextEditingController(
    text: widget.config?.tag ?? '',
  );
  late final nameController = TextEditingController(
    text: widget.config?.name ?? '',
  );
  late final configController = TextEditingController(
    text: widget.config?.config ?? '',
  );
  String statusText = '';
  String statusKind = '';
  bool busy = false;
  bool parsedOk = false;
  late bool camouflageEnabled = widget.config?.camouflageEnabled ?? false;

  bool get editing => widget.config != null;

  @override
  void dispose() {
    tagController.dispose();
    nameController.dispose();
    configController.dispose();
    super.dispose();
  }

  Future<void> _paste(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      controller.text = data!.text!;
    }
  }

  Future<void> _parseAndSave() async {
    if (configController.text.trim().isEmpty) {
      setState(() {
        statusKind = 'error';
        statusText = 'Вставьте WireGuard конфиг.';
      });
      return;
    }
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = 'Проверяем WireGuard конфиг...';
    });
    final result = await widget.bridge.parseWireGuard(configController.text);
    if (!mounted) {
      return;
    }
    setState(() {
      parsedOk = result['success'] == true;
      statusKind = parsedOk ? 'success' : 'error';
      statusText = parsedOk
          ? 'Конфиг корректен: ${result['endpoint'] ?? 'endpoint найден'}'
          : result['error']?.toString() ?? 'Конфиг не прошёл проверку';
    });
    if (!parsedOk) {
      setState(() => busy = false);
      return;
    }
    await _save();
  }

  Future<void> _save() async {
    setState(() {
      busy = true;
      statusKind = 'loading';
      statusText = 'Сохраняем WireGuard...';
    });
    final tag = tagController.text.trim();
    final name = nameController.text.trim();
    final configText = configController.text;
    final result = editing
        ? await widget.bridge.updateWireGuard(
            widget.config!.tag,
            tag,
            name,
            configText,
            camouflageEnabled,
          )
        : await widget.bridge.addWireGuard(
            tag,
            name,
            configText,
            camouflageEnabled,
          );
    if (!mounted) {
      return;
    }
    if (result['success'] == false) {
      setState(() {
        busy = false;
        statusKind = 'error';
        statusText = result['error']?.toString() ?? 'Не удалось сохранить';
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    if (!editing) {
      return;
    }
    final result = await widget.bridge.deleteWireGuard(widget.config!.tag);
    if (!mounted) {
      return;
    }
    if (result['success'] == false) {
      setState(() {
        statusKind = 'error';
        statusText = result['error']?.toString() ?? 'Не удалось удалить';
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return _AppDialog(
      title: editing ? 'Редактировать WireGuard' : 'Добавить WireGuard',
      icon: editing ? Icons.edit : Icons.add,
      width: 580,
      centered: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Вставьте стандартный WireGuard конфиг или заполните поля вручную.',
            style: TextStyle(color: Color(0xFF8892B0), fontSize: 12),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: 'Тег (латиница, без пробелов) *',
            controller: tagController,
            hint: 'dropo-internal',
            onPaste: () => _paste(tagController),
          ),
          const SizedBox(height: 10),
          _LabeledField(
            label: 'Название',
            controller: nameController,
            hint: 'dropo офис',
            onPaste: () => _paste(nameController),
          ),
          const SizedBox(height: 10),
          _LabeledField(
            label: 'WireGuard конфиг',
            controller: configController,
            hint:
                '[Interface]\nPrivateKey = ...\nAddress = ...\n\n[Peer]\nPublicKey = ...',
            minLines: 8,
            maxLines: 14,
            onPaste: () => _paste(configController),
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: camouflageEnabled,
              onChanged: busy
                  ? null
                  : (value) => setState(() => camouflageEnabled = value),
              title: const Text(
                'Маскировать WireGuard handshake',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text(
                'Экспериментально: только endpoint этого WireGuard. При проблеме функция автоматически отключится на текущую сессию.',
                style: TextStyle(color: Color(0xFF8892B0), fontSize: 10),
              ),
            ),
          ],
          if (statusText.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StatusBox(kind: statusKind, text: statusText),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _DialogAction(
                  label: 'Отмена',
                  icon: Icons.close,
                  onPressed: busy
                      ? null
                      : () => Navigator.of(context).pop(false),
                ),
              ),
              if (editing) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _DialogAction(
                    label: 'Удалить',
                    icon: Icons.delete,
                    danger: true,
                    onPressed: busy ? null : _delete,
                  ),
                ),
              ],
              const SizedBox(width: 10),
              Expanded(
                child: _DialogAction(
                  label: 'Проверить',
                  icon: Icons.fact_check,
                  primary: true,
                  onPressed: busy || widget.vpnRunning ? null : _parseAndSave,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DialogAction extends StatelessWidget {
  const _DialogAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: danger || primary
          ? _ActionButton(
              label: label,
              icon: icon,
              danger: danger,
              secondary: !primary && !danger,
              onPressed: onPressed,
            )
          : _ActionButton(
              label: label,
              icon: icon,
              secondary: true,
              onPressed: onPressed,
            ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.kind, required this.text});

  final String kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      'success' => const Color(0xFF86EFAC),
      'error' => const Color(0xFFFCA5A5),
      'warning' => const Color(0xFFFCD34D),
      'loading' => const Color(0xFFFCD34D),
      _ => const Color(0xFFB7CAC5),
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: SelectableText(
        text,
        style: TextStyle(color: color, fontSize: 12, height: 1.35),
      ),
    );
  }
}

class _StatsSectionTitle extends StatelessWidget {
  const _StatsSectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Color(0xFF4A5568),
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.62,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: children,
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Color(0xFF7F918C), fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _ChartPlaceholder extends StatelessWidget {
  const _ChartPlaceholder({
    required this.title,
    required this.upload,
    required this.download,
    this.compact = false,
  });

  final String title;
  final int upload;
  final int download;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final total = (upload + download).clamp(1, 1 << 62);
    final up = (upload / total).clamp(0.08, 1.0);
    final down = (download / total).clamp(0.08, 1.0);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF8EA2A0),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          _MeterLine(color: const Color(0xFF36D399), factor: up),
          SizedBox(height: compact ? 5 : 8),
          _MeterLine(color: const Color(0xFF60A5FA), factor: down),
        ],
      ),
    );
  }
}

class _MeterLine extends StatelessWidget {
  const _MeterLine({required this.color, required this.factor});

  final Color color;
  final double factor;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: factor,
      child: Container(
        height: 6,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _WireGuardTile extends StatelessWidget {
  const _WireGuardTile({required this.item, required this.onEdit});

  final WireGuardInfo item;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final networks = item.allowedIps.take(3).join(', ');
    return MouseRegion(
      cursor: onEdit == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onEdit,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.055),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              const Icon(Icons.hub, color: Color(0xFFBAF7D0), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name.isEmpty ? item.tag : item.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    if (item.camouflageEnabled)
                      const Text(
                        'Защита handshake',
                        style: TextStyle(
                          color: Color(0xFF86EFAC),
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      item.endpoint.isEmpty ? item.tag : item.endpoint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8EA2A0),
                        fontSize: 10,
                      ),
                    ),
                    if (networks.isNotEmpty)
                      Text(
                        networks,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF4A5568),
                          fontSize: 9,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onEdit,
                icon: const Icon(Icons.edit, size: 16),
                tooltip: 'Редактировать',
                mouseCursor: onEdit == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.onPaste,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final VoidCallback onPaste;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8892B0), fontSize: 11),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          minLines: minLines,
          maxLines: maxLines,
          decoration: _fieldDecoration(
            hint: hint,
            suffixIcon: IconButton(
              onPressed: onPaste,
              icon: const Icon(Icons.content_paste),
              tooltip: 'Вставить из буфера',
              mouseCursor: SystemMouseCursors.click,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(color: Color(0xFF4A5568), fontSize: 12),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 126,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF8EA2A0)),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(color: Color(0xFFE8F5F1)),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkFactRow extends StatelessWidget {
  const _LinkFactRow({
    required this.label,
    required this.value,
    required this.onPressed,
  });

  final String label;
  final String value;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 126,
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF8EA2A0)),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => unawaited(onPressed()),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: Text(value, overflow: TextOverflow.ellipsis),
                style: _withClickCursor(
                  TextButton.styleFrom(
                    foregroundColor: const Color(0xFFBAF7D0),
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontWeight: FontWeight.w400),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TelegramAssetShot extends StatelessWidget {
  const _TelegramAssetShot({required this.title, required this.asset});

  final String title;
  final String asset;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1112),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFBAF7D0),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(asset, fit: BoxFit.cover),
          ),
        ],
      ),
    );
  }
}

InputDecoration _fieldDecoration({
  String? hint,
  Widget? suffixIcon,
  bool enabled = true,
}) {
  return InputDecoration(
    hintText: hint,
    suffixIcon: suffixIcon,
    filled: true,
    hintStyle: const TextStyle(color: Color(0xFF82958F)),
    fillColor: enabled ? const Color(0xFF0D1715) : const Color(0xFF182321),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFF3A514B)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFF45615A)),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFF30423D)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFF36D399)),
    ),
  );
}

String _routingModeDescription(String mode) {
  return switch (mode) {
    'all_traffic' =>
      'Весь трафик через VPN. Максимальная приватность, высокая нагрузка.',
    _ =>
      'VPN и Zapret работают только для выбранных сервисов. Остальной трафик идёт напрямую.',
  };
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return const {};
}

List<String> _asStringList(Object? value) {
  if (value is List) {
    return value.map((item) => item.toString()).toList(growable: false);
  }
  if (value is String && value.trim().isNotEmpty) {
    return value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
  return const [];
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _cleanError(Object error) {
  final text = error.toString();
  return text
      .replaceFirst('HttpException: ', '')
      .replaceFirst('TimeoutException after ', 'Таймаут: ');
}

String _routePolicyFromJson(Map<String, dynamic> json) {
  final selected =
      json['selectedMethod']?.toString().trim().toLowerCase() ?? '';
  if (selected == 'auto' ||
      selected == 'direct' ||
      selected == 'vpn' ||
      selected == 'zapret') {
    return selected;
  }
  if (json['requiresVpn'] == true) {
    return 'vpn';
  }
  final effective = [
    json['effectiveMethod'],
    json['method'],
    json['outbound'],
    json['effectiveMethodLabel'],
    json['methodLabel'],
  ].whereType<Object>().map((value) => value.toString().toLowerCase());
  return effective.any(
        (value) =>
            value == 'vpn' || value.contains('vpn') || value == 'auto-select',
      )
      ? 'vpn'
      : 'direct';
}

const List<RouteService> fallbackRoutes = [
  RouteService(
    tag: 'openai',
    name: 'ChatGPT',
    method: 'Через VPN',
    selectedMethod: 'vpn',
    requiresVpn: true,
    delayMs: 0,
    domainSuffixes: ['openai.com', 'chatgpt.com'],
  ),
  RouteService(
    tag: 'youtube',
    name: 'YouTube',
    method: 'Через VPN',
    selectedMethod: 'vpn',
    requiresVpn: true,
    delayMs: 0,
    domainSuffixes: ['youtube.com', 'youtu.be', 'googlevideo.com'],
  ),
  RouteService(
    tag: 'discord',
    name: 'Discord',
    method: 'Через VPN',
    selectedMethod: 'vpn',
    requiresVpn: true,
    delayMs: 0,
    domainSuffixes: ['discord.com', 'discord.gg', 'discordapp.net'],
  ),
  RouteService(
    tag: 'meta',
    name: 'Instagram',
    method: 'Через VPN',
    selectedMethod: 'vpn',
    requiresVpn: true,
    delayMs: 0,
    domainSuffixes: ['instagram.com', 'cdninstagram.com', 'threads.net'],
  ),
  RouteService(
    tag: 'google',
    name: 'Google Search',
    method: 'Напрямую',
    selectedMethod: 'direct',
    requiresVpn: false,
    delayMs: 0,
    domainSuffixes: ['google.com', 'google.ru', 'gstatic.com'],
  ),
  RouteService(
    tag: 'gosuslugi',
    name: 'Gosuslugi and RU services',
    method: 'Напрямую',
    selectedMethod: 'direct',
    requiresVpn: false,
    delayMs: 0,
    domainSuffixes: ['gosuslugi.ru', 'mos.ru', 'nalog.ru'],
  ),
];
