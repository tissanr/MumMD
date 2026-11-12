#!/bin/bash
# Baut MDView.app nur mit swiftc und installiert es nach ~/Applications (oder $DEST).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=MDView
MARKED_VERSION=15.0.12
MARKED_SHA256=3e7e7d7feb3e5d58cb6c804f68ab5c24cc7e5eb6270fd6e5cbb9124739217d0c
MIN_MACOS=12.0
DEST="${DEST:-$HOME/Applications}"

BUILD=build
APP="$BUILD/$APP_NAME.app"
MARKED="$BUILD/vendor/marked-$MARKED_VERSION.min.js"

# marked.js einmalig laden (gecacht in build/vendor) und Prüfsumme verifizieren.
if [[ ! -f "$MARKED" ]]; then
    echo "→ Lade marked.js $MARKED_VERSION"
    mkdir -p "$BUILD/vendor"
    curl -fsSL "https://cdn.jsdelivr.net/npm/marked@$MARKED_VERSION/marked.min.js" -o "$MARKED.tmp"
    mv "$MARKED.tmp" "$MARKED"
fi
echo "$MARKED_SHA256  $MARKED" | shasum -a 256 -c --quiet - || { rm -f "$MARKED"; echo "Prüfsumme falsch" >&2; exit 1; }

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
codesign --force --sign - "$APP" >/dev/null

echo "→ Installiere nach $DEST"
mkdir -p "$DEST"
rm -rf "${DEST:?}/$APP_NAME.app"
ditto "$APP" "$DEST/$APP_NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST/$APP_NAME.app"

echo "✓ $DEST/$APP_NAME.app"
