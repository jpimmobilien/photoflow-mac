# Video-KI – Bestandsaufnahme, Modellrecherche, Architektur, Status

Stand: 16.11.2026. Diese Datei ist die Phase‑1‑Grundlage für die Video‑KI und hält fest, was tatsächlich
funktioniert, was gemessen wurde und was (noch) nicht verfügbar ist.

## 1. Ausgangslage (Bestandsaufnahme)

- **Foto‑KI** (bisher „AI Studio“): Core ML auf GPU / Neural Engine, Stable Diffusion 1.5 / 2.1 / XL,
  float32‑VAE (behebt die leeren Bilder, siehe `AI_FEHLERANALYSE.md`), Real‑ESRGAN, LaMa, Vision.
  Bleibt unverändert erhalten und heißt jetzt **Foto‑KI**.
- **Navigation**: Der Tab heißt **KI**, darin gibt es den Umschalter **Foto‑KI | Video‑KI**. Der Tab öffnet den zuletzt
  benutzten Bereich.
- Core ML eignet sich für die aktuellen Videomodelle nicht: Es gibt keine Core‑ML‑Konvertierungen. Die
  Diffusion‑Transformer mit 1,3–14 Mrd. Parametern, 3D‑VAE und dynamischen Sequenzlängen lassen sich mit
  coremltools nicht verlässlich konvertieren. Für Video wird deshalb das passende Backend der jeweiligen Modellfamilie
  genutzt (siehe 3).

## 2. Modellrecherche (Lizenz, Apple Silicon, Speicher, Qualität)

| Modell | Lizenz (kommerziell?) | Aufgaben | Größe / Download | Apple Silicon | Entscheidung |
|---|---|---|---|---|---|
| **Wan 2.1 T2V 1.3B** | Apache 2.0 (ja) | Text→Video, Video→Video | 6,2 GB + Textencoder 11,4 GB | PyTorch/MPS, MLX (mlx‑video) | **aufgenommen** (kompakt, 480p, 16 fps, bis 5 s) |
| **Wan 2.2 TI2V 5B** | Apache 2.0 (ja) | Text→Video, Bild→Video | 22,8 GB + Textencoder | PyTorch/MPS, MLX; veröffentlichte Mac‑Messung: 1280×704, 41 Bilder, 56 GB Spitze auf M3 Max (mlx‑video) | **aufgenommen** (≥ 32 GB, 720p ab 64 GB) |
| **Wan 2.1 VACE 1.3B** | Apache 2.0 (ja) | maskierte Videobearbeitung (Füllen/Entfernen, Erweitern, Referenzfigur, Pose) | 7,7 GB + Textencoder | PyTorch/MPS (diffusers) | **im Katalog**, Funktionen erst nach Hardware‑Abnahme freigegeben |
| Wan 2.2 A14B (T2V/I2V) | Apache 2.0 | Text/Bild→Video, beste Wan‑Qualität | 126 GB (2 × 14B Experten) | nur mit 64–128 GB sinnvoll | nicht aufgenommen (Größe) |
| LTX‑2 / LTX‑2.5 (19–22B + Gemma 12B) | LTX‑2.x Community License: frei unter 10 Mio. $ Jahresumsatz, darüber kostenpflichtig | Text/Bild/Audio→Video mit Ton | > 40 GB, **Download nur mit Hugging‑Face‑Konto (gated)** | MLX‑Ports vorhanden | nicht aufgenommen (Login‑pflichtig, Größe, Umsatzgrenze) |
| LTX‑Video 0.9.8 2B distilled | LTXV Open Weights License: frei unter 10 Mio. $, Nutzungsbeschränkungen; Lizenzgeber darf die Nutzung nachträglich einschränken | Text/Bild/Video→Video, schnell | ~6 GB + T5‑XXL | diffusers | vorerst nicht aufgenommen (Lizenzklauseln), Kandidat |
| CogVideoX‑2B / 5B | 2B Apache 2.0; 5B eigene Lizenz mit Registrierung | Text→Video 720×480, 8 fps | 5B ~ 20 GB | diffusers | nicht aufgenommen (Qualität unter Wan 2.1) |
| HunyuanVideo | Tencent Hunyuan Community License – **schließt EU, UK und Südkorea aus** | Text→Video | > 25 GB | – | **ausgeschlossen** (in Deutschland nicht lizenziert) |
| MiniMax H3 | Lizenz schließt EU, UK, Südkorea, USA aus | Text→Video | 33B | – | **ausgeschlossen** |
| SVOR (Video‑Objektentfernung) | Code Apache 2.0; Gewichte (LoRA auf VACE 1.3B) ohne klare Lizenzangabe | Objekte + Schatten entfernen | ~33 GB VRAM (CUDA) | nicht geprüft | nicht aufgenommen, bis die Gewichtslizenz geklärt ist |
| ProPainter, E2FGVI | nicht kommerziell (S‑Lab / CC BY‑NC) | Video‑Inpainting | – | – | **ausgeschlossen** (Lizenz) |
| SAM 2 / 2.1 | Apache 2.0; Apple stellt Core‑ML‑Fassungen (nur Einzelbild, ohne Video‑Gedächtnis) | Segmentierung / Tracking | 40–900 MB | Core ML | Kandidat für die Objektauswahl; derzeit Apple Vision |
| Audio: MusicGen | Gewichte CC BY‑NC | Musik | – | – | ausgeschlossen (Lizenz) |
| Audio: Stable Audio Open | Stability Community License (kommerziell nur < 1 Mio. $) | Musik/SFX | – | – | nicht aufgenommen |

Quellen: Modellkarten auf Hugging Face (Wan‑AI, Lightricks, Tencent), Repositorien (Blaizzy/mlx‑video,
xiaomi‑research/svor), Lizenztexte; Mac‑Laufzeiten aus veröffentlichten Messungen (modelfit.io, Stand Okt. 2026).
Das ist keine Rechtsberatung.

**Wichtig:** Auch bei Apache 2.0 bist du für die Verwendung der erzeugten Inhalte verantwortlich. Für reale Personen
gilt: nur eigene Aufnahmen oder mit Einwilligung.

## 3. Architektur

```
PhotoFlow.app (Swift)
 ├─ AIJobManager          – zentrale Warteschlange: immer nur ein schwerer KI‑Auftrag (Foto ODER Video)
 ├─ VideoAIModel          – Video‑KI‑Zustand, Formate/Längen aus den Modellfähigkeiten, Speicherschätzung
 ├─ VideoEngineClient     – startet die Video‑Engine als eigenen Prozess, JSON‑Zeilen‑Protokoll,
 │                          Fortschritt pro Schritt, Abbrechen, Absturz‑/Speichererkennung, Leerlauf‑Beenden
 ├─ VideoIO               – AVFoundation: Bilder ⇄ H.264/HEVC/ProRes, Ton bleibt erhalten, KI‑Metadaten,
 │                          sichtbarer Hinweis „KI‑generiert“ beim Export
 ├─ VideoFrameProcessor   – Streaming‑Verarbeitung (AVAssetReader → Core Image → AVAssetWriter)
 ├─ VideoBackgroundReplacer – Apple Vision Personen-/Motivsegmentierung, zeitlich geglättete Maske
 └─ VideoOptimizer        – Szenenwechsel, Schlüsselbild‑Analyse alle 2 s mit PhotoFlows Optimierungs-Engine,
                            weiche Interpolation, Stabilisierung (Vision‑Registrierung)

Video‑Engine (eigener Prozess, Resources/VideoEngine/photoflow_video)
 ├─ worker.py   – JSON‑Zeilen: hello, load, t2v, i2v, v2v, vace, cancel, unload, memory
 ├─ engine.py   – Wan über Hugging Face diffusers auf PyTorch (Metal/MPS); UMT5‑Textencoder wird nur zum
 │               Kodieren geladen und sofort freigegeben; VAE in float32 mit Kachel‑Dekodierung
 ├─ attention.py– Attention in Abschnitten: hält jede Attention‑Matrix unter 2^28 Elementen
 │               (MPS liefert ab ~2^31 Elementen falsche Ergebnisse)
 └─ validate.py – Inhaltsprüfung jedes Videos (leer, Rauschen, Schwarz/Weiß, Sprünge, Stillstand, Flackern)
```

**Warum PyTorch/MPS + diffusers und nicht MLX als erstes Backend?** Ein Codepfad deckt alle Wan‑Aufgaben ab:
Text→Video, Bild→Video, Video→Video und VACE (maskierte Bearbeitung). VACE gibt es in mlx‑video nicht. Außerdem lässt
sich derselbe Code in CI auf der CPU numerisch prüfen. MLX (mlx‑video, MIT) ist als zweites, schnelleres Backend für
Text/Bild→Video vorgesehen. Die Architektur ist dafür vorbereitet (`AIComputeBackend`, Modell‑`videoKind`).

**Laufzeitumgebung:** Die Video‑Engine braucht Python 3.12 (python‑build‑standalone), PyTorch 2.11, diffusers 0.42.1
und transformers 5.22.1. Sie ist ein optionaler Download von 160 MB („Video‑Engine“ in der Modellverwaltung):
- Jede Datei ist mit URL, Größe und SHA‑256 festgelegt (`requirements-macos-arm64.lock`, erzeugt mit
  `uv --exclude-newer 2026-10-31`).
- PhotoFlows geprüfter Downloader lädt die Dateien.
- Die Pakete werden **offline** installiert (`pip --no-index`).
- Die Engine läuft mit `HF_HUB_OFFLINE=1` und kontaktiert nie das Netz.

**Speicher:** Der Textencoder (11,4 GB) wird nur kurz geladen. Danach liegen Transformer (bf16) und VAE (float32) im
Speicher. Vor jedem Auftrag zeigt PhotoFlow den voraussichtlichen Speicherbedarf an. Nach dem ersten Lauf ersetzt der
auf diesem Mac **gemessene** Spitzenwert die Schätzung. Nach 2 Minuten Leerlauf beendet PhotoFlow den Engine‑Prozess,
damit macOS den gesamten Speicher zurückbekommt.

## 4. Funktionsstatus

| Funktion | Status | Technik | Getestet |
|---|---|---|---|
| Videos generieren (Text→Video) | verfügbar (Apple Silicon ≥ 16 GB, macOS 14) | Wan 2.1 1.3B / Wan 2.2 5B | CI: CPU‑Pipeline (siehe TEST_REPORT §5); **echte Mac‑GPU: ausstehend** |
| Bilder animieren (Bild→Video) | verfügbar (≥ 32 GB) | Wan 2.2 5B | **ausstehend** |
| Video→Video | verfügbar | Wan 2.1 1.3B, Stärke 20–90 % | CI: CPU‑Pipeline; Mac‑GPU ausstehend |
| Hintergrund ersetzen | verfügbar (alle Macs) | Apple Vision, zeitlich geglättete Maske, Bild/Video/Unschärfe/Farbe | macOS-VM ✓ (Flackern 0,0006, TEST_REPORT §5.2); Apple-Silicon-Hardware ausstehend |
| Video optimieren + Stabilisieren | verfügbar (alle Macs) | Szenen‑/Schlüsselbildanalyse, Interpolation, Vision‑Registrierung | macOS-VM ✓ (Wackeln 5,57 → 0,44 px/Bild); Apple-Silicon-Hardware ausstehend |
| Objekte/Personen aus Videos entfernen | **nicht verfügbar** | VACE im Katalog; Masken‑Tracking‑UI und Hardware‑Abnahme fehlen | – |
| Personen austauschen / Charaktertransformation | **nicht verfügbar** | VACE‑Referenz + Pose wäre der Weg; zuverlässige Identitätskonsistenz ist mit 1,3B‑Modellen nicht gegeben | – |
| Video‑Upscaling, Video‑Restaurierung | **nicht verfügbar** | bildweises Real‑ESRGAN flackert; kein geprüfter zeitlich konsistenter Upscaler | – |
| Video erweitern (Outpainting / Verlängern) | **nicht verfügbar** | VACE bzw. Bild→Video vom letzten Bild; folgt nach Hardware‑Abnahme | – |
| Video‑Editor mit Zeitleiste | **nicht verfügbar** (Phase 6) | – | – |
| Audio | Originalton bleibt erhalten; keine KI‑Audiomodelle (Lizenzen) | – | – |
| KI‑Kennzeichnung | verfügbar | QuickTime‑Metadaten (IPTC Digital Source Type, Modell, Prompt, Seed) + optional sichtbarer Hinweis | Build ✓ |

## 5. Hardware‑Matrix Video

| Mac | Text→Video 1.3B | Bild→Video 5B | Hintergrund/Optimieren |
|---|---|---|---|
| Apple Silicon, 8 GB | nicht unterstützt (Textencoder allein 11 GB) | nicht unterstützt | unterstützt |
| Apple Silicon, 16–24 GB | unterstützt (480p, bis 5 s) – **ungetestet** | nicht unterstützt | unterstützt |
| Apple Silicon, 32–48 GB | unterstützt – ungetestet | eingeschränkt (reduzierte Auflösung) – ungetestet | unterstützt |
| Apple Silicon, ≥ 64 GB | unterstützt – ungetestet | unterstützt (720p) – ungetestet | unterstützt |
| Intel | nicht unterstützt (keine PyTorch‑Builds für Intel‑Macs mit aktuellem MPS, keine sinnvolle Leistung) | nicht unterstützt | unterstützt |

„Ungetestet“ heißt: Es gibt noch keine Messung auf echter Hardware. Die Speichergrenzen sind aus den Modellgrößen
abgeleitet und werden nach dem Hardware‑Test durch Messwerte ersetzt.

## 6. Datenschutz

- Alle Fotos und Videos bleiben auf dem Mac. Es gibt keine Cloud‑API, keine Konten und keine Telemetrie.
- Netzwerk wird nur für Downloads genutzt, die du in der Modellverwaltung startest:
  - Modelle von huggingface.co (Wan‑AI)
  - die Laufzeit von files.pythonhosted.org und github.com
- Danach läuft alles offline. Die Engine startet mit `HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE` und `DO_NOT_TRACK`.
- Ablageorte:
  - Modelle: `~/Library/Application Support/PhotoFlow/Models/`
  - Videos: `~/Library/Application Support/PhotoFlow/AI Studio/Videos/`
  - Zwischenbilder: temporärer Ordner, wird nach jedem Auftrag gelöscht
