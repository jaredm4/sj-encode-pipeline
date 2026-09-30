#!/bin/bash
# compare_encode.sh - score an existing encode against its original with VMAF.
#
# Usage:  ./compare_encode.sh [--full] ORIGINAL ENCODE [offset_seconds ...]
#   No offsets given: 5 clips at 10/30/50/70/90% of the duration.
#   Example matching earlier tests: ./compare_encode.sh orig.mkv enc.mkv 600 1500 2100 2250
#   --full: score the ENTIRE file in one pass instead of sampling clips. Any trailing
#           offset_seconds arguments are ignored in this mode. Alignment is checked at the
#           10%, 50%, and 90% marks; if all three agree on the same frame shift, that shift
#           is applied across the whole file with high (but not absolute) confidence nothing
#           drifts in between. If they disagree, the midpoint's shift is used with a warning
#           -- this means something changes between those points, and the default clip-
#           sampling mode with offsets spanning the file should be used to find where. This
#           mode is much slower: expect close to real-time-per-frame-decoded x2 (both files
#           decode the whole runtime), so a 2-hour film can take a couple of hours.
#
# Env overrides: FFMPEG (ffmpeg binary with libvmaf built in; default: "ffmpeg" via $PATH),
#                FPS (default 24000/1001), CLIP (seconds, 60), SUB (n_subsample, 5),
#                THREADS (4), WORK (scratch dir), MODEL (force a specific libvmaf model
#                name, e.g. "vmaf_4k_v0.6.1" -- overrides auto-detection below),
#                MODEL_4K_MIN_WIDTH (auto-detection threshold, default 3800)
#
# VMAF model selection: different models predict different assumed viewing conditions (the
# default model predicts a 1080p TV at ~3x screen-height distance; vmaf_4k_v0.6.1 predicts a
# 4K TV at ~1.5x screen-height) and their scores are NOT comparable to each other. Unless
# MODEL is set explicitly, this script picks vmaf_4k_v0.6.1 automatically when the ORIGINAL
# file's native width is >= MODEL_4K_MIN_WIDTH, else the standard vmaf_v0.6.1. The choice is
# based on the original's raw resolution (before any CROP), since that's what determines the
# real viewing condition being modeled, not the encode's resolution or crop.
#
# Uses frame-order timestamps (setpts=N/fps/TB) and checks alignment INDEPENDENTLY at each
# clip (not just once globally), since drift can start partway through a file even when the
# beginning is aligned. Each clip is scored with whichever of shift -2..+2 frames scores best
# on a quick 20s pre-check, so a localized one-frame drift doesn't silently corrupt that clip's
# score the way it would with a single global alignment check.
# Set CROP=W:H (e.g. CROP=1920:804) to center-crop BOTH files to the picture area, so
# letterbox bars left in an uncropped encode don't inflate its score.
# If the encode is cropped (e.g. HandBrake auto-crop of letterbox bars), the original is
# center-cropped to match; if it is scaled, the encode is scaled up to the original size.

set -u

FFMPEG=${FFMPEG:-ffmpeg}
FPS=${FPS:-24000/1001}
CLIP=${CLIP:-60}
SUB=${SUB:-5}
THREADS=${THREADS:-4}
WORK=${WORK:-/tmp/vmaf_compare}
MODEL_OVERRIDE=${MODEL:-}
MODEL_4K_MIN_WIDTH=${MODEL_4K_MIN_WIDTH:-3800}

FULL=0
if [ "${1:-}" = "--full" ]; then FULL=1; shift; fi

if [ $# -lt 2 ]; then
  echo "usage: $0 [--full] ORIGINAL ENCODE [offset_seconds ...]"; exit 1
fi
ORIG=$1; ENC=$2; shift 2
if [ "$FULL" -eq 1 ] && [ $# -gt 0 ]; then
  echo "note: --full ignores the offset_seconds arguments ($*); scoring the whole file."
  shift $#
fi
[ -f "$ORIG" ] || { echo "not found: $ORIG"; exit 1; }
[ -f "$ENC" ]  || { echo "not found: $ENC"; exit 1; }
command -v "$FFMPEG" >/dev/null 2>&1 || { echo "ffmpeg not found: $FFMPEG (set FFMPEG=/path/to/ffmpeg-with-libvmaf, or put one on \$PATH)"; exit 1; }
"$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q libvmaf || echo "WARNING: '$FFMPEG -filters' does not list libvmaf; scoring will likely fail."
command -v python3 >/dev/null || { echo "python3 is required for the statistics"; exit 1; }

mkdir -p "$WORK"
rm -f "$WORK"/clip_*.json "$WORK/errors.log"
TS="setpts=N/(${FPS})/TB"

# duration in whole seconds, read via ffmpeg
dur() {
  "$FFMPEG" -hide_banner -i "$1" 2>&1 | awk '/Duration:/ {
    gsub(",", "", $2); split($2, t, ":"); printf "%d", t[1]*3600 + t[2]*60 + t[3]; exit }'
}

DO=$(dur "$ORIG"); DE=$(dur "$ENC")
if [ -z "$DO" ] || [ -z "$DE" ] || [ "$DO" -le 0 ] || [ "$DE" -le 0 ]; then
  echo "could not read durations (original='$DO' encode='$DE')"; exit 1
fi
DIFF=$(( DO > DE ? DO - DE : DE - DO ))
echo "Original: $ORIG (${DO}s)"
echo "Encode:   $ENC (${DE}s)"
if [ "$DIFF" -gt 2 ]; then
  echo "WARNING: durations differ by ${DIFF}s. Frame-order pairing will drift and scores will be"
  echo "         unreliable (trimmed, different cut, or different frame rate?)."
fi

# ---- Frame sizes: handle cropped or scaled encodes ----
size_of() { "$FFMPEG" -hide_banner -i "$1" 2>&1 | grep -m1 'Video:' | grep -oE '[0-9]{3,5}x[0-9]{3,5}' | head -1; }
SO=$(size_of "$ORIG"); SE=$(size_of "$ENC")
OW=${SO%x*}; OH=${SO#*x}; EW=${SE%x*}; EH=${SE#*x}
DSCALE=""; RCROP=""
if [ -z "$SO" ] || [ -z "$SE" ]; then
  echo "WARNING: could not read frame sizes; assuming they match."
elif [ "$SO" != "$SE" ]; then
  if [ "$EW" -eq "$OW" ] && [ "$EH" -lt "$OH" ]; then
    RCROP="crop=${EW}:${EH},"
    echo "Encode is ${SE}, original ${SO}: center-cropping the original to match."
  else
    DSCALE="scale=${OW}:${OH}:flags=bicubic,"
    echo "Encode is ${SE}, original ${SO}: scaling the encode up to the original size."
    echo "  (If the encode was cropped on more than one axis, scores will be unreliable.)"
  fi
fi

# ---- VMAF model selection ----
if [ -n "$MODEL_OVERRIDE" ]; then
  MODEL="$MODEL_OVERRIDE"
  echo "VMAF model: ${MODEL} (explicitly set via MODEL)"
elif [ -n "$OW" ] && [ "$OW" -ge "$MODEL_4K_MIN_WIDTH" ]; then
  MODEL="vmaf_4k_v0.6.1"
  echo "VMAF model: ${MODEL} (original is ${OW} wide, >= ${MODEL_4K_MIN_WIDTH})"
else
  MODEL="vmaf_v0.6.1"
  if [ -z "$OW" ]; then
    echo "VMAF model: ${MODEL} (default; could not read the original's width)"
  else
    echo "VMAF model: ${MODEL} (original is ${OW} wide, < ${MODEL_4K_MIN_WIDTH})"
  fi
fi

# Optional: force both files to the same center-cropped picture area
if [ -n "${CROP:-}" ]; then
  DSCALE=""; RCROP=""
  [ "${OW}:${OH}" != "$CROP" ] && RCROP="crop=${CROP},"
  [ "${EW}:${EH}" != "$CROP" ] && DSCALE="crop=${CROP},"
  echo "CROP=${CROP}: comparing the center ${CROP} region of both files."
fi

if [ "$FULL" -eq 1 ]; then
  OFFS=()   # unused in full mode; kept for messages below
else
  if [ $# -gt 0 ]; then
    OFFS=("$@")
  else
    OFFS=()
    for p in 10 30 50 70 90; do
      o=$(( DO * p / 100 - CLIP / 2 )); [ "$o" -lt 0 ] && o=0
      OFFS+=("$o")
    done
  fi
fi

# run_score <enc_trim> <ref_trim> <offset> <length> <subsample> [json_path]
# Trim prefixes are filter fragments like "trim=start_frame=1," (or empty).
run_score() {
  local dt="$1" rt="$2" off="$3" len="$4" sub="$5" json="${6:-}"
  local opts="n_subsample=${sub}:n_threads=${THREADS}:model=version=${MODEL}"
  [ -n "$json" ] && opts="${opts}:log_fmt=json:log_path=${json}"
  "$FFMPEG" -hide_banner -nostats \
    -ss "$off" -t "$len" -i "$ENC" \
    -ss "$off" -t "$len" -i "$ORIG" -an -sn \
    -lavfi "[0:v:0]${dt}${DSCALE}${TS},format=yuv420p10le[d];[1:v:0]${rt}${RCROP}${TS},format=yuv420p10le[r];[d][r]libvmaf=${opts}" \
    -f null -
}

quick() {  # prints mean VMAF or nothing
  run_score "$1" "$2" "$3" 20 4 2>&1 | grep -o 'VMAF score: [0-9.]*' | awk '{print $3}'
}

# ---- Alignment probing (shared by per-clip mode and --full mode) ----
# Tries shift -2..+2 frames on a quick 20s window at a given offset and reports which
# scores best. Prints "<best_shift> <best_score>" on stdout; diagnostics go to stderr.
probe_shift() {
  local off="$1"
  local best_shift=0 best_score=-1 s score
  local results=""
  for s in 0 1 2 -1 -2; do
    if [ "$s" -ge 0 ]; then dt="trim=start_frame=$s,setpts=PTS-STARTPTS,"; rt=""
    else                    dt=""; rt="trim=start_frame=$(( -s )),setpts=PTS-STARTPTS,"; fi
    score=$(quick "$dt" "$rt" "$off")
    [ -z "$score" ] && score=0
    results="${results}${s}:${score} "
    awk -v sc="$score" -v best="$best_score" 'BEGIN{exit !(sc>best)}' && { best_score=$score; best_shift=$s; }
  done
  echo "  shift scores @ ${off}s: ${results}-> best shift ${best_shift} (score ${best_score})" >&2
  echo "$best_shift $best_score"
}

# Given a frame-shift integer, echoes "<enc_trim> <ref_trim>" filter-chain fragments
# (either may be empty) that compensate for it.
trim_for_shift() {
  local shift="$1"
  if [ "$shift" -gt 0 ]; then
    echo "trim=start_frame=$shift,setpts=PTS-STARTPTS," ""
  elif [ "$shift" -lt 0 ]; then
    echo "" "trim=start_frame=$(( -shift )),setpts=PTS-STARTPTS,"
  else
    echo "" ""
  fi
}

# ---- Per-clip alignment check + score ----
# For each offset, find the best shift with probe_shift() and echo the corresponding
# "<enc_trim> <ref_trim>" pair. Drift beyond +/-2 frames at a given offset is flagged as
# unresolved rather than guessed at.
align_and_score() {
  local off="$1"
  local best_shift best_score
  read -r best_shift best_score <<< "$(probe_shift "$off")"
  if awk -v b="$best_score" 'BEGIN{exit !(b<50)}'; then
    echo "  WARNING: no shift in -2..+2 scored above 50 at ${off}s; drift here exceeds what this" >&2
    echo "           script compensates for, or there is a genuine content difference. Treat this" >&2
    echo "           clip's score as unreliable." >&2
  fi
  trim_for_shift "$best_shift"
}

echo
if [ "$FULL" -eq 1 ]; then
  P10=$(( DO * 10 / 100 )); P50=$(( DO / 2 )); P90=$(( DO * 90 / 100 ))
  echo "Full-file mode: checking alignment at 10% (${P10}s), 50% (${P50}s), and 90% (${P90}s) ..."
  read -r S10 SC10 <<< "$(probe_shift "$P10")"
  read -r S50 SC50 <<< "$(probe_shift "$P50")"
  read -r S90 SC90 <<< "$(probe_shift "$P90")"
  echo "  10%: shift ${S10} (score ${SC10})   50%: shift ${S50} (score ${SC50})   90%: shift ${S90} (score ${SC90})"

  if [ "$S10" = "$S50" ] && [ "$S50" = "$S90" ]; then
    echo "  -> consistent shift (${S10}) at all three points; applying it across the whole file."
    CHOSEN=$S10
  else
    echo "  WARNING: alignment differs across the file (10%=${S10}, 50%=${S50}, 90%=${S90})."
    echo "           This means drift starts somewhere between these points, or one of them is a"
    echo "           genuine content mismatch. Using the midpoint's shift (${S50}) for the whole-"
    echo "           file score, but treat this result with real caution -- run without --full and"
    echo "           sample offsets between these three points to find where it actually changes."
    CHOSEN=$S50
  fi
  read -r DT RT <<< "$(trim_for_shift "$CHOSEN")"

  echo -n "Scoring the entire file (${DO}s) ... "
  run_score "$DT" "$RT" 0 "$DO" "$SUB" "$WORK/clip_0.json" 2>>"$WORK/errors.log"
  if [ -s "$WORK/clip_0.json" ]; then echo done; else echo "FAILED (see $WORK/errors.log)"; fi
else
  for off in "${OFFS[@]}"; do
    read -r DT RT <<< "$(align_and_score "$off")"
    echo -n "Scoring ${CLIP}s @ ${off}s ... "
    run_score "$DT" "$RT" "$off" "$CLIP" "$SUB" "$WORK/clip_${off}.json" 2>>"$WORK/errors.log"
    if [ -s "$WORK/clip_${off}.json" ]; then echo done; else echo "FAILED (see $WORK/errors.log)"; fi
  done
fi

shopt -s nullglob
JSONS=("$WORK"/clip_*.json)
[ ${#JSONS[@]} -gt 0 ] || { echo "no results"; exit 1; }

echo
python3 - "${JSONS[@]}" <<'EOF'
import json, os, sys

def stats(v):
    v = sorted(v); n = len(v)
    return sum(v) / n, v[int(0.01 * (n - 1))], v[0]

rows, pooled = [], []
for p in sys.argv[1:]:
    off = os.path.basename(p)[len("clip_"):-len(".json")]
    v = [f["metrics"]["vmaf"] for f in json.load(open(p))["frames"]]
    rows.append((int(off), *stats(v)))
    pooled += v

print(f"{'offset':>8} {'mean':>8} {'p1':>8} {'min':>8}")
for off, m, p1, mn in sorted(rows):
    print(f"{off:>8} {m:>8.2f} {p1:>8.2f} {mn:>8.2f}")
m, p1, mn = stats(pooled)
print(f"{'pooled':>8} {m:>8.2f} {p1:>8.2f} {mn:>8.2f}")
EOF
echo "(model: ${MODEL} -- scores from different models are not directly comparable to each other)"

so=$(stat -c %s "$ORIG"); se=$(stat -c %s "$ENC")
echo
awk -v o="$so" -v e="$se" -v d="$DE" 'BEGIN{
  printf "Sizes: original %.2f GB, encode %.2f GB (%.0f%% of original), encode avg %.1f Mbps (all streams)\n",
         o/1e9, e/1e9, 100*e/o, e*8/d/1e6 }'
echo "Logs and per-frame JSON: $WORK"
