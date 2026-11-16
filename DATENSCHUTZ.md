# Datenschutz in PhotoFlow

Kurz: **Deine Fotos und Videos verlassen deinen Mac nicht.** PhotoFlow hat keine Cloud-Funktionen, keine Konten,
keine Werbung und keine Telemetrie.

## Was lokal passiert

| Bereich | Wo gerechnet wird | Was gespeichert wird |
|---|---|---|
| Bibliothek, Optimierung, Stapelverarbeitung, Duplikate | auf dem Mac (Apple Vision, Core Image, PhotoFlows Analyse) | Bibliotheksdatenbank in `~/Library/Application Support/PhotoFlow/` |
| Foto-KI (Bilder generieren, Füllen, Entfernen, Erweitern, Hochskalieren) | auf dem Mac (Core ML auf GPU / Neural Engine) | Ergebnisse in `~/Library/Application Support/PhotoFlow/AI Studio/`, auf Wunsch in `~/Pictures/PhotoFlow AI/` |
| Video-KI (Text→Video, Bild→Video, Video→Video) | auf dem Mac, in einem eigenen Prozess (PyTorch auf Metal) | Videos in `~/Library/Application Support/PhotoFlow/AI Studio/Videos/`; Zwischenbilder werden nach jedem Auftrag gelöscht |
| Hintergrund ersetzen, Video optimieren / stabilisieren | auf dem Mac (Apple Vision, AVFoundation) | neue Datei, das Original bleibt unverändert |

Originale werden nie überschrieben. Jede KI-Bearbeitung ist eine neue Datei mit Kennzeichnung als KI-erzeugt
(IPTC „Digital Source Type“, bei Videos zusätzlich optional ein sichtbarer Hinweis).

## Wann PhotoFlow ins Internet geht

Nur, wenn du in der Modellverwaltung selbst einen Download startest:

- Bildmodelle: `huggingface.co` (Apple, Stability AI) und `github.com` (PhotoFlows konvertierte Modelle)
- Videomodelle: `huggingface.co` (Wan-AI)
- Video-Engine-Laufzeit: `github.com` (Python) und `files.pythonhosted.org` (Pakete)

Jede Datei ist mit Größe und SHA-256-Prüfsumme festgelegt. Eine Datei mit abweichender Prüfsumme wird verworfen.
Bei diesen Downloads sieht der jeweilige Server – wie bei jedem Download – deine IP-Adresse; es werden keine Fotos,
Prompts oder sonstigen Inhalte übertragen.

Danach funktionieren alle installierten Funktionen **offline**. Das ist getestet: Die Generierung läuft in den Tests
mit gesperrtem Netzwerkzugang. Die Video-Engine startet zusätzlich mit `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`
und `DO_NOT_TRACK=1`.

## Was du löschen kannst

- Modelle: Modellverwaltung ▸ „Entfernen“ (oder den Ordner `~/Library/Application Support/PhotoFlow/Models/`)
- KI-Kreationen und KI-Videos: in „KI-Kreationen“ bzw. „KI-Videoprojekte“ löschen
- Alles: die Ordner `~/Library/Application Support/PhotoFlow/` und `~/Pictures/PhotoFlow AI/`

## Verantwortungsvolle Nutzung

KI-Veränderungen an Aufnahmen realer Personen nur mit deren Einwilligung. Keine Täuschung, kein Identitätsmissbrauch.
Einige Modelllizenzen (z. B. LTX) verlangen ausdrücklich, KI-erzeugte Inhalte als solche zu kennzeichnen – PhotoFlow
tut das in den Metadaten automatisch.
