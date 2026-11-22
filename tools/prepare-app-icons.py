"""Export bundled app icons from approved artwork; requires Pillow."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
ICO_SIZES = [(size, size) for size in (16, 20, 24, 32, 40, 48, 64, 128, 256)]


def export() -> None:
    sources = {
        "green": ROOT / "store-assets/app-icon-512.png",
        "grey": ROOT / "store-assets/source/app-icon-grey-master.png",
        "red": ROOT / "store-assets/source/app-icon-red-master.png",
    }
    artwork = {}
    for state, path in sources.items():
        with Image.open(path) as source:
            if source.width != source.height or source.width < 256:
                raise ValueError(f"Expected square master of at least 256 px: {path}")
            artwork[state] = (
                source.convert("L").convert("RGBA")
                if state == "grey"
                else source.convert("RGBA")
            )

    icons = ROOT / "app/assets/icons"
    for state, source in artwork.items():
        png = source.resize((256, 256), Image.Resampling.LANCZOS)
        png.save(icons / f"icon_{state}.png", optimize=True)
        png.save(icons / f"icon_{state}.ico", sizes=ICO_SIZES)

    primary = artwork["green"].resize((256, 256), Image.Resampling.LANCZOS)
    primary.save(icons / "app_icon.png", optimize=True)
    primary.save(icons / "app_icon.ico", sizes=ICO_SIZES)
    primary.save(
        ROOT / "flutter_app/windows/runner/resources/app_icon.ico", sizes=ICO_SIZES
    )
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        destination = ROOT / f"flutter_app/android/app/src/main/res/mipmap-{density}/ic_launcher.png"
        artwork["green"].resize((size, size), Image.Resampling.LANCZOS).save(
            destination, optimize=True
        )
    print("Exported Windows app/tray icons (9 sizes) and 5 Android launcher densities.")


if __name__ == "__main__":
    export()
