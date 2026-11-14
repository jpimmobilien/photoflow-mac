#!/bin/bash
# PhotoFlow AI Studio – hardware acceptance test for a real Mac.
#
# Usage (Terminal):
#   /Applications/PhotoFlow.app/Contents/Resources/ai_hardware_test.sh            # full test (20 images + editing)
#   /Applications/PhotoFlow.app/Contents/Resources/ai_hardware_test.sh quick      # 10 images, no editing
#
# What it does – everything locally, no data leaves the Mac:
#   1. Shows hardware and installed models.
#   2. Downloads the model recommended for this Mac if no image model is installed (official source, SHA-256 checked),
#      plus Real-ESRGAN x2 and LaMa for the editing tests.
#   3. Runs the acceptance test: real generations, each saved as PNG, re-opened and checked
#      (not empty / not noise / content recognised), cancellation, variants, formats, model switching, memory, editing.
#   4. Starts PhotoFlow's engine a second time (= app restart) and generates once more.
#   5. Opens the report (report.md / index.html) – please send report.md to the developer.
set -u
MODE="${1:-full}"
APP="${PHOTOFLOW_APP:-}"
if [[ -z "$APP" ]]; then
    for c in "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" /Applications/PhotoFlow.app "$HOME/Applications/PhotoFlow.app"; do
        [[ -x "$c/Contents/MacOS/PhotoFlow" ]] && APP="$c" && break
    done
fi
[[ -z "$APP" ]] && { echo "PhotoFlow.app not found – set PHOTOFLOW_APP=/path/to/PhotoFlow.app"; exit 1; }
BIN="$APP/Contents/MacOS/PhotoFlow"
OUT="$HOME/Pictures/PhotoFlow KI-Hardwaretest/$(date +%Y-%m-%d\ %H.%M)-cli"
mkdir -p "$OUT"
LOG="$OUT/console.log"
echo "PhotoFlow KI-Hardwaretest → $OUT"
{
  echo "== System"; sw_vers; sysctl -n machdep.cpu.brand_string hw.memsize; system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|Metal|Cores" ;
  echo "== PhotoFlow"; "$BIN" --qa ai-info
} 2>&1 | tee "$LOG"

if ! "$BIN" --qa ai-info 2>/dev/null | grep -q "installed=true, compatible=ok" ; then :; fi
INSTALLED=$("$BIN" --qa ai-info 2>/dev/null | grep -E "^  (sd|sdxl)" | grep "installed=true, compatible=ok" | wc -l | tr -d ' ')
if [[ "$INSTALLED" == "0" ]]; then
    REC=$("$BIN" --qa ai-info | sed -n 's/^ai recommended diffusion model: //p')
    echo "== Kein Bildmodell installiert – lade $REC" | tee -a "$LOG"
    "$BIN" --qa ai-install "$REC" 2>&1 | tee -a "$LOG" || exit 1
fi
for m in realesrgan-x2plus lama; do
    "$BIN" --qa ai-info 2>/dev/null | grep -q "^  $m: .*installed=true" || "$BIN" --qa ai-install "$m" 2>&1 | tail -2 | tee -a "$LOG"
done

echo "== Abnahmetest ($MODE)" | tee -a "$LOG"
"$BIN" --qa ai-acceptance "$MODE" --out "$OUT" 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}

echo "== Neustart-Test (neuer Prozess)" | tee -a "$LOG"
"$BIN" --qa ai-restart-check "$OUT" 2>&1 | tee -a "$LOG"

echo
echo "Fertig. Bericht: $OUT/report.md"
open "$OUT/index.html" 2>/dev/null
exit $RC
