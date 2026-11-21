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
  - `usr/local/bin/streamer-daemon` — wrapper that starts the
    player: pins the volume floor, buffer and sample rate, the DAC's on-board
    codec trim (`STREAMER_DAC_GAIN`: full scale first, then the dB, hunting
    for the 'Digital' control rather than assuming a card number), and exports
    the PATH that finds ffmpeg. Deliberately never starts playback.
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
  shells out to the same command; it never writes the record itself. On the
  page, only two things reach it: the "use the now playing" button
  (`/api/boot/now` → `streamer remember`) and the explicit `station|playlist|mode`
  call (`/api/intent`). Tapping a list, an album, a track or a row of the
  live list plays and writes nothing — what boots is a decision, never a
  side effect. That is what keeps the volume floor, the ramp and boot.log
  unavoidable.
- Only `streamer-play` starts audio. The daemon exists to hold the IPC
  socket and sit at the floor; the ramp guards (a level that will not move,
  a step budget, a level set elsewhere) live in that script.
- journald is volatile on purpose. `/data/streamer/boot.log` is the durable
  record; `streamer-bootlog` is its only writer, append-and-trim under a
  flock on the log file itself.
- A playlist on a streaming service is stored as `kind=provider` and loaded
  with `provider.load`; `cliamp load` only resolves lists saved on the card.
- What a reboot should load is worked out on the card, not in the page:
  `boot_target()` (streamer-http) maps the snapshot's `playlist` label —
  `tidal:<id>`, `tidal:album:<id>`, a bare saved-playlist name, `radio:l:0`
  — onto the right `streamer remember` verb, and `/api/boot/now` is the page's
  one question. A row's path is a fallback, never the first choice. The same
  file answers "can the radio follow this?" (`radio_of`, `STREAMER_RADIO_PROVIDERS`),
  which is what greys out the page's radio tab — the tab is always in the
  tab bar, grey when the question cannot be asked. And it puts a name on a
  list where the provider has one (`list_name`, `playlist_name`, cached per
  provider for `LIST_NAMES_TTL` s because the page polls `/api/status` every
  2 s): the page prefers that name for the now line and the boot line, while
  `listkey()` keeps matching on the raw `playlist` label — names are not
  unique, ids are.
- cliamp `status --json` pretty-prints with two-space indent. The fixtures
  answer the same way; extractors that assume compact JSON are a known
  failure mode with a mutation entry guarding it.
- The IPC snapshot is not the whole player. On cliamp 2.4.1 `cliamp remote
  state` answers 16 keys and no `volume` among them — checked on the card
  2026-11-21 — so the level the page shows is read from `cliamp status --json`
  (`live_volume`), the same source `json_num` in `streamer` and `pick` in
  `streamer-play` read. `tests/fixtures/fake-ipc.py` leaves `volume` out of
  its snapshot for the same reason; put it back and the control server is
  reading a key the card never sends.
- The payload ships its own tools and reaches for nothing else. Every program
  a unit names, and every interpreter a payload script declares, is checked
  against what the image actually ships.

## Working against a real card

The card answers at `streamer.home`/`streamer.local` over SSH with
`~/.ssh/streamer`. Root is read-only: `streamer rw` to write, `sync &&
streamer ro` when done. Deploy during development: `scp` to `/tmp`, `sudo cp`
into place, `systemctl restart <unit>`. The HTTP API on port 8077 takes the
token from `/data/streamer/http.token`.
