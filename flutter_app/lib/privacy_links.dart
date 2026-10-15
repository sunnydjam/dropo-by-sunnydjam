part of 'main.dart';

const String dropoPrivacyPolicyUrl = 'https://dropo.fun/privacy';
const String dropoAccountDeletionUrl = 'https://dropo.fun/account/delete';

// Public policy/deletion pages must remain reachable without a local account.
// Do not attach a bearer token, profile or subscription URL to these links.
class _PrivacyActions extends StatelessWidget {
  const _PrivacyActions({required this.onOpenExternal});

  final Future<void> Function(String) onOpenExternal;

  Future<void> _open(BuildContext context, String url) async {
    try {
      await onOpenExternal(url).timeout(const Duration(seconds: 6));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось открыть страницу. Проверьте интернет и повторите попытку.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      TextButton.icon(
        key: const ValueKey('account-privacy-policy'),
        onPressed: () => unawaited(_open(context, dropoPrivacyPolicyUrl)),
        icon: const Icon(Icons.privacy_tip_outlined, size: 18),
        label: const Text('Политика конфиденциальности'),
      ),
      TextButton.icon(
        key: const ValueKey('account-deletion-page'),
        onPressed: () => unawaited(_open(context, dropoAccountDeletionUrl)),
        icon: const Icon(Icons.manage_accounts_outlined, size: 18),
        label: const Text('Удаление аккаунта через сайт'),
      ),
    ],
  );
}
