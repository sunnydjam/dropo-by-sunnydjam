part of 'main.dart';

// The artwork is bundled: opening a service list never makes a network request.
// See assets/SERVICE_ICONS_NOTICE.md for per-brand provenance and exceptions.
const Map<String, String> _serviceBrandAssets = {
  'youtube': 'youtube',
  'discord': 'discord',
  'meta': 'instagram',
  'facebook': 'facebook',
  'twitter': 'x',
  'signal': 'signal',
  'telegram': 'telegram',
  'whatsapp': 'whatsapp',
  'viber': 'viber',
  'twitch': 'twitch',
  'spotify': 'spotify',
  'slack': 'slack',
  'miro': 'miro',
  'wix': 'wix',
  'coda': 'coda',
  'grammarly': 'grammarly',
  'docker': 'docker',
  'clickup': 'clickup',
  'helpscout': 'helpscout',
  'atlassian': 'atlassian',
  'openai': 'openai',
};

// These are deliberately not imitations of restricted trademarks. A route that
// covers a group of products also must not pretend to represent just one brand.
const Map<String, IconData> _servicePictograms = {
  'linkedin': Icons.business_center_rounded,
  'facetime': Icons.video_chat_rounded,
  'snapchat': Icons.camera_alt_rounded,
  'tiktok': Icons.video_library_rounded,
  'canva': Icons.palette_rounded,
  'notion': Icons.menu_book_rounded,
  'manychat': Icons.mark_unread_chat_alt_rounded,
  'ai-other': Icons.hub_rounded,
};

@visibleForTesting
Set<String> get serviceIconCatalogTags =>
    Set.unmodifiable({..._serviceBrandAssets.keys, ..._servicePictograms.keys});

@visibleForTesting
String? serviceIconAssetPath(String tag) {
  final asset = _serviceBrandAssets[tag.trim().toLowerCase()];
  return asset == null ? null : 'assets/service-$asset.svg';
}

@visibleForTesting
Widget serviceIconForTesting({required String tag, double size = 32}) =>
    _ServiceBrandIcon(tag: tag, size: size);

class _ServiceBrandIcon extends StatelessWidget {
  const _ServiceBrandIcon({required this.tag, this.size = 32});

  final String tag;
  final double size;

  @override
  Widget build(BuildContext context) {
    final normalizedTag = tag.trim().toLowerCase();
    final assetPath = serviceIconAssetPath(normalizedTag);
    final foreground = switch (normalizedTag) {
      'youtube' => const Color(0xFFFF202C),
      'discord' => const Color(0xFF5865F2),
      'facebook' => const Color(0xFF0866FF),
      'signal' => const Color(0xFF3B45FD),
      'telegram' => const Color(0xFF26A5E4),
      'whatsapp' => const Color(0xFF25D366),
      'viber' => const Color(0xFF7360F2),
      'twitch' => const Color(0xFF9146FF),
      'spotify' => const Color(0xFF1ED760),
      'coda' => const Color(0xFFF46A54),
      'grammarly' => const Color(0xFF027E6F),
      'docker' => const Color(0xFF2496ED),
      'clickup' => const Color(0xFF7B68EE),
      'helpscout' => const Color(0xFF1292EE),
      'atlassian' => const Color(0xFF0052CC),
      _ => const Color(0xFFF3F7F6),
    };
    final artwork = assetPath != null
        ? SvgPicture.asset(
            assetPath,
            width: size,
            height: size,
            fit: BoxFit.contain,
            colorFilter: ColorFilter.mode(foreground, BlendMode.srcIn),
          )
        : Icon(
            _servicePictograms[normalizedTag] ?? Icons.language_rounded,
            size: size,
            color: const Color(0xFF9DAEA9),
          );
    return ExcludeSemantics(
      child: SizedBox(
        key: ValueKey('service-brand-icon-$normalizedTag'),
        width: size,
        height: size,
        child: normalizedTag == 'youtube'
            ? Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: size * .5,
                    height: size * .4,
                    child: const ColoredBox(color: Color(0xFFF3F7F6)),
                  ),
                  artwork,
                ],
              )
            : normalizedTag == 'meta'
            ? DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size * .29),
                  gradient: const LinearGradient(
                    begin: Alignment.bottomLeft,
                    end: Alignment.topRight,
                    colors: [
                      Color(0xFFFFCE52),
                      Color(0xFFFF285B),
                      Color(0xFF983ADD),
                    ],
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.all(size / 7),
                  child: artwork,
                ),
              )
            : artwork,
      ),
    );
  }
}
