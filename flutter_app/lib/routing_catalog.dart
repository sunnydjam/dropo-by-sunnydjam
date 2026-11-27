part of 'main.dart';

class _BlockedCatalogPage extends StatefulWidget {
  const _BlockedCatalogPage({required this.bridge});
  final CoreBridge bridge;
  @override
  State<_BlockedCatalogPage> createState() => _BlockedCatalogPageState();
}

class _BlockedCatalogPageState extends State<_BlockedCatalogPage> {
  Timer? debounce;
  String query = '';
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FeaturePage(
    title: 'Домены и IP-адреса',
    icon: Icons.manage_search,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          maxLength: 253,
          decoration: const InputDecoration(
            labelText: 'Поиск домена, IP или подсети',
            prefixIcon: Icon(Icons.search),
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
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: SelectableText(item),
                    ),
                ],
              ],
            );
          },
        ),
      ],
    ),
  );
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
    widget.onBusyChanged?.call(true);
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
      widget.onBusyChanged?.call(false);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FilledButton.tonalIcon(
        onPressed: !widget.enabled || busy ? null : () => change(null),
        icon: const Icon(Icons.add),
        label: const Text('Привязать приложение'),
      ),
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
  late String? tag = widget.old?['service']?.toString();
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
    title: const Text('Привязка приложения'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: path,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Полный путь к .exe',
              suffixIcon: IconButton(
                onPressed: pick,
                tooltip: 'Выбрать файл',
                icon: const Icon(Icons.folder_open),
              ),
            ),
          ),
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
