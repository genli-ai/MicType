#!/bin/bash
# Build the app icon into an app bundle. / 把 App 图标装进 .app。
#
# Usage: scripts/build-app-icon.sh <path/to/MicType.app>   (run from the MicType/ package directory)
#
# macOS 26 (Tahoe) draws any app that ships only a legacy .icns inside a grey glass tile,
# scaled down - the "grey ring" users see in the Dock. The only way out is an Icon Composer
# icon (Resources/AppIcon.icon) compiled by actool into Assets.car, named by CFBundleIconName.
# actool also renders an AppIcon.icns from the same source for macOS 15.
# If actool is unavailable or fails, fall back to the old sips/iconutil path from AppIcon.png
# so a build never ships without an icon.
set -u
APP="${1:?usage: build-app-icon.sh <MicType.app>}"
RES="$APP/Contents/Resources"
mkdir -p "$RES"

# Absolute paths only: actool resolves relative paths against $PWD as inherited from the
# environment, not the shell's real working directory, and silently compiles the wrong thing.
ICON_SRC="$(pwd -P)/Resources/AppIcon.icon"
if [ -d "$ICON_SRC" ]; then
    OUT=$(mktemp -d)
    if xcrun actool "$ICON_SRC" --compile "$OUT" \
            --output-format human-readable-text --errors \
            --output-partial-info-plist "$OUT/partial.plist" \
            --app-icon AppIcon --include-all-app-icons \
            --enable-on-demand-resources NO --development-region en \
            --target-device mac --minimum-deployment-target 15.0 --platform macosx \
            >"$OUT/actool.log" 2>&1 \
       && [ -f "$OUT/Assets.car" ] && [ -f "$OUT/AppIcon.icns" ]; then
        cp "$OUT/Assets.car" "$OUT/AppIcon.icns" "$RES/"
        echo "  ✓ App icon: Assets.car + AppIcon.icns compiled from AppIcon.icon"
        exit 0
    fi
    echo "  ! actool could not compile AppIcon.icon - falling back to AppIcon.png (see $OUT/actool.log)"
fi

if [ -f "Resources/AppIcon.png" ]; then
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    for SZ in 16 32 128 256 512; do
        sips -z $SZ $SZ Resources/AppIcon.png --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
        sips -z $((SZ*2)) $((SZ*2)) Resources/AppIcon.png --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
    done
    if iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"; then
        echo "  ✓ App icon: AppIcon.icns from AppIcon.png (legacy; grey tile on macOS 26)"
        exit 0
    fi
fi
echo "  ✗ No app icon could be built" >&2
exit 1
