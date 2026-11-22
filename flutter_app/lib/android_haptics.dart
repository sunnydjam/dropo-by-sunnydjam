part of 'main.dart';

const _hapticPreferences = MethodChannel('dropo/core');
final _hapticsEnabled = ValueNotifier(true);
int _hapticsRevision = 0;

Future<void> _restoreAndroidHaptics() async {
  final revision = _hapticsRevision;
  try {
    final enabled = await _hapticPreferences.invokeMethod<bool>(
      'getHapticsEnabled',
    );
    if (enabled != null && revision == _hapticsRevision) {
      _hapticsEnabled.value = enabled;
    }
  } on PlatformException {
    // Keep the current setting if local preferences cannot be read.
  } on MissingPluginException {
    // Platform preferences are unavailable in host tests.
  }
}

Future<void> _setAndroidHaptics(bool enabled) async {
  final revision = ++_hapticsRevision;
  if (Platform.isAndroid) {
    await _hapticPreferences.invokeMethod<void>('setHapticsEnabled', enabled);
  }
  if (revision == _hapticsRevision) _hapticsEnabled.value = enabled;
}

void _androidHaptic({bool impact = false}) {
  if (!_isAndroidPlatform || !_hapticsEnabled.value) return;
  final feedback = impact
      ? HapticFeedback.mediumImpact()
      : HapticFeedback.selectionClick();
  unawaited(feedback.catchError((Object _) {}));
}
