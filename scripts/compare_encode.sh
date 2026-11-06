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
# GPU scoring (libvmaf_cuda): used automatically when an ffmpeg with libvmaf_cuda is found
#                (FFMPEG_CUDA, else FFMPEG); VMAF_CUDA=0 forces the CPU, VMAF_CUDA=1 warns if
#                it isn't available. The VMAF is then computed on the NVIDIA GPU instead of the
#                CPU. By default both files are also DECODED on the GPU (NVDEC), and the crop
#                or scale happens there too, so frames never touch the CPU: a full 43-minute
#                1080p episode takes ~3 minutes with almost no CPU, vs ~8-9 minutes and 6-7
#                cores on the CPU. Frame pairing and shift probing are unchanged. Needs an
#                ffmpeg built with libvmaf_cuda:
#                  FFMPEG_CUDA  (default /opt/ffmpeg-cuda/bin/ffmpeg; FFMPEG is still used for
#                               durations, sizes and the CPU path)
#                  CUDA_FMT     how frames reach the GPU filter, which only takes 8-bit 4:2:0
#                               or 16-bit 4:4:4:
#                                 yuv444p16 (default): uploaded as 10-bit 4:2:0 and widened on
#                                   the GPU; keeps the 10-bit precision the CPU path uses
#                                   (VMAF only looks at luma, so the 4:4:4 doesn't change it)
#                                 yuv420p: everything converted to 8-bit on the CPU first
#                  CUDA_DEVICE  GPU index (default 0)
#                  CUDA_DECODE  unset (default): decode on the GPU, except a VC-1 original,
#                               which decodes on the CPU (the GPU's VC-1 decoder lands a frame
#                               off after some seeks); its encode still decodes on the GPU.
#                               1: decode both on the GPU, VC-1 too. 0: decode, crop and convert
#                               both on the CPU and upload finished frames (slower).
#                               GPU decoding is also skipped automatically for a pair whose
#                               crop it can't do (odd crop values, unknown codec).
#                If a GPU step fails it falls back, with a note: GPU decoding -> CPU decoding
#                with GPU scoring -> all CPU; after 2 failures in a pair the failing mode is
#                skipped for the rest of it, so a night's batch doesn't stop over it. GPU and CPU scores can differ slightly;
#                check a few titles both ways before relying on fixed thresholds.
#                THREADS doesn't apply to the GPU path; SUB (n_subsample) does.
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
# beginning is aligned. Each clip is scored with whichever shift (-2..+2 frames, further if the best is at an edge) scores best
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
VMAF_CUDA=${VMAF_CUDA:-auto}
FFMPEG_CUDA=${FFMPEG_CUDA:-/opt/ffmpeg-cuda/bin/ffmpeg}
CUDA_FMT=${CUDA_FMT:-yuv444p16}
CUDA_DEVICE=${CUDA_DEVICE:-0}
CUDA_DECODE_SET=${CUDA_DECODE:+1}   # set explicitly: it also overrides the VC-1 rule below
CUDA_DECODE=${CUDA_DECODE:-1}

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
# GPU scoring: auto (default) uses it whenever an ffmpeg with libvmaf_cuda is found (FFMPEG_CUDA,
# else FFMPEG itself); 1 = required (warns if missing); 0 = always CPU.
case "$VMAF_CUDA" in
  0) ;;
  1|auto)
    case "$CUDA_FMT" in yuv444p16|yuv420p) ;; *) echo "CUDA_FMT must be yuv444p16 or yuv420p (got '$CUDA_FMT')"; exit 1 ;; esac
    cuda_ff=""
    for cand in "$FFMPEG_CUDA" "$FFMPEG"; do
      if command -v "$cand" >/dev/null 2>&1 && "$cand" -hide_banner -filters 2>/dev/null | grep -q 'libvmaf_cuda'; then
        cuda_ff="$cand"; break
      fi
    done
    if [ -n "$cuda_ff" ]; then
      FFMPEG_CUDA="$cuda_ff"; VMAF_CUDA=1
    else
      [ "$VMAF_CUDA" = "1" ] && echo "WARNING: VMAF_CUDA=1 but no ffmpeg with libvmaf_cuda was found ($FFMPEG_CUDA, $FFMPEG); scoring on the CPU instead."
      VMAF_CUDA=0
    fi ;;
  *) echo "VMAF_CUDA must be auto, 1 or 0 (got '$VMAF_CUDA')"; exit 1 ;;
esac

TS="setpts=N/(${FPS})/TB"
# REF_CFR: put the ORIGINAL's frames on a constant grid (fps filter: a frame repeated
# over a timestamp gap, dropped where frames come too fast) before pairing them by order, the
# way NVEncC's --avsync cfr made the encode. For originals with irregular timestamps (a DVD's
# cell gaps, a section at another rate): without it the pairs slip a frame at each irregularity.
#   auto (default): off, but in --full mode, when the shift differs across the file, the check
#                   is redone with it on, and used if that makes the shift consistent
#   1: always on;  0: never
# The grid is the rate the ENCODE's frames actually run at (it's constant: the encoder made it so):
# its frame count over its duration, snapped to a standard rate. Not FPS, which comes from the
# original and can be its container's nominal rate (30000/1001 for a DVD whose film frames run at
# 24000/1001), nor the encode's own label (NVEncC's MKVs say 24/1 for 23.976 frames). Counting
# reads the encode's whole file (no decode), so it's only done when the grid is needed.
REF_CFR=${REF_CFR:-auto}
RFPS=""
grid_fps() {
  local n d
  n=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$1" 2>/dev/null | head -1)
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -1)
  awk -v n="$n" -v d="$d" -v fb="$FPS" 'BEGIN {
    if (n + 0 <= 0 || d + 0 <= 0) { print fb; exit }
    r = n / d; m = split("24000/1001 24/1 25/1 30000/1001 30/1 48/1 50/1 60000/1001 60/1", c, " ")
    for (i = 1; i <= m; i++) { split(c[i], p, "/"); v = p[1] / p[2]; if (r > v * 0.9995 && r < v * 1.0005) { print c[i]; exit } }
    printf "%d/1000\n", r * 1000 + 0.5 }'
}

# duration in whole seconds, read via ffmpeg
dur() {
  "$FFMPEG" -hide_banner -i "$1" 2>&1 | awk '/Duration:/ {
    gsub(",", "", $2); split($2, t, ":"); printf "%d", t[1]*3600 + t[2]*60 + t[3]; exit }'
}

size_of() { "$FFMPEG" -hide_banner -i "$1" 2>&1 | grep -m1 'Video:' | grep -oE '[0-9]{3,5}x[0-9]{3,5}' | head -1; }
vcodec_of() { "$FFMPEG" -hide_banner -i "$1" 2>&1 | grep -m1 'Video:' | sed -E 's/.*Video: ([a-z0-9]+).*/\1/'; }

# gpu_crop_args "W:H[:X:Y]" <frame_w> <frame_h> <file>: NVDEC decoder options that crop the
# file's frames to W:H at X:Y (centered if X:Y omitted), e.g. "-c:v h264_cuvid -crop 140x140x0x0"
# (top x bottom x left x right). Prints nothing and fails if it can't (odd values, unknown codec).
gpu_crop_args() {
  local spec="${1%,}" fw="$2" fh="$3" f="$4" w h x y t b l r dec
  IFS=: read -r w h x y <<< "$spec"
  [ -z "${x:-}" ] && x=$(( (fw - w) / 2 ))
  [ -z "${y:-}" ] && y=$(( (fh - h) / 2 ))
  t=$y; b=$(( fh - h - y )); l=$x; r=$(( fw - w - x ))
  for v in "$t" "$b" "$l" "$r"; do
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    [ $(( v % 2 )) -eq 0 ] || return 1
  done
  case "$(vcodec_of "$f")" in
    h264) dec=h264_cuvid ;; hevc) dec=hevc_cuvid ;; vc1) dec=vc1_cuvid ;;
    mpeg2video) dec=mpeg2_cuvid ;; av1) dec=av1_cuvid ;; vp9) dec=vp9_cuvid ;; *) return 1 ;;
  esac
  echo "-c:v $dec -crop ${t}x${b}x${l}x${r}"
}

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

# Where the video starts relative to the file's own start (what ffmpeg's -ss counts from), in
# seconds. Usually 0; non-zero when another track starts first or a remux shifted the video.
video_rel_start() {
  local v f
  v=$(ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1)
  f=$(ffprobe -v error -show_entries format=start_time -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1)
  awk -v v="$v" -v f="$f" 'BEGIN { if (v == "" || v == "N/A") v = 0; if (f == "" || f == "N/A") f = 0; printf "%.6f", v - f }'
}

# Frames missing from the start of the encode, when the original starts mid-sequence (e.g. an
# episode cut out of one long stream on the disc): its first frames need the previous scene to
# decode, so decoders and the encoder throw them away, and the encode's first frame is a later
# one of the original's. Found from the evidence: the original shows N frames before its first
# keyframe, and the encode has fewer frames than the original; the smaller of the two is the
# number dropped at the start. Prints "<frames> <seconds>"; "0 0" when none.
lead_offset() {
  local orig="$1" enc="$2" rate so se lead
  rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$orig" 2>/dev/null | head -1)
  lead=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#300" -show_entries packet=pts_time,flags -of csv=p=0 "$orig" 2>/dev/null \
    | awk -F, -v rate="$rate" 'BEGIN { split(rate, r, "/"); fd = (r[2] ? r[2] : 1) / r[1] }
        $1 == "N/A" { next }
        { n++; pts[n] = $1 + 0; if (!k && index($2, "K")) { k = n; kp = $1 + 0 } }
        END { c = 0; if (k) for (i = 1; i <= n; i++) if (pts[i] < kp - fd / 4) c++; print c }')
  if [ -z "$lead" ] || [ "$lead" -le 0 ]; then echo "0 0"; return; fi
  so=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$orig" 2>/dev/null | head -1)
  se=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$enc" 2>/dev/null | head -1)
  awk -v so="$so" -v se="$se" -v lead="$lead" -v rate="$rate" 'BEGIN {
    split(rate, r, "/"); fd = (r[2] ? r[2] : 1) / r[1]
    d = so - se; if (so == "" || se == "" || d <= 0) { print "0 0"; exit }
    if (d > lead) d = lead
    printf "%d %.6f", d, d * fd }'
}

# The -ss position for offset <off> in a file whose video starts <vrel> seconds in: half a frame
# before the frame nearest <off>, counted from that file's first frame. Seeking by plain time
# picks "the first frame at or after <off>", and when a frame sits within a few milliseconds of
# <off>, two files whose timestamps differ by a few ms (a remux, rounding) start on different
# frames, which looks like a one-frame shift at that offset only. Half a frame of margin
# makes both start on the same frame. <off> 0 is the first frame (0 when the video starts at 0).
seek_pos() {
  local vrel="$1" off="$2"
  awk -v r="$vrel" -v o="$off" -v fps="$FPS" 'BEGIN {
    n = split(fps, p, "/"); f = (n == 2 && p[2] + 0 > 0) ? p[1] / p[2] : p[1] + 0
    if (o + 0 < 0) o = 0
    if (f <= 0) { print (o + 0 > 0 ? o : 0); exit }
    k = int(o * f + 0.5); t = r + (k - 0.5) / f; if (t < 0) t = 0
    printf "%.6f", t }'
}

# run_score <enc_trim> <ref_trim> <offset> <length> <subsample> [json_path]
# Trim prefixes are filter fragments like "trim=start_frame=1," (or empty). Reads ORIG,
# ENC, DSCALE, RCROP, MODEL, TS, THREADS from the caller's scope (score_pair's locals).
run_score() {
  local dt="$1" rt="$2" off="$3" len="$4" sub="$5" json="${6:-}"
  local fails=0 dfails=0
  [ -s "$WORK/.cuda_fallbacks" ] && fails=$(wc -l < "$WORK/.cuda_fallbacks")
  [ -s "$WORK/.gpudec_fallbacks" ] && dfails=$(wc -l < "$WORK/.gpudec_fallbacks")
  # after 2 failures of a mode, the rest of this pair skips it
  if [ "$VMAF_CUDA" = "1" ] && [ "$GPUDEC" = "2" ] && [ "$dfails" -lt 2 ]; then
    run_score_mixed "$@" && return 0
    echo "NOTE: GPU decoding of the encode failed for this step; redoing it with CPU decoding." >&2
    echo x >> "$WORK/.gpudec_fallbacks"
    [ -n "$json" ] && rm -f "$json"
  fi
  if [ "$VMAF_CUDA" = "1" ] && [ "$GPUDEC" = "1" ] && [ "$dfails" -lt 2 ]; then
    run_score_gpudec "$@" && return 0
    echo "NOTE: GPU decoding failed for this step; redoing it with CPU decoding." >&2
    echo x >> "$WORK/.gpudec_fallbacks"
    [ -n "$json" ] && rm -f "$json"
  fi
  if [ "$VMAF_CUDA" = "1" ] && [ "$fails" -lt 2 ]; then
    run_score_cuda "$@" && return 0
    echo "NOTE: GPU scoring (libvmaf_cuda) failed for this step; redoing it on the CPU." >&2
    echo x >> "$WORK/.cuda_fallbacks"
    [ -n "$json" ] && rm -f "$json"
  fi
  local opts="n_subsample=${sub}:n_threads=${THREADS}:model=version=${MODEL}"
  [ -n "$json" ] && opts="${opts}:log_fmt=json:log_path=${json}"
  "$FFMPEG" -hide_banner -nostats -nostdin \
    -ss "$(seek_pos "$ENC_VREL" "$off")" -t "$len" -i "$ENC" \
    -ss "$(seek_pos "$ORIG_VREL" "$off")" -t "$len" -i "$ORIG" -an -sn \
    -lavfi "[0:v:0]${dt}${DSCALE}${TS},format=yuv420p10le[d];[1:v:0]${RFPS}${rt}${RCROP}${TS},format=yuv420p10le[r];[d][r]libvmaf=${opts}" \
    -f null -
}

# Same comparison with the VMAF computed on the GPU. Everything up to the final pixel format
# runs on the CPU exactly as in run_score; then both streams are uploaded to one CUDA device
# (shared by both inputs, as libvmaf_cuda expects) and converted there if needed.
run_score_cuda() {
  local dt="$1" rt="$2" off="$3" len="$4" sub="$5" json="${6:-}"
  local opts="n_subsample=${sub}:model=version=${MODEL}"
  [ -n "$json" ] && opts="${opts}:log_fmt=json:log_path=${json}"
  local up
  if [ "$CUDA_FMT" = "yuv420p" ]; then
    up="format=yuv420p,hwupload"
  else
    up="format=p010le,hwupload,scale_cuda=format=yuv444p16"
  fi
  "$FFMPEG_CUDA" -hide_banner -nostats -nostdin \
    -init_hw_device "cuda=vmafgpu:${CUDA_DEVICE}" -filter_hw_device vmafgpu \
    -ss "$(seek_pos "$ENC_VREL" "$off")" -t "$len" -i "$ENC" \
    -ss "$(seek_pos "$ORIG_VREL" "$off")" -t "$len" -i "$ORIG" -an -sn \
    -lavfi "[0:v:0]${dt}${DSCALE}${TS},${up}[d];[1:v:0]${RFPS}${rt}${RCROP}${TS},${up}[r];[d][r]libvmaf_cuda=${opts}" \
    -f null -
  local rc=$?
  [ $rc -eq 0 ] && [ -n "$json" ] && [ ! -s "$json" ] && rc=1
  return $rc
}

# The encode decoded on the GPU (as in run_score_gpudec) and the original on the CPU (as in
# run_score_cuda: cropped there, then uploaded), both handed to libvmaf_cuda on one device.
run_score_mixed() {
  local dt="$1" rt="$2" off="$3" len="$4" sub="$5" json="${6:-}"
  local opts="n_subsample=${sub}:model=version=${MODEL}"
  [ -n "$json" ] && opts="${opts}:log_fmt=json:log_path=${json}"
  local up
  if [ "$CUDA_FMT" = "yuv420p" ]; then up="format=yuv420p,hwupload"
  else up="format=p010le,hwupload,scale_cuda=format=yuv444p16"; fi
  "$FFMPEG_CUDA" -hide_banner -nostats -nostdin \
    -init_hw_device "cuda=vmafgpu:${CUDA_DEVICE}" -filter_hw_device vmafgpu \
    "${DGPU[@]}" -hwaccel_device vmafgpu -ss "$(seek_pos "$ENC_VREL" "$off")" -t "$len" -i "$ENC" \
    -ss "$(seek_pos "$ORIG_VREL" "$off")" -t "$len" -i "$ORIG" -an -sn \
    -lavfi "[0:v:0]${dt}${DGPU_SCALE}${TS},scale_cuda=format=${CUDA_FMT}[d];[1:v:0]${RFPS}${rt}${RCROP}${TS},${up}[r];[d][r]libvmaf_cuda=${opts}" \
    -f null -
  local rc=$?
  [ $rc -eq 0 ] && [ -n "$json" ] && [ ! -s "$json" ] && rc=1
  return $rc
}

# Everything on the GPU: NVDEC decodes both files (cropping in the decoder if needed), the
# encode is scaled there if needed, frame pairing (trim/setpts) only touches timestamps, and
# scale_cuda converts both to CUDA_FMT for libvmaf_cuda. Uses DGPU / RGPU (decoder options)
# and DGPU_SCALE from score_pair.
run_score_gpudec() {
  local dt="$1" rt="$2" off="$3" len="$4" sub="$5" json="${6:-}"
  local opts="n_subsample=${sub}:model=version=${MODEL}"
  [ -n "$json" ] && opts="${opts}:log_fmt=json:log_path=${json}"
  "$FFMPEG_CUDA" -hide_banner -nostats -nostdin \
    "${DGPU[@]}" -ss "$(seek_pos "$ENC_VREL" "$off")" -t "$len" -i "$ENC" \
    "${RGPU[@]}" -ss "$(seek_pos "$ORIG_VREL" "$off")" -t "$len" -i "$ORIG" -an -sn \
    -lavfi "[0:v:0]${dt}${DGPU_SCALE}${TS},scale_cuda=format=${CUDA_FMT}[d];[1:v:0]${RFPS}${rt}${TS},scale_cuda=format=${CUDA_FMT}[r];[d][r]libvmaf_cuda=${opts}" \
    -f null -
  local rc=$?
  [ $rc -eq 0 ] && [ -n "$json" ] && [ ! -s "$json" ] && rc=1
  return $rc
}

quick() {  # prints mean VMAF or nothing
  run_score "$1" "$2" "$3" 20 4 2>&1 | grep -o 'VMAF score: [0-9.]*' | awk '{print $3}'
}

# ---- Alignment probing (shared by per-clip mode and --full mode) ----
# Tries shift -2..+2 frames (and further past an edge while it improves) on a quick 20s window at a given offset and reports which
# scores best. Prints "<best_shift> <best_score>" on stdout; diagnostics go to stderr.
probe_shift() {
  local off="$1"
  local best_shift=0 best_score=-1 s score dir lim second=-1
  local results=""
  for s in 0 1 2 -1 -2; do
    if [ "$s" -ge 0 ]; then dt="trim=start_frame=$s,setpts=PTS-STARTPTS,"; rt=""
    else                    dt=""; rt="trim=start_frame=$(( -s )),setpts=PTS-STARTPTS,"; fi
    score=$(quick "$dt" "$rt" "$off")
    [ -z "$score" ] && score=0
    results="${results}${s}:${score} "
    if awk -v sc="$score" -v best="$best_score" 'BEGIN{exit !(sc>best)}'; then second=$best_score; best_score=$score; best_shift=$s
    elif awk -v sc="$score" -v b="$second" 'BEGIN{exit !(sc>b)}'; then second=$score; fi
  done
  # Best at an edge: keep going that way while it improves (up to SHIFT_MAX frames), so an
  # offset a little bigger than expected is found instead of scored wrong.
  if [ "$best_shift" = 2 ] || [ "$best_shift" = -2 ]; then
    dir=$(( best_shift > 0 ? 1 : -1 )); s=$best_shift; lim=${SHIFT_MAX:-30}
    while [ $(( s * dir )) -lt "$lim" ]; do
      s=$(( s + dir ))
      if [ "$s" -ge 0 ]; then dt="trim=start_frame=$s,setpts=PTS-STARTPTS,"; rt=""
      else                    dt=""; rt="trim=start_frame=$(( -s )),setpts=PTS-STARTPTS,"; fi
      score=$(quick "$dt" "$rt" "$off")
      [ -z "$score" ] && score=0
      results="${results}${s}:${score} "
      awk -v sc="$score" -v best="$best_score" 'BEGIN{exit !(sc>best)}' || break
      second=$best_score; best_score=$score; best_shift=$s
    done
    if [ $(( best_shift * dir )) -ge "$lim" ]; then
      echo "  WARNING: the best shift at ${off}s is at the search limit (${best_shift}); the real offset may be bigger." >&2
    fi
  fi
  echo "  shift scores @ ${off}s: ${results}-> best shift ${best_shift} (score ${best_score})" >&2
  echo "$best_shift $best_score $second"
}

# probe_shift_from_start <seconds> <shift>...: like probe_shift, but decoding both files from
# their very first frame (no seek) and scoring a 20s window <seconds> in, for the given shifts
# only. That's how the whole-file score decodes; in a few files (VC-1 especially) seeking lands
# one frame off from it, and when the opening is static or dark a window at 0s can't tell the
# shifts apart. Costs decoding <seconds> of both files per shift. Prints "<best> <score> <second>".
probe_shift_from_start() {
  local at="$1"; shift
  local k s score best_shift="" best_score=-1 second=-1 results="" dt rt
  # (the frame count to skip, from the rate the frames really run at: FPS can be a DVD's nominal
  # 30000/1001 for 24000/1001 frames, which would skip past the window)
  k=$(awk -v t="$at" -v fps="${REALFPS:-$FPS}" 'BEGIN { n = split(fps, p, "/"); f = (n == 2 && p[2] + 0 > 0) ? p[1] / p[2] : p[1] + 0; printf "%d", t * f }')
  for s in "$@"; do
    if [ "$s" -ge 0 ]; then dt="trim=start_frame=$(( k + s )),setpts=PTS-STARTPTS,"; rt="trim=start_frame=${k},setpts=PTS-STARTPTS,"
    else                    dt="trim=start_frame=${k},setpts=PTS-STARTPTS,"; rt="trim=start_frame=$(( k - s )),setpts=PTS-STARTPTS,"; fi
    score=$(run_score "$dt" "$rt" 0 $(( at + 20 )) 4 2>&1 | grep -o 'VMAF score: [0-9.]*' | awk '{print $3}')
    [ -z "$score" ] && score=0
    results="${results}${s}:${score} "
    if awk -v sc="$score" -v best="$best_score" 'BEGIN{exit !(sc>best)}'; then second=$best_score; best_score=$score; best_shift=$s
    elif awk -v sc="$score" -v b="$second" 'BEGIN{exit !(sc>b)}'; then second=$score; fi
  done
  echo "  shift scores from the start, ${at}s in (no seek): ${results}-> best shift ${best_shift} (score ${best_score})" >&2
  echo "$best_shift $best_score $second"
}

# clear_win <best> <next best>: whether a from-the-start check picked a shift clearly. A score of
# 90+ that's 5+ ahead, or 70+ that's 10+ ahead. (Busy, detailed picture separates shifts by 30-50
# points; flat animation only by ~8-10, as a neighbouring frame looks much the same.)
clear_win() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a >= 90 && a - b >= 5) || (a >= 70 && a - b >= 10)) }'; }

# Given a frame-shift integer, echoes "<enc_trim>|<ref_trim>" filter-chain fragments (either
# may be empty) that compensate for it. Read back with: IFS='|' read -r DT RT. (A space as the
# separator loses an empty first field, which put a negative shift's trim on the wrong file.)
trim_for_shift() {
  local shift="$1"
  if [ "$shift" -gt 0 ]; then
    echo "trim=start_frame=$shift,setpts=PTS-STARTPTS,|"
  elif [ "$shift" -lt 0 ]; then
    echo "|trim=start_frame=$(( -shift )),setpts=PTS-STARTPTS,"
  else
    echo "|"
  fi
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
  # (per pair: a constant grid found for one pair in folder mode isn't carried to the next)
  local GRID=""
  REALFPS=""   # the encode's measured frame rate, once something needs it (grid_fps)
  RFPS=""; if [ "$REF_CFR" = "1" ]; then GRID=$(grid_fps "$ENC"); REALFPS=$GRID; RFPS="fps=${GRID},"; echo "REF_CFR=1: the original's frames are put on a constant ${GRID} grid (the encode's frame rate)."; fi
  local ORIG="$1" ENC="$2"
  local DO DE DIFF SO SE OW OH EW EH DSCALE RCROP MODEL GPUDEC DGPU_SCALE GPUDEC_WHY ga
  local DGPU=() RGPU=()
  local P10 P50 P90 S10 SC10 S50 SC50 S90 SC90 CHOSEN DT RT off
  local JSONS PYOUT PLABEL PMEAN PP1 PMIN so se ENC_VREL ORIG_VREL LEADN LEADS

  mkdir -p "$WORK"
  rm -f "$WORK"/clip_*.json "$WORK/errors.log" "$WORK/.cuda_fallbacks" "$WORK/.gpudec_fallbacks"

  DO=$(dur "$ORIG"); DE=$(dur "$ENC")
  if [ -z "$DO" ] || [ -z "$DE" ] || [ "$DO" -le 0 ] || [ "$DE" -le 0 ]; then
    echo "could not read durations (original='$DO' encode='$DE')"
    summary_row "$ORIG" "-" "FAILED" "-" "-"
    return 1
  fi
  DIFF=$(( DO > DE ? DO - DE : DE - DO ))
  ENC_VREL=$(video_rel_start "$ENC"); ORIG_VREL=$(video_rel_start "$ORIG")
  echo "Original: $ORIG (${DO}s)"
  echo "Encode:   $ENC (${DE}s)"
  read -r LEADN LEADS <<< "$(lead_offset "$ORIG" "$ENC")"
  if [ "${LEADN:-0}" -gt 0 ]; then
    ORIG_VREL=$(awk -v a="$ORIG_VREL" -v b="$LEADS" 'BEGIN { printf "%.6f", a + b }')
    printf "The original starts mid-sequence: its first %d frame(s) (%.3f s) can't be decoded and aren't in the\n" "$LEADN" "$LEADS"
    echo "  encode, so the encode is lined up with the original from the frame after them."
  fi
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
    local rcw rch
    IFS=: read -r rcw rch _ <<< "$REF_CROP"
    if [ -n "$SE" ] && [ "${rcw}x${rch}" != "$SE" ]; then
      echo "ERROR: REF_CROP crops the original to ${rcw}x${rch}, but the encode is ${SE}. Use the crop"
      echo "       this encode was made with (Width:Height:Left:Top, e.g. from its .crop.json)."
      summary_row "$ORIG" "$MODEL" "FAILED" "-" "-"
      return 1
    fi
  fi

  # ---- GPU decoding plan: the same crop / scale, done by NVDEC and scale_cuda ----
  # GPUDEC: 0 = both decoded on the CPU, 1 = both on the GPU, 2 = the encode on the GPU and
  # the original on the CPU (a VC-1 original: after a seek, the GPU's VC-1 decoder sometimes
  # starts a frame off, differently from point to point, so the alignment checks disagree;
  # the CPU decoder is consistent). CUDA_DECODE=1 set explicitly forces 1 for VC-1 too.
  GPUDEC=0; DGPU_SCALE=""; GPUDEC_WHY=""
  if [ "$VMAF_CUDA" = "1" ] && [ "$CUDA_DECODE" = "1" ]; then
    GPUDEC=1
    if [ -z "$CUDA_DECODE_SET" ] && [ "$(vcodec_of "$ORIG")" = "vc1" ]; then
      GPUDEC=2; GPUDEC_WHY="the original is VC-1 (the GPU decoder seeks inconsistently in VC-1)"
    fi
    DGPU=(-hwaccel cuda -hwaccel_output_format cuda); RGPU=(-hwaccel cuda -hwaccel_output_format cuda)
    case "$DSCALE" in
      scale=*) DGPU_SCALE="scale_cuda=w=${OW}:h=${OH}:interp_algo=bicubic," ;;
      crop=*)  if ga=$(gpu_crop_args "${DSCALE#crop=}" "$EW" "$EH" "$ENC"); then DGPU+=($ga)
               else GPUDEC=0; GPUDEC_WHY="the encode's crop (${DSCALE%,}) can't be done in the GPU decoder"; fi ;;
    esac
    if [ "$GPUDEC" = "1" ]; then
      case "$RCROP" in
        crop=*)  if ga=$(gpu_crop_args "${RCROP#crop=}" "$OW" "$OH" "$ORIG"); then RGPU+=($ga)
                 else GPUDEC=0; GPUDEC_WHY="the original's crop (${RCROP%,}) can't be done in the GPU decoder"; fi ;;
      esac
    fi
  fi
  if [ "$VMAF_CUDA" = "1" ] && [ "$GPUDEC" = "1" ]; then
    echo "VMAF engine: libvmaf_cuda on GPU ${CUDA_DEVICE}, decoding on the GPU (frames as ${CUDA_FMT}, n_subsample=${SUB}) via ${FFMPEG_CUDA}"
  elif [ "$VMAF_CUDA" = "1" ] && [ "$GPUDEC" = "2" ]; then
    echo "VMAF engine: libvmaf_cuda on GPU ${CUDA_DEVICE}, decoding the encode on the GPU and the original on the CPU because ${GPUDEC_WHY} (frames as ${CUDA_FMT}, n_subsample=${SUB}) via ${FFMPEG_CUDA}"
  elif [ "$VMAF_CUDA" = "1" ]; then
    echo "VMAF engine: libvmaf_cuda on GPU ${CUDA_DEVICE}, decoding on the CPU$([ -n "$GPUDEC_WHY" ] && echo " because ${GPUDEC_WHY}") (frames as ${CUDA_FMT}, n_subsample=${SUB}) via ${FFMPEG_CUDA}"
  else
    echo "VMAF engine: libvmaf on the CPU (${THREADS} threads, n_subsample=${SUB})"
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
    read -r S10 SC10 _ <<< "$(probe_shift "$P10")"
    read -r S50 SC50 _ <<< "$(probe_shift "$P50")"
    read -r S90 SC90 _ <<< "$(probe_shift "$P90")"
    echo "  10%: shift ${S10} (score ${SC10})   50%: shift ${S50} (score ${SC50})   90%: shift ${S90} (score ${SC90})"
    if ! { [ "$S10" = "$S50" ] && [ "$S50" = "$S90" ]; } && [ "$REF_CFR" = "auto" ] && [ -z "$RFPS" ]; then
      [ -z "$REALFPS" ] && REALFPS=$(grid_fps "$ENC")
      GRID=$REALFPS
      echo "  -> the shift differs across the file. The original may have irregular timestamps (gaps, or a section at another rate) that the encoder evened out (--avsync cfr); re-checking with the original's frames put on a constant ${GRID} grid (the encode's frame rate) ..."
      RFPS="fps=${GRID},"
      read -r T10 TC10 _ <<< "$(probe_shift "$P10")"
      read -r T50 TC50 _ <<< "$(probe_shift "$P50")"
      read -r T90 TC90 _ <<< "$(probe_shift "$P90")"
      echo "  10%: shift ${T10} (score ${TC10})   50%: shift ${T50} (score ${TC50})   90%: shift ${T90} (score ${TC90})   (constant grid)"
      # Used only if it lines up as well as the original's own timestamps did where those lined
      # up (a wrong grid can look consistent while matching badly everywhere).
      if [ "$T10" = "$T50" ] && [ "$T50" = "$T90" ] && awk -v a="$TC10" -v b="$TC50" -v c="$TC90" -v x="$SC10" -v y="$SC50" -v z="$SC90" 'BEGIN {
           lo = a; if (b < lo) lo = b; if (c < lo) lo = c; best = x; if (y > best) best = y; if (z > best) best = z
           exit !(lo >= best - 5) }'; then
        echo "  -> consistent on a constant grid: the original's timestamps are irregular, so it's scored that way (REF_CFR)."
        S10=$T10; SC10=$TC10; S50=$T50; SC50=$TC50; S90=$T90; SC90=$TC90
      else
        echo "  -> no better on a constant grid; back to the original's own timestamps."
        RFPS=""
      fi
    fi

    local BOUNDS=() SEGSH=()
    if [ "$S10" = "$S50" ] && [ "$S50" = "$S90" ]; then
      echo "  -> consistent shift (${S10}) at all three points; applying it across the whole file."
      CHOSEN=$S10
      # The whole-file score decodes from the very first frame, without seeking. A few sources
      # (VC-1 especially) come out one frame different that way than after a seek, so check the
      # shift at the start too and score with it, when the start can tell shifts apart (a clear
      # winner). A static or dark opening can't: then the two candidates are compared decoding
      # from the start (no seek) a few minutes in, where there's picture to compare.
      read -r S0 SC0 SC0b <<< "$(probe_shift 0)"
      if [ "$S0" != "$CHOSEN" ]; then
        if awk -v a="$SC0" -v b="$SC0b" 'BEGIN { exit !(a >= 70 && a - b >= 10) }'; then
          echo "  -> from the very start it lines up at shift ${S0} (score ${SC0}); decoding from the start differs from seeking in this file, so the whole file is scored with ${S0}."
          CHOSEN=$S0
        else
          local AT=$(( P10 < 600 ? P10 : 600 ))
          # The candidates: the seek-measured shift and its neighbours (a weak start's pick is
          # noise; VC-1's from-the-start shift is usually one more than after a seek), plus that
          # pick if it's further away.
          local CANDS=("$CHOSEN" $(( CHOSEN + 1 )) $(( CHOSEN - 1 )))
          [ "$S0" -gt $(( CHOSEN + 1 )) ] || [ "$S0" -lt $(( CHOSEN - 1 )) ] && CANDS+=("$S0")
          echo "  -> the start suggests shift ${S0}, but too weakly to tell (score ${SC0}, next best ${SC0b}); comparing shifts ${CANDS[*]} decoding from the start, ${AT}s in ..."
          [ -z "$REALFPS" ] && REALFPS=$(grid_fps "$ENC")
          read -r SD SCD SCDb <<< "$(probe_shift_from_start "$AT" "${CANDS[@]}")"
          if [ -n "$SD" ] && clear_win "$SCD" "$SCDb"; then
            if [ "$SD" != "$CHOSEN" ]; then
              echo "  -> decoding from the start it lines up at shift ${SD} (score ${SCD}); the whole file is scored with ${SD}."
            else
              echo "  -> decoding from the start it lines up at shift ${SD} too (score ${SCD}); keeping it."
            fi
            CHOSEN=$SD
          else
            echo "  WARNING: decoding from the start didn't settle it either (score ${SCD}, next best ${SCDb}); keeping ${CHOSEN}. If the score below is very low, the shift is likely wrong."
          fi
        fi
      fi
      # Where the encode starts in the original, for syncing its audio (Encode-Batch reads this):
      # from the shift the whole file is scored with, as that's how a player (and the encoder)
      # decodes it, from the start.
      echo "Start: the encode's first frame is the original's frame $(( ${LEADN:-0} - CHOSEN )) (measured)"
    else
      # Drift: the encode gained or lost a frame somewhere (a frame the encoder repeated or
      # dropped). Find each place the shift changes (halving the gap between two checks that
      # disagree, down to ~20s) and score each part of the file with its own shift.
      echo "  -> alignment differs across the file (10%=${S10}, 50%=${S50}, 90%=${S90}): the encode gains or loses a frame somewhere. Finding where, to score each part with its own shift ..."
      local PTS=("$P10" "$P50" "$P90") SHS=("$S10" "$S50" "$S90") ok=1 i lo hi mid SM a b
      SEGSH=("$S10")
      for i in 0 1; do
        a=${SHS[$i]}; b=${SHS[$((i + 1))]}
        [ "$a" = "$b" ] && continue
        lo=${PTS[$i]}; hi=${PTS[$((i + 1))]}
        while [ $(( hi - lo )) -gt 20 ]; do
          mid=$(( (lo + hi) / 2 ))
          read -r SM _ _ <<< "$(probe_shift "$mid")"
          if [ "$SM" = "$a" ]; then lo=$mid
          elif [ "$SM" = "$b" ]; then hi=$mid
          else ok=0; echo "  -> at ${mid}s the shift is ${SM}, neither ${a} nor ${b}: more than one change here."; break; fi
        done
        [ "$ok" -eq 1 ] || break
        BOUNDS+=($(( (lo + hi) / 2 ))); SEGSH+=("$b")
        echo "  -> the shift changes from ${a} to ${b} between ${lo}s and ${hi}s; from $(( (lo + hi) / 2 ))s on it's scored with ${b}."
      done
      if [ "$ok" -ne 1 ]; then
        echo "  WARNING: alignment differs across the file (10%=${S10}, 50%=${S50}, 90%=${S90}), and"
        echo "           where it changes couldn't be pinned down. Using the midpoint's shift (${S50})"
        echo "           for the whole-file score, but treat this result with real caution -- run without"
        echo "           --full and sample offsets between these three points to find where it changes."
        BOUNDS=(); SEGSH=("$S50")
      fi
    fi
    if [ ${#BOUNDS[@]} -eq 0 ]; then
      [ ${#SEGSH[@]} -gt 0 ] && CHOSEN=${SEGSH[0]}
      IFS='|' read -r DT RT <<< "$(trim_for_shift "$CHOSEN")"
      echo -n "Scoring the entire file (${DO}s) ... "
      run_score "$DT" "$RT" 0 "$DO" "$SUB" "$WORK/clip_0.json" 2>>"$WORK/errors.log"
      if [ -s "$WORK/clip_0.json" ]; then echo done; else echo "FAILED (see $WORK/errors.log)"; fi
    else
      # Each part from its start to the next change; pooled below like clips. The later parts
      # are scored after a seek, which is how their shifts were measured. The first is scored
      # from the very start, and some files (VC-1, some MPEG-2) line up a frame differently that
      # way than after a seek, so its shift is checked decoding from the start (no seek), like
      # the start check above.
      local AT1=$(( BOUNDS[0] - 22 )); [ "$AT1" -gt "$P10" ] && AT1=$P10
      if [ "$AT1" -ge 1 ]; then
        local C0=${SEGSH[0]} FS FSC FSCb
        echo "  -> checking the first part's shift decoding from the start (no seek), ${AT1}s in ..."
        [ -z "$REALFPS" ] && REALFPS=$(grid_fps "$ENC")
        read -r FS FSC FSCb <<< "$(probe_shift_from_start "$AT1" "$C0" $(( C0 + 1 )) $(( C0 - 1 )))"
        if [ -n "$FS" ] && clear_win "$FSC" "$FSCb"; then
          if [ "$FS" != "$C0" ]; then echo "  -> decoding from the start it lines up at shift ${FS} (score ${FSC}), not ${C0}: the first part is scored with ${FS}."; SEGSH[0]=$FS
          else echo "  -> decoding from the start it lines up at shift ${FS} too (score ${FSC})."; fi
        else
          if awk -v a="${FSC:-0}" 'BEGIN { exit !(a + 0 <= 0) }'; then
            echo "  WARNING: the check decoding from the start failed (no scores; see $WORK/errors.log); keeping ${C0} for the first part. If its score below is very low, it's likely wrong."
          else
            echo "  WARNING: decoding from the start didn't settle the first part's shift (score ${FSC:-?}, next best ${FSCb:-?}); keeping ${C0}. If the first part's score below is very low, it's likely wrong."
          fi
        fi
      fi
      local starts=(0 "${BOUNDS[@]}") k st en
      for k in "${!starts[@]}"; do
        st=${starts[$k]}
        if [ $(( k + 1 )) -lt ${#starts[@]} ]; then en=${starts[$((k + 1))]}; else en=$DO; fi
        IFS='|' read -r DT RT <<< "$(trim_for_shift "${SEGSH[$k]}")"
        echo -n "Scoring ${st}s-${en}s with shift ${SEGSH[$k]} ... "
        run_score "$DT" "$RT" "$st" $(( en - st )) "$SUB" "$WORK/clip_${st}.json" 2>>"$WORK/errors.log"
        if [ -s "$WORK/clip_${st}.json" ]; then echo done; else echo "FAILED (see $WORK/errors.log)"; fi
      done
    fi
  else
    local SHIFTS=() SH SC
    for off in "${OFFS[@]}"; do
      read -r SH SC _ <<< "$(probe_shift "$off")"
      if awk -v b="$SC" 'BEGIN{exit !(b<50)}'; then
        echo "  WARNING: no shift tried scored above 50 at ${off}s; drift here exceeds what this"
        echo "           script compensates for, or there is a genuine content difference. Treat this"
        echo "           clip's score as unreliable."
      fi
      SHIFTS+=("$SH")
      IFS='|' read -r DT RT <<< "$(trim_for_shift "$SH")"
      echo -n "Scoring ${CLIP}s @ ${off}s ... "
      run_score "$DT" "$RT" "$off" "$CLIP" "$SUB" "$WORK/clip_${off}.json" 2>>"$WORK/errors.log"
      if [ -s "$WORK/clip_${off}.json" ]; then echo done; else echo "FAILED (see $WORK/errors.log)"; fi
    done
    # Every clip agrees on the shift: that's where the encode starts in the original.
    if [ ${#SHIFTS[@]} -ge 2 ] && [ "$(printf '%s\n' "${SHIFTS[@]}" | sort -u | wc -l)" -eq 1 ]; then
      echo "Start: the encode's first frame is the original's frame $(( ${LEADN:-0} - SHIFTS[0] )) (measured)"
    fi
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
  if [ -s "$WORK/.gpudec_fallbacks" ]; then
    echo "NOTE: GPU decoding failed for $(wc -l < "$WORK/.gpudec_fallbacks") step(s), which were redone with CPU decoding (see the ffmpeg errors in $WORK/errors.log)."
  fi
  if [ -s "$WORK/.cuda_fallbacks" ]; then
    echo "NOTE: GPU scoring failed for $(wc -l < "$WORK/.cuda_fallbacks") step(s), which were redone on the CPU (see the ffmpeg errors in $WORK/errors.log)."
  fi
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

