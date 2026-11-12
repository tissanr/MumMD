#!/bin/bash
# Baut MDView.app nur mit swiftc und installiert es nach ~/Applications (oder $DEST).
#   MARKED_JS=<pfad>  vorhandene marked.min.js nutzen statt sie zu laden (z. B. für Homebrew, ohne Netz)
#   HLJS_JS=<pfad>    vorhandene highlight.min.js (Common-Bundle) nutzen statt sie zu laden
#   NO_INSTALL=1      nur nach build/MDView.app bauen, nichts installieren
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=MDView
MARKED_VERSION=15.0.12
MARKED_SHA256=3e7e7d7feb3e5d58cb6c804f68ab5c24cc7e5eb6270fd6e5cbb9124739217d0c
HLJS_VERSION=11.11.1
HLJS_SHA256=c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381
MIN_MACOS=12.0
DEST="${DEST:-$HOME/Applications}"

BUILD=build
APP="$BUILD/$APP_NAME.app"
MARKED="${MARKED_JS:-$BUILD/vendor/marked-$MARKED_VERSION.min.js}"
HLJS="${HLJS_JS:-$BUILD/vendor/highlight-$HLJS_VERSION.min.js}"
mkdir -p "$BUILD"

# marked.js einmalig laden (gecacht in build/vendor) und Prüfsumme verifizieren.
if [[ ! -f "$MARKED" ]]; then
    echo "→ Lade marked.js $MARKED_VERSION"
    mkdir -p "$BUILD/vendor"
    curl -fsSL "https://cdn.jsdelivr.net/npm/marked@$MARKED_VERSION/marked.min.js" -o "$MARKED.tmp"
    mv "$MARKED.tmp" "$MARKED"
fi
echo "$MARKED_SHA256  $MARKED" | shasum -a 256 -c --quiet - || { echo "Prüfsumme von $MARKED falsch" >&2; [[ -z "${MARKED_JS:-}" ]] && rm -f "$MARKED"; exit 1; }

# highlight.js (Common-Bundle, ~35 Sprachen) für Syntax-Highlighting in Codeblöcken, ebenso gecacht.
if [[ ! -f "$HLJS" ]]; then
    echo "→ Lade highlight.js $HLJS_VERSION"
    mkdir -p "$BUILD/vendor"
    curl -fsSL "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@$HLJS_VERSION/build/highlight.min.js" -o "$HLJS.tmp"
    mv "$HLJS.tmp" "$HLJS"
fi
echo "$HLJS_SHA256  $HLJS" | shasum -a 256 -c --quiet - || { echo "Prüfsumme von $HLJS falsch" >&2; [[ -z "${HLJS_JS:-}" ]] && rm -f "$HLJS"; exit 1; }

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
cp "$HLJS" "$APP/Contents/Resources/highlight.min.js"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Quick-Look-Erweiterung (Vorschau mit Leertaste im Finder), eingebettet in die App.
echo "→ Kompiliere Quick-Look-Erweiterung"
APPEX="$APP/Contents/PlugIns/MDViewQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
swiftc -O -swift-version 5 -application-extension \
    -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -module-name MDViewQuickLook \
    -framework QuickLookUI -framework JavaScriptCore \
    -Xlinker -e -Xlinker _NSExtensionMain \
    quicklook/PreviewProvider.swift -o "$APPEX/Contents/MacOS/MDViewQuickLook"
cp quicklook/Info.plist "$APPEX/Contents/Info.plist"
cp style.css "$APPEX/Contents/Resources/"
cp "$MARKED" "$APPEX/Contents/Resources/marked.min.js"
cp "$HLJS" "$APPEX/Contents/Resources/highlight.min.js"
codesign --force --sign - --entitlements quicklook/QuickLook.entitlements "$APPEX" >/dev/null

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
    -f -R "$DEST/$APP_NAME.app"
# Quick-Look-Erweiterung sofort anmelden (sonst erst nach dem ersten App-Start).
pluginkit -a "$DEST/$APP_NAME.app/Contents/PlugIns/MDViewQuickLook.appex" || true
qlmanage -r >/dev/null 2>&1 || true

echo "✓ $DEST/$APP_NAME.app"
