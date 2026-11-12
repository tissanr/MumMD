# MumMD – MDView

Minimaler, schnell startender Markdown-Viewer für macOS (Swift, AppKit, WKWebView, marked.js).

```bash
./build.sh            # baut MDView.app und installiert es nach ~/Applications
```

- Öffnen: Doppelklick / „Öffnen mit“, Drag & Drop auf Dock-Icon oder Fenster, `open -a MDView datei.md`, ⌘O
- Auto-Reload bei Änderungen (auch atomares Speichern), Scrollposition bleibt erhalten
- ⌘R neu laden · ⌘+ / ⌘− / ⌘0 Schriftgröße · ⌘W schließen · ⌘Q beenden
- Zur Laufzeit keine Netzwerkzugriffe (CSP); externe Links öffnen im Standardbrowser

Tests: `MDVIEW_DEBUG=1` gibt Render-Ereignisse auf stderr aus, `MDVIEW_DEBUG_SNAPSHOT=<ordner>` speichert
nach jedem Rendern ein PNG, `MDVIEW_DEBUG_SCROLL=<px>` scrollt nach dem ersten Rendern
(z. B. `open -a MDView --env MDVIEW_DEBUG=1 --stderr log.txt datei.md`).
