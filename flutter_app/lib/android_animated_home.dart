part of 'main.dart';

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
    if (!const {
      'ready',
      'failed',
      'toggle',
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
    required this.onToggle,
    required this.onCancel,
    required this.onMode,
    required this.onSources,
    required this.onServices,
    required this.onHelp,
    required this.fallback,
  });

  final bool connected, connecting, disconnecting, busy, enabled, canCancel;
  final DateTime? connectedAt;
  final bool motionEnabled, visible, error;
  final String routingMode, source, message;
  final VoidCallback onToggle, onCancel, onSources, onServices, onHelp;
  final ValueChanged<String> onMode;
  final Widget fallback;

  @override
  State<_AndroidAnimatedHome> createState() => _AndroidAnimatedHomeState();
}

class _AndroidAnimatedHomeState extends State<_AndroidAnimatedHome>
    with WidgetsBindingObserver {
  static const _asset = 'assets/android_home/index.html';
  static const _url = 'file:///android_asset/flutter_assets/$_asset';
  late final WebViewController _controller;
  bool _loaded = false, _failed = false, _foreground = true;
  String? _lastPayload;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _controller = WebViewController();
      await _controller.setBackgroundColor(const Color(0xff030908));
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.enableZoom(false);
      await _controller.addJavaScriptChannel(
        'DropoScene',
        onMessageReceived: (message) => _onMessage(message.message),
      );
      await _controller.setNavigationDelegate(
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
            if (error.isForMainFrame == true) _fail();
          },
        ),
      );
      if (!mounted) return;
      await _controller.loadFlutterAsset(_asset);
      if (mounted) setState(() {});
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (mounted && !_failed) setState(() => _failed = true);
  }

  void _onMessage(String message) {
    if (!mounted || _failed) return;
    final command = parseAndroidSceneAction(message);
    if (command == null) return;
    // Recheck native state at dispatch time; stale JavaScript cannot start or
    // change a session while another operation owns the core.
    switch (command.action) {
      case 'ready':
        _loaded = true;
        _lastPayload = null;
        _synchronize();
      case 'failed':
        _fail();
      case 'toggle':
        if (widget.enabled) widget.onToggle();
      case 'cancel':
        if (widget.canCancel) widget.onCancel();
      case 'mode':
        if (widget.enabled && widget.connected) widget.onMode(command.value!);
      case 'sources':
        if (widget.enabled) widget.onSources();
      case 'services':
        if (widget.enabled && widget.connected) widget.onServices();
      case 'help':
        widget.onHelp();
    }
  }

  void _synchronize() {
    if (!_loaded || _failed || !mounted) return;
    final payload = jsonEncode({
      'connected': widget.connected,
      'connectedAt': widget.connectedAt?.millisecondsSinceEpoch,
      'connecting': widget.connecting,
      'disconnecting': widget.disconnecting,
      'busy': widget.busy,
      'enabled': widget.enabled,
      'canCancel': widget.canCancel,
      'motion': widget.motionEnabled,
      'active':
          _foreground && widget.visible && TickerMode.valuesOf(context).enabled,
      'mode': widget.routingMode,
      'source': widget.source,
      'message': widget.message,
      'error': widget.error,
    });
    if (_lastPayload == payload) return;
    _lastPayload = payload;
    unawaited(
      _controller
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
    WidgetsBinding.instance.removeObserver(this);
    // Android destroys the platform view with its widget. Stop its animation
    // immediately as well, including navigation away to the account page.
    if (_loaded && !_failed) {
      unawaited(
        _controller
            .runJavaScript('window.DropoHome?.update({active:false});')
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    WidgetsBinding.instance.addPostFrameCallback((_) => _synchronize());
    return WebViewWidget(
      key: const ValueKey('android-animated-home'),
      controller: _controller,
    );
  }
}
