# AI Studio – technische Fehleranalyse, behobene Fehler und Modellbewertung

Stand: 14.11.2026. Alle Zahlen stammen aus Messungen mit `PhotoFlow --qa ai-diag`, `ai-t2i` und dem
Hardware-Abnahmetest (`--qa ai-acceptance`). Wo etwas nicht gemessen werden konnte, steht das ausdrücklich da.

## 1. Symptome

| Umgebung | Symptom |
|---|---|
| Apple Silicon (GitHub-VM, M1) | gleichmäßig graue/braune Bilder („leer“), auch bei Bild-zu-Bild und Inpainting |
| Intel (GitHub-VM, i7-8700B) | erste Generierung korrekt, danach `GPU Hang` im VAE-Decoder, später Verbindungsabbruch des Runners |
| Intel, nur CPU | UNet-Vorhersage schlägt fehl (`Unable to compute the prediction using ML Program`) |

## 2. Systematische Analyse

### 2.1 Wo wird tatsächlich gerechnet? (`MLComputePlan`)
`AIComputePlanInfo` liest über `MLComputePlan` (macOS 14.4+) aus, auf welchem Rechenwerk Core ML jede Operation
ausführt. Ergebnis auf der Apple-Silicon-VM mit angeforderter GPU: **„UNet: GPU 0 %, Neural Engine 0 %, CPU 100 % von
1841 Operationen“**. Die paravirtualisierte VM-GPU („Apple Paravirtual device“, nur Metal-Familie *Mac 2*) wird von Core ML
nicht genutzt – alles läuft still auf der CPU. Die Diagnose bestätigt das: CPU-, GPU- und „alle“-Einstellung liefern auf
der VM bitgenau dieselben Ausgaben.

### 2.2 Text-Conditioning, Latents, Noise-Schedule (`PipelineDiagnostics`)
Neu im Sampling-Loop: Streuung der Latents und der Rauschvorhersage pro Schritt, Zählung nicht-endlicher Werte.
Bei den „leeren“ Bildern auf Apple Silicon:

```
steps 1–12: latent std 1.000 → 0.880, noise std 1.009 → 0.757, all values finite
```

Text-Encoder, UNet, Scheduler und Latent-Initialisierung arbeiten also korrekt (keine NaN/Inf, plausibler Verlauf).
Der Text-Encoder liefert auf CPU (x86 und ARM) und GPU dieselben Werte (max. Abweichung 0,03).

### 2.3 VAE (Bild-Dekodierung) – die eigentliche Ursache
Gleiche, fest geseedete Eingaben auf allen Rechenwerken (`ai-diag`), verglichen mit der PyTorch-Referenz:

| VAE-Decoder (SD 2.1, Apple Core ML float16) | Mittelwert | Streuung |
|---|---|---|
| PyTorch float32 (Referenz) | −0,0986 | 0,0936 |
| Intel-GPU (Metal) | −0,1021 | 0,0943 ✓ |
| Intel-CPU | −0,0576 | 0,0697 ✗ |
| Apple-Silicon-CPU | −0,0576 | 0,0699 ✗ |

| VAE-Encoder | Mittelwert | Streuung |
|---|---|---|
| PyTorch float32 (Referenz) | −8,226 | 7,248 |
| Intel-GPU | −8,223 | 7,253 ✓ |
| Intel-CPU / Apple-Silicon-CPU | −5,30 | 4,70 ✗ |

**Befund:** Apples float16-VAE wird von Core ML auf der CPU falsch berechnet – auf x86 und ARM identisch falsch, also
ein systematischer Fehler der CPU-Ausführung dieses Modells in float16, kein Zufall. Mit echten Latents (Streuung ≈ 5
nach Skalierung) dekodiert der falsche Decoder zu nahezu einfarbigen Bildern. Weil die VM alles auf der CPU rechnet,
entstanden dort leere Bilder.

### 2.4 Intel: GPU-Hänger
Auf der Intel-VM brauchte ein einzelner VAE-Decoder-Aufruf auf der paravirtualisierten GPU 45–56 s, ein UNet-Schritt
36–83 s. Lange GPU-Kernel lösen die GPU-Watchdog-Erkennung aus („GPU Hang“). Der Hänger trat im VAE auf, nicht im UNet.
Auf echten Intel-GPUs ist die Laufzeit pro Kernel um Größenordnungen kürzer; das konnte hier nicht gemessen werden.
Maßnahme: Der VAE läuft auf Intel jetzt in float32 auf der **CPU** (dort korrekt, siehe 3.1); auf der GPU bleibt nur das
UNet, dessen CPU-Ausführung auf x86 nicht möglich ist.

## 3. Behobene Fehler

| # | Fehler | Ursache | Behebung |
|---|---|---|---|
| 3.1 | Leere/graue Bilder bei CPU-Ausführung | Apples float16-VAE rechnet auf der CPU falsch | Eigener **float32-VAE** (stabilityai/sd-vae-ft-mse, MIT), konvertiert mit `Scripts/ai/convert_vae.py`, gleiche Schnittstelle wie Apples Modell; wird mit SD 1.5/2.1 automatisch geladen und ersetzt Apples VAE (`ComponentConfiguration.setVAE`). Ergebnis: alle Tests auf Apple-Silicon-CPU bestanden |
| 3.2 | Bild-zu-Bild/Inpainting mit falschem Ausgangslatent | float16-VAE-Encoder auf der CPU falsch | float32-Encoder im selben Paket |
| 3.3 | GPU-Hänger im VAE (Intel-VM) | sehr lange VAE-Kernel auf langsamer GPU | VAE auf Intel auf der CPU (float32, korrekt) |
| 3.4 | Fehler wurden als Bild angezeigt | keine Inhaltsprüfung | `AIImageValidator`: Streuung, Rausch-Kennzahl (Laplace/Streuung), Schwarz/Weiß-Anteil; kalibriert an echten Ausgaben (gültig 0,13–0,19, Rauschen ≈ 2,7–3,0). Ungültige Ergebnisse werden nie angezeigt |
| 3.5 | Kein Ausweichweg | nur GPU-Varianten | **Neural-Engine-Varianten** (SD 1.5 / 2.1 split_einsum) als zweiter, unabhängiger Rechenweg; bei ungültigem Ergebnis automatischer Wechsel auf ein installiertes Modell des anderen Rechenwerks |
| 3.6 | Kompatibilität wurde behauptet statt geprüft | – | `ModelValidation`: pro Mac gespeichert, ob ein Modell gültige Bilder erzeugt hat; „Auf diesem Mac prüfen“ und Hardware-Abnahmetest |
| 3.7 | Outpainting: harte Nähte, niedrige Auflösung | ganze Leinwand wurde in ein 512-px-Quadrat gezwängt | Erweiterung kachelweise: jede Kachel enthält neuen Rand **und** echten Bildinhalt in Modellauflösung; weicher Übergang der Latent-Maske |
| 3.8 | CPU-Fallback nach GPU-Fehler erzeugte falsche Bilder | CPU-Pfad numerisch falsch (3.1) | kein CPU-Fallback für das UNet; nach Fehler einmal sauber neu laden |

## 4. Modellbewertung

| Modell | Lizenz | Apple Silicon | Intel | Download / RAM | Bildqualität | Backends | Entscheidung |
|---|---|---|---|---|---|---|---|
| SD 1.5 (Apple Core ML) | CreativeML Open RAIL-M (kommerziell erlaubt) | GPU, Neural Engine | GPU | 2,1 GB / 0,96 GB (6-bit) · ab 6–8 GB | gut bei 512 px, sehr verbreitet | Core ML | **aufgenommen** (GPU + Neural Engine) |
| SD 2.1 base (Apple Core ML) | CreativeML Open RAIL++-M | GPU, Neural Engine | GPU | 2,6 GB / 1,1 GB (6-bit) | gut bei 512 px | Core ML | **aufgenommen** (GPU + Neural Engine) |
| SDXL base (Apple Core ML) | CreativeML Open RAIL++-M | GPU, ab 16 GB | nein (zu langsam) | 3,4 GB (4,5-bit) / 7 GB | deutlich besser, 1024 px | Core ML | aufgenommen, nur Apple Silicon ≥ 16 GB |
| FLUX.1 schnell | Apache 2.0 | nur über MLX (Python „mflux“ bzw. experimentelle Swift-Ports) | nein | ~24 GB bf16, ~6–7 GB 4-bit (inoffizielle Quantisierungen) | sehr gut | MLX | **nicht aufgenommen**: offizieller Download nur mit Hugging-Face-Konto (gated); 4-bit-Varianten stammen nicht vom Herausgeber; MLX-Metal-Shader lassen sich mit SwiftPM nicht bauen und auf den Test-VMs nicht ausführen → nicht verifizierbar |
| SDXL-Turbo / SD-Turbo | nicht kommerziell | – | – | – | – | – | ausgeschlossen (Lizenz) |
| SD 3 / 3.5 Medium | Stability Community License (kommerziell nur < 1 Mio. $ Umsatz) | Core ML (SD3) | nein | ~5–10 GB | gut | Core ML | ausgeschlossen (Lizenz-Einschränkung) |

**MLX** wurde als Backend geprüft: Es läuft nur auf Apple Silicon, die Metal-Kernel müssen mit Xcode gebaut werden
(SwiftPM-Kommandozeilenbuilds können sie nicht erzeugen), und auf GitHubs Apple-Silicon-VMs steht keine nutzbare
Metal-GPU zur Verfügung (siehe 2.1). Die Architektur ist modular (`AIModelDescriptor.backend`,
`AIHardware.diffusionPlan`), sodass ein MLX-Backend später ergänzt werden kann, wenn es auf echter Hardware geprüft
werden kann.

## 5. Was noch auf echter Hardware zu bestätigen ist

Die GitHub-VMs haben keine von Core ML nutzbare GPU und keine Neural Engine. Bestätigt sind dort deshalb der komplette
Ablauf (Text, Latents, Sampling, Dekodierung, Speichern, Prüfen) **auf der CPU von Apple Silicon** sowie alle Abläufe
drumherum. Ob GPU- und Neural-Engine-Ausführung auf einem echten Mac gültige Bilder liefern, zeigt der
Hardware-Abnahmetest (Modellverwaltung ▸ Hardware-Test oder
`/Applications/PhotoFlow.app/Contents/Resources/ai_hardware_test.sh`). Ergebnisse: `TEST_REPORT.md`, Abschnitt 4.
