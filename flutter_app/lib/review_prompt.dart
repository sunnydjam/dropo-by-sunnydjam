part of 'main.dart';

/// Native counters include sessions while Flutter is paused. Only presentation
/// belongs to the UI; no timer, health probe or review SDK touches the VPN path.
class AndroidReviewPromptCoordinator {
  AndroidReviewPromptCoordinator({
    required this.readStatus,
    required this.claim,
    required this.cancelUnpresented,
    required this.confirmPresentation,
    required this.canPresent,
    required this.present,
  });

  final Future<Map<String, dynamic>> Function() readStatus;
  final Future<Map<String, dynamic>> Function() claim;
  final Future<void> Function(String) cancelUnpresented;
  final Future<void> Function(String) confirmPresentation;
  final bool Function() canPresent;
  final Future<void> Function() present;
  bool _busy = false;
  bool _finished = false;

  Future<void> check() async {
    if (_busy || _finished || !canPresent()) return;
    _busy = true;
    try {
      final state = await readStatus();
      if (state['shown'] == true) {
        _finished = true;
        return;
      }
      if (state['eligible'] != true || !canPresent()) return;
      final reservation = await claim();
      final id = reservation['claimId'];
      if (reservation['claimed'] != true || id is! String || id.isEmpty) return;
      if (!canPresent()) {
        // A terminal service event can arrive before Flutter finishes its own
        // disconnect UI. This reservation has never opened a route and is safe
        // to release; a confirmed presentation cannot be released natively.
        await cancelUnpresented(id);
        return;
      }
      // showDialog pushes its route synchronously before returning its Future.
      // Do not insert an await/lifecycle gap between the guard and presentation.
      final presentation = present();
      _finished = true;
      unawaited(confirmPresentation(id).catchError((_) {}));
      await presentation;
    } catch (_) {
      // Storage, lifecycle and Play Store errors must never affect VPN use.
    } finally {
      _busy = false;
    }
  }
}

@visibleForTesting
Future<void> showAndroidReviewPrompt(
  BuildContext context, {
  required Future<void> Function(String) openExternal,
}) async {
  final review = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.rate_review_outlined),
      title: const Text('Оставить отзыв о Dropo?'),
      content: const Text(
        'Поделитесь впечатлениями в Google Play. '
        'Ваш отзыв поможет нам улучшить приложение.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Не сейчас'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Оставить отзыв'),
        ),
      ],
    ),
  );
  if (review != true || !context.mounted) return;
  try {
    await openExternal(_playStoreUrl);
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Не удалось открыть Google Play.')),
    );
  }
}
