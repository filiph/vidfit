#!/usr/bin/env bash
# vidfit - encode a video to fit strictly under a hard size limit.
# Output: MP4 / H.264 High / yuv420p / AAC-LC / faststart (Discord, X, Mastodon safe)
set -eo pipefail

MB=20; UNIT=1000000; HEIGHT=0; NOAUDIO=0; AUTO=0; FPS=0; MIN_FPS=30
PRESET=slow; TOL=20; TRIES=5; ABR=0; OUT=""; IN=""; VERBOSE=0

prog=${0##*/}
die()  { printf '%s: %s\n' "$prog" "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*" >&2; }
human(){ awk -v b="$1" 'BEGIN{printf "%.2f MB", b/1000000}'; }

usage() {
  cat <<EOF
usage: $prog [options] <input> [output.mp4]

  -s, --size MB     hard limit, 1 MB = 1,000,000 B (default $MB)
  -h, --height PX   downscale to height <= PX (aspect kept, never upscales)
  -A, --auto        pick height (and fps) automatically for the bit budget
      --fps N       cap frame rate at N
      --min-fps N   minimum frame rate for --auto before downscaling (default $MIN_FPS)
  -n, --no-audio    strip audio
      --ab KBPS     force audio bitrate (default: auto 48-128k)
      --preset P    x264 preset (default $PRESET; try veryslow for small clips)
      --tol PCT     accept results down to PCT% below the limit (default $TOL)
      --tries N     max encode attempts (default $TRIES)
  -v                show full ffmpeg output
EOF
}

while [ $# -gt 0 ]; do
  case $1 in
    -s|--size)    [ $# -ge 2 ] || die "missing argument for $1"; MB=$2; shift 2;;
    -h|--height)  [ $# -ge 2 ] || die "missing argument for $1"; HEIGHT=$2; shift 2;;
    -A|--auto)    AUTO=1; shift;;
    --fps)        [ $# -ge 2 ] || die "missing argument for $1"; FPS=$2; shift 2;;
    --min-fps)    [ $# -ge 2 ] || die "missing argument for $1"; MIN_FPS=$2; shift 2;;
    -n|--no-audio) NOAUDIO=1; shift;;
    --ab)         [ $# -ge 2 ] || die "missing argument for $1"; ABR=$2; shift 2;;
    --preset)     [ $# -ge 2 ] || die "missing argument for $1"; PRESET=$2; shift 2;;
    --tol)        [ $# -ge 2 ] || die "missing argument for $1"; TOL=$2; shift 2;;
    --tries)      [ $# -ge 2 ] || die "missing argument for $1"; TRIES=$2; shift 2;;
    -v)           VERBOSE=1; shift;;
    --help)       usage; exit 0;;
    -*)           die "unknown option: $1";;
    *)            if [ -z "$IN" ]; then IN=$1; elif [ -z "$OUT" ]; then OUT=$1; else die "unexpected extra argument: $1"; fi; shift;;
  esac
done

[ -n "$IN" ] || { usage; exit 1; }
[ -f "$IN" ] || die "no such file: $IN"
command -v ffmpeg  >/dev/null || die "ffmpeg not found (brew install ffmpeg)"
command -v ffprobe >/dev/null || die "ffprobe not found (brew install ffmpeg)"
[ -n "$OUT" ] || OUT="${IN%.*}.fit.mp4"

if [ "$IN" = "$OUT" ] || { [ -e "$OUT" ] && [ "$IN" -ef "$OUT" ]; }; then
  die "output file cannot be the same file as input: $OUT"
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ "$VERBOSE" = 1 ]; then Q=(-v info); else Q=(-v error -stats); fi

# ---- probe -----------------------------------------------------------------
read -r SRC_W SRC_H RFR <<< "$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$IN" | tr ',' ' ')"
[ -n "$SRC_H" ] || die "no video stream found"
SRC_FPS=$(awk -F/ '{ if ($2>0) printf "%.3f", $1/$2; else printf "30" }' <<< "$RFR")

DUR=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$IN")
case "$DUR" in ""|N/A) DUR=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=duration -of default=nk=1:nw=1 "$IN");; esac
case "$DUR" in ""|N/A) die "cannot determine duration";; esac
awk -v d="$DUR" 'BEGIN{exit !(d>0.2)}' || die "duration is ~zero"

HAS_AUDIO=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
  -of csv=p=0 "$IN" || true)
[ -z "$HAS_AUDIO" ] && NOAUDIO=1

# ---- budget ----------------------------------------------------------------
BUDGET=$(awk -v m="$MB" -v u="$UNIT" 'BEGIN{printf "%d", m*u}')
TOTAL=$(awk -v b="$BUDGET" -v d="$DUR" 'BEGIN{printf "%d", b*8/d/1000}')

if [ "$NOAUDIO" = 1 ]; then ABR=0
elif [ "$ABR" = 0 ]; then
  ABR=$(awk -v t="$TOTAL" 'BEGIN{ if(t>=1500)print 128; else if(t>=800)print 96;
                                  else if(t>=400)print 64; else print 48 }')
fi
AC=2; [ "$ABR" -le 48 ] 2>/dev/null && AC=1

VB=$(awk -v t="$TOTAL" -v a="$ABR" 'BEGIN{printf "%d", t*0.97-a}')
[ "$VB" -ge 40 ] || die "budget too small: only ${VB}k left for video. Try -n, or a bigger -s."

# ---- fast path: already fits and already compatible ------------------------
SRC_BYTES=$(wc -c < "$IN" | tr -d ' ')
VC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$IN")
PIX_FMT=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$IN")
AC_NAME=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$IN" || true)
if { [ "$HEIGHT" = 0 ] || [ "$HEIGHT" -ge "$SRC_H" ]; } \
   && { [ "$FPS" = 0 ] || awk -v sf="$SRC_FPS" -v f="$FPS" 'BEGIN{exit !(sf<=f)}'; } \
   && [ "$SRC_BYTES" -le "$BUDGET" ] && [ "$VC" = "h264" ] && [ "$PIX_FMT" = "yuv420p" ] \
   && { [ "$NOAUDIO" = 1 ] || [ "$AC_NAME" = "aac" ]; }; then
  say "input already fits and is H.264 -> remuxing only"
  if [ "$NOAUDIO" = 1 ]; then AMAP=(-an); else AMAP=(-map "0:a:0?" -c:a copy); fi
  ffmpeg -hide_banner "${Q[@]}" -y -i "$IN" -map 0:v:0 "${AMAP[@]}" -c:v copy \
    -sn -dn -movflags +faststart "$OUT"
  OUT_BYTES=$(wc -c < "$OUT" | tr -d ' ')
  if [ "$OUT_BYTES" -le "$BUDGET" ]; then
    say "done: $OUT ($(human "$OUT_BYTES"))"; exit 0
  fi
  rm -f "$OUT"
  say "remuxed file exceeded budget (${OUT_BYTES} B > ${BUDGET} B); re-encoding..."
fi

# ---- auto scale ------------------------------------------------------------
pick_height() { # $1 video kbps, $2 fps -> best height
  local vb=$1 f=$2 h w need
  for h in 2160 1920 1440 1280 1080 900 720 576 480 360 288 240 180; do
    [ "$h" -gt "$SRC_H" ] && continue
    w=$(awk -v h=$h -v sw=$SRC_W -v sh=$SRC_H 'BEGIN{printf "%d", h*sw/sh}')
    need=$(awk -v w=$w -v h=$h -v f=$f 'BEGIN{printf "%d", w*h*f*0.045/1000}')
    [ "$vb" -ge "$need" ] && { echo "$h"; return; }
  done
  echo 180
}

if [ "$AUTO" = 1 ]; then
  if [ "$FPS" = 0 ]; then
    cand_fps=()
    for f in 60 50 48 30 25 24; do
      if awk -v sf="$SRC_FPS" -v mf="$MIN_FPS" -v f="$f" 'BEGIN{exit !(f<=sf && f>=mf)}'; then
        cand_fps+=("$f")
      fi
    done
    if awk -v sf="$SRC_FPS" -v mf="$MIN_FPS" 'BEGIN{exit !(mf<=sf)}'; then
      has_min=0
      for f in "${cand_fps[@]}"; do
        if [ "$f" = "$MIN_FPS" ]; then has_min=1; break; fi
      done
      [ "$has_min" = 0 ] && cand_fps+=("$MIN_FPS")
    fi

    matched=0
    for f in "$SRC_FPS" "${cand_fps[@]}"; do
      need=$(awk -v w="$SRC_W" -v h="$SRC_H" -v f="$f" 'BEGIN{printf "%d", w*h*f*0.045/1000}')
      if [ "$VB" -ge "$need" ]; then
        if awk -v sf="$SRC_FPS" -v f="$f" 'BEGIN{exit !(f<sf)}'; then
          FPS=$f
        fi
        matched=1
        break
      fi
    done

    if [ "$matched" = 0 ]; then
      if awk -v sf="$SRC_FPS" -v mf="$MIN_FPS" 'BEGIN{exit !(sf>mf)}'; then
        FPS=$MIN_FPS
      fi
      target_f=$([ "$FPS" != 0 ] && echo "$FPS" || echo "$SRC_FPS")
      cand_h=$(pick_height "$VB" "$target_f")
      [ "$HEIGHT" = 0 ] && HEIGHT=$cand_h
    fi
  else
    cand_h=$(pick_height "$VB" "$FPS")
    [ "$HEIGHT" = 0 ] && HEIGHT=$cand_h
  fi
fi

say "source : ${SRC_W}x${SRC_H} @ ${SRC_FPS}fps, $(awk -v d="$DUR" 'BEGIN{printf "%.1fs", d}')"
say "budget : $(human "$BUDGET")  ->  video ${VB}k + audio ${ABR}k"
say "target : height $([ "$HEIGHT" = 0 ] && echo "as-is" || echo "<= $HEIGHT"), fps $([ "$FPS" = 0 ] && echo "as-is" || echo "$FPS"), preset $PRESET"

# ---- encode ----------------------------------------------------------------
encode() { # $1 video kbps, $2 out
  local vb=$1 out=$2 fl="" vfa=() aa=()
  if [ "$HEIGHT" -gt 0 ]; then
    fl="scale=-2:trunc(min(ih\,$HEIGHT)/2)*2"
  else
    fl="scale=trunc(iw/2)*2:trunc(ih/2)*2"
  fi
  if [ "$FPS" != 0 ] && awk -v s="$SRC_FPS" -v t="$FPS" 'BEGIN{exit !(s>t)}'; then
    [ -n "$fl" ] && fl="$fl,fps=$FPS" || fl="fps=$FPS"
  fi
  [ -n "$fl" ] && vfa=(-vf "$fl")
  if [ "$NOAUDIO" = 1 ]; then aa=(-an)
  else aa=(-map "0:a:0?" -c:a aac -b:a "${ABR}k" -ac "$AC" -ar 48000); fi

  local common=(-map 0:v:0 "${vfa[@]}" -c:v libx264 -preset "$PRESET"
    -profile:v high -pix_fmt yuv420p
    -b:v "${vb}k" -maxrate "$((vb*3/2))k" -bufsize "$((vb*2))k" -sn -dn)

  ffmpeg -hide_banner "${Q[@]}" -y -i "$IN" \
    "${common[@]}" -an -pass 1 -passlogfile "$TMP/x264" -f null /dev/null
  ffmpeg -hide_banner "${Q[@]}" -y -i "$IN" \
    "${common[@]}" "${aa[@]}" -pass 2 -passlogfile "$TMP/x264" \
    -movflags +faststart -f mp4 "$out"
}

ABYTES=$(awk -v a="$ABR" -v d="$DUR" 'BEGIN{printf "%d", a*1000/8*d}')
LO=$(awk -v b="$BUDGET" -v t="$TOL" 'BEGIN{printf "%d", b*(1-t/100)}')
best=""; best_size=0; prev_sz=0; vb=$VB; i=1

while [ "$i" -le "$TRIES" ]; do
  say "--- attempt $i/$TRIES: ${vb}k video"
  encode "$vb" "$TMP/try.mp4"
  sz=$(wc -c < "$TMP/try.mp4" | tr -d ' ')
  say "    $(human "$sz")  ($(awk -v s="$sz" -v b="$BUDGET" 'BEGIN{printf "%.1f", 100*s/b}')% of limit)"

  if [ "$sz" -le "$BUDGET" ] && [ "$sz" -gt "$best_size" ]; then
    mv -f "$TMP/try.mp4" "$TMP/best.mp4"; best="$TMP/best.mp4"; best_size=$sz
  fi
  if [ "$sz" -le "$BUDGET" ] && [ "$sz" -ge "$LO" ]; then break; fi

  # If under budget but size stopped growing (codec saturated), stop trying higher bitrates
  if [ "$i" -gt 1 ] && [ "$sz" -le "$BUDGET" ] && awk -v s="$sz" -v p="$prev_sz" 'BEGIN{exit !(s <= p*1.01)}'; then
    break
  fi
  prev_sz=$sz

  newvb=$(awk -v v="$vb" -v s="$sz" -v b="$BUDGET" -v ab="$ABYTES" 'BEGIN{
    mv=s-ab; tv=b*0.97-ab;
    if (mv<1 || tv<1) { print v; exit }
    f=tv/mv; if (f>2) f=2; if (f<0.2) f=0.2; printf "%d", v*f }')

  if [ -z "$best" ] && [ "$newvb" -ge "$vb" ]; then
    newvb=$(awk -v v="$vb" 'BEGIN{printf "%d", v*0.95}')
  elif [ -n "$best" ] && awk -v a="$newvb" -v b="$vb" 'BEGIN{exit !(a<b*1.01 && a>b*0.99)}'; then
    break
  fi
  vb=$newvb; i=$((i+1))
done

[ -n "$best" ] || die "could not fit under $(human "$BUDGET") - try -A, -h 480, -n, or a bigger -s."
mv -f "$best" "$OUT"
say "done: $OUT  $(human "$best_size")  ($(awk -v s="$best_size" -v b="$BUDGET" 'BEGIN{printf "%.1f", 100*s/b}')% of limit)"

