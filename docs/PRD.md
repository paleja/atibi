---
title: "PRD — rpi-streamer"
type: prd
owner: janp
status: v3 — image built, first card running on the bench
updated: 2026-11-18
changelog:
  - "v3 (2026-11-18): LAN control page shipped; boot intent redesigned (saved on change, periodic writer removed); DNS follows the DHCP lease; boot unit ordered against network-online.target; docs cleanup"
  - "v1→v2: boot behaviour resolved (auto-play, resume last); Tidal provisioning via first-boot SSH login; primary board switched to Raspberry Pi 4"
---

## 1. Problem

The listening setup is a power amplifier + speakers with a streamer in front of
it. Commercial streamers are slow, walled gardens, or overkill. A Raspberry Pi
running `cliamp` covers every wanted source (internet radio, Tidal, local
files). The remaining problems to engineer around:

1. A stock Raspberry Pi OS boots in 15–25s — too slow against the amp's own
   ~10s start-and-relay-click sequence.
2. The device is powered from a strip and gets cut cold. A writable root
   filesystem on SD will eventually corrupt; fsck/journal replay also blows
   the boot budget.
3. A TUI in a tmux session is not an appliance. The player must be a managed
   daemon with a scriptable control surface.

## 2. Product definition (main deliverable)

A reproducible custom Raspberry Pi OS image containing:

- Trimmed Raspberry Pi OS Lite (Debian) base with the boot-time tuning of §6.
- Read-only root + a separate writable `/data` partition (§7) — safe to pull
  the plug at any moment.
- `cliamp` in headless daemon mode, autostarted via systemd, auto-play of
  whatever source the listener last chose at the level they last set; no
  service credentials in the image — providers are logged in on first use
  over SSH (§8.2).
- Correct audio bring-up for the IQaudIO Pi-DAC+ HAT (§5, §6.4), with the
  3.5mm jack as a build-time alternative and a runtime switch between the two.
- Wired Ethernet only, SSH enabled for maintenance, key-only login: no
  password in the image to guess. DNS from the network's DHCP lease, not the
  vendor-baked resolver (§6.3).
- Image build is scripted (`image/build.sh`, hash-pinned inputs), so a fresh
  SD card can be rebuilt from this repo.
- Maintenance without reflashing: audio output, playback target, volume and
  the cliamp config all live on writable storage, and a newer binary dropped
  on `/data/bin` takes precedence over the one in the root (§7).
- A token-guarded LAN control server with a phone-sized web page (§9.3).

## 3. Goals

- Power-on → audio playing (last-played source resumed) in **≤ 10 s wall
  clock**, measured from 5V applied, median of ≥5 cold boots.
- On every boot the streamer auto-plays the source the listener last chose
  (radio station, saved playlist, or streaming-service playlist) at the level
  they last set. Position is not resumed: a live stream has none, and coming
  up mid-playlist is a detail rather than a feature (§8.3).
- Survive unlimited hard power-cuts with zero manual recovery.
- Sources: internet radio (Radio Browser + custom stations), Tidal (OAuth
  device-code login), local files on a USB stick (optional).
- Control without a keyboard/monitor attached: from the Omarchy bar panel
  (`omarchy-remote-cliamp` over SSH), from the LAN web page (§9.3), and from
  scripts via cliamp's IPC socket.
- Primary target: **Raspberry Pi 4**. Pi 5 supported as a secondary/bench
  target where the boot plumbing differs trivially.

## 4. Non-goals

- No local HDMI UI, no display, no IR remote.
- No multiroom/sync, no Bluetooth audio.
- No Buildroot/from-scratch OS. The target is ≤10s; sub-5s Buildroot work is
  out of scope unless 10s turns out unreachable (see risks).
- Native DSD playback (I2S path is PCM-only; Tidal does not need it).
- AirPlay receiver / DLNA server features.

## 5. Hardware

| Item | Decision | Notes |
|---|---|---|
| Board | **Raspberry Pi 4** (primary, ≥2 GB RAM) | Pi 5 kept as bench/secondary |
| DAC | **Raspberry Pi DAC+ / IQaudIO Pi-DAC+** (I2S HAT, PCM5122, 24/192, line-level RCA out) | Selection worked out in §5.1; first-party product with a published obsolescence floor, which suits a reproducible image |
| Storage | A2-class microSD (primary). USB3 SSD possible if boot time needs it | Pi 4 has no PCIe/NVMe boot; microSD first, measure |
| Amplifier | Existing **Sony TA-F535R** (1993) | Chain consequences in §5.2 |
| Speakers | Existing, 4–16 Ω | Inside the amp's rated load range |
| Network | Wired Ethernet | Wi-Fi adds untunable association+DHCP variance to the boot |
| PSU | Quality 5V/3A USB-C supply | Ground-loop hum vs the amp is the known failure mode; isolate only if measured |
| Case | HAT-form Pi 4 case (the DAC+ is 58 × 65 mm) or stack-and-go bare | Verify case fit before assuming it |

Onboard 3.5mm jack is not a product output: PWM+RC, ~9–10 effective bits, RFI
leakage. A real I2S HAT replaces it; the jack exists only to develop before
the HAT arrives.

### 5.1 DAC: Pi DAC+ over the HiFiBerry DAC2 Pro

Same silicon (TI PCM5122), same 24/192 ceiling, same SNR claim; the price gap
is what the other board adds around the chip, and the loss is accepted:

- **Clocking.** The Pi DAC+ has no onboard oscillators — the Pi supplies the
  clocks. Somewhat worse jitter: a raised noise floor at low levels, small in
  a line-level → power-amp chain.
- **Output level: 0–2.0 V RMS** — standard line level; the amp has full
  headroom (§5.2). `24db_digital_gain` exists on the overlay but is gain
  above 0 dBFS: it stays out of the normal volume path.
- **No headphone amp wanted** — and its jack carries a headphone-detect MUTE
  that silences the RCA outputs. Physical don't: plugging headphones in
  mid-session kills the speakers.

Any replacement board at the same form factor (HiFiBerry DAC+ Standard, Pi
DAC Pro) is an overlay-name change.

### 5.2 Amplifier chain: Sony TA-F535R

From the service manual: line inputs are **150 mV / 50 kΩ** for rated output,
75 W into 8 Ω; speakers 4–16 Ω. What that means for the image:

- **Level match is generous.** 2.0 V RMS from the DAC is 22.5 dB above rated
  input: the amp reaches full power with headroom to spare, so digital gain
  is not just unneeded, it is the wrong direction. The live question is how
  much attenuation to hold at power-on (§6.4).
- **Input selection:** a high-level line input (CD/TUNER/AUX), never PHONO;
  `SOURCE DIRECT` to leave the tone stage flat.
- **The amp is never the slow device.** Its speaker-protection relay closes
  in a second or two, long before the Pi's first audio sample exists. The
  real risk is the knob.
- **Volume is a physical, non-volatile variable.** The pot keeps its position
  through a hard power cut, so switch-on level equals wherever the knob was
  left; knob-at-maximum with a digital zero at the DAC means full rated
  power, clipped, on the first sample. This sets the boot-volume floor
  (§6.4).
- The motorised pot and IR remote are not automatable and not plumbed.

## 6. Boot time

Budget, power-on → first audible sample (reference: Raspberry Pi whitepaper
RP-010196; gen4 has a shorter pre-Linux stage than gen5):

| Stage | Budget |
|---|---|
| BootROM + EEPROM + firmware (incl. DRAM cal) | 2.5 s |
| Kernel + init | 1.5 s |
| userspace → `multi-user`-equivalent target | 2.5 s |
| cliamp daemon ready + stream buffer fill | 2.0 s |
| Headroom | 1.5 s |
| **Total** | **≤ 10 s** |

### 6.1 EEPROM config
- `BOOT_ORDER` restricted to the actual boot device only.
- `NET_INSTALL_ENABLED=0`, `NET_INSTALL_AT_POWER_ON=0`.

### 6.2 `/boot/firmware/config.txt`
- No display: `disable_splash=1`, `camera_auto_detect=0`,
  `display_auto_detect=0`, `max_framebuffers=0`.
- Wifi/Bluetooth off via firmware overlays (`disable-wifi`, `disable-bt`)
  rather than masked units: cheaper, and the modules never appear.
- `force_eeprom_read=0` (boot budget, and it makes HAT EEPROM misdetection
  impossible — the overlay is pinned explicitly, §6.4).

### 6.3 Kernel / systemd / network
- `cmdline.txt`: stock line with the bare `resize` token stripped and `ro`
  appended. The `ro` here is intent, not the mechanism: fstab is the
  mechanism (§7).
- No initramfs work: the image boots plain ext4, as the stock image does.
- **Network units:** `streamer-cliamp` orders after `network-online.target`
  (NetworkManager-wait-online is enabled, so this returns exactly when the
  lease is in). A daemon started against plain `network.target` resolves
  names before an address exists.
- **DNS follows the lease.** The vendor base image bakes a plain
  `/etc/resolv.conf` pointing at 8.8.8.8, which survives on a read-only root
  and breaks whenever that resolver is unreachable. The build replaces it
  with a symlink to `/run/NetworkManager/resolv.conf` and sets
  `rc-manager=symlink`: nameservers then come from DHCP on tmpfs, rewritten
  every boot, no write to the read-only root.
- Method: measure with `systemd-analyze critical-chain`, change one unit at
  a time, 5 cold boots per config, report median.

### 6.4 Audio bring-up and the volume floor
- **Board is settled:** IQaudIO Pi-DAC+ → `dtoverlay=iqaudio-dacplus`. One
  check remains on real hardware: confirm the HAT EEPROM string.
- **The audio output is a runtime switch, not a rebuild:**
  `streamer audio jack|dac` splices a fragment into the marked block at the
  end of `config.txt`; `build.sh --audio jack|dac` only picks which fragment
  is live on first boot.
- **Output device:** nothing pinned. The device is the system default sink,
  which is whatever the overlay in `config.txt` makes it. Pinning card
  numbers is the fragile option.
- **The sound stack is bare ALSA on Lite** (verified on the real card: no
  PipeWire in `raspios_lite`). One volume path, not two: all volume via
  cliamp's dB so the control surface has a single knob; the codec's ALSA
  control stays at 0 dB (the driver's attenuate-only default).
  - **Revised 2026-11-20 (M2 bench):** the Pi-DAC+ measured ~16 dB louder
    than the jack at the same cliamp level — not a quirk but the full-scale
    difference between the output stages: 2.0 V RMS line out (the figure
    above) against the Pi jack's filtered-PWM ~0.3 V. The codec's 'Digital'
    control now carries a fixed trim closing exactly that gap,
    `STREAMER_DAC_GAIN=-16` in `streamer.conf`, pinned by `streamer-daemon`
    at every start (the codec wakes at 0 dB each power-on; the pin is
    full-scale-then-dB, so a daemon restart cannot stack it). Every cliamp
    dB — floor, ramp, saved level — then means the same thing on both audio
    setups. For a person there is still one knob: the trim is a calibration
    constant under the player, not a second control surface — verified on
    the card: −16.00 dB reads back after boot and after a daemon restart,
    boot-play resumes at the saved −20 dB. Attenuating in the codec's
    digital engine is also the dithered path this bullet's open question
    points at, so it survives even if that answer goes the other way.
  - **Open bench question:** is cliamp's dB applied in software, at what
    sample format, dithered? Undithered software attenuation to 16-bit pins
    a hiss floor near −96 dBFS, ~6 dB above this amp's residual noise, and
    normal living-room listening on this amp sits around −20 to −35 dBFS,
    exactly the region where it binds. If the answer is bad,
    move volume into the codec's own digital engine (≥32-bit, dithered) and
    leave cliamp at 0 dB — still one path, different control at its end.
- **Boot volume floor: −30 dBFS**, applied before the stream starts, then
  ramped in steps toward the resumed level (§8.3). The math behind the
  numbers lives in the comments in `streamer.conf`; the decision is: a boot
  can never produce a full-power first sample, and the cost — a quiet first
  second — is the accepted trade. The floor is not bypassable: only
  `streamer-play` starts audio, and it sets the floor with a failure check
  before playback.
- **Ramp guards** (all three observable in boot.log; mechanics in
  `streamer-play`): the ramp stops where the output device stops it, it has
  a step budget that fits the boot budget, and it yields to a level set
  elsewhere (bar panel or SSH wins over the boot's own climb).
- **A saved level at or below the floor counts as a parked control, not a
  preference**: it is replaced by the configured default, in boot.log.
  Deliberately quiet is `streamer stop`, a different thing.
- **Pi 5 note:** the DAC+ driver had a real Pi 5 bug on non-Raspberry-Pi-OS
  kernels (LP #2060240); Pi 5 stays bench-only, so this is gated behind the
  Pi 5 image decision.

## 7. Storage & power-cut safety

Architecture as built (the earlier overlayroot/EROFS idea was dropped: it
hides which partition is writable at exactly the moment you need to know, and
gets corruptable itself mid-overlay-writeback):

- **p1** vfat `/boot/firmware`, read-only. **p2** ext4 `/`, read-only. **p3**
  ext4 `/data`, the only writable filesystem and the only one holding
  anything the player would miss. Pulling the power out has one possible
  consequence: a dirty `/data` that the distro's own fsck repairs at the next
  boot — that is the entire recovery protocol.
- **The read-only is done in fstab, not on the kernel command line**: an
  fstab line saying `defaults` overrides a cmdline `ro`
  (`systemd-remount-fs` applies fstab on top), and the first card shipped
  with a writable root because of exactly that. The build edits the fstab in
  place (`image/fstab-ro.awk`).
- **p3 is a finished, seeded filesystem made at build time, at a fixed size**
  (`--data-size`, default 1 GiB): a boot that rewrites a partition table is a
  boot that can be interrupted on the one disk that has everything, so the
  card never resizes anything. The seed directory is the single source of
  truth for the shape of a fresh `/data`. Giving an existing card more space
  is a manual, once-in-its-life step (`growpart` + `resize2fs`).
- **The `/data` mount is by filesystem label, with `nofail` and fsck pass
  2.** A `/data` that cannot be mounted does not stop the boot: the player
  units ask for `data.mount` and fail with it, and the box stays reachable
  over SSH to be fixed.
- Writable content that must survive a cut, all at the top of `/data` (which
  is what makes a clean slate one command): cliamp config and credentials
  (symlinked from `~/.config/cliamp`), the appliance's record of what to
  play next boot and at what level (`/data/streamer/state`),
  `/data/streamer/boot.log`, and the LAN server's token. That state record
  has exactly one writer — the `streamer` command, at the moment a person
  changes something; nothing writes it on a timer, which is what keeps it an
  intent rather than a position snapshot.
- **journald stays deliberately volatile.** A durable journal on `/data`
  would be left dirty at exactly the instant of a hard cut. The durable
  record is `boot.log`: one line per event, written by a single appender
  (`streamer-bootlog`) that survives overlapping attempts of a boot that
  keeps failing (mechanics, including file-level locking and ownership
  recovery, are commented in the script). Read back with `streamer boots`.
- **Boot self-healing was removed** (boot counter + rollback of
  `config.txt`/`cmdline.txt`). It protected against one scenario — an audio
  switch on a headless box — and cost two units, two scripts and a state
  file. On a read-only root the same protection is one SSH session and
  `streamer audio jack`; if the card truly will not boot, the firmware
  partition is writable from any card reader. Not rebuilding it is a
  decision, recorded so it stays one.
- Nothing is deleted from the base image that merely looks unused:
  cloud-init, wifi/bt and the resize/apt/e2scrub units are neutralised by
  config or unlinked, because a stock unit that turns out to matter is
  cheaper to keep than to debug.
- **Updating a binary without remounting:** the daemon's `PATH` puts
  `/data/bin` in front of `/usr/local/bin`, so a newer `ffmpeg` (or cliamp,
  or an added `yt-dlp`) can be dropped on the writable partition with the
  image copy as fallback.
- **Factory reset = `streamer reset --yes`**: stop the player, clear `/data`,
  copy the template back from `/usr/share/streamer/seed` — the same tree the
  build seeded the partition with, which is why a reset card and a freshly
  built one are identical. Providers logged out, defaults restored.
- **Identity is per build, not per vendor image.** `machine-id`, the SSH host
  keys and the root UUID all come shared from the stock image and leak into
  DHCP, mDNS and the first SSH session; the build regenerates all three and
  saves the host key's public half next to the image.

## 8. Player software

`cliamp` (github.com/bjarneo/cliamp), Go TUI player. Key integration facts:

- **Daemon mode** (`cliamp --daemon`): headless, same engine, owns the IPC
  socket; no tmux/screen needed. The unit's `ExecStart` is a wrapper that
  pins the floor, buffer and sample rate and deliberately does **not** start
  playback: only `streamer-play` does, which makes the floor and ramp
  unbypassable.
- **IPC**: newline-delimited JSON over `~/.config/cliamp/cliamp.sock`; verbs
  `play/pause/toggle/next/prev/status --json/volume/seek/load/eq/device`, v2
  `remote state|capabilities|events`. This is the integration surface. The
  socket path is capped at 107 characters; here it sits on `/data` behind
  the config-dir symlink, comfortably short.
- **No HTTP frontend** in cliamp itself (the upstream `cliamp-server` is a
  radio broadcast server, unrelated). Player control is socket + MPRIS only.
- **MPRIS2 on D-Bus** is published only when a session bus exists; this
  daemon runs as a system service with `User=pi` and no login session, so
  `playerctl` is not expected to work and nothing in the design depends on
  it. (`DBusSessionMode=up` is the one-line experiment if it is ever wanted.)

### 8.1 Radio
- Radio Browser directory + custom stations. Nothing baked: the box starts
  from one default station (`STREAMER_START_TARGET` in `/etc/streamer.conf`)
  and `streamer station <url>` records what you actually want, on `/data`.
  The built-in list is fetched, not duplicated in the image, so the two
  cannot drift.
- `yt-dlp` is **excluded from the Pi 4 image**: slow on Cortex-A72, the
  fattest optional dependency, and it rots monthly against a pinned
  read-only root. Radio, Tidal and local files need only ffmpeg.
- If YouTube ever becomes a requirement: the official standalone binary into
  `/data/bin/` (writable, self-updatable, already on the daemon's PATH
  ahead of the image copy — §7), accepting multi-second resolution per
  track and upstream breakage as a support cost. Search can run
  desktop-side (the Omarchy panel ships yt-dlp and only URLs cross the
  wire); playback still resolves on the Pi.

### 8.2 Tidal
- Device-code OAuth (`link.tidal.com`). **Credentials are never part of the
  image.** First run: SSH, `cliamp --provider tidal`, visit the printed
  URL, enter the code. Credentials land on `/data` and survive power-cuts
  and reflashes of the read-only root.
- Quality caveat: FLAC only for tracks with a hi-res master; others are
  served AAC 320 server-side. Accepted limitation.
- Risk: Tidal periodically revokes shared OAuth client IDs; cliamp supports
  a `client_id`/`client_secret` override as escape hatch.

### 8.3 Auto-play & resume policy (implemented)
- Requirement: every cold boot starts what the listener last chose, at the
  level they last set — station, saved playlist, or streaming-service
  playlist, with provider context, plus the listening level. Position
  inside a playlist or track is deliberately **not** part of it: this is a
  radio; a boot that came up three rows into a Tuesday playlist is
  indistinguishable from one that lost its place. The appliance records
  *what* and *how loud*, never *where*.
- cliamp's own resume state is not enough: a headless radio start bypasses
  it, so the appliance keeps its own record on `/data` and replays it
  through IPC.
- **Saved on change, not on a timer.** Every surface that changes intent —
  `streamer play/station/playlist/remember/mode/stop/vol/up/down` and the
  web page's equivalents — rewrites the whole record, carrying over
  arguments it was not given: turning the level down cannot forget the
  station, choosing a station cannot forget the level. The old periodic
  writer (one-minute timer, position and index) is gone: it bought a detail
  nobody asked for at the cost of a unit, a timer and a boot that resumed
  in the middle of things.
- The level is read back **from the player**, not recorded from what was
  asked for: the value cliamp settled at is the one the next boot should
  aim at.
- **Provider playlists are a first-class kind** (`kind=provider`,
  `provider=`, bare list id), fetched at boot through
  `provider.load` — `cliamp load` only resolves playlists saved on the
  card, which was why the box stayed silent on a Tidal playlist. Since
  `provider.load` starts playing, the boot starts row 0 only if the player
  is not already playing.
- A provider target has no hostname to wait on, so the boot additionally
  waits for an actual route and source address (budget:
  `STREAMER_NET_WAIT`) before spending the load call — asking before the
  lease lands fails as `sign-in required`. A wait that actually waits
  leaves one WARN line in boot.log; no retry, `Restart=on-failure` stays
  as the backstop for transients, not as the designed path. An https
  target likewise waits for clock sync first (`STREAMER_SYNC_WAIT`): a
  cold-boot clock behind NTP makes every TLS handshake fail as
  "certificate is not yet valid".
- `streamer remember <what> <target>` records intent without touching
  playback. The web page needs it: a tapped playlist has already started
  the music, and the plain play command on top would restart the boot
  sequence — a second start and a trip back to the volume floor — in the
  middle of a track.
- What each boot did is one line in `boot.log`: `OK <kind> <target> at N dB`
  or `FAIL …`, plus intent changes and audio-output switches, so the file
  reads as the box's history, not only its failures (§7).

## 9. Control surface

### 9.1 On the box (`streamer`, over SSH)

One command, its own help text is the reference. Groups: transport
(`play/pause/toggle/next/prev/stop`); level (`vol <dB>`, `up/down <N>` — all
through cliamp's dB, all recorded for the next boot); what to play
(`station <url>`, `playlist <name>` or `<provider>:<id>`, `stations`, `last`,
`mode last|stop`, `remember <what> <target>`); diagnostics (`status`, `log`,
`boots`); maintenance (`reload`, `audio [jack|dac]`, `rw`/`ro`,
`reset --yes`). The privileged ones re-run under sudo via a passwordless
sudoers drop-in the build ships.

### 9.2 From the desktop

Omarchy bar panel `omarchy-remote-cliamp`: one `ssh -N -L` tunnel to the Pi's
cliamp socket; search + transport + volume from the desktop. Requires
passwordless `ssh -o BatchMode=yes` and cliamp ≥1.63 on the Pi. In the
widget's entry in `~/.config/omarchy/shell.json` set
`"remoteCliamp": "/usr/local/bin/cliamp"` (the panel looks in `~/.local/bin`
by default); leave `remoteSocket` alone — `~/.config/cliamp` is a symlink to
`/data/cliamp`, so the probed path resolves. YouTube search from the panel
needs yt-dlp on the Pi and is out of v1 (§8.1).

### 9.3 On the LAN (shipped)

A token-guarded HTTP server (`streamer-http`) on port 8077 with a
phone-sized page: transport, volume, shuffle/repeat, queue, the radio list,
and provider browsing/playlists/search through the player's own IPC socket.
The token is generated on first boot into `/data`, owner-readable, printed
once to the journal. Boot intent changes go through the same `streamer`
command as over SSH, so floor, ramp and boot.log apply from every surface.

Still open: physical power strategy — a soft-latch button or WoL-style
policy instead of a dumb strip (§12).

## 10. Acceptance criteria

1. Fresh flash → the **first** boot reaches a playing source in **≤ 10 s**
   power-on-to-audio (cold boot, stopwatch at 5V application, with
   `systemd-analyze` + firmware timestamps as evidence). There is no setup
   boot: the first time this box is powered on is a runtime boot like every
   other one.
2. 20 consecutive hard power-cuts: the 21st boot succeeds, **auto-plays the
   source that was playing before the first cut**, at the level it was at,
   credentials intact. A missing or unusable saved level falls back to the
   configured default — never silence — and `streamer boots` says which
   happened.
3. `streamer toggle` over SSH works from the desktop with no interactive
   prompts, and the bar panel drives the Pi instance.
4. Bar panel controls the Pi instance (search + transport + volume).
5. First-boot Tidal login over SSH completes, and an album plays
   start-to-finish with correct hi-res where the master allows; credentials
   on `/data` survive any change to the read-only root. (A full-card reflash
   is a factory reset, §7.)
6. Rebuilding the image from this repo reproduces a working card on a second
   SD of the same size.
7. Boot behaviour (§8.3) is deterministic over the torture sequence.
8. `streamer audio jack` ↔ `dac` changes the output on a running box with no
   reflash, leaves the rest of `config.txt` untouched, and is idempotent.
9. `config.txt` can only be damaged deliberately (`streamer audio jack|dac`
   is the only writer), and recovery is proportional: usually `streamer audio
   jack` over SSH, otherwise one vfat edit from a card reader (§7).

### 10.1 Test tiers

A green result means different things at different tiers:

- **Script level** (automated, build host, no root/no Pi/no network):
  `tests/appliance-scripts.sh` runs the real payload scripts against a
  stand-in player IPC and a sandbox for `/data` and `/boot/firmware`,
  covering the boot ramp and its guards, saved-on-change intent, the
  provider-list boot including its network wait, the durable boot log under
  a boot loop, the factory reset, and the packaging (unit programs,
  interpreters). Plus the **build contract**: the recipe's real `sfdisk`,
  `mkfs.ext4 -d`, `e2fsck`, `dd`, `debugfs` run for real on an image file,
  and `fstab-ro.awk` diffed against a real card's fstab.
- **Meta level**: `tests/mutation-check.py` — every shipped behaviour has a
  deliberate break that must turn a named check red, or the check doesn't
  own that behaviour. This is what makes a green suite mean something.
- **On-device** (M1+): what no sandbox can stand in for — `ro` root *as
  systemd actually mounts it*, unit ordering against real NetworkManager,
  real cliamp, timing, dithering, the relay.
- **Torture** (M4): the 20 cuts of criterion 2, cut at arbitrary moments
  including mid-write, verifying the stock fsck repairs rather than the box
  coming up with a failed `/data`.

## 11. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| ≤10s not reached on stock userspace (Pi 4 SD I/O) | Goal miss | Critical-chain work is incremental; fallback ladder: faster SD → USB3 SSD → trimmed userspace, before considering Buildroot. SSD is bought only if the first five-boot median misses |
| Tidal revokes shared OAuth client IDs | Provider breakage | `client_id`/`client_secret` override; re-login path documented |
| cliamp updates change socket protocol (1.x → 2.x was breaking) | Control breakage | Pin the version in the image; upgrade deliberately, `/data/bin` for a trial first |
| HAT EEPROM misdetection | No audio | `force_eeprom_read=0` plus the explicit pinned overlay; `/proc/device-tree/hat/product` confirms on first boot; `streamer audio jack` is one command away |
| Ground-loop hum Pi→amp (a 1993 amp bonding the Pi's SMPS earth into its analog ground) | Audible defect | Quality PSU; test before buying a galvanic isolator; note inline transformers roll off bass, so with full-range speakers the real remedies are a proper isolator or breaking the loop at the mains side |
| `/data` wear | SD wear-out | The state file is rewritten only when a person changes something; the journal is volatile, so nothing else is written to the card at all |
| Loud surprise at power-on (the amp knob survives a hard cut) | UX / speaker damage | Boot floor −30 dBFS bounds the worst case at single-digit watts even at maximum knob (§6.4) |
| cliamp's software volume may be undithered truncation | Sound quality | Measured in M1 (§6.4); fallback is the codec's dithered digital volume from the same control surface |

## 12. Open questions

1. USB SSD vs A2 microSD for the acceptance boot time on Pi 4 — decide after
   the first bench measurement (§11 ladder).
2. Local-file (USB stick) playback: include mount plumbing in v1 or defer?
3. Pi 5 support depth: same image with `[pi4]/[pi5]` gated config vs a
   separate documented variant.
4. Physical power strategy long-term: dumb strip (current) vs soft-latch /
   Wake-on-LAN (§9.3).

## 13. Milestones

- **M0 — Image build**: done. Pinned inputs, payload installed, boot files
  patched, both filesystems checked; payload logic covered by the script
  suite and the mutation tool.
- **M1 — Bench bring-up (Pi 4, jack)**: largely done on the first real card
  — `/data` seeded and mounted on first boot, root `ro` as systemd mounts
  it, key-only SSH, boot-play of a saved station and of a Tidal playlist,
  boot log, DNS. Remaining bench checks: cliamp dB dithering and output
  sample format (§6.4), the floor/ramp at a reference dial position, the
  amp's relay close time, the baseline boot measurement.
- **M2 — I2S bring-up (Pi-DAC+)**: `streamer audio dac` on the running box,
  confirm the HAT in the device tree and `aplay -l`, check the case fit.
- **M3 — Boot tuning (Pi 4)**: §6 applied one unit at a time, 5 cold boots
  per config, median ≤10s; decide SD vs SSD on that number (§12.1).
- **M4 — Appliance hardening**: power-cut torture test incl. resume-last,
  `streamer reset --yes` on hardware, the `config.txt` recovery path, the
  first-boot provider login flow.
- **M5 — Control**: bar panel wired up; stretch: `yt-dlp` on `/data`
  (§8.1), physical power (§12.4). The LAN page is shipped (§9.3).

## 14. References

- cliamp repo & docs: github.com/bjarneo/cliamp (`docs/remote-control.md`,
  `docs/headless.md`, `docs/tidal.md`, `docs/radio.md`)
- omarchy-remote-cliamp: github.com/orsa86/omarchy-remote-cliamp
- Raspberry Pi boot-time whitepaper: RP-010196
- Raspberry Pi DAC+ product page (obsolescence floor); "Four new products:
  IQaudio is now Raspberry Pi" (explains the dual branding)
- `raspberrypi/linux`: `arch/arm/boot/dts/overlays/README` — authoritative
  overlay names and params
- Launchpad #2060240 — Pi 5 designware-i2s failure of the DAC driver (§6.4)
- Sony TA-F535R service manual — line sensitivity 150 mV / 50 kΩ, 75 W into
  8 Ω, residual noise <170 µV (§5.2 numbers)
