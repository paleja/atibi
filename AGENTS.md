# AGENTS.md — working on this repo

The repo builds one artefact: a finished Raspberry Pi SD-card image. There is
no runtime here — the product is the card. Read `docs/PRD.md` for the design
decisions and their reasons; this file is only about the code.

## Layout

- `image/build.sh` — the whole build, and the only thing you run. It fetches
  and hash-verifies the pinned base image, cliamp and ffmpeg; settles SSH
  access; makes the tree `/data` starts with; writes a third partition entry
  and a finished, seeded, checked ext4 filesystem in it at a size decided
  here; installs the payload into the root partition; patches the firmware
  partition; then checks both filesystems, reads back what it patched, and
  compresses. It mounts filesystems, so it re-runs itself under sudo.
- `image/fstab-ro.awk` — makes the root and boot partitions read-only in
  `/etc/fstab`. A file rather than a quote inside the build script, so the
  suite can run it against the fstab a real card shipped (`tests/fixtures/`).
- `config/` — the payload that goes into the image, in the shape of the root
  filesystem:
  - `etc/streamer.conf` — every knob, each with its own comment; all
    streamer-* scripts and the `streamer` command source it
  - `etc/systemd/system/` — `streamer-cliamp` (the player daemon),
    `streamer-play` (the boot-time play), `streamer-http` (the LAN control
    server), `streamer.target` (ties them together)
  - `etc/streamer/audio-{jack,dac}.txt` — the two audio setups, swapped into
    the marked block at the end of `config.txt` by `streamer audio jack|dac`
  - `boot/appliance-config.txt` — the block appended to
    `/boot/firmware/config.txt`
  - `usr/local/bin/streamer` — the command people use over SSH, and the only
    thing that writes the record of what to play next boot and how loud
  - `usr/local/bin/streamer-daemon` — four-line wrapper that starts the
    player: pins the volume floor, buffer and sample rate, exports the PATH
    that finds ffmpeg. Deliberately never starts playback.
  - `usr/local/bin/streamer-play` — the boot-time play: waits for the clock
    and the network, sets the floor, starts the saved target, ramps the level
  - `usr/local/bin/streamer-bootlog` — one durable line per event; the only
    record that outlives a power cut
  - `usr/local/bin/streamer-http` — the LAN control server: token-guarded
    HTTP API and a phone-sized web page, talking to the player over its own
    IPC socket
- Things `build.sh` writes into the root itself, with no file here: the fstab
  changes, the volatile journald config, hostname/timezone, `authorized_keys`,
  a fresh machine-id and SSH host keys, the passwordless-sudoers drop-in for
  the privileged `streamer` subcommands, the NetworkManager resolv.conf
  hand-off (so DNS follows the DHCP lease instead of the vendor's baked
  8.8.8.8), and the unit enable symlinks.
- `tests/appliance-scripts.sh` — the regression suite (twenty scenarios,
  ~280 checks). `bash tests/appliance-scripts.sh` runs all of them; pass
  scenario numbers to run a few. Verdict: last line `N checks, M failed`,
  plus the exit status.
- `tests/mutation-check.py` — the test of the tests: breaks one shipped
  behaviour at a time and requires the suite to go red on the check that owns
  it; anything it misses is a check that looks meaningful and is not. Each
  mutation names exactly one anchor line and one existing check. Run with
  `python3 tests/mutation-check.py`; it restores every file it touched even
  if a run is killed.
- `tests/fixtures/` — the shape the radio service really answers with, the
  fstab a real card shipped (input) and what the editor is expected to make
  of it (expected, written by hand), and `fake-ipc.py`, the stand-in player.
- `docs/PRD.md` — requirements, design decisions, their history.
- `.cache/` — downloaded artefacts, kept so a rebuild does not re-fetch.
- `output/` — the finished `.img.xz`, its SHA256, generated SSH keys.

## Rules the code enforces

Design invariants, most of them guarded by suite checks and mutation entries —
break one of these and a test should say so:

- `/data/streamer/state` (the boot intent: `mode`/`kind`/`target`, plus
  `provider=`/`volume=` when they apply) has exactly one writer: the
  `streamer` command, when a person changes something. The HTTP server
  shells out to the same command; it never writes the record itself. That is
  what keeps the volume floor, the ramp and boot.log unavoidable.
- Only `streamer-play` starts audio. The daemon exists to hold the IPC
  socket and sit at the floor; the ramp guards (a level that will not move,
  a step budget, a level set elsewhere) live in that script.
- journald is volatile on purpose. `/data/streamer/boot.log` is the durable
  record; `streamer-bootlog` is its only writer, append-and-trim under a
  flock on the log file itself.
- A playlist on a streaming service is stored as `kind=provider` and loaded
  with `provider.load`; `cliamp load` only resolves lists saved on the card.
- cliamp `status --json` pretty-prints with two-space indent. The fixtures
  answer the same way; extractors that assume compact JSON are a known
  failure mode with a mutation entry guarding it.
- The payload ships its own tools and reaches for nothing else. Every program
  a unit names, and every interpreter a payload script declares, is checked
  against what the image actually ships.

## Working against a real card

The card answers at `streamer.home`/`streamer.local` over SSH with
`~/.ssh/streamer`. Root is read-only: `streamer rw` to write, `sync &&
streamer ro` when done. Deploy during development: `scp` to `/tmp`, `sudo cp`
into place, `systemctl restart <unit>`. The HTTP API on port 8077 takes the
token from `/data/streamer/http.token`.
