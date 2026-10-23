# Application icon exports

The approved green source is `store-assets/app-icon-512.png`. The original
artwork and store publication exports stay unchanged. Windows tray states use
`app-icon-grey-master.png` (disconnected) and `app-icon-red-master.png` (error).
Both variants were produced with the built-in `image_gen` edit tool using the
approved green icon as the sole edit target. No status-routing code changed.

Run `python tools/prepare-app-icons.py` from the repository root with Pillow
installed. This only resizes and encodes the approved artwork: Windows PNGs
are 256 px; ICOs contain 16, 20, 24, 32, 40, 48, 64, 128 and 256 px; Android
launcher densities are 48, 72, 96, 144 and 192 px. Windows window, installer,
tray and Android launcher consumers use their existing resource paths.

## Grayscale edit prompt

Use case: precise-object-edit. Edit target: the attached existing Dropo app icon.
Produce the Windows disconnected/idle state of this exact logo. Recolor the entire
existing image into neutral grayscale/silver, including the planet, orbit, small
flying alien doctor, cape and dark background. Keep every shape, proportions,
composition, details, subject positioning, lighting gradients and crop exactly
matching the reference. The face stays friendly. NO new elements, no text, no
symbols, no border, no rounded corners, no redesign. Full square opaque background,
crisp polished app icon, 1024x1024. Use only neutral grays; no green or other color cast.

## Red edit prompt

Use case: precise-object-edit. Edit target: the attached existing Dropo app icon.
Produce the Windows error/unavailable state of this exact logo. Recolor the
existing green palette to vivid crimson/red: the planet, orbit, small flying alien
doctor, cape and dark background. Preserve the white doctor's coat, highlight
contrast, every shape, proportions, composition, details, subject positioning and
crop exactly matching the reference. Friendly expression remains. NO new elements,
no text, no warning symbol, no border, no rounded corners, no redesign. Full square
opaque deep burgundy background, crisp polished app icon, 1024x1024.
