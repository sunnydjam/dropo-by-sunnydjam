# Night Earth surface

`earth_night_atlas.png` is an original decorative image created for Dropo's
approved night-Earth visual direction with the built-in image generation tool.
It is not a satellite observation, a server-location map, or live telemetry.
No third-party photograph or remote runtime image URL is used.

- Source: 1774 × 887 pixels, equirectangular 2:1 world surface.
- SHA-256: `7c076c237aa555405e17973e2eb187a48711c16d891e0064194703228ee8ffae`.
- The approved app concept supplied the appearance reference: dark emerald
  terrain and clouds, small warm city lights, thin atmosphere, black space.
- Ship this file inside the Flutter asset bundle. Never download a replacement
  at runtime. Geometry, atmospheric shading, status palettes, controls and
  animation remain code-native.
- Geographic details and city illumination are artistic approximations, not
  navigational or scientific data.

## Asset brief

Use case: stylized-concept. Asset type: production texture for a rotating 3D Earth in a desktop app. Image 1 is STYLE REFERENCE ONLY, the approved night-Earth concept. Produce ONLY a standalone FLAT EQUIRECTANGULAR WORLD TEXTURE, EXACT 2:1 aspect ratio, ideally 2048x1024. NOT a sphere, NOT an app screenshot, NO text, NO labels, NO frame. Fill every pixel edge-to-edge. Longitude -180 at left, +180 at right, Greenwich at center; latitude +90 at top, equator exactly middle, -90 at bottom. Conventional real-world Earth geography: Americas in left half, Europe/Africa at center, Asia/Australia in right half, Antarctica stretched along bottom. Entire map is NIGHT: detailed but dim dark-emerald land and oceans with real-looking coastline/terrain relief, subtle thin desaturated green clouds, and fine bright warm ivory/golden city lights. Follow the approved reference's realistic texture, restrained emerald-green surface, tiny detailed golden urban networks. Population pattern: dense European and eastern-USA city clusters, Mediterranean coasts, Nile delta/valley, India, eastern China and Japan, sparse Africa and Australia; no random lights in oceans/deserts. City lights must be bright enough to survive downsampling for a small 250px globe but occupy only a small minority of map area; no solid glowing continents, no exaggerated thick coastline outlines. This is a seamless UV material to wrap around a sphere: LEFT AND RIGHT EDGES MATCH, no baked sphere shading, no terminator, no vignette, no perspective, no edge glow, no atmosphere or stars, no blank margins. Lighting uniformly night across whole world, no lateral brightness gradient. Land/sea/cloud texture stays dim emerald/teal GREEN; ONLY cities use warm yellow-white emissions (this color separation lets code extract a city-light mask). Ocean near RGB 6,20,17, terrain roughly 12,35,26 to 35,70,50, cloudy highlights muted 50,80,67; cities pale gold ~245,205,110. Preserve geographic recognizability and crisp intricate natural detail. Output one full rectangular seamless map texture, not a concept sheet.
