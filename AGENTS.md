# AGENTS.md — working on this repo

The repo builds one artefact: a finished Raspberry Pi SD-card image. There is
no runtime here — the product is the card. Everything that has to be true at
boot is decided here, at build time: no first-boot setup script, nothing
resized or repaired on the card.

## Layout

- `image/build.sh` — the whole build, and the only thing you run. Fetches and
  hash-verifies the pinned base image, cliamp and ffmpeg; settles SSH access;
  makes the tree `/data` starts with; grows the image, adds partition 3 and
  writes a finished, seeded, checked ext4 into it; installs the payload into
  the root partition; patches the firmware partition; then checks both
  filesystems, reads back what it patched, and compresses. It mounts, so it
  re-runs itself under sudo.
- `image/fstab-ro.awk` — makes root and boot read-only in `/etc/fstab`. A
  separate file so the suite can run it against the fstab a real card shipped.
- `config/` — the payload, in the shape of the root filesystem:
  `etc/streamer.conf` (every knob, sourced by everything else),
  `etc/systemd/system/` (`streamer-cliamp` the player daemon, `streamer-play`
  the boot-time play, `streamer-http` the LAN control server,
  `streamer.target` tying them together), `etc/streamer/audio-{jack,dac}.txt`
  (the two audio setups, spliced into the marked block at the end of `config.txt`),
  `boot/appliance-config.txt` (appended to `/boot/firmware/config.txt`), and
  `usr/local/bin/`: `streamer` (the command people use over SSH, and the only
  writer of what plays next boot and how loud), `streamer-daemon` (starts the
  player, never playback), `streamer-play`, `streamer-bootlog` (the one durable
  log-line writer), `streamer-http`.
- Things `build.sh` writes with no file here: fstab edits, volatile journald
  config, hostname/timezone, `authorized_keys`, a fresh machine-id and SSH host
  keys, the passwordless-sudoers drop-in, the NetworkManager resolv.conf hand-off,
  the unit enable symlinks, and the baked-in `/var` state directories a
  read-only root can never make.
- `tests/appliance-scripts.sh` — the regression suite (~280 checks). Run
  `bash tests/appliance-scripts.sh`, or pass scenario numbers. Verdict: last
  line `N checks, M failed`, plus the exit status.
- `tests/mutation-check.py` — the test of the tests: breaks one shipped
  behaviour at a time and requires the suite to go red on the check that owns
  it. Each entry names one anchor line and one existing check;
  `mc.preflight()` checks the anchors still match.
- `tests/fixtures/` — what the radio service really answers with, the fstab a
  real card shipped and what the editor must make of it, and `fake-ipc.py`,
  the stand-in player.
- `.cache/` — fetched artefacts. `output/` — the `.img.xz`, its SHA256,
  generated SSH keys.

## The product

Pi 4 (Pi 5 bench-only: the DAC+ driver fails on Pi 5 kernels, Launchpad
#2060240). Wired Ethernet, key-only SSH, no display, no IR, no multiroom,
no Bluetooth. A `cliamp` daemon that comes up at every boot playing what the
listener last chose, at the level they last set.

- **Boot budget: 5 V applied → first audible sample ≤ 10 s.** 2.5 s firmware,
  1.5 s kernel+init, 2.5 s userspace to the play unit, 2.0 s cliamp ready plus
  buffer fill, 1.5 s headroom. Method: `systemd-analyze critical-chain`, one
  unit at a time, 5 cold boots per config, report the median. 
- **Partitions:** p1 vfat `/boot/firmware` ro, p2 ext4 `/` ro, p3 ext4 `/data`
  — the only writable filesystem. Read-only is set in **fstab**, not on the
  kernel command line: an fstab `defaults` line overrides a cmdline `ro`,
  because `systemd-remount-fs` applies fstab last.
- **`/data` is finished at build time**: seeded tree at a fixed size
  (`--data-size`, default 1 GiB), mounted by label with `nofail` and fsck pass.
  Growing an existing card is a manual, once-in-its-life `growpart` +
  `resize2fs`. A `/data` that will not mount does not stop the boot: the player
  units ask for `data.mount` and fail with it, and the box stays reachable over
  SSH.
- **Power-cut protocol:** a dirty `/data` is repaired by the distro's own fsck
  at the next boot. Nothing else writes to the card — journald is volatile on
  purpose, and the state record is written only when a person changes something.
- **Audio:** IQaudIO Pi-DAC+ (`dtoverlay=iqaudio-dacplus`) is the product
  output; the 3.5mm jack is a development output only. The output is a runtime
  switch (`streamer audio jack|dac`), never a rebuild. Never pin an ALSA card
  number: the device is the system default sink. One volume path: cliamp's dB.
  The DAC measures ~16 dB louder than the jack at the same cliamp level, so
  `STREAMER_DAC_GAIN` carries that fixed trim on the codec's own 'Digital'
  control — pinned by the daemon at every start, full scale first then the
  dB, so a restart cannot stack it.
- **Identity is per build, not per vendor image:** `machine-id`, SSH host keys
  and the filesystem UUID are shared by the stock image and leak into DHCP,
  mDNS and the first SSH session, so the build regenerates all three.
- **DNS follows the lease:** the base image bakes `/etc/resolv.conf`, the build
  points it at  `/run/NetworkManager/resolv.conf` with `rc-manager=symlink`, 
  and `streamer-cliamp` orders after `network-online.target`.
- `/data/bin` is first on the daemon's `PATH`, so a newer ffmpeg or cliamp can
  be dropped on the writable partition with the image copy as fallback.
  `streamer reset --yes` restores `/data` from `/usr/share/streamer/seed`, the
  same tree the build seeds the partition with.

## Rules the code enforces

Break one of these and a test should say so.

- `/data/streamer/state` (`mode`/`kind`/`target`, plus `provider=`/`volume=`)
  has exactly one writer: the `streamer` command, when a person changes something.
  What plays next boot is decided only by `streamer remember` — the page reaches
  it through the boot tab's "use the now playing" button (`/api/boot/now` →
  `streamer remember`) and through `/api/intent`, which passes `--save` — and by
  `--save` on `station|playlist|album|track`. Without `--save` those four play and
  write nothing to the card: the request rides in `$STREAMER_PLAY_NOW`, a
  key=value file under `/run` (tmpfs), which the play unit reads, plays and
  unlinks. Saved on change, never on a timer — that is what keeps it an intent,
  and what keeps the floor, the ramp and boot.log unavoidable.
- Only `streamer-play` starts audio, the saved record and the one-shot request
  both included: the daemon holds the IPC socket and sits at the floor, and the
  ramp and its three guards (a level that will not move, a step budget that fits
  the boot budget, a level set elsewhere winning over the boot's own climb) live
  in that script.
- The level is read back from the player, never recorded from what was asked
  for: what cliamp settled at is what the next boot aims at. `streamer remember`
  re-reads it along with the source.
- `streamer remember <what> <target>` records intent without touching playback:
  a tapped playlist has already started the music, and a plain play command on
  top would mean a second start and a trip back to the floor mid-track.
- A streaming-service playlist is `kind=provider` and boots through
  `provider.load`; `cliamp load` only resolves lists saved on the card.
  `provider.load` starts playing, so the boot starts row 0 only if the player
  is not already playing.
- A provider target has no hostname to wait on, so the boot waits for a real
  route and source address (`STREAMER_NET_WAIT`) before spending the load call —
  asking before the lease lands fails as *sign-in required*. An https target
  likewise waits for clock sync (`STREAMER_SYNC_WAIT`): a cold-boot clock behind
  NTP makes every TLS handshake fail as *certificate is not yet valid*.
  `Restart=on-failure` is the backstop for transients, not the designed path.
- What a reboot should load is worked out on the card, not in the page:
  `boot_target()` maps the snapshot's `playlist` label onto the right
  `streamer remember` verb. A row's path is a fallback, never the first choice:
  guessing here boots to silence.
- journald is volatile on purpose. `/data/streamer/boot.log` is the durable
  record: `streamer-bootlog` is its only writer, append-and-trim under a flock
  on the log file itself, and it keeps working when a boot loop retries over
  its own earlier attempts. `streamer boots` reads it back.
- The payload ships its own tools and reaches for nothing else: every program a
  unit names and every interpreter a payload script declares is checked against
  what the image actually ships.
- **The page has no sentences.** Grey means cannot act now (the radio tab for a
  row whose provider has no similar songs; its two actions before there is an
  answer), green means on (the open tab, a mode that is on). The only green row
  in the live list is the row playing. Four tabs: browse · playing · radio
  (headed `suggested tracks`) · at boot; the boot control is `use the now
  playing`. A list is shown by the name its owner gave it where the card can
  look it up. An interface that needs a sentence under it is designed badly, and
  so is a card that needs a sentence to be fixed: recovery is `streamer audio
  jack` over SSH, or one vfat edit from any card reader.

## Facts about the player, as checked on the card

- `cliamp remote state` answers 16 keys and **no `volume`** among them (2026-11-21);
  the level comes from `cliamp status --json` — `live_volume` in
  `streamer-http`, `json_num` in `streamer`, `pick` in `streamer-play`.
  `fake-ipc.py` leaves `volume` out of its snapshot for the same reason; put it
  back and the server is reading a key the card never sends.
- `cliamp status --json` pretty-prints with two-space indent and repeats some
  keys; fixtures answer the same way. Extractors that assume compact JSON are a
  known failure mode with a mutation entry guarding it.
- The snapshot's `playlist` label, 2026-11-21, four shapes and only these:
  `tidal:<list id>`, `tidal:album:<album id>` (a spelling `provider.load` itself
  refuses, so the word `album` comes back out before the intent is written), a
  bare name for a playlist saved on the card, and `radio:l:0` for the built-in
  channel — which `cliamp load` cannot open, hence `radio` in
  `STREAMER_PROVIDERS`. A single `track.play` leaves the key out altogether.
- Daemon mode owns the IPC socket (`~/.config/cliamp/cliamp.sock`, a path capped
  at 107 characters). Verbs `play/pause/toggle/next/prev/status --json/volume/seek/load/eq/device`
  plus v2 `remote state|capabilities|call|job|events`. No HTTP frontend (upstream
  `cliamp-server` is a radio broadcaster, unrelated). MPRIS over D-Bus needs a
  login session, so `playerctl` does not work against a `User=pi` system service.
  Tidal is device-code OAuth (`link.tidal.com`), logged in over SSH on first use;
  Tidal revokes shared client IDs now and then, with cliamp's
  `client_id`/`client_secret` override as the escape hatch.
- The same file answers "can the radio follow this?" (`radio_of`,
  `STREAMER_RADIO_PROVIDERS`) and "what is this list called?" (`list_name`,
  `playlist_name`, cached per provider for `LIST_NAMES_TTL` s because the page
  polls `/api/status` every 2 s). `listkey()` keeps matching the raw `playlist`
  label: names are not unique, ids are.
- Unresolved bench question: is cliamp's dB applied in software, and dithered?
  Undithered attenuation to 16-bit pins a hiss around −96 dBFS, about 6 dB above
  this amp's residual noise. If the answer is bad, attenuate in the codec's
  digital engine (≥32-bit, dithered) and leave cliamp at 0 dB — still one
  control surface, with the work at its end.

## Acceptance, briefly

1. First boot reaches audio in ≤ 10 s, not a hard rule.
2. SSH control with no prompts; the Omarchy bar panel drives the Pi instance
   (`omarchy-remote-cliamp`, one `ssh -N -L` tunnel to the cliamp socket; in
   `~/.config/omarchy/shell.json` set `"remoteCliamp": "/usr/local/bin/cliamp"`
   — the panel looks in `~/.local/bin` by default; leave `remoteSocket` alone,
   `~/.config/cliamp` is a symlink to `/data/cliamp`).
3. First-boot Tidal login over SSH, an album start-to-finish at hi-res where
   the master allows.
4. `streamer audio jack|dac` swaps the output on a running box, leaves the
   rest of `config.txt` alone, and is idempotent; `config.txt` can only be
   damaged deliberately.

Green means different things at different tiers: script level (no root, no
Pi, no network — the payload against a stand-in IPC and a sandbox, plus the
build contract running real `sfdisk`/`mkfs.ext4`/`e2fsck`/`dd`/`debugfs` on an
image file), meta level (mutation entries), on-device (real ro root as systemd
mounts it, real unit ordering, real cliamp, timing, dithering, the relay),
torture (the 20 cuts, at arbitrary moments including mid-write).

## Working against a real card

The card answers at `streamer.home`/`streamer.local` over SSH with
`~/.ssh/streamer`. Root is read-only: `streamer rw` to write, `sync &&
streamer ro` when done. Deploy during development: `scp` to `/tmp`, `sudo cp`
(or `sudo install -m 755`) into place, `systemctl restart <unit>`. The HTTP
API on port 8077 takes the token from `/data/streamer/http.token`. Restarting
`streamer-http` does not disturb playback; only `streamer-play` and the
`streamer` command touch what is playing.

`cliamp remote state` is the snapshot, `cliamp remote call <op> --params …
--wait` the operation channel, `cliamp status --json` the level. Facts about
the player belong in this file when they change what a payload script should
do, with the date they were checked.

## References

cliamp repo and its `docs/{remote-control,headless,tidal,radio}.md`;
omarchy-remote-cliamp (github.com/orsa86); Raspberry Pi boot-time whitepaper
RP-010196; `raspberrypi/linux` `arch/arm/boot/dts/overlays/README` for
authoritative overlay names; Sony TA-F535R service manual for the amp's
numbers.
