#!/bin/bash
# Baut MDView als Universal-App (Apple Silicon + Intel) und verpackt sie in ein DMG zum Weitergeben.
# Ergebnis: build/MDView-<version>.dmg
#
#   SIGN_IDENTITY="Developer ID Application: …"  mit Developer-ID signieren statt ad hoc
#   NOTARY_PROFILE=<name>                         zusätzlich von Apple notarisieren lassen
#                                                 (Profil vorher anlegen: xcrun notarytool store-credentials <name>)
#
# Ohne Developer-ID ist die App nur ad hoc signiert. Sie läuft trotzdem, aber macOS fragt beim
# ersten Start nach – siehe „Erst lesen.txt“ im DMG.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=MDView
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=build
STAGE="$BUILD/dmg"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGN_IDENTITY:-}" ]]; then
    echo "NOTARY_PROFILE braucht SIGN_IDENTITY (Developer ID Application)" >&2
    exit 1
fi

# hdiutil ohne die Hinweise auf diskutil image (gibt es erst ab neueren macOS-Versionen).
hd() { hdiutil "$@" 2> >(grep -v "is deprecated" >&2); }

NO_INSTALL=1 UNIVERSAL=1 ./build.sh

echo "→ Stelle DMG-Inhalt zusammen"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$BUILD/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Programme"
cp "$BUILD/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    cat > "$STAGE/Erst lesen.txt" <<EOF
MDView $VERSION – Markdown-Viewer für macOS (ab macOS 12)

Installation:
  MDView auf den Ordner „Programme“ ziehen und von dort starten.

Als Standard-App für .md-Dateien:
  .md-Datei im Finder auswählen → ⌘I → „Öffnen mit: MDView“ → „Alle ändern …“
EOF
else
    cat > "$STAGE/Erst lesen.txt" <<EOF
MDView $VERSION – Markdown-Viewer für macOS (ab macOS 12)

Installation:
  1. MDView auf den Ordner „Programme“ ziehen.
  2. MDView im Ordner Programme doppelklicken.

Beim ersten Start meldet macOS, dass MDView nicht überprüft werden kann
(die App ist nicht bei Apple registriert). So lässt sie sich trotzdem öffnen:

  macOS 15 und neuer:
    Meldung mit „Fertig“ schließen → Systemeinstellungen → Datenschutz & Sicherheit
    → ganz nach unten scrollen → bei „MDView“ auf „Dennoch öffnen“ klicken.

  macOS 12 bis 14:
    Im Ordner Programme mit der rechten Maustaste auf MDView → „Öffnen“ → „Öffnen“.

Das ist nur einmal nötig. Alternativ im Terminal:
  xattr -dr com.apple.quarantine /Applications/MDView.app

Als Standard-App für .md-Dateien:
  .md-Datei im Finder auswählen → ⌘I → „Öffnen mit: MDView“ → „Alle ändern …“
EOF
fi

echo "→ Erzeuge $DMG"
hd create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

# Eigenes Icon für das gemountete Laufwerk aktivieren (Finder-Flag „hat eigenes Icon“).
if command -v SetFile >/dev/null; then
    RW="$BUILD/rw.dmg"
    hd convert "$DMG" -format UDRW -ov -o "$RW" >/dev/null
    MNT=$(hd attach "$RW" -nobrowse -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
    SetFile -a C "$MNT"
    hd detach "$MNT" >/dev/null
    hd convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
    rm -f "$RW"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "→ Notarisiere (kann einige Minuten dauern)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

rm -rf "$STAGE"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
