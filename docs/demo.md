# Projektnotizen

MDView zeigt Markdown so an, wie es auf GitHub aussieht – und aktualisiert sich,
**sobald die Datei gespeichert wird**. Ideal neben dem Editor oder einem KI-Agenten,
der gerade an der Doku schreibt.

## Status

| Bereich        | Stand        | Verantwortlich |
|----------------|--------------|----------------|
| Datenmodell    | fertig       | Team A         |
| Schnittstellen | in Arbeit    | Team B         |
| Tests          | offen        | Team A         |

## Nächste Schritte

- [x] Entwurf abstimmen
- [x] Prototyp bauen
- [ ] Review mit dem Fachbereich
- [ ] Go-Live vorbereiten

> Tipp: Mit ⌘+ und ⌘− lässt sich die Schriftgröße anpassen.

```swift
let viewer = MDView()
viewer.open("README.md")   // lädt neu, sobald sich die Datei ändert
```
