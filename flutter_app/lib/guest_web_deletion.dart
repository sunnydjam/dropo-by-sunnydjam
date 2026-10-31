part of 'main.dart';

/// A code is revealed and copied only by explicit actions in this guest dialog.
/// The website receives it through its form, never via a link or browser history.
class GuestWebDeletionDialog extends StatefulWidget {
  const GuestWebDeletionDialog({
    super.key,
    required this.identity,
    required this.onOpenExternal,
  });

  final GuestIdentityCoordinator identity;
  final Future<void> Function(String url) onOpenExternal;

  @override
  State<GuestWebDeletionDialog> createState() => _GuestWebDeletionDialogState();
}

class _GuestWebDeletionDialogState extends State<GuestWebDeletionDialog> {
  late final int _epoch = widget.identity.identityEpoch;
  late final String? _installation = widget.identity.installationId;
  String? _code;
  String _message = '';
  bool _busy = false, _identityChanged = false;

  bool get _current =>
      mounted &&
      !_identityChanged &&
      widget.identity.identityEpoch == _epoch &&
      widget.identity.installationId == _installation &&
      widget.identity.accountKind == 'guest' &&
      widget.identity.account?['demoAccount'] != true &&
      !widget.identity.suppressed;

  @override
  void initState() {
    super.initState();
    widget.identity.addListener(_onIdentityChanged);
  }

  @override
  void dispose() {
    widget.identity.removeListener(_onIdentityChanged);
    _code = null;
    super.dispose();
  }

  void _onIdentityChanged() {
    if (!mounted || _current) return;
    setState(() {
      _code = null;
      _identityChanged = true;
      _busy = false;
      _message = 'Профиль изменился. Закройте это окно.';
    });
  }

  Future<void> _reveal() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final code = await widget.identity.guestWebDeletionCode();
      if (!_current) return;
      setState(() => _code = code);
    } on AccountIdentityChanged {
      _onIdentityChanged();
    } on AccountApiException catch (error) {
      if (!_current) return;
      setState(() {
        _message = error.code == 'guest_web_deletion_unavailable'
            ? 'Удаление на сайте пока недоступно на сервере. Повторите позже. Сейчас профиль можно удалить в приложении.'
            : 'Не удалось подтвердить код на сервере. Проверьте подключение и повторите попытку. Сохранённый код не изменится.';
      });
    } catch (_) {
      if (!_current) return;
      setState(() {
        _message =
            'Не удалось подготовить код в защищённом хранилище или подтвердить его на сервере. Повторите попытку.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    // No awaits between the identity check and the clipboard operation: an old
    // reveal completion can never queue a copy after logout or account linking.
    if (!_current || _code == null || _busy) return;
    try {
      await Clipboard.setData(ClipboardData(text: _code!));
      if (_current) {
        setState(
          () => _message = 'Код скопирован. Сохраните его в надёжном месте.',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _message = 'Не удалось скопировать код. Повторите попытку.',
        );
      }
    }
  }

  Future<void> _openWebsite() async {
    if (!_current || _busy) return;
    // Accept an origin only and construct a fixed path. No credential is ever
    // included in a URL, in the query string, or in a fragment.
    if (!accountEndpointAvailable(widget.identity.endpoint)) return;
    final url = Uri.parse(
      widget.identity.endpoint,
    ).replace(path: '/account/delete').toString();
    widget.identity.checkGuestProfileOnReturn();
    try {
      await widget.onOpenExternal(url);
    } catch (_) {
      if (_current) {
        setState(
          () => _message = 'Не удалось открыть сайт. Повторите попытку.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('guest-web-delete-dialog'),
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    title: const Text('Удаление на сайте'),
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Сохраните код заранее: с ним можно удалить бесплатный профиль Dropo и связанные данные через сайт, даже после удаления приложения.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Любой, у кого есть код, сможет удалить этот профиль. Код не даёт доступа к аккаунту и не позволяет войти в него. Храните его в надёжном месте.',
          ),
          const SizedBox(height: 16),
          if (_current && _code == null)
            FilledButton.icon(
              key: const ValueKey('guest-web-delete-reveal'),
              onPressed: _busy ? null : _reveal,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.visibility_outlined),
              label: Text(_busy ? 'Подготавливаем…' : 'Показать код удаления'),
            ),
          if (_current && _code != null) ...[
            SelectableText(
              _code!,
              key: const ValueKey('guest-web-delete-code'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('guest-web-delete-copy'),
              onPressed: _copy,
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Скопировать код'),
            ),
            const SizedBox(height: 12),
            const Text(
              'На странице удаления выберите бесплатный профиль, вставьте этот код в форму и подтвердите удаление. Открытие сайта само по себе ничего не удаляет.',
            ),
          ],
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_message, key: const ValueKey('guest-web-delete-message')),
          ],
          const SizedBox(height: 12),
          if (_current)
            TextButton.icon(
              key: const ValueKey('guest-web-delete-open'),
              onPressed: _busy ? null : _openWebsite,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Открыть страницу удаления'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Закрыть'),
      ),
    ],
  );
}
