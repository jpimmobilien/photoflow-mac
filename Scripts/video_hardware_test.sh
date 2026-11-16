#!/bin/bash
# PhotoFlow Video-KI – hardware acceptance test for a real Apple-Silicon Mac.
#
# Usage (Terminal):
#   /Applications/PhotoFlow.app/Contents/Resources/video_hardware_test.sh          # 5 clips + V2V/I2V/background/optimise
#   /Applications/PhotoFlow.app/Contents/Resources/video_hardware_test.sh 10       # 10 consecutive clips
#
# Everything runs locally. Downloads (only if missing): video engine runtime (~160 MB), UMT5 text encoder (11.4 GB),
# Wan 2.1 1.3B (6.2 GB); on Macs with ≥ 32 GB also Wan 2.2 5B (Bild→Video). Afterwards the test runs offline.
# Report: ~/Pictures/PhotoFlow KI-Hardwaretest/<date> Video/report.md – please send it to the developer.
set -u
RUNS="${1:-5}"
APP="${PHOTOFLOW_APP:-}"
if [[ -z "$APP" ]]; then
    for c in "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" /Applications/PhotoFlow.app "$HOME/Applications/PhotoFlow.app"; do
        [[ -x "$c/Contents/MacOS/PhotoFlow" ]] && APP="$c" && break
    done
fi
[[ -z "$APP" ]] && { echo "PhotoFlow.app not found – set PHOTOFLOW_APP=/path/to/PhotoFlow.app"; exit 1; }
BIN="$APP/Contents/MacOS/PhotoFlow"
[[ "$(uname -m)" != "arm64" ]] && { echo "Video-KI braucht einen Mac mit Apple Silicon (dieser Mac: $(uname -m))."; exit 2; }
OUT="$HOME/Pictures/PhotoFlow KI-Hardwaretest/$(date +%Y-%m-%d\ %H.%M) Video"
mkdir -p "$OUT"
LOG="$OUT/console.log"
MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
echo "PhotoFlow Video-KI-Hardwaretest → $OUT"
{
  echo "== System"; sw_vers; sysctl -n machdep.cpu.brand_string; echo "RAM: ${MEM_GB} GB"
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|Metal|Cores"
  df -h "$HOME" | tail -1
} 2>&1 | tee "$LOG"

echo "== Installation (nur fehlende Teile)" | tee -a "$LOG"
"$BIN" --qa video-install wan21-t2v-1.3b 2>&1 | grep -vE "^\s+[0-9.]+ %" | tee -a "$LOG" || { echo "Installation fehlgeschlagen" | tee -a "$LOG"; exit 1; }
if (( MEM_GB >= 32 )); then
    "$BIN" --qa video-install wan22-ti2v-5b 2>&1 | grep -vE "^\s+[0-9.]+ %" | tee -a "$LOG" || true
fi

echo "== Abnahmetest ($RUNS Clips)" | tee -a "$LOG"
"$BIN" --qa video-acceptance --runs "$RUNS" --out "$OUT" 2>&1 | grep -vE "^\s+[0-9.]+ %" | tee -a "$LOG"
RC=${PIPESTATUS[0]}

echo "== Neustart-Test: neuer Prozess, eine Generierung OHNE Netzwerk (sandbox-exec deny network)" | tee -a "$LOG"
sandbox-exec -p '(version 1)(allow default)(deny network*)' "$BIN" --qa video-t2v "$OUT/after_restart_offline.mp4" 832 480 33 30 2>&1 | tail -5 | tee -a "$LOG"
[[ ${PIPESTATUS[0]} == 0 ]] && echo "| Neustart + offline | ✓ | neuer Prozess, Netzwerk gesperrt |" >> "$OUT/report.md" || echo "| Neustart + offline | ✗ | siehe console.log |" >> "$OUT/report.md"

echo
echo "Fertig. Bericht: $OUT/report.md"
open "$OUT" 2>/dev/null
exit $RC
