part of 'main.dart';

InputDecoration _catalogSearchDecoration(
  String hint, {
  VoidCallback? onClear,
}) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: _atlasMuted, fontSize: 14),
  prefixIcon: const Icon(Icons.search, size: 22),
  filled: true,
  fillColor: _atlasSurface,
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: _atlasBorder),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: _atlasBorder),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: _atlasMint),
  ),
  suffixIcon: onClear == null
      ? null
      : _AccessibleIconButton(
          tooltip: 'Очистить поиск',
          onPressed: onClear,
          icon: const Icon(Icons.close),
        ),
);

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    super.key,
    this.rowKey,
    required this.title,
    required this.icon,
    this.subtitle,
    this.actions,
    this.badge,
    this.accentBadge = false,
    this.expanded,
    this.onTap,
    this.detail,
    this.selectable = false,
  });
  final Key? rowKey;
  final String title;
  final String? subtitle, badge;
  final Widget icon;
  final Widget? actions, detail;
  final bool accentBadge, selectable;
  final bool? expanded;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    const titleStyle = TextStyle(
      color: _atlasText,
      fontSize: 14,
      fontWeight: FontWeight.w500,
    );
    final header = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox.square(dimension: 32, child: Center(child: icon)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (selectable)
                    SelectableText(title, style: titleStyle)
                  else
                    Text(title, style: titleStyle),
                  if (subtitle != null)
                    SelectableText(
                      subtitle!,
                      style: const TextStyle(
                        color: _atlasMuted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                ],
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: accentBadge
                      ? _atlasMint.withValues(alpha: .10)
                      : _atlasSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge!,
                  style: TextStyle(
                    color: accentBadge ? _atlasMint : _atlasText,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            ?actions,
            if (onTap != null) ...[
              const SizedBox(width: 12),
              Icon(
                expanded == true ? Icons.expand_less : Icons.chevron_right,
                color: _atlasMuted,
                size: 20,
              ),
            ],
          ],
        ),
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _atlasBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onTap != null)
            Semantics(
              button: true,
              expanded: expanded,
              child: InkWell(key: rowKey, onTap: onTap, child: header),
            )
          else
            header,
          ?detail,
        ],
      ),
    );
  }
}

class _CatalogAddButton extends StatelessWidget {
  const _CatalogAddButton({
    required this.buttonKey,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final Key buttonKey;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: const Icon(Icons.add_circle_outline),
        label: Text(_uiText(context, label)),
      ),
    ),
  );
}

class _BlockedCatalogPage extends StatefulWidget {
  const _BlockedCatalogPage({required this.bridge, this.inline = false});
  final bool inline;
  final CoreBridge bridge;
  @override
  State<_BlockedCatalogPage> createState() => _BlockedCatalogPageState();
}

class _BlockedCatalogPageState extends State<_BlockedCatalogPage> {
  Timer? debounce;
  final searchText = TextEditingController();
  String query = '', editError = '';
  bool saving = false;
  Future<void> change([String? remove]) async {
    if (saving) return;
    String input = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          remove == null
              ? _uiText(ctx, 'Добавить домен или IP-адрес')
              : 'Удалить адрес?',
        ),
        content: remove == null
            ? TextField(
                key: const ValueKey('personal-address-input'),
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Домен, IP или подсеть',
                  hintText: 'example.org',
                ),
                onChanged: (value) => input = value,
              )
            : Text(remove),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const ValueKey('save-personal-address'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(remove == null ? 'Добавить' : 'Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      saving = true;
      editError = '';
    });
    try {
      final result = await widget.bridge.callMap(
        'SetPersonalAddress',
        args: [remove ?? input.trim(), remove != null],
        timeout: const Duration(minutes: 2),
      );
      if (result['success'] != true) {
        throw StateError(result['error']?.toString() ?? 'Ошибка сохранения');
      }
      if (!mounted) return;
      debounce?.cancel();
      if (remove == null) {
        searchText.clear();
        query = '';
      }
      setState(() => page = fetch(query));
    } catch (e) {
      if (mounted) setState(() => editError = _cleanError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  late Future<Map<String, dynamic>> page = fetch('');
  Future<Map<String, dynamic>> fetch(String value) async {
    final response = await widget.bridge.callMap(
      'SearchBlockedCatalog',
      args: [value],
    );
    if (response['success'] != true) {
      throw StateError(response['error']?.toString() ?? 'Каталог недоступен');
    }
    return response;
  }

  void search(String value) {
    query = value.trim();
    debounce?.cancel();
    debounce = Timer(
      const Duration(milliseconds: 200),
      () => setState(() {
        page = fetch(query);
      }),
    );
  }

  @override
  void dispose() {
    debounce?.cancel();
    searchText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: searchText,
          maxLength: 253,
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) =>
                  null,
          decoration: _catalogSearchDecoration(
            'Поиск домена, IP или подсети',
            onClear: searchText.text.isEmpty
                ? null
                : () {
                    searchText.clear();
                    search('');
                  },
          ),
          onChanged: search,
        ),
        FutureBuilder<Map<String, dynamic>>(
          future: page,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LinearProgressIndicator();
            }
            if (snapshot.hasError) {
              return Column(
                children: [
                  Text(_cleanError(snapshot.error!)),
                  TextButton(
                    onPressed: () => setState(() {
                      page = fetch(query);
                    }),
                    child: const Text('Повторить'),
                  ),
                ],
              );
            }
            final data = snapshot.requireData;
            final items = _asStringList(data['items']);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Записей в каталоге: ${data['total']}'),
                if (items.isEmpty)
                  const Text('Совпадений нет')
                else ...[
                  Text(
                    query.isEmpty
                        ? 'Последние 10 записей каталога'
                        : 'Совпадения (до 10)',
                  ),
                  for (final item in items)
                    _CatalogRow(
                      title: item,
                      selectable: true,
                      icon: Icon(
                        item.contains('/') ||
                                InternetAddress.tryParse(item) != null
                            ? Icons.dns_outlined
                            : Icons.language_rounded,
                        color: _atlasMuted,
                        size: 24,
                      ),
                      actions: _asStringList(data['personal']).contains(item)
                          ? IconButton(
                              tooltip: 'Удалить адрес',
                              onPressed: saving ? null : () => change(item),
                              icon: const Icon(Icons.delete_outline),
                            )
                          : null,
                    ),
                ],
              ],
            );
          },
        ),
        if (editError.isNotEmpty) Text(editError),
        _CatalogAddButton(
          buttonKey: const ValueKey('add-personal-address'),
          label: 'Добавить домен или IP-адрес',
          onPressed: saving ? null : change,
        ),
      ],
    );
    return widget.inline
        ? content
        : _FeaturePage(
            title: 'Домены и IP-адреса',
            icon: Icons.manage_search,
            child: content,
          );
  }
}

class _ApplicationBindingsEditor extends StatefulWidget {
  const _ApplicationBindingsEditor({
    required this.bridge,
    required this.enabled,
    this.onBusyChanged,
  });
  final CoreBridge bridge;
  final bool enabled;
  final ValueChanged<bool>? onBusyChanged;
  @override
  State<_ApplicationBindingsEditor> createState() =>
      _ApplicationBindingsEditorState();
}

class _ApplicationBindingsEditorState
    extends State<_ApplicationBindingsEditor> {
  late Future<List<Map>> bindings = load();
  String error = '';
  bool busy = false;
  Map<String, String> targets = {};
  Future<List<Map>> load() async {
    final response = await widget.bridge.callMap('GetApplicationBindings');
    if (response['success'] != true) {
      throw StateError(response['error']?.toString() ?? 'Ошибка загрузки');
    }
    targets = Map<String, String>.from(response['services'] as Map? ?? {});
    return (response['bindings'] as List? ?? []).whereType<Map>().toList();
  }

  Future<void> change(Map? old, {bool remove = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    final onBusyChanged = widget.onBusyChanged;
    onBusyChanged?.call(true);
    try {
      String path = '', tag = '';
      if (remove) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Удалить привязку?'),
            content: Text(old!['path'].toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Удалить'),
              ),
            ],
          ),
        );
        if (ok != true) return;
      } else {
        await bindings;
        final services = targets;
        if (!mounted) return;
        final selection = await showDialog<(String, String)>(
          context: context,
          builder: (_) =>
              _ApplicationBindingDialog(services: services, old: old),
        );
        if (selection == null) return;
        (path, tag) = selection;
      }
      final response = await widget.bridge.callMap(
        'SetApplicationBinding',
        args: [old?['path'] ?? '', path, tag],
        timeout: const Duration(minutes: 2),
      );
      if (response['success'] != true) {
        throw StateError(response['error']?.toString() ?? 'Ошибка сохранения');
      }
      if (mounted) {
        setState(() {
          bindings = load();
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = _cleanError(e));
    } finally {
      onBusyChanged?.call(false);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FutureBuilder<List<Map>>(
        future: bindings,
        builder: (ctx, snapshot) {
          if (snapshot.hasError) {
            return TextButton(
              onPressed: () => setState(() {
                bindings = load();
              }),
              child: Text(
                'Повторить загрузку привязок: ${_cleanError(snapshot.error!)}',
              ),
            );
          }
          return Column(
            children: [
              for (final binding in snapshot.data ?? const <Map>[])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(binding['path'].toString()),
                  subtitle: Text(
                    targets[binding['service']] ??
                        binding['service'].toString(),
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: 'Изменить привязку',
                        onPressed: widget.enabled && !busy
                            ? () => change(binding)
                            : null,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: 'Удалить привязку',
                        onPressed: widget.enabled && !busy
                            ? () => change(binding, remove: true)
                            : null,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
      if (error.isNotEmpty) Text(error),
      _CatalogAddButton(
        buttonKey: const ValueKey('add-local-app'),
        label: 'Добавить приложение',
        onPressed: widget.enabled && !busy ? () => change(null) : null,
      ),
      const SizedBox(height: 12),
    ],
  );
}

class _ApplicationBindingDialog extends StatefulWidget {
  const _ApplicationBindingDialog({required this.services, this.old});
  final Map<String, String> services;
  final Map? old;
  @override
  State<_ApplicationBindingDialog> createState() =>
      _ApplicationBindingDialogState();
}

class _ApplicationBindingDialogState extends State<_ApplicationBindingDialog> {
  late final path = TextEditingController(
    text: widget.old?['path']?.toString(),
  );
  late String? tag =
      widget.old?['service']?.toString() ??
      (widget.services.containsKey('user-app-vpn') ? 'user-app-vpn' : null);
  String error = '';
  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    try {
      final selected = await const MethodChannel(
        'dropo/application_picker',
      ).invokeMethod<String>('pickExecutable');
      if (mounted && selected != null) setState(() => path.text = selected);
    } catch (e) {
      if (mounted) setState(() => error = _cleanError(e));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.old == null
          ? _uiText(context, 'Добавить приложение')
          : _tr(context, 'Изменить приложение', 'Edit application'),
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: path,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: _isMobileShell
                  ? 'Имя пакета Android'
                  : 'Полный путь к .exe',
              hintText: _isMobileShell ? 'com.example.app' : null,
              suffixIcon: _isMobileShell
                  ? null
                  : IconButton(
                      onPressed: pick,
                      tooltip: 'Выбрать файл',
                      icon: const Icon(Icons.folder_open),
                    ),
            ),
          ),
          if (!_isMobileShell)
            DropdownButtonFormField<String>(
              initialValue: tag,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Сервис'),
              items: [
                for (final s in widget.services.entries)
                  DropdownMenuItem(
                    value: s.key,
                    child: Text(s.value, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) => setState(() => tag = value),
            ),
          const SizedBox(height: 12),
          if (_isMobileShell)
            const Text('Соединения добавленного приложения пойдут через VPN.')
          else
            const Text(
              'Правило действует для всех интернет-соединений выбранного файла. Для браузера это включает все его вкладки.',
            ),
          if (error.isNotEmpty) Text(error),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed:
            tag == null ||
                path.text.trim().isEmpty ||
                (widget.old?['service'] == tag &&
                    widget.old?['path']?.toString().toLowerCase() ==
                        path.text.trim().toLowerCase())
            ? null
            : () => Navigator.pop(context, (path.text.trim(), tag!)),
        child: const Text('Сохранить'),
      ),
    ],
  );
}
