#!/bin/zsh
# run-tests-vm.sh — build and test MilkDropMetalKit inside a disposable Tart VM, and capture what it draws.
#
# Tests never run on the host; see docs/testing-in-vm.md. Each run clones the shared golden image (resolved by
# `tart-golden`, never hardcoded), boots it headless with no audio path to the host (`--no-audio`) and the guest
# output muted, runs the steps, pulls the results back to build/vm-tests/<run-id>/, and deletes the clone.
#
# Usage: scripts/run-tests-vm.sh [--head] [--frames] [--screens] [--record SECONDS] [--app] [--preset PATH]
#                                [--count N] [--every K] [--size WxH]
#   --head          test the last commit (git archive HEAD) instead of the working tree
#   --frames        render the preset offscreen with milkview-demo: every Kth of N frames → frames/<preset>/NNNN.png
#   --screens       open milkview-demo's window and take screenshots of it → screens/
#   --record N      record N seconds of milkview-demo's window with screencapture → recordings/<preset>.mov
#   --app           build the MilkDrop Gallery bundle (ad hoc signed) and screenshot it on two presets → screens/
#   --preset PATH   preset for the capture steps, relative to the repo (default: none, the renderer's defaults).
#                   A directory renders every .milk in it with --frames; the window steps then use the first.
#   --corpus DIR    also render every .milk under DIR (any host path, e.g. Corpus/…) with --frames; the files are
#                   copied into the run's snapshot, never committed
#   --count N, --every K, --size WxH   frames options (default 300, 30, 1280x720)
#   --next PATH     after 2 s of each capture, blend into this preset (relative to the repo) over 2.7 s
#
# In the guest, in order:
#   build      swift build --build-tests, and a release build of milkview-demo (a failure skips everything below)
#   tests      swift test --skip-build
#   metal      the guest's GPU and Metal support (system_profiler) → metal-device.txt
#   frames, screens, record, app   only when asked
# Exit codes: 0 pass, 1 a step failed (or the host's coreaudiod started IO during the run), 2 bad arguments,
#             3 infrastructure (the guest never came up or was lost): not a code problem, rerun.

set -euo pipefail

USE_HEAD=0
FRAMES=0
SCREENS=0
RECORD=0
APP=0
CORPUS=""
PRESET=""
NEXT=""
COUNT=300 EVERY=30 FRAME_SIZE=1280x720
args=("$@")
while (( $#args )); do
  arg=$args[1]; shift args
  case "$arg" in
    --head) USE_HEAD=1 ;;
    --frames) FRAMES=1 ;;
    --screens) SCREENS=1 ;;
    --record) RECORD=${args[1]:-}; shift args 2>/dev/null; [[ "$RECORD" == <1-120> ]] || { print -r -- "--record needs 1-120 seconds" >&2; exit 2 } ;;
    --app) APP=1 ;;
    --corpus) CORPUS=${args[1]:-}; shift args 2>/dev/null; [[ -d "$CORPUS" ]] || { print -r -- "--corpus needs a directory" >&2; exit 2 }; CORPUS=${CORPUS:A} ;;
    --count) COUNT=${args[1]:-}; shift args 2>/dev/null; [[ "$COUNT" == <1-100000> ]] || { print -r -- "--count needs a number" >&2; exit 2 } ;;
    --every) EVERY=${args[1]:-}; shift args 2>/dev/null; [[ "$EVERY" == <1-100000> ]] || { print -r -- "--every needs a number" >&2; exit 2 } ;;
    --size) FRAME_SIZE=${args[1]:-}; shift args 2>/dev/null; [[ "$FRAME_SIZE" == <1-8192>x<1-8192> ]] || { print -r -- "--size needs WxH" >&2; exit 2 } ;;
    --preset) PRESET=${args[1]:-}; shift args 2>/dev/null; [[ -n "$PRESET" ]] || { print -r -- "--preset needs a path" >&2; exit 2 } ;;
    --next) NEXT=${args[1]:-}; shift args 2>/dev/null; [[ -n "$NEXT" ]] || { print -r -- "--next needs a path" >&2; exit 2 } ;;
    -h|--help) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
    *) print -r -- "unknown option: $arg" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[[ -z "$PRESET" || -e "$REPO/$PRESET" ]] || { print -r -- "--preset: no file $REPO/$PRESET" >&2; exit 2 }
[[ -z "$NEXT" || -f "$REPO/$NEXT" ]] || { print -r -- "--next: no file $REPO/$NEXT" >&2; exit 2 }
# Presets to render offscreen; the window steps use the first.
PRESETS=()
if [[ -n "$PRESET" && -d "$REPO/$PRESET" ]]; then
  PRESETS=("${PRESET%/}"/*.milk(N:t))
  PRESETS=("${PRESET%/}/"${^PRESETS})
  (( $#PRESETS )) || { print -r -- "--preset: no .milk files in $REPO/$PRESET" >&2; exit 2 }
elif [[ -n "$PRESET" ]]; then
  PRESETS=("$PRESET")
fi
PRESET=${PRESETS[1]:-}
# File names for captures: anything outside [A-Za-z0-9._-] becomes "_", since preset names have spaces and "!".
PRESET_NAME=${${${PRESET:t:r}:-default}//[^A-Za-z0-9._-]/_}
CAPTURE=$(( SCREENS || RECORD || APP ))

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
CLONE="milkdrop-test-$RUN_ID"
EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/milkdrop-test-export.XXXXXX")"
RESULTS_DIR="$REPO/build/vm-tests/$RUN_ID"
GUEST_SRC="/Users/admin/src"
GUEST_RESULTS="/Users/admin/results"
BOOT_TIMEOUT_SECS=120
# Keep in sync with the golden image's memory (`tart set --memory`).
GUEST_MEM_MB=12288
# The guest's virtual display while capturing, and where milkview-demo puts its window (points, top left).
DISPLAY_SIZE=1920x1080
WIN_X=100 WIN_Y=100 WIN_W=1280 WIN_H=720
LEASE_ID=""
MEMORY_REQUEST_ID=""
START_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
SUMMARY_FILE=""

log()  { print -r -- "==> $*"; if [[ -n "$SUMMARY_FILE" ]]; then print -r -- "==> $*" >>"$SUMMARY_FILE"; fi; }
fail() { print -r -- "!! $*" >&2; exit 1; }
summary_start() { mkdir -p "$RESULTS_DIR"; SUMMARY_FILE="$RESULTS_DIR/summary.txt"; : >"$SUMMARY_FILE"; }
infra_fail() {
  summary_start
  cp "$EXPORT/tart-run.log" "$RESULTS_DIR/" 2>/dev/null || true
  log "INFRA  $*"
  log "Logs: $RESULTS_DIR"
  exit 3
}

MEMORY_LIB="$HOME/Developer/Homelab/protocols/memory-signal/lib/memory-signal.sh"
[[ -f "$MEMORY_LIB" ]] && source "$MEMORY_LIB"

cleanup() {
  local rc=$?
  trap - EXIT
  log "Cleaning up (exit $rc)"
  # Give the Tart slot back first so a waiting session starts sooner.
  [[ -n "$LEASE_ID" ]] && { tart-lease release --id "$LEASE_ID" 2>/dev/null || true; }
  if [[ -n "$MEMORY_REQUEST_ID" ]] && typeset -f memory_release >/dev/null; then
    memory_release 2>/dev/null || true
  fi
  tart stop "$CLONE" >/dev/null 2>&1 || true
  tart delete "$CLONE" >/dev/null 2>&1 || true
  rm -rf "$EXPORT"
  if [[ -n "$SUMMARY_FILE" ]]; then log "Summary: $SUMMARY_FILE"; fi
}
trap cleanup EXIT

# --- Preflight -------------------------------------------------------------

command -v tart >/dev/null || fail "Tart is not installed (brew install cirruslabs/cli/tart)"
command -v tart-golden >/dev/null || fail "tart-golden not on PATH -- see ~/Developer/Homelab/protocols/tart-golden/PROTOCOL.md"
GOLDEN="$(tart-golden require --xcode 27.0)"

free_kb=$(df -k / | awk 'NR == 2 { print $4 }')
(( free_kb / 1024 / 1024 >= 20 )) || fail "Only $((free_kb / 1024 / 1024)) GiB free on / -- need at least 20 GiB"

need_bytes=$(( (GUEST_MEM_MB + 4096) * 1024 * 1024 ))
if typeset -f memory_available_bytes >/dev/null; then
  avail=$(memory_available_bytes)
  if (( avail < need_bytes )); then
    log "Host memory short ($(( avail / 1073741824 )) of $(( need_bytes / 1073741824 )) GiB) -- asking the memory-signal observer"
    set +e
    memory_request "$need_bytes" "milkdrop-run-tests-vm" "Tart VM test run needs guest RAM plus headroom" 120
    rc=$?
    set -e
    (( rc == 0 )) || fail "Memory request not fulfilled (rc=$rc); free memory and retry"
  fi
fi

# A SIGKILL or OOM kill skips the trap, so sweep clones whose run is gone. Only names shaped exactly like this
# script's run ids are touched (a prefix match once deleted a golden image); a live run's clone is left alone.
MAX_RUN_HOURS=4
run_is_live() { local cmd; cmd=$(ps -p "$1" -o command= 2>/dev/null) || return 1; [[ "$cmd" == *run-tests-vm.sh* ]]; }
for old in $(tart list --quiet); do
  [[ "$old" =~ '^milkdrop-test-([0-9]{8})-([0-9]{6})-([0-9]+)$' ]] || continue
  [[ "$old" == "$CLONE" || "$old" == "$GOLDEN" ]] && continue
  pid=$match[3]
  started=$(date -j -f '%Y%m%d%H%M%S' "$match[1]$match[2]" +%s 2>/dev/null) || started=0
  age_h=$(( ($(date +%s) - started) / 3600 ))
  if run_is_live "$pid" && (( age_h < MAX_RUN_HOURS )); then
    log "Leaving clone of a live run: $old (pid $pid)"; continue
  fi
  log "Sweeping stale clone: $old"
  tart stop "$old" >/dev/null 2>&1 || true
  tart delete "$old" >/dev/null 2>&1 || true
done

# --- Export a snapshot -----------------------------------------------------
# Working tree by default (tracked plus untracked-but-not-ignored files), so a change can be verified before it is
# committed. Shared read-only; never the live working copy.

mkdir -p "$EXPORT/src"
if (( USE_HEAD )); then
  log "Exporting HEAD ($(git -C "$REPO" rev-parse --short HEAD))"
  git -C "$REPO" archive HEAD | tar -x -C "$EXPORT/src"
else
  log "Exporting the working tree"
  ( cd "$REPO" && git ls-files -z -co --exclude-standard \
      | while IFS= read -r -d '' f; do [[ -e "$f" ]] && print -rN -- "$f"; done ) \
    | rsync -a --from0 --files-from=- "$REPO/" "$EXPORT/src/"
fi
if [[ -n "$CORPUS" ]]; then
  # Flattened into one folder; the frames step renders each.
  mkdir -p "$EXPORT/src/CorpusRun"
  find "$CORPUS" -name '*.milk' -print0 | while IFS= read -r -d '' f; do cp "$f" "$EXPORT/src/CorpusRun/"; done
  for f in "$EXPORT"/src/CorpusRun/*.milk(N); do PRESETS+=("CorpusRun/${f:t}"); done
  log "Corpus: $(ls "$EXPORT/src/CorpusRun" | wc -l | tr -d ' ') presets from $CORPUS"
  # Without --preset, the window steps (screens, record) use the first corpus preset.
  if [[ -z "$PRESET" ]]; then
    PRESET=${PRESETS[1]:-}
    PRESET_NAME=${${${PRESET:t:r}:-default}//[^A-Za-z0-9._-]/_}
  fi
fi

# --- Clone and boot --------------------------------------------------------

if command -v tart-lease >/dev/null; then
  LEASE_ID=$(tart-lease acquire --label milkdrop --pid $$)
else
  log "WARNING: tart-lease not on PATH -- running without admission control"
fi

log "Cloning $GOLDEN -> $CLONE"
tart clone "$GOLDEN" "$CLONE"
(( CAPTURE )) && tart set "$CLONE" --display "${DISPLAY_SIZE}px"
log "Booting headless, no audio device, export mounted read-only"
tart run "$CLONE" --no-graphics --no-audio --dir=run:"$EXPORT":ro >"$EXPORT/tart-run.log" 2>&1 &
boot_deadline=$(( SECONDS + BOOT_TIMEOUT_SECS ))
until tart exec "$CLONE" true >/dev/null 2>&1; do
  (( SECONDS < boot_deadline )) || infra_fail "guest not reachable within ${BOOT_TIMEOUT_SECS}s"
  sleep 3
done
log "Guest reachable"

gx() { tart exec "$CLONE" /bin/zsh -lc "$1"; }
guest_alive() { tart exec "$CLONE" true >/dev/null 2>&1 && return 0; sleep 2; tart exec "$CLONE" true >/dev/null 2>&1; }
gx_prep() { gx "$1" && return 0; guest_alive && fail "Guest prepare step failed: $1"; infra_fail "guest lost during prepare"; }

gx_prep "rm -rf $GUEST_SRC $GUEST_RESULTS && mkdir -p $GUEST_RESULTS && cp -R '/Volumes/My Shared Files/run/src' $GUEST_SRC"
# --no-audio only cuts the guest's path to the host; mute the guest's own output as well.
gx_prep "osascript -e 'set volume output volume 0' -e 'set volume with output muted' >/dev/null 2>&1 || true"
if (( CAPTURE )); then
  # macOS 15+ asks whether tart-guest-agent may "bypass the system private window picker" on the first capture, and
  # the dialog lands in region recordings. Pre-approve it in this clone only (never in the golden image).
  gx_prep "P=~/Library/Group\\ Containers/group.com.apple.replayd/ScreenCaptureApprovals; mkdir -p \"\${P:h}\"
    for x in \$(readlink -f /opt/homebrew/bin/tart-guest-agent) /opt/homebrew/bin/tart-guest-agent /usr/sbin/screencapture; do
      defaults write \"\$P\" \"\$x\" -date '3024-01-01 00:00:00 +0000'; done; killall replayd 2>/dev/null; true"
fi

# --- Steps -----------------------------------------------------------------
# `set -o pipefail` inside the guest shell: without it a step's status is tee's, which is always 0.

typeset -A step_rc; typeset -a step_order; build_failed=0
run_step() {   # run_step name cmd [build]
  local name=$1 cmd=$2 stage=${3:-test} rc=0
  step_order+=("$name")
  if (( build_failed )); then step_rc[$name]=skip; return; fi
  log "Guest: $name"
  gx "set -o pipefail; cd $GUEST_SRC && { $cmd; } 2>&1 | tee $GUEST_RESULTS/$name.log >/dev/null" || rc=$?
  if (( rc != 0 )) && ! guest_alive; then infra_fail "guest lost during $name"; fi
  step_rc[$name]=$rc
  (( rc != 0 )) && [[ "$stage" == build ]] && build_failed=1
  return 0
}

DEMO_BIN=".build/release/milkview-demo"
preset_arg=""
[[ -n "$PRESET" ]] && preset_arg="--preset ${(q)PRESET}"
[[ -n "$NEXT" ]] && preset_arg+=" --next ${(q)NEXT}"

run_step build "swift build --build-tests && swift build -c release --product milkview-demo" build
run_step tests "swift test --skip-build"
run_step metal "$DEMO_BIN info | tee $GUEST_RESULTS/metal-device.txt"

if (( FRAMES )); then
  frames_cmd="bad=0; "
  for p in ${PRESETS:-""}; do
    name=${${p:t:r}:-default}
    frames_cmd+="$DEMO_BIN frames ${p:+--preset ${(q)p}} ${NEXT:+--next ${(q)NEXT}} --out $GUEST_RESULTS/frames/${(q)name} --count $COUNT --every $EVERY --size $FRAME_SIZE || { echo \"frames failed: ${(q)name}\"; bad=1; }; "
  done
  run_step frames "${frames_cmd}exit \$bad"
fi

# Start milkview-demo's window, wait until it prints its window line, then run the capture command ($1 may use
# $WID, the window's CGWindowID). The demo stays up for the capture plus a margin and quits on its own.
capture_cmd() {
  local seconds=$1 body=$2
  print -r -- "rm -f /tmp/demo.out; $DEMO_BIN window $preset_arg --seconds $seconds --size ${WIN_W}x$WIN_H --origin $WIN_X,$WIN_Y > /tmp/demo.out 2>&1 &
    demo=\$!
    for i in {1..40}; do grep -q '^window ' /tmp/demo.out && break; sleep 0.5; done
    cat /tmp/demo.out
    WID=\$(awk '/^window / { print \$2 }' /tmp/demo.out)
    [[ -n \$WID ]] || { echo 'milkview-demo never showed its window'; exit 1; }
    $body
    wait \$demo"
}

if (( SCREENS )); then
  run_step screens "mkdir -p $GUEST_RESULTS/screens; $(capture_cmd 8 "
    sleep 2; screencapture -x -l \$WID $GUEST_RESULTS/screens/$PRESET_NAME-window.png
    sleep 2; screencapture -x -m $GUEST_RESULTS/screens/$PRESET_NAME-display.png
    ls -l $GUEST_RESULTS/screens")"
fi

if (( RECORD )); then
  # screencapture -v records until -V's limit; kill it if it outlives that, so a step can't hang.
  run_step record "mkdir -p $GUEST_RESULTS/recordings; $(capture_cmd $(( RECORD + 6 )) "
    sleep 1
    screencapture -x -v -V $RECORD -R$WIN_X,$WIN_Y,$WIN_W,$WIN_H $GUEST_RESULTS/recordings/$PRESET_NAME.mov &
    rec=\$!
    for i in {1..$(( RECORD + 20 ))}; do kill -0 \$rec 2>/dev/null || break; sleep 1; done
    kill -0 \$rec 2>/dev/null && { echo 'screencapture still running; stopping it'; kill -INT \$rec; sleep 2; }
    wait \$rec; rc=\$?
    ls -l $GUEST_RESULTS/recordings
    [[ -s $GUEST_RESULTS/recordings/$PRESET_NAME.mov ]] || { echo 'no recording written'; exit 1; }
    exit \$rc")"
fi

if (( APP )); then
  # The bundle as build-app.sh makes it, ad hoc signed. `say -o` writes a short clip without playing it, so the
  # audio-file path is exercised; with no output device the app should say so and keep using the built-in beat.
  GALLERY_BIN="/tmp/gallery/MilkDrop\\ Gallery.app/Contents/MacOS/MilkDropGallery"
  run_step app "scripts/build-app.sh --identity - --arch native --out /tmp/gallery
    mkdir -p $GUEST_RESULTS/screens; say -o /tmp/voice.aiff 'MilkDrop gallery'
    for p in wave-scope echo; do
      $GALLERY_BIN --select \$p --audio /tmp/voice.aiff --dump-views >/tmp/app-\$p.log 2>&1 &
      app=\$!
      sleep 8; screencapture -x -m $GUEST_RESULTS/screens/gallery-\$p.png
      kill -0 \$app || { echo \"MilkDropGallery exited early\"; cat /tmp/app-\$p.log; exit 1; }
      kill \$app; wait \$app; cat /tmp/app-\$p.log
    done
    ls -l $GUEST_RESULTS/screens"
fi

# --- Results back ----------------------------------------------------------

summary_start
gx "tar -C $GUEST_RESULTS -cf - ." | tar -x -C "$RESULTS_DIR" || log "WARNING: could not pull every result"

failed=0
for name in $step_order; do
  case ${step_rc[$name]} in
    0) log "PASS  $name" ;;
    skip) log "SKIP  $name (build failed)" ;;
    *) log "FAIL  $name (exit ${step_rc[$name]})"; failed=1 ;;
  esac
done
for name in $step_order; do
  [[ -f "$RESULTS_DIR/$name.log" ]] || continue
  if [[ ${step_rc[$name]} == 0 ]]; then
    lines=$(grep -E 'Build complete|Test run with|^frames |^device |^window |\.(png|mov)$|Chipset Model|Metal' "$RESULTS_DIR/$name.log" | tail -6 || true)
  else
    lines=$(grep -E 'error:|✘|FAIL|failed|never|no recording|still running' "$RESULTS_DIR/$name.log" | head -20 || true)
    [[ -n "$lines" ]] || lines=$(tail -15 "$RESULTS_DIR/$name.log")
  fi
  [[ -n "$lines" ]] && print -r -- "$lines" | sed 's/^/    /' | tee -a "$SUMMARY_FILE"
done

io_events=$(/usr/bin/log show --start "$START_STAMP" \
  --predicate 'process == "coreaudiod" AND eventMessage CONTAINS "Starting IO"' 2>/dev/null \
  | grep -vc '^Timestamp' || true)
if (( io_events > 0 )); then
  log "AUDIO  host coreaudiod logged $io_events 'Starting IO' event(s) since $START_STAMP -- something reached a speaker (could be another app)"
  failed=1
else
  log "AUDIO  silent: no host 'Starting IO' events during the run"
fi
log "Logs: $RESULTS_DIR"
exit $failed
