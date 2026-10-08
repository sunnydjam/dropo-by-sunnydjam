# Service artwork provenance

Reviewed for the service-list UI on 2026-10-08. This notice applies to Android
and Windows. The artwork is bundled locally; the UI never fetches logos.

The original four files (`service-youtube.svg`, `service-discord.svg`,
`service-instagram.svg`, `service-openai.svg`) are unchanged. The additional
SVG geometry is pinned to
[Simple Icons 14.0.0](https://github.com/simple-icons/simple-icons/tree/14.0.0/icons),
not fetched from a moving CDN at runtime. Paths are rendered proportionally;
colors use the identifiable brand or documented monochrome treatment.

The collection's CC0-1.0 text is retained in `Simple-Icons-LICENSE.txt`.
**CC0 for the collection does not imply that every represented logo or trademark
is unrestricted.** Simple Icons' [disclaimer](https://github.com/simple-icons/simple-icons/blob/14.0.0/DISCLAIMER.md)
and [per-icon metadata](https://github.com/simple-icons/simple-icons/blob/14.0.0/_data/simple-icons.json)
must be read separately. No separate icon-license field was supplied for the
17 new SVGs below; that absence is not a grant of trademark permission.

Marks identify third-party services that have route settings in Dropo. They are
not Dropo branding and do not imply sponsorship, partnership or endorsement.
Owners retain their rights. The following is a provenance/usage review, not a
legal clearance certificate; distribution and future brand-policy changes
remain subject to the repository owner's review.

## SVG sources and review notes

Every SVG source URL is
`https://raw.githubusercontent.com/simple-icons/simple-icons/14.0.0/icons/<slug>.svg`.
The slug below identifies the exact downloaded file.

| Route tag | SVG slug | Brand/source reference | Review note |
| --- | --- | --- | --- |
| `facebook` | `facebook` | [Meta Facebook logo](https://about.meta.com/brand/resources/facebook/logo/) | Official page required login during review. Preserve the full Facebook / Messenger group label; the family identifier is not a Messenger-only claim. |
| `twitter` | `x` | [X toolkit](https://about.x.com/en/who-we-are/brand-toolkit) | White proportional mark on dark background; retain X (Twitter) label. The toolkit still presents legacy Twitter content, so do not claim current asset approval. |
| `signal` | `signal` | [Signal brand](https://signal.org/brand/) | Accurate referential use; no rotation, effects, or shape changes. Default 32 px satisfies the stated 26 px glyph minimum; surrounding layout supplies clear space. |
| `telegram` | `telegram` | [Telegram logos](https://telegram.org/tour/screenshots) | The official page permits identifying illustrations/buttons, provided there is no claim of official representation. Its screenshot CC0 statement is not a blanket logo license. |
| `whatsapp` | `whatsapp` | [Meta WhatsApp brand](https://about.meta.com/brand/resources/whatsapp/whatsapp-brand/) | Official page required login during review. Plain referential mark; no endorsement claim. |
| `viber` | `viber` | [Viber Brand Center](https://www.viber.com/en/brand-center/) | Proportional master purple #7360F2 glyph, not the separately restricted community promotional badge. |
| `twitch` | `twitch` | [Twitch brand assets](https://brand.twitch.com/) | Referenced official asset portal; recognizable purple Glitch geometry from pinned collection, without distortion. |
| `spotify` | `spotify` | [Spotify design guidelines](https://developer.spotify.com/documentation/design) | Green icon on black, proportional and at least the 21 px digital minimum. No music/metadata integration, pairing into Dropo's logo, or playback claim. |
| `slack` | `slack` | [Slack media kit](https://slack.com/media-kit) | Standalone monochrome identifier beside the service name; not an API integration or co-branded app logo. |
| `miro` | `miro` | [Miro](https://miro.com/) | Monochrome glyph from upstream's official-source reference. Separate explicit logo license was not present; press/brand URL was unavailable during review. |
| `wix` | `wix` | [Wix design assets](https://www.wix.com/about/design-assets) | Official page provides white/black logo treatments and asks not to change the logo. Use the white proportional mark. |
| `coda` | `coda` | [Coda](https://coda.io/) | Preserve catalog's Coda identity and pinned geometry. Official site now announces Superhuman Docs; this UI change does not rename a network route. |
| `grammarly` | `grammarly` | [Grammarly media assets](https://www.grammarly.com/media-assets) | Pinned legacy Grammarly identity matches the existing route name. Official page has newer media assets; do not describe this as newly approved/current artwork. |
| `docker` | `docker` | [Docker media resources](https://www.docker.com/company/newsroom/media-resources/), [trademark guidelines](https://www.docker.com/legal/trademark-guidelines/) | Symbol is a supported secondary icon, scaled proportionally to at least 24 px. No implication of affiliation. |
| `clickup` | `clickup` | [ClickUp brand](https://clickup.com/brand) | Symbol treatment beside the product name, proportional; official page also provides monochrome variants. |
| `helpscout` | `helpscout` | [Help Scout](https://www.helpscout.com/) | Pinned recognizable mark from upstream's official-source reference; separate current brand/press URL was unavailable during review. |
| `atlassian` | `atlassian` | [Atlassian logos](https://atlassian.design/foundations/logos/) | Family mark accompanies the full Atlassian / Trello group label, rather than claiming this grouped rule routes Trello alone. |

## Deliberate non-brand pictograms

These entries use distinct bundled Flutter Material Icons rather than tracing a
brand logo, using generated letters, or assigning a misleading single-company
logo to a group. Material Icons' license is distributed in Flutter's license
bundle. Pictograms are not represented as official brand artwork.

| Route tag | Pictogram | Reason / source checked |
| --- | --- | --- |
| `linkedin` | Professional briefcase | [LinkedIn logo terms](https://brand.linkedin.com/in-logo) permit profile/share/follow uses, not this service-routing use. No written permission is recorded. |
| `facetime` | Video/chat | The route groups FaceTime and iMessage. A neutral combined-function graphic avoids inventing an official Apple group logo. |
| `snapchat` | Camera | [Snap guidelines](https://www.snap.com/brand-guidelines?lang=en-US) require official-source assets; the official vault could not expose a usable asset during review. No third-party ghost copy is included. |
| `tiktok` | Video library | [TikTok developer guidelines](https://developers.tiktok.com/doc/getting-started-design-guidelines/) require prior written permission for logo use. No permission is recorded. |
| `canva` | Palette | [Canva trademark policy](https://public.canva.site/canva-trademark-policy) disallows logos without existing approval. No approval is recorded. |
| `notion` | Notebook | [Notion trademark guidelines](https://notion.notion.site/Notion-Trademark-Usage-Guidelines-9826313c686a4f6e9d8a48347162714b) distinguish accurate reference from approved use of marks. No separate logo permission is recorded. |
| `manychat` | Chat notifications | [Manychat brand announcement](https://manychat.com/blog/meet-manychats-new-brand-identity/) was checked; a reusable official vector/permission could not be obtained. No guessed logo is shipped. |
| `ai-other` | Connected nodes | This is a multi-vendor route, not a single company's product. |

Unknown future or custom tags use a neutral globe. The test suite checks every
current Android/Windows catalog tag has a specific asset or pictogram, so new
built-in services cannot silently fall back to that globe.
