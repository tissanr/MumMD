#!/bin/bash
# Baut MDView.app nur mit swiftc und installiert es nach ~/Applications (oder $DEST).
#   MARKED_JS=<pfad>  vorhandene marked.min.js nutzen statt sie zu laden (z. B. für Homebrew, ohne Netz)
#   NO_INSTALL=1      nur nach build/MDView.app bauen, nichts installieren
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=MDView
MARKED_VERSION=15.0.12
MARKED_SHA256=3e7e7d7feb3e5d58cb6c804f68ab5c24cc7e5eb6270fd6e5cbb9124739217d0c
MIN_MACOS=12.0
DEST="${DEST:-$HOME/Applications}"

BUILD=build
APP="$BUILD/$APP_NAME.app"
MARKED="${MARKED_JS:-$BUILD/vendor/marked-$MARKED_VERSION.min.js}"
mkdir -p "$BUILD"

# marked.js einmalig laden (gecacht in build/vendor) und Prüfsumme verifizieren.
if [[ ! -f "$MARKED" ]]; then
    echo "→ Lade marked.js $MARKED_VERSION"
    mkdir -p "$BUILD/vendor"
    curl -fsSL "https://cdn.jsdelivr.net/npm/marked@$MARKED_VERSION/marked.min.js" -o "$MARKED.tmp"
    mv "$MARKED.tmp" "$MARKED"
fi
echo "$MARKED_SHA256  $MARKED" | shasum -a 256 -c --quiet - || { echo "Prüfsumme von $MARKED falsch" >&2; [[ -z "${MARKED_JS:-}" ]] && rm -f "$MARKED"; exit 1; }

# App-Icon aus icon.svg erzeugen (nur wenn sich das SVG geändert hat).
ICNS="$BUILD/AppIcon.icns"
if [[ ! -f "$ICNS" || icon.svg -nt "$ICNS" ]]; then
    echo "→ Erzeuge App-Icon"
    cat > "$BUILD/render-icon.swift" <<'SWIFT'
import AppKit
// render-icon <svg> <iconset-ordner>: rastert das SVG in alle .iconset-Größen.
let args = CommandLine.arguments
guard let image = NSImage(contentsOfFile: args[1]) else { fatalError("SVG nicht lesbar") }
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
    }
}
SWIFT
    swiftc -O "$BUILD/render-icon.swift" -o "$BUILD/render-icon"
    rm -rf "$BUILD/AppIcon.iconset" && mkdir -p "$BUILD/AppIcon.iconset"
    "$BUILD/render-icon" icon.svg "$BUILD/AppIcon.iconset"
    iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ICNS"
fi

echo "→ Kompiliere"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -framework AppKit -framework WebKit \
    main.swift -o "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
cp template.html style.css "$APP/Contents/Resources/"
cp "$MARKED" "$APP/Contents/Resources/marked.min.js"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

if [[ "${NO_INSTALL:-}" == 1 ]]; then
    echo "✓ $APP"
    exit 0
fi

echo "→ Installiere nach $DEST"
mkdir -p "$DEST"
rm -rf "${DEST:?}/$APP_NAME.app"
ditto "$APP" "$DEST/$APP_NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST/$APP_NAME.app"

echo "✓ $DEST/$APP_NAME.app"
