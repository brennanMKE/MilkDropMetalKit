# Tests, screenshots and recordings in a Tart VM

All of MilkDropMetalKit's test automation runs inside a disposable macOS VM, never on the host. That covers
`swift test`, `milkconvert` corpus runs, golden-image comparisons, launching `MilkView` in a window, screenshots
and screen recordings. This doc covers why, the shared setup on cameron, how a run works, and how visual output
(frames, screenshots, video) gets made in a headless guest and brought back.

It is adapted from the host runbook, `~/Developer/Homelab/cameron/tart-ui-test-vm.md`, which records how the
approach was proven with Changeover, and from Roadie's `docs/testing-in-vm.md` and `scripts/make-screenshots.sh`,
which already capture screenshots this way. Check the runbook for anything about the golden image itself.

> **Status.** `scripts/run-tests-vm.sh` implements everything below. Screenshots and screen recordings were verified
> in the guest on 2026-10-23 (see [Verified in the guest](#verified-in-the-guest)).

## Why a VM

- **Isolation.** UI automation (`XCTAutomationSupport`) once loaded into other GUI apps on cameron and crashed a
  terminal app, killing ~38 sessions. A guest has its own WindowServer, apps and TCC database, so nothing a test
  loads can reach the host's apps. A clone deleted after every run also never builds up permission prompts.
- **Silence.** The guest boots with `--no-audio` and its own output muted. Without `--no-audio` Tart passes guest
  audio to the host's speakers, which caused stray sound on cameron on 2026-10-12. The library never plays audio,
  but MilkDrop Gallery does: in the guest it plays its test clip into the guest's muted output, and nothing reaches
  the host (checked by the run's coreaudiod check).
- **Clean state.** Every clone starts cold, with no DerivedData, no caches and no leftover preferences, so a pass
  means the same thing every time.

## Shared setup on cameron

Every project on cameron uses the same three tools, so don't build new ones:

| Tool | What it does | Use |
|---|---|---|
| `tart-golden` | Owns the single golden image (`uitest-golden`: macOS 26.6.2, Xcode 27.0 at the time of writing) | `GOLDEN="$(tart-golden require --xcode 27.0)"`. Never hardcode an image name and never make a project golden |
| `tart-lease` | Hands out the two VM slots Apple allows per host | `tart-lease acquire --label milkdrop --pid $$` before cloning, release first in cleanup. `tart-lease status` shows who holds them. If it isn't on `PATH`, warn and carry on |
| memory-signal | Asks cameron's observer to free memory (e.g. unload LM Studio models) | `source ~/Developer/Homelab/protocols/memory-signal/lib/memory-signal.sh`, then `memory_request` when the host has less than guest memory + 4 GB free |

Golden-image facts the script relies on: user `admin`, auto-logged-in, passwordless `sudo`, Automation Mode
enabled without authentication, screen lock and sleep off, SSH refused (use `tart exec`), 6 CPUs / 12 GB.
The default display is 1024×768.

## Running

Modelled on Roadie's `scripts/run-tests-vm.sh`:

```bash
scripts/run-tests-vm.sh                     # build, swift test for every target
scripts/run-tests-vm.sh --head              # test the last commit instead of the working tree
scripts/run-tests-vm.sh --frames            # also render the preset offscreen: every 30th of 300 frames to PNG
scripts/run-tests-vm.sh --screens           # also open MilkView in a window and take screenshots
scripts/run-tests-vm.sh --record 15         # also record 15 s of MilkView as a .mov
scripts/run-tests-vm.sh --preset Presets/spike-tunnel.milk --frames --screens --record 15   # the usual capture run
scripts/run-tests-vm.sh --preset Presets --frames --every 100   # 3 frames of every preset in the folder
scripts/run-tests-vm.sh --app               # build the MilkDrop Gallery .app and screenshot it
scripts/run-tests-vm.sh --corpus ~/sample --frames --every 100   # render presets from any host folder
scripts/run-tests-vm.sh --compat Corpus/presets-cream-of-the-crop --compat-stride 50   # sampled compatibility run
```

`--preset` picks the preset for the capture steps (default: the renderer's built-in defaults). A folder renders
every `.milk` in it with `--frames`, and the window steps use its first preset. `--count`, `--every` and `--size`
set the frames step's frame count, sampling and size (default 300, 30, 1280x720). `--app` builds the gallery
bundle with `scripts/build-app.sh` (ad hoc signed) and screenshots it on two presets, playing a clip made by
`say -o` into the guest's muted output. It passes `--dump-views`, so `app.log` has the window's view tree with
frames and fitting sizes, which is how a layout that overflowed the window was found. `--corpus DIR` copies every
`.milk` under a host folder (for example a sample of the git-ignored `Corpus/`) into the run's snapshot and renders
each with `--frames`; without `--preset`, the window steps use its first preset. Translating and compiling a whole
pack's shaders doesn't need the VM (it draws nothing): `swift run milkconvert shaders --compile Corpus/…`.

`--compat DIR` is the compatibility run ([compatibility.md](compatibility.md)): it copies every `.milk` under DIR,
keeping the folders, renders each offscreen with `milkview-demo compat` and brings back `report.jsonl` (one line
per preset) and `summary.json`; the summary's lines go into `summary.txt`. `--compat-stride N` takes every Nth
preset, `--compat-limit N` at most N, `--compat-frames N` and `--compat-timeout S` set the frames per preset and the
time limit per preset, and `--compat-hours H` (default 10) stops the step and brings back a partial report. The loop
runs detached in the guest and the host polls it every 20 s, printing a progress line every 5 minutes, so a long
run never rides on one `tart exec`. Failing presets don't fail the step; it fails only if the tool couldn't finish
(the loop died, hit its 1000-restart cap or the hour limit).

Results come back to `build/vm-tests/<run-id>/` (gitignored), and the last line printed is the path of `summary.txt`:

```
build/vm-tests/<run-id>/
├── summary.txt          PASS/FAIL per step, plus the lines that matter from each log
├── <step>.log           full output of each step
├── frames/<preset>/     offscreen frames, NNNN.png (--frames)
├── screens/             <preset>-window.png (the window alone) and <preset>-display.png (the whole screen) (--screens);
│                        gallery-<preset>.png (--app)
├── recordings/          screen recordings, <preset>.mov (--record)
├── report.jsonl         one JSON line per preset (--compat); summary.json, the totals; compat.log, its progress
└── metal-device.txt     the guest's Metal device and GPU families (milkview-demo info)
```

Run it in the foreground of a terminal. A dropped session costs a clone, not a work session. Exit codes:
0 pass, 1 a step failed, 2 bad arguments, 3 infrastructure (guest never came up or was lost), which is safe to retry once.

## How a run works

1. **Preflight.** `tart` and `tart-golden` on `PATH`; `GOLDEN="$(tart-golden require --xcode 27.0)"`; at least
   20 GiB free on `/` (disk usually runs out before memory); memory checked, with a memory-signal request if short.
2. **Sweep stale clones.** A SIGKILL skips the `EXIT` trap and leaves a clone behind. Delete only names shaped
   exactly `milkdrop-test-<YYYYMMDD>-<HHMMSS>-<pid>` whose `<pid>` is not a live `run-tests-vm.sh`, or whose run id
   is over 12 h old (long enough for a full `--compat` run). **Never match on a prefix.** A prefix sweep once deleted a golden image.
3. **Export a snapshot** into a fresh `mktemp -d`. By default it's the working tree, tracked files plus untracked
   files that aren't ignored, so a change can be checked before it's committed:
   `git ls-files -z -co --exclude-standard | … | rsync -a --from0 --files-from=- "$REPO/" "$EXPORT/src/"`.
   With `--head`, `git archive HEAD | tar -x`. Never share the live working copy or `$HOME`, and never share
   read-write: the guest runs test code.
4. **Take a slot** with `tart-lease acquire`.
5. **Clone and boot.**
   ```bash
   tart clone "$GOLDEN" "$CLONE"
   tart set "$CLONE" --display 1920x1080px        # only for --screens / --record; see below
   tart run "$CLONE" --no-graphics --no-audio --dir=run:"$EXPORT":ro >"$EXPORT/tart-run.log" 2>&1 &
   until tart exec "$CLONE" true 2>/dev/null; do sleep 3; done   # give up after 120 s → exit 3
   ```
   Shares appear in the guest at `/Volumes/My Shared Files/<name>`. They don't pass symlinks through, so copy
   regular files only, or pack a tree with `ditto -c` and unpack it in the guest.
6. **Prepare the guest.** `cp -R '/Volumes/My Shared Files/run/src' ~/src`, mute the output
   (`osascript -e 'set volume output volume 0' -e 'set volume with output muted'`), and, for capture runs,
   pre-approve screen capture (see [The screen-capture prompt](#the-screen-capture-prompt)).
7. **Steps.** Each runs through `tart exec "$CLONE" /bin/zsh -lc '…'` with its output teed to `<step>.log`. Set
   `set -o pipefail` **inside the guest's shell**: without it the step's status is `tee`'s, which is always 0
   (Changeover reported false passes that way until 2026-10-04). Build first
   (`swift build --build-tests`); if that fails, mark the remaining steps `SKIP`. Then `swift test --skip-build`, then
   the capture steps below, then `--compat`.
8. **Pull results** by streaming a tarball out. The export share is read-only on purpose, so nothing comes back
   through it:
   ```bash
   tart exec "$CLONE" tar -C /Users/admin/results -cf - . | tar -x -C "$RESULTS_DIR"
   ```
9. **Check the host's audio log** for `coreaudiod` "Starting IO" events since the run began, as Roadie does, and
   write the summary.
10. **Clean up in the `EXIT` trap.** Release the lease first so a waiting run starts sooner, then the
    memory-signal request; `tart stop` and `tart delete` the clone; `rm -rf "$EXPORT"`.

## Capturing visual output

There are three ways to get pictures out of a run. Prefer them in this order.

### 1. Offscreen frames (golden images and frame videos)

This is the main path for anything checked automatically. A test or a small render tool calls
`MilkRenderer.render(to:commandBuffer:time:)` on an offscreen `MTLTexture` with fixed time steps, a fixed seed and a
recorded or generated PCM clip, then reads the texture back (`getBytes`) and writes PNG with ImageIO. There's no
window, no display and no display link, so the output is deterministic and doesn't depend on the guest's screen.

- Golden-image tests (handoff §7) compare these frames against reference frames with a per-pixel tolerance:
  tight for early frames, loose for later ones, because feedback amplifies small differences.
- **Make the package's own reference frames in the guest, never on the host.** The guest GPU is paravirtualized,
  and its rounding can differ from the host's Apple GPU. Butterchurn reference frames come from a different
  renderer entirely; compare them loosely and record the tolerance per preset.
- For review by eye, the same frames can be encoded into a `.mov` in the guest with `AVAssetWriter` (H.264 or HEVC
  at the fixed frame rate). That gives an exact-timing video with no dropped frames, which a screen recording
  can't promise. The guest has no `ffmpeg`, so don't plan on it.
- Write frames under `/Users/admin/results/frames/<preset>/NNNN.png`. Large runs should keep only every Nth frame,
  or the tarball back gets slow.

### 2. Screenshots of `MilkView` in a window

These show the real view on a real (virtual) display: `CAMetalLayer`, drawable sizing and the display-link loop.
Use them as evidence and for documentation, not for pixel comparison.

- A window needs an app: `milkview-demo window [--preset P] [--seconds N] [--size WxH] [--origin X,Y]` opens a
  borderless window with `MilkView` at a known position, feeds it a generated signal (`SynthAudio`: kick, snare,
  hats and a pad at 120 BPM), prints `window <CGWindowID> <x> <y> <w> <h>` once it is on screen, and quits after
  N seconds. It plays nothing: samples go to `feed`, never to an output device. Running the bare executable through
  `tart exec` works; it doesn't need an app bundle or `open`.
- **Display size.** The headless guest still has a virtual display, 1024×768 by default. Set it per clone before
  booting, e.g. `tart set "$CLONE" --display 1920x1080px`. Roadie uses `2560x1300px` to fit its window stack.
- **Plain background.** Set a solid desktop picture first (Roadie's `capture-roadie-windows wallpaper RRGGBB` does
  it with `NSWorkspace.setDesktopImageURL`), so a capture never shows the stock wallpaper.
- **Capture.** In the guest, `screencapture -x -l <CGWindowID> <out.png>` captures just the window, at its size,
  with nothing on top of it (verified). `screencapture -x -m <out.png>` captures the whole display, useful to see
  what else is on screen. Roadie crops a display capture with `CGWindowListCopyWindowInfo` instead, which is only
  needed when several windows make up the picture.
- Give the view a few seconds before capturing, so the first drawables have presented and the feedback has built up.
- Captures run through `tart exec` without a Screen Recording permission prompt. They do raise a different one;
  see below.

### 3. Screen recordings

Use these to watch real-time behaviour: frame pacing, preset transitions, resizing.

```bash
# in the guest, while milkview-demo runs
screencapture -x -v -V 15 -R100,100,1280,720 /Users/admin/results/recordings/<name>.mov
```

`-v` records video, `-V <seconds>` stops it after that long, `-R x,y,w,h` limits it to the window's rectangle (in
points from the top left), and `-x` turns off sounds. Don't pass `-g`, which adds audio. This works headless
through `tart exec` (verified): about 57 fps at 1280×720, H.264, roughly 10 Mbit/s for a busy preset. The script
kills `screencapture` if it outlives its limit by 20 s, so a stuck recording can't hang a run.

### The screen-capture prompt

On macOS 15 and later, the first capture by a process that hasn't been approved shows a dialog:
"tart-guest-agent is requesting to bypass the system private window picker and directly access your screen and
audio" (Allow / Open System Settings). Nothing answers it in a headless guest. The capture still works, but the
dialog sits on screen: a window capture (`-l`) leaves it out, while a display or region capture, and so every
recording, shows it.

The approval lives in a per-user plist that the guest agent can write, so the script pre-approves the agent (both
its symlink and real path) and `screencapture` **in the clone**, then restarts `replayd`:

```bash
P=~/Library/Group\ Containers/group.com.apple.replayd/ScreenCaptureApprovals
defaults write "$P" /opt/homebrew/bin/tart-guest-agent -date '3024-01-01 00:00:00 +0000'
killall replayd
```

Verified 2026-10-23: with the entries in place, a 3 s recording and a display capture showed no dialog. The
golden image is shared, so this stays a per-clone step rather than a change to the golden.

- Start the recording, then the app (or the other way round with a fixed delay), and wait for both before pulling
  results. A recording that is still being written comes back truncated.
- Recordings are large (roughly tens of MB per 10 s at 1080p). Keep them short and only make them when asked
  (`--record`).
- A recording shows timing **on the guest's virtual GPU**. Don't read performance numbers from it.

### Watching a guest live

To see the guest's screen while debugging, boot the clone without `--no-graphics` (keep `--no-audio`). Memory is
the constraint on cameron: an idle VM opened with graphics was OOM-killed after about an hour on 2026-09-12.
Close it when done.

## Test design for a headless, silent guest

- **No network.** The package has no dependencies, so a run needs no package resolution. Reference frames and
  preset packs are copied in through a read-only share, never downloaded in the guest.
- **No sound.** Tests feed recorded or generated PCM to `feed` and assert on frames and levels. Nothing opens an
  output device.
- **Determinism.** Fixed time steps (not wall clock), a fixed `rand` seed, and the same PCM clip each run.
- **No unlicensed presets in git.** Corpus packs live in `Corpus/` (gitignored) and go in through
  `--dir=corpus:<path>:ro`, copied to the guest's disk before anything is timed.
- **UI tests**, if a UI test target is ever added, go in a separate scheme that only the VM script runs.

## Debugging a run

- To keep a failed clone, comment out the `tart delete` in `cleanup`, then `tart exec <clone> …` to look around.
  It still holds one of the two slots. To keep it past the next sweep, `tart rename` it to a name outside the
  sweep pattern (e.g. `milkdrop-keep-<id>`) and delete it by hand later.
- SSH is refused in the golden image on purpose. Use `tart exec`.
- `[DisplayManager] Could not find any displays containing rect` in a log is expected in a headless guest.
- `Code=-9 "Failed to create new HostKey"` at boot means the host's `login.keychain` is locked, i.e. the shell is
  not in the GUI (Aqua) session. Stop and report rather than working around it.

## Known limits

- **Two guests per host**, shared with every other project on cameron. A third run waits for a lease.
- A run takes 6 CPUs and 12 GB while it lasts. Interactive work on the host will notice during the build.
- **The guest GPU is paravirtualized** and reports only the `mac2` family. It runs this package's shaders, but don't
  use it for the handoff's performance budget (under 8 ms of GPU time at 1920×1080). See the open decision below.
- A golden-image update (new Xcode) can shift guest-rendered frames slightly. Regenerate the package's own
  reference frames when `tart-golden manifest` shows a new image, and note it in the commit.

## Verified in the guest

Golden `uitest-golden` (macOS 26.6.2, Xcode 27.0), 2026-10-23:

| Check | Result |
|---|---|
| Metal device | `Apple Paravirtual device`. Of the families checked, only `mac2` (no `apple7`–`apple9`, no `metal3`); 1024 threads per threadgroup. `rgba16Float` feedback textures and `bgra8Unorm` targets work |
| `screencapture -l <id>` | Works headless; the window alone at 1280×720, no dialog in it |
| `screencapture -v -V 15 -R…` | Works headless; 15.0 s, ~57 fps, 1280×720, ~20 MB |
| Screen-capture dialog | Appears on the first capture; suppressed by the per-clone approval above |
| Offscreen frames | 300 frames at 1280×720 in 0.6 s (render, read back and every 30th written to PNG) |
| Wall clock | ~80 s per run, clone through delete, with build, tests, frames, screenshots and a 15 s recording |
| Host audio | Silent: no `coreaudiod` "Starting IO" events during any run |

## Open decision

**Where do performance benchmarks run?** The handoff's budget is measured "on the slowest supported Mac", and the
guest's paravirtualized GPU can't stand in for one. Options: a benchmark target that runs on the host (no UI
automation and no audio, so it's outside the reasons for the VM rule), or on another real Mac. Until this is
decided, the VM script doesn't run benchmarks.
