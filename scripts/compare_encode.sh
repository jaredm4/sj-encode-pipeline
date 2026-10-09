#!/bin/bash
# compare_encode.sh - score an existing encode against its original with VMAF.
#
# Usage:  ./compare_encode.sh [--full] ORIGINAL ENCODE [offset_seconds ...]
#
#   ORIGINAL and ENCODE may each be:
#     - a pair of FILES: compares that one pair, same as always. Results print to stdout
#       only, exactly as before.
#     - a pair of DIRECTORIES: compares every <name>.mkv found in ORIGINAL's root (not
#       recursive) against a same-named <name>.mp4 or <name>.mkv found in ENCODE's root.
#       A source file with no counterpart in ENCODE is skipped with a note. ALL per-pair
#       comparison output (in addition to printing live to stdout, as always) plus a
#       one-line-per-episode summary table at the very end are written to a single
#       "_vmaf_log.txt" inside the ENCODE directory, so you can see at a glance whether a
#       bad score is isolated to one file or widespread across the batch, then scroll up
#       in the same file for that episode's full detail. offset_seconds (if given) and
#       --full apply identically to every matched pair; FPS is likewise assumed uniform
#       across the whole batch.
#
#   No offsets given (file mode or folder mode): 5 clips at 10/30/50/70/90% of each file's
#   own duration.
#   Example matching earlier tests: ./compare_encode.sh orig.mkv enc.mkv 600 1500 2100 2250
#   --full: score the ENTIRE file in one pass instead of sampling clips. Any trailing
#           offset_seconds arguments are ignored in this mode. Alignment is checked at the
#           10%, 50%, and 90% marks; if all three agree on the same frame shift, that shift
#           is applied across the whole file with high (but not absolute) confidence nothing
#           drifts in between. If they disagree, the midpoint's shift is used with a warning
#           -- this means something changes between those points, and the default clip-
#           sampling mode with offsets spanning the file should be used to find where. This
#           mode is much slower: expect close to real-time-per-frame-decoded x2 (both files
#           decode the whole runtime), so a 2-hour film can take a couple of hours -- in
#           folder mode that cost applies to every matched pair.
#
# Env overrides: FFMPEG (ffmpeg binary with libvmaf built in; default: "ffmpeg" via $PATH),
#                FPS (default 24000/1001), CLIP (seconds, 60), SUB (n_subsample, 5),
#                THREADS (4), WORK (scratch dir -- transient, cleaned and reused for each
#                pair; durable per-pair output in folder mode is the single combined log
#                file written into the ENCODE directory instead), MODEL (force a specific
#                libvmaf model name, e.g. "vmaf_4k_v0.6.1" -- overrides auto-detection
#                below), MODEL_4K_MIN_WIDTH (auto-detection threshold, default 3800),
#                SIZE_SCOPE (default "video": the final Sizes line compares only the first
#                video stream's size on each side via a stream-copy remux to null, so a
#                source with retained audio/subtitle tracks isn't unfairly compared against
#                an encode that dropped them, or vice versa. Set to "total" for the old
#                behavior, a plain whole-file stat(). "video" costs an extra full read of
#                both files with no decode -- cheap next to --full's own double-decode, but
#                a real added cost in the default clip-sampling mode, especially over a
#                slow network mount or on a very large file.)
#
# VMAF model selection: different models predict different assumed viewing conditions (the
# default model predicts a 1080p TV at ~3x screen-height distance; vmaf_4k_v0.6.1 predicts a
# 4K TV at ~1.5x screen-height) and their scores are NOT comparable to each other. Unless
# MODEL is set explicitly, this script picks vmaf_4k_v0.6.1 automatically when the ORIGINAL
# file's native width is >= MODEL_4K_MIN_WIDTH, else the standard vmaf_v0.6.1. The choice is
# based on each pair's original raw resolution (before any CROP), since that's what
# determines the real viewing condition being modeled, not the encode's resolution or crop.
# In folder mode this is decided independently per pair, so a season mixing 1080p and 4K
# sources is handled correctly, but means mean/p1/min are not comparable across rows in the
# summary unless their "model" column matches.
#
# Uses frame-order timestamps (setpts=N/fps/TB) and checks alignment INDEPENDENTLY at each
# clip (not just once globally), since drift can start partway through a file even when the
# beginning is aligned. Each clip is scored with whichever of shift -2..+2 frames scores best
# on a quick 20s pre-check, so a localized one-frame drift doesn't silently corrupt that clip's
# score the way it would with a single global alignment check.
# Set CROP=W:H (e.g. CROP=1920:804) to center-crop BOTH files to the picture area, so
# letterbox bars left in an uncropped encode don't inflate its score. In folder mode CROP
# applies identically to every pair -- if episodes within a season have inconsistent crops,
# leave CROP unset and rely on the automatic per-pair crop/scale detection below instead.
# If the encode is cropped (e.g. HandBrake auto-crop of letterbox bars), the original is
# center-cropped to match; if it is scaled, the encode is scaled up to the original size.
# Set REF_CROP=W:H:X:Y to crop only the original at an exact position instead (what an
# encoder that cropped asymmetrically actually kept); it overrides both of the above.

set -u

FFMPEG=${FFMPEG:-ffmpeg}
FPS=${FPS:-24000/1001}
CLIP=${CLIP:-60}
SUB=${SUB:-5}
THREADS=${THREADS:-4}
WORK=${WORK:-./vmaf_compare_$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 4)}
MODEL_OVERRIDE=${MODEL:-}
MODEL_4K_MIN_WIDTH=${MODEL_4K_MIN_WIDTH:-3800}
SIZE_SCOPE=${SIZE_SCOPE:-video}

FULL=0
if [ "${1:-}" = "--full" ]; then FULL=1; shift; fi

if [ $# -lt 2 ]; then
  echo "usage: $0 [--full] ORIGINAL ENCODE [offset_seconds ...]"
  echo "  ORIGINAL/ENCODE may both be files (compare that pair) or both be directories"
  echo "  (compare every <name>.mkv in ORIGINAL's root against a same-named .mp4/.mkv in"
  echo "  ENCODE's root; not recursive)."
  exit 1
fi
ORIG=$1; ENC=$2; shift 2
if [ "$FULL" -eq 1 ] && [ $# -gt 0 ]; then
  echo "note: --full ignores the offset_seconds arguments ($*); scoring the whole file."
  shift $#
fi
EXPLICIT_OFFS=("$@")

[ -e "$ORIG" ] || { echo "not found: $ORIG"; exit 1; }
[ -e "$ENC" ]  || { echo "not found: $ENC"; exit 1; }
if [ -d "$ORIG" ] && [ -d "$ENC" ]; then
  BATCH=1
elif [ -f "$ORIG" ] && [ -f "$ENC" ]; then
  BATCH=0
else
  echo "ORIGINAL and ENCODE must both be files, or both be directories."
  echo "  ORIGINAL ($ORIG) is $([ -d "$ORIG" ] && echo a directory || echo a file)"
  echo "  ENCODE   ($ENC) is $([ -d "$ENC" ] && echo a directory || echo a file)"
  exit 1
fi

command -v "$FFMPEG" >/dev/null 2>&1 || { echo "ffmpeg not found: $FFMPEG (set FFMPEG=/path/to/ffmpeg-with-libvmaf, or put one on \$PATH)"; exit 1; }
"$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q libvmaf || echo "WARNING: '$FFMPEG -filters' does not list libvmaf; scoring will likely fail."
command -v python3 >/dev/null || { echo "python3 is required for the statistics"; exit 1; }

TS="setpts=N/(${FPS})/TB"

# duration in whole seconds, read via ffmpeg
dur() {
  "$FFMPEG" -hide_banner -i "$1" 2>&1 | awk '/Duration:/ {
    gsub(",", "", $2); split($2, t, ":"); printf "%d", t[1]*3600 + t[2]*60 + t[3]; exit }'
}

size_of() { "$FFMPEG" -hide_banner -i "$1" 2>&1 | grep -m1 'Video:' | grep -oE '[0-9]{3,5}x[0-9]{3,5}' | head -1; }

# video_stream_bytes <file>: size in KiB of the file's first video stream only.
#
# Tries mediainfo first, if installed: it reads container-structural/index info (e.g. a
# Matroska file's Cues/block sizes) rather than the stream data itself, so it's typically
# near-instant even on a huge file. Falls back to an ffmpeg stream-copy remux to null if
# mediainfo isn't available or gives no clean number -- that path is exact but requires a
# full sequential read of the whole file (no decode, but still real I/O), which is the slow
# path this was added to avoid. Deliberately NOT trusting any embedded metadata/statistics
# tags (e.g. NUMBER_OF_BYTES) as a shortcut here: some encoders/muxers pass such
# tags through unmodified even after re-encoding, which would silently report the SOURCE's
# original byte count for an ENCODE that is now a completely different size. mediainfo's
# StreamSize is computed from the file's actual current structure, not a copied-over tag,
# so it doesn't have that failure mode.
# Prints an integer (KiB), or nothing on failure. Diagnostics go to stderr so they don't
# pollute the captured value at the call site.
video_stream_bytes() {
  local f="$1" bytes
  if command -v mediainfo >/dev/null 2>&1; then
    bytes=$(mediainfo --Output="Video;%StreamSize%" "$f" 2>/dev/null | head -1 | tr -dc '0-9')
    if [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null; then
      echo "  video size via mediainfo (fast): $(basename "$f")" >&2
      echo $(( bytes / 1024 ))
      return 0
    fi
  fi
  echo "  video size via ffmpeg remux (slower -- mediainfo unavailable or gave no result): $(basename "$f")" >&2
  "$FFMPEG" -hide_banner -i "$f" -map 0:v:0 -c copy -f null - 2>&1 \
    | grep -oE 'video:[0-9]+ ?[kK]i?B' | tail -1 | grep -oE '[0-9]+'
}

# run_score <enc_trim> <ref_trim> <offset> <length> <subsample> [json_path]
# Trim prefixes are filter fragments like "trim=start_frame=1," (or empty). Reads ORIG,
# ENC, DSCALE, RCROP, MODEL, TS, THREADS from the caller's scope (score_pair's locals).
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

# summary_row <orig_file> <model> <mean> <p1> <min>  -- appended to SUMMARY_ROWS_FILE if
# set. Deliberately file-based rather than an in-memory array: score_pair runs on the
# left side of a pipe (`score_pair ... | tee -a "$LOGFILE"`), which bash executes in a
# subshell, so any array it mutated would be lost when that subshell exits. A file write
# is a real filesystem side effect and survives the subshell boundary correctly.
summary_row() {
  [ -n "${SUMMARY_ROWS_FILE:-}" ] || return 0
  printf "%-60s %-16s %8s %8s %8s\n" "$(basename "$1")" "$2" "$3" "$4" "$5" >> "$SUMMARY_ROWS_FILE"
}

# score_pair ORIG_FILE ENC_FILE
# Compares one pair. Reads FULL, EXPLICIT_OFFS, CLIP, SUB, WORK, SUMMARY_FILE from the
# enclosing scope. Prints the full report to stdout; appends one row to SUMMARY_FILE (if
# set) on both success and failure. Returns 0 on success, 1 if nothing could be scored.
score_pair() {
  local ORIG="$1" ENC="$2"
  local DO DE DIFF SO SE OW OH EW EH DSCALE RCROP MODEL
  local P10 P50 P90 S10 SC10 S50 SC50 S90 SC90 CHOSEN DT RT off
  local JSONS PYOUT PLABEL PMEAN PP1 PMIN so se

  mkdir -p "$WORK"
  rm -f "$WORK"/clip_*.json "$WORK/errors.log"

  DO=$(dur "$ORIG"); DE=$(dur "$ENC")
  if [ -z "$DO" ] || [ -z "$DE" ] || [ "$DO" -le 0 ] || [ "$DE" -le 0 ]; then
    echo "could not read durations (original='$DO' encode='$DE')"
    summary_row "$ORIG" "-" "FAILED" "-" "-"
    return 1
  fi
  DIFF=$(( DO > DE ? DO - DE : DE - DO ))
  echo "Original: $ORIG (${DO}s)"
  echo "Encode:   $ENC (${DE}s)"
  if [ "$DIFF" -gt 2 ]; then
    echo "WARNING: durations differ by ${DIFF}s. Frame-order pairing will drift and scores will be"
    echo "         unreliable (trimmed, different cut, or different frame rate?)."
  fi

  # ---- Frame sizes: handle cropped or scaled encodes ----
  SO=$(size_of "$ORIG"); SE=$(size_of "$ENC")
  OW=${SO%x*}; OH=${SO#*x}; EW=${SE%x*}; EH=${SE#*x}
  DSCALE=""; RCROP=""
  if [ -z "$SO" ] || [ -z "$SE" ]; then
    echo "WARNING: could not read frame sizes; assuming they match."
  elif [ "$SO" != "$SE" ]; then
    if [ "$EW" -le "$OW" ] && [ "$EH" -le "$OH" ]; then
      # The encode fits entirely within the original's frame on both axes -- this covers
      # letterboxing (EH<OH, EW=OW), pillarboxing (EW<OW, EH=OH), and a crop reduced on
      # both axes at once, all via the same centered crop. Previously this branch only
      # matched the letterbox case specifically, so a pillarboxed encode (bars on the
      # sides, e.g. 4:3 content auto-cropped from a 16:9 disc frame) fell through to the
      # scale-up branch below instead -- which is wrong for a real crop, and can silently
      # produce catastrophically low scores that look like a content/quality problem but
      # are actually just this comparison being set up incorrectly.
      RCROP="crop=${EW}:${EH},"
      echo "Encode is ${SE}, original ${SO}: center-cropping the original to match."
    else
      DSCALE="scale=${OW}:${OH}:flags=bicubic,"
      echo "Encode is ${SE}, original ${SO}: scaling the encode up to the original size."
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

  # Optional: the exact crop the encoder applied, as W:H:X:Y (ffmpeg crop order). Crops only
  # the ORIGINAL, at that exact offset, and overrides the automatic centered crop above --
  # needed when the crop isn't symmetric (e.g. top 264 / bottom 266), where a centered crop
  # would land a pixel off and quietly lower every score.
  if [ -n "${REF_CROP:-}" ]; then
    DSCALE=""; RCROP="crop=${REF_CROP},"
    echo "REF_CROP=${REF_CROP}: cropping the original at exactly that position."
  fi

  local OFFS=()
  if [ "$FULL" -eq 1 ]; then
    OFFS=()
  elif [ ${#EXPLICIT_OFFS[@]} -gt 0 ]; then
    OFFS=("${EXPLICIT_OFFS[@]}")
  else
    for p in 10 30 50 70 90; do
      off=$(( DO * p / 100 - CLIP / 2 )); [ "$off" -lt 0 ] && off=0
      OFFS+=("$off")
    done
  fi

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
  if [ ${#JSONS[@]} -eq 0 ]; then
    echo "no results"
    summary_row "$ORIG" "$MODEL" "FAILED" "-" "-"
    return 1
  fi

  echo
  PYOUT=$(python3 - "${JSONS[@]}" <<'EOF'
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
)
  echo "$PYOUT"
  echo "(model: ${MODEL} -- scores from different models are not directly comparable to each other)"
  read -r PLABEL PMEAN PP1 PMIN <<< "$(echo "$PYOUT" | grep -E '^[[:space:]]*pooled')"

  echo
  if [ "$SIZE_SCOPE" = "video" ]; then
    local vso vse
    vso=$(video_stream_bytes "$ORIG"); vse=$(video_stream_bytes "$ENC")
    if [ -n "$vso" ] && [ -n "$vse" ]; then
      awk -v o="$vso" -v e="$vse" -v d="$DE" 'BEGIN{
        printf "Sizes (video stream only): original %.2f GB, encode %.2f GB (%.0f%% of original), encode avg %.1f Mbps\n",
               o*1024/1e9, e*1024/1e9, 100*e/o, e*1024*8/d/1e6 }'
    else
      echo "WARNING: could not read per-stream video size; falling back to whole-file size."
      so=$(stat -c %s "$ORIG"); se=$(stat -c %s "$ENC")
      awk -v o="$so" -v e="$se" -v d="$DE" 'BEGIN{
        printf "Sizes (whole file, fallback): original %.2f GB, encode %.2f GB (%.0f%% of original), encode avg %.1f Mbps\n",
               o/1e9, e/1e9, 100*e/o, e*8/d/1e6 }'
    fi
  else
    so=$(stat -c %s "$ORIG"); se=$(stat -c %s "$ENC")
    awk -v o="$so" -v e="$se" -v d="$DE" 'BEGIN{
      printf "Sizes (whole file, all streams): original %.2f GB, encode %.2f GB (%.0f%% of original), encode avg %.1f Mbps\n",
             o/1e9, e/1e9, 100*e/o, e*8/d/1e6 }'
  fi
  echo "Logs and per-frame JSON: $WORK"

  summary_row "$ORIG" "$MODEL" "${PMEAN:-?}" "${PP1:-?}" "${PMIN:-?}"
  return 0
}

# ---- Build the list of pairs to process ----
PAIR_ORIG=(); PAIR_ENC=()
LOGFILE=""
SUMMARY_ROWS_FILE=""

if [ "$BATCH" -eq 1 ]; then
  ORIGDIR="$ORIG"; ENCDIR="$ENC"
  shopt -s nullglob
  for f in "$ORIGDIR"/*.mkv "$ORIGDIR"/*.MKV; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"; stem="${base%.*}"
    match=""
    for ext in mp4 mkv MP4 MKV; do
      if [ -f "$ENCDIR/$stem.$ext" ]; then match="$ENCDIR/$stem.$ext"; break; fi
    done
    if [ -z "$match" ]; then
      echo "SKIP: no matching encode found for '$base' in $ENCDIR"
      continue
    fi
    PAIR_ORIG+=("$f")
    PAIR_ENC+=("$match")
  done
  shopt -u nullglob

  if [ ${#PAIR_ORIG[@]} -eq 0 ]; then
    echo "no matching file pairs found between '$ORIGDIR' and '$ENCDIR'"
    exit 1
  fi

  LOGFILE="$ENCDIR/_vmaf_log.txt"
  : > "$LOGFILE"
  mkdir -p "$WORK"
  SUMMARY_ROWS_FILE="$WORK/_summary_rows.tmp"
  : > "$SUMMARY_ROWS_FILE"
  echo "Comparing ${#PAIR_ORIG[@]} pair(s). All output plus a summary table at the end will"
  echo "be written to: $LOGFILE  ($WORK is transient scratch, reused per episode.)"
else
  PAIR_ORIG=("$ORIG"); PAIR_ENC=("$ENC")
fi

# ---- Process each pair ----
FAILCOUNT=0
for i in "${!PAIR_ORIG[@]}"; do
  o="${PAIR_ORIG[$i]}"; e="${PAIR_ENC[$i]}"
  if [ "$BATCH" -eq 1 ]; then
    { echo; echo "==================================================================="
      echo "== $(basename "$o")"
      echo "==================================================================="
    } | tee -a "$LOGFILE"
  fi
  if [ -n "$LOGFILE" ]; then
    score_pair "$o" "$e" 2>&1 | tee -a "$LOGFILE"
    status=${PIPESTATUS[0]}
  else
    score_pair "$o" "$e"
    status=$?
  fi
  [ "$status" -ne 0 ] && FAILCOUNT=$((FAILCOUNT + 1))
done

if [ "$BATCH" -eq 1 ]; then
  {
    echo
    echo "==================================================================="
    echo "== Summary"
    echo "==================================================================="
    printf "%-60s %-16s %8s %8s %8s\n" "file" "model" "mean" "p1" "min"
    cat "$SUMMARY_ROWS_FILE"
    echo
    echo "Batch complete: ${#PAIR_ORIG[@]} pair(s) compared, ${FAILCOUNT} failed."
  } | tee -a "$LOGFILE"
  [ "$FAILCOUNT" -gt 0 ] && exit 1
  exit 0
else
  exit "$status"
fi
