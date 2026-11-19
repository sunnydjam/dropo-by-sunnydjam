part of 'main.dart';

/// A page-load event does not mean its scripts or renderer became usable.
/// Give the scene a bounded foreground startup window, then use native controls.
@visibleForTesting
class AndroidSceneLoadGuard {
  AndroidSceneLoadGuard({
    required this.onFailure,
    this.timeout = const Duration(seconds: 8),
  }) {
    _arm();
  }

  final VoidCallback onFailure;
  final Duration timeout;
  Timer? _timer;
  bool _finished = false, _active = true;

  void _arm() {
    if (_finished || !_active) return;
    _timer = Timer(timeout, fail);
  }

  void setActive(bool active) {
    if (_finished || _active == active) return;
    _active = active;
    _timer?.cancel();
    // Background WebViews may stop loading entirely. Allow a fresh bounded
    // interval on resume, rather than failing while the app is invisible.
    _arm();
  }

  void ready() {
    _finished = true;
    _timer?.cancel();
  }

  void fail() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    onFailure();
  }

  void dispose() => ready();
}

@visibleForTesting
bool isAndroidSceneCriticalResource(String? url) {
  final path = Uri.tryParse(url ?? '')?.path ?? '';
  return const [
    '/assets/android_home/index.html',
    '/assets/android_home/bootstrap.js',
    '/assets/android_home/art.js',
    '/assets/android_home/scene.js',
    '/assets/android_home/scene.css',
    '/assets/android_home/vendor/three-0.160.1.min.js',
  ].any(path.endsWith);
}

/// A closed command vocabulary for the bundled scene. It never receives tokens,
/// subscription URLs, arbitrary native calls or permission to navigate online.
@visibleForTesting
({String action, String? value})? parseAndroidSceneAction(String message) {
  if (message.length > 256) return null;
  try {
    final data = jsonDecode(message);
    if (data is! Map<String, dynamic>) return null;
    final action = data['action'];
    if (action is! String) return null;
    if (action == 'mode') {
      final value = data['value'];
      if (value != 'blocked_only' && value != 'all_traffic') return null;
      return (action: action, value: value as String);
    }
    if (action == 'ready') {
      final revision = data['value'];
      if (revision is! String ||
          !RegExp(r'^[1-9][0-9]{0,7}$').hasMatch(revision)) {
        return null;
      }
      return (action: action, value: revision);
    }
    if (!const {
      'failed',
      'connect',
      'disconnect',
      'cancel',
      'sources',
      'services',
      'help',
    }.contains(action)) {
      return null;
    }
    return (action: action, value: null);
  } catch (_) {
    return null;
  }
}

class _AndroidAnimatedHome extends StatefulWidget {
  const _AndroidAnimatedHome({
    required this.connected,
    required this.connectedAt,
    required this.responseMs,
    required this.connecting,
    required this.disconnecting,
    required this.busy,
    required this.enabled,
    required this.canCancel,
    required this.motionEnabled,
    required this.visible,
    required this.routingMode,
    required this.source,
    required this.message,
    required this.error,
    required this.onConnectionRequested,
    required this.onCancel,
    required this.onMode,
    required this.onSources,
    required this.onServices,
    required this.onHelp,
    required this.fallback,
    required this.onPresented,
  });

  final bool connected, connecting, disconnecting, busy, enabled, canCancel;
  final DateTime? connectedAt;
  final int? responseMs;
  final bool motionEnabled, visible, error;
  final String routingMode, source, message;
  final ValueChanged<bool> onConnectionRequested;
  final VoidCallback onCancel, onSources, onServices, onHelp;
  final ValueChanged<String> onMode;
  final Widget fallback;
  final VoidCallback onPresented;

  @override
  State<_AndroidAnimatedHome> createState() => _AndroidAnimatedHomeState();
}

class _AndroidAnimatedHomeState extends State<_AndroidAnimatedHome>
    with WidgetsBindingObserver {
  static const _asset = 'assets/android_home/index.html';
  static const _url = 'file:///android_asset/flutter_assets/$_asset';
  static const _visualState = MethodChannel('dropo/android-scene');
  WebViewController? _controller;
  late final AndroidSceneLoadGuard _loadGuard;
  MethodChannel? _rendererEvents;
  bool _loaded = false, _failed = false, _foreground = true;
  String? _lastPayload;
  String? _candidate;
  Timer? _retryPresentation;
  bool _presented = false, _checking = false, _active = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _loadGuard = AndroidSceneLoadGuard(onFailure: _fail);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController();
      _controller = controller;
      await controller.setBackgroundColor(const Color(0xff030908));
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.enableZoom(false);
      await controller.addJavaScriptChannel(
        'DropoScene',
        onMessageReceived: (message) => _onMessage(message.message),
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) => request.url == _url
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) {
            if (!mounted) return;
            _loaded = true;
            _lastPayload = null;
            _synchronize();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true ||
                isAndroidSceneCriticalResource(error.url)) {
              _fail();
            }
          },
        ),
      );
      if (!mounted || _failed) return;
      final platform = controller.platform as AndroidWebViewController;
      final id = platform.webViewIdentifier;
      _rendererEvents = MethodChannel('dropo/android-scene/$id')
        ..setMethodCallHandler((call) async {
          if (call.method == 'rendererGone') _fail();
        });
      await _visualState.invokeMethod<void>('observeRenderer', id);
      if (!mounted || _failed) return;
      await controller.loadFlutterAsset(_asset);
      if (mounted) setState(() {});
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    _loadGuard.dispose();
    _retryPresentation?.cancel();
    if (!mounted || _failed) return;
    setState(() {
      _failed = true;
      _controller = null;
    });
    scheduleMicrotask(() {
      if (mounted) widget.onPresented();
    });
  }

  Future<void> _presentWhenDrawn() async {
    final candidate = _candidate;
    final controller = _controller;
    if (!_active ||
        _checking ||
        _presented ||
        _failed ||
        candidate == null ||
        controller == null) {
      return;
    }
    _retryPresentation?.cancel();
    _checking = true;
    try {
      final platform = controller.platform as AndroidWebViewController;
      final frameSize = await _visualState.invokeListMethod<int>(
        'awaitFrame',
        platform.webViewIdentifier,
      );
      if (!mounted ||
          !_active ||
          _failed ||
          frameSize == null ||
          frameSize.length != 2 ||
          _candidate != candidate) {
        return;
      }
      final revealed = await controller.runJavaScriptReturningResult(
        'window.DropoHome.reveal(${jsonEncode(candidate)},${frameSize[0]},${frameSize[1]})',
      );
      if (!mounted || _failed || revealed != true) return;
      _presented = true;
      _loadGuard.ready();
      widget.onPresented();
    } catch (_) {
      _fail();
    } finally {
      _checking = false;
      if (mounted && _active && !_presented && !_failed) {
        _retryPresentation = Timer(
          const Duration(milliseconds: 60),
          () => unawaited(_presentWhenDrawn()),
        );
      }
    }
  }

  void _onMessage(String message) {
    if (!mounted || _failed) return;
    final command = parseAndroidSceneAction(message);
    if (command == null) return;
    if (!_presented &&
        command.action != 'ready' &&
        command.action != 'failed') {
      return;
    }
    // Recheck native state at dispatch time; stale JavaScript cannot start or
    // change a session while another operation owns the core.
    switch (command.action) {
      case 'ready':
        _candidate = command.value;
        unawaited(_presentWhenDrawn());
      case 'failed':
        _fail();
      case 'connect':
        if (widget.enabled && !widget.connected) {
          widget.onConnectionRequested(true);
        }
      case 'disconnect':
        if (widget.enabled && widget.connected) {
          widget.onConnectionRequested(false);
        }
      case 'cancel':
        if (widget.canCancel) widget.onCancel();
      case 'mode':
        if (widget.enabled && !widget.connecting && !widget.disconnecting) {
          widget.onMode(command.value!);
        }
      case 'sources':
        if (widget.enabled) widget.onSources();
      case 'services':
        if (widget.enabled && !widget.connecting && !widget.disconnecting) {
          widget.onServices();
        }
      case 'help':
        widget.onHelp();
    }
  }

  void _synchronize() {
    if (_failed || !mounted) return;
    final active =
        _foreground && widget.visible && TickerMode.valuesOf(context).enabled;
    _active = active;
    _loadGuard.setActive(active);
    final controller = _controller;
    if (!_loaded || controller == null) return;
    unawaited(_presentWhenDrawn());
    final payload = !active
        ? '{"active":false}'
        : jsonEncode({
            'connected': widget.connected,
            'connectedAt': widget.connectedAt?.millisecondsSinceEpoch,
            'connecting': widget.connecting,
            'disconnecting': widget.disconnecting,
            'busy': widget.busy,
            'enabled': widget.enabled,
            'canCancel': widget.canCancel,
            'motion':
                widget.motionEnabled &&
                !MediaQuery.disableAnimationsOf(context),
            'active': active,
            'mode': widget.routingMode,
            'language': _english(context) ? 'en' : 'ru',
            'source': widget.source,
            'responseMs': widget.responseMs,
            'message': widget.message,
            'error': widget.error,
          });
    if (_lastPayload == payload) return;
    _lastPayload = payload;
    unawaited(
      controller
          .runJavaScript('window.DropoHome?.update($payload);')
          .catchError((Object _) {
            _fail();
          }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _synchronize();
  }

  @override
  void didUpdateWidget(_AndroidAnimatedHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronize();
  }

  @override
  void dispose() {
    _loadGuard.dispose();
    _retryPresentation?.cancel();
    _rendererEvents?.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    // Android destroys the platform view with its widget. Stop its animation
    // immediately as well, including navigation away to the account page.
    final controller = _controller;
    if (_loaded && controller != null) {
      unawaited(
        controller
            .runJavaScript('window.DropoHome?.update({active:false});')
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    WidgetsBinding.instance.addPostFrameCallback((_) => _synchronize());
    return WebViewWidget(
      key: const ValueKey('android-animated-home'),
      controller: controller,
    );
  }
}

// Keep the native platform view at a stable position in the widget tree.
// Only Flutter pages cross-fade. A parked scene keeps its controller and pauses
// drawing while the foreground page owns focus and pointer input.
class _AndroidHomeSections extends StatelessWidget {
  const _AndroidHomeSections({
    required this.section,
    required this.motionEnabled,
    required this.home,
    required this.page,
  });

  final String section;
  final bool motionEnabled;
  final Widget home;
  final Widget? page;

  @override
  Widget build(BuildContext context) {
    final showHome = page == null;
    final animate = motionEnabled && !MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: !showHome,
          child: ExcludeFocus(
            excluding: !showHome,
            child: ExcludeSemantics(excluding: !showHome, child: home),
          ),
        ),
        AnimatedSwitcher(
          duration: animate ? const Duration(milliseconds: 190) : Duration.zero,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [
              for (final child in previous)
                IgnorePointer(
                  child: ExcludeFocus(child: ExcludeSemantics(child: child)),
                ),
              ?current,
            ],
          ),
          child: showHome
              ? null
              : ColoredBox(
                  key: ValueKey(section),
                  color: _atlasBackground,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _AtlasSpaceBackground(motionEnabled: motionEnabled),
                      Padding(padding: const EdgeInsets.all(12), child: page),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
