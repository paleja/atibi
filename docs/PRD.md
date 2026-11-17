# PRD — rpi-streamer

A purpose-built Raspberry Pi appliance image for a music streamer feeding a
power amplifier. Boot-from-power-off to audible music in under 10 seconds,
hard power-cut safe, controlled remotely from the desktop bar or phone.

Status: draft v2 (2026-11-17)
Owner: janp

Changelog v1→v2: resolved boot behavior (auto-play, resume last), Tidal
provisioning (first-boot SSH login, credentials on overlay), primary board
switched to Raspberry Pi 4.

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
- Read-only root + a separate writable `/data` partition (§7) — safe to pull the
  plug at any moment.
- `cliamp` in headless daemon mode, autostarted via systemd, auto-play and
  resume of the last-played source; radio favorites baked into the image.
  No service credentials in the image — providers are logged in on first use
  over SSH (§8.2).
- Correct audio bring-up for the IQaudIO Pi-DAC+ HAT (§5, §6.4), with the 3.5mm
  jack as a build-time alternative and a runtime switch between the two, so the
  software can be proven before the HAT arrives.
- Wired Ethernet only, SSH enabled for maintenance, key-only login: no password
  in the image to guess.
- Image build is scripted (`image/build.sh`, hash-pinned inputs), so a fresh SD
  card can be rebuilt from this repo.
- Maintenance without reflashing: the audio output, the playback target, the
  volume and the CLIAMP config all live on writable storage, and a newer binary
  dropped on `/data/bin` takes precedence over the one in the root (§7).

Secondary deliverables: a desktop-side control path (bar widget or script) and
a maintenance story (config updates without reflashing).

## 3. Goals

- Power-on → audio playing (last-played source resumed) in **≤ 10 s wall
  clock**, measured from 5V applied, median of ≥5 cold boots.
- On every boot the streamer auto-plays what was playing at the previous
  power-off (radio station / playlist / provider context; stream position is
  not resumed — live streams have none).
- Survive unlimited hard power-cuts with zero manual recovery.
- Sources: internet radio (Radio Browser, ~58k stations + custom favorites),
  Tidal (OAuth device-code login), local files on a USB stick (optional).
- Control without a keyboard/monitor attached: from the Omarchy bar panel
  (`omarchy-remote-cliamp` over SSH) and from scripts via cliamp's IPC socket.
- Primary target: **Raspberry Pi 4** (the board in use). Pi 5 supported as a
  secondary/bench target where the boot plumbing differs trivially.

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
| Board | **Raspberry Pi 4** (primary, ≥2 GB RAM) | Pi 5 kept as bench/secondary. Pi 4 is audibly equivalent with this HAT; slower than Pi 5 on yt-dlp-class workloads — acceptable, see §8.1 |
| DAC | **Raspberry Pi DAC+ / IQaudIO Pi-DAC+** (MPN SC2078, EAN 5056561802374) — €26, Elecom.sk, in stock | I2S HAT, PCM5122, 24/192, line-level RCA out, HAT EEPROM. Replaces the HiFiBerry DAC2 Pro (€44.90 delivered) after a local-availability/price comparison; same DAC chip, same 112 dB SNR claim. Trade-offs listed below |
| Storage | A2-class microSD (primary). USB3 SSD possible on Pi 4 if boot time needs it | Pi 4 has no PCIe/NVMe boot; USB mass storage boot works via USB EEPROM but adds a boot stage — microSD first, measure |
| Amplifier | Existing **Sony TA-F535R** (1993, ESPR) | Not a new purchase. Chain consequences worked out in §5.2 |
| Speakers | Existing, 4–16 Ω | Inside the amp's rated load range; no constraint on the image |
| Network | Wired Ethernet | Wi-Fi adds 3–5s of untunable association+DHCP variance |
| PSU | Quality 5V/3A USB-C supply | Ground-loop hum vs amp is the known failure mode; isolate only if measured |
| Case | HAT-form Pi 4 case (Pi DAC+ is 58 × 65 mm) or stack-and-go bare | HAT stacks directly on Pi 4 GPIO, no cooler conflict at radio/Tidal loads. HiFiBerry Steel case is sized for HiFiBerry's own board outline — verify before assuming it fits |

Onboard 3.5mm jack is not a product output: PWM+RC output, ~9–10 effective
bits, poor THD, RFI leakage. A real I2S HAT replaces it entirely.

### 5.1 DAC selection: Pi DAC+ vs HiFiBerry DAC2 Pro

Same silicon (TI PCM5122), same 24-bit/192k ceiling, same 112 dB SNR claim. The
price gap is not chip quality; it is what the DAC2 Pro adds around the chip,
and we are accepting the loss:

- **Clocking.** The Pi DAC+ has no onboard oscillators — the Pi supplies MCLK,
  BCLK and LRCLK (IQaudIO's own spec sheet: "clock generator: Raspberry Pi").
  The DAC2 Pro's dual low-jitter oscillators are the main reason it costs
  twice as much. Consequence: somewhat worse jitter, which shows up as a
  raised noise floor at low levels, not as a spec-sheet number. In a
  line-level → power-amp chain this is small; it is the one place a hi-res
  Tidal "Max" master could sound marginally worse (§8.2).
- **Output level: 0–2.0 V RMS** vs 2.95 V RMS. Standard line level, so a normal
  integrated/power amp has full headroom. Last-resort knob if an amp is short
  on gain: `24db_digital_gain` on the overlay, which unlocks the PCM512x
  digital volume up to +24 dB — that is gain above 0 dBFS and clips if abused,
  so it stays out of the normal volume path (§6.4).
- **Headphone amp (TI TPA6133A)** we do not need, and its 3.5mm jack carries a
  headphone-detect MUTE that silences the RCA outputs — plugging headphones in
  mid-session kills the speakers. Not a boot risk; document it as a physical
  don't.
- **What we gain:** €19 saved, no customs/wait/tax for a Slovak buyer, board is
  in local stock, and it is a first-party Raspberry Pi product (IQaudIO's line
  was absorbed by Raspberry Pi in 2020; Pi DAC+ has a published obsolescence
  floor of January 2028) — better for a reproducible image than a discontinued
  third-party board.

If the Pi DAC+ ever goes out of stock locally, the nearest same-shop equivalent
is the HiFiBerry DAC+ Standard (RCA, ~€30, `hifiberry-dacplus-std`) — also
Pi-clocked, so no advantage over this one. If a **Raspberry Pi DAC Pro**
(PCM5242, `rpi-dacpro`) shows up locally, it is a strict upgrade at the same
form factor: one overlay-name change.

### 5.2 Amplifier chain: Sony TA-F535R (1993, ESPR)

From Sony's own service manual: line inputs (TUNER, CD, AUX, DAT/TAPE1, TAPE2)
are **150 mV / 50 kΩ** for rated output; 75 W per channel into 8 Ω (90 W on the
German-model DIN rating, 110 W at 4 Ω); line SNR 103 dB, residual noise
<170 µV; THD <0.008 % at 10 W; speakers 4–16 Ω; motor-driven volume pot with an
RM-S311 remote; a protector circuit that holds the speaker relay open after AC
switch-on (the VOLUME indicator blinks until it closes).

What that means for the image:

- **Level match is generous, not marginal.** 2.0 V RMS from the Pi DAC+ is
  22.5 dB above the 150 mV that produces rated output — the amp reaches full
  rated power with ~22 dB of headroom to spare. So `24db_digital_gain` is not
  just unneeded, it is the wrong direction to be thinking in; the live question
  is how much attenuation to hold at power-on (§6.4). 50 kΩ is a trivial load
  for the PCM5122 output driver.
- **Input selection:** a high-level line input (CD / TUNER / AUX). Never PHONO
  (2 mV MM, 0.25 mV MC — a 2 V source there is a wrecking ball), and REC OUT is
  an output, not an input. Engage `SOURCE DIRECT` to bypass the tone stage and
  leave bass/treble flat, so the Pi's output is the whole signal path.
- **The amp is never the slow device.** Its protection delay is on the order of
  a second or two (Sony doesn't publish the figure; M1 measures it) against a
  ~10 s Pi boot, so the relay is closed long before the first audio sample
  exists. §11's relay concern is therefore retired: the real risk is the knob.
- **Volume is a physical, non-volatile variable.** The pot keeps its position
  through a hard power cut, so switch-on level equals wherever the knob was
  left. Worst case — knob near maximum, cliamp at 0 dBFS — is 2.0 V into a
  150 mV-sensitive input: full rated output, clipped, on the very first sample.
  This sets the boot-volume floor in §6.4.
- The motorized pot and RM-S311 infrared remote are **not** automatable without
  an IR emitter and are not worth plumbing. Recorded so nobody re-discovers
  them later as an obvious idea.

## 6. Boot time

Budget, power-on → first audible sample. Reference points: Raspberry whitepaper
RP-010196 (covers gen4 and gen5; gen5 boots OS in ~7s at defaults — gen4 has a
shorter pre-Linux stage, no PCIe enumeration or PD negotiation).

| Stage | Budget |
|---|---|
| BootROM + EEPROM + firmware (incl. DRAM cal) | 2.5 s |
| Kernel + init | 1.5 s |
| userspace → `multi-user`-equivalent target | 2.5 s |
| cliamp daemon ready + stream buffer fill | 2.0 s |
| Headroom | 1.5 s |
| **Total** | **≤ 10 s** |

cliamp budget is +0.5s vs the Pi 5 plan: Go binary init and FLAC/AAC decode
startup are slower on Cortex-A72.

### 6.1 EEPROM config (`vcgencmd config` / raspi-config advanced)
- `BOOT_ORDER` restricted to the actual boot device only.
- `NET_INSTALL_ENABLED=0`, `NET_INSTALL_AT_POWER_ON=0`.
- (`PSU_MAX_CURRENT` is Pi 5/CM5-specific — not needed on Pi 4.)

### 6.2 `/boot/firmware/config.txt`
- `camera_auto_detect=0`, `display_auto_detect=0`, `max_framebuffers=0`
- `force_eeprom_read=0` (also required for reliable HAT detection, §6.4)
- `dtparam=audio=off`, `dtoverlay=vc4-kms-v3d,noaudio`

### 6.3 Kernel / systemd
- `cmdline.txt`: one line, the stock one, with `resize` stripped and `ro`
  appended (matches what `streamer-firstboot` puts in fstab). The build script
  prints the resulting line so it can be eyeballed.
- Wifi and Bluetooth are turned off in `config.txt` (`dtoverlay=disable-wifi`,
  `disable-bt`) rather than by masking units: the firmware overlay is cheaper and
  the kernel modules never appear. The `userconfig.service` symlink (the
  Raspberry Pi OS first-boot reconfigure job) is removed; the unit file itself is
  left in place. No `network-online.target` gate — the cliamp unit orders itself
  against the interfaces it needs.
- No initramfs work: the image boots plain ext4, which is what the stock image
  already does. Any boot-time gain from an initramfs rewrite is deferred until
  after the first measurement.
- Method: measure with `systemd-analyze critical-chain` (not `blame`), change
  one unit at a time, 5 cold boots per config, report median.

### 6.4 Audio bring-up (IQaudIO Pi-DAC+, bought)
- **Board is settled: black IQaudIO Pi-DAC+ (MPN SC2078, elecom.sk, delivered by
  20.11.2026) → `dtoverlay=iqaudio-dacplus`.** The listing carried the Raspberry
  Pi MPN/EAN as well, and electrically the two boards are the same PCM5122 part,
  so `rpi-dacplus` would almost certainly work too. Pinning the IQaudIO overlay
  is the choice; auto-detect is off anyway (`force_eeprom_read=0`).
  **Still worth one check on real hardware:**
  `cat /proc/device-tree/hat/product` to confirm what the EEPROM actually says.
- The audio output is a **runtime switch**, not a rebuild:
  `/etc/streamer/audio-{jack,dac}.txt` are spliced by `streamer audio jack|dac`
  into the `# --- streamer audio begin/end ---` block at the end of
  `config.txt`, so the jack variant can be converted to the HAT over SSH without
  reflashing. `build.sh --audio jack|dac` only picks which fragment is live on
  first boot.
- `force_eeprom_read=0` + explicit overlay (same rule as before: HAT EEPROM
  misdetection is a documented failure mode, and skipping the firmware 1-wire
  read is also boot-time budget, §6.2).
- `iqaudio-dacplus` additionally accepts `unmute_amp` / `auto_mute_amp`
  (GPIO-driven mute line handling). Not expected to be needed on the DAC+ —
  its RCA mute is the headphone-detect switch, not a GPIO amp enable — but if
  the bench unit comes up silent with the card visible in `aplay -l`, that
  parameter is the first thing to try.
- **Output device:** nothing is pinned. The payload ships no `asound.conf` and
  passes no `audio_device` to cliamp: on this image the device is whatever the
  system default sink is, which is the 3.5mm jack in the jack build and the
  PCM512x card in the DAC build, because that is what the overlay in
  `config.txt` makes it. Pinning card 0 by number is the fragile option — the
  number depends on probe order — so it stays out unless the default turns out
  to be wrong on real hardware.
- **The sound stack is PipeWire + WirePlumber** (confirmed in the base image:
  both are present), not bare ALSA. That matters for debugging, because there are
  two volumes in the chain and they are not the same control: PipeWire's own sink
  volume and mute, and the PCM512x `Digital` control underneath it. A silent
  output with a visible card can be either one. M1 check on the bench:
  `wpctl status` / `wpctl inspect <sink>` for the sink PipeWire picked and its
  volume/mute, then `amixer` for the codec. Only after both are known good is
  `unmute_amp` worth trying.
- **Volume path (decided):** all volume via cliamp's dB control so
  `playerctl`/bar panel is the single path; the card's ALSA control (PCM512x
  `Digital`) stays at 0 dB. Default driver behaviour already caps it at 0 dB —
  attenuate-only — which is what we want, and `24db_digital_gain` stays off
  (§5.2: 22 dB of headroom already exists at the amp).
- **M1 check on that decision:** is cliamp's dB applied in software, at what
  sample format does it hand samples to ALSA, and is the result dithered?
  Software attenuation followed by truncation to 16 bits leaves a floor pinned
  near −96 dBFS of the analogue full swing regardless of how much you attenuate:
  ≈0.32 mV referred to the line input, about 6 dB *above* this amp's 170 µV
  residual noise, so SNR there is ~66 dB and the Pi's volume implementation, not
  the amplifier, is the hiss floor. Undithered truncation also adds correlated
  granular artifacts, usually more objectionable than the hiss itself. Normal
  living-room listening on this amp sits around −20 to −35 dBFS, which is
  exactly the region where it binds. If cliamp negotiates S24_3LE/S32 or hands
  volume to the mixer, the whole question is moot. Otherwise move volume into
  the codec's own digital engine (a ≥32-bit path, dithered) and drive
  `amixer sset 'Digital' …` from the same control surface, leaving cliamp at
  0 dB — the one-path rule is unchanged, only which control sits at its end.
  Establish this with `amixer` output and an attenuation/null test, not by
  reading cliamp's docs.
- **Boot volume floor: −30 dBFS** (`cliamp --vol` or config), applied before the
  stream starts, then ramped to the resumed session level (§8.3). Math for the
  worst case (amp knob left at maximum): −30 dBFS ≈ 63 mV from the Pi into a
  150 mV/75 W input → ≤13 W on the first sample, 1–3 W at a typical dial
  position. Bounded, not speaker-abusing. The cost is that the first second or
  two is quiet-to-inaudible at a normal dial position before the ramp — that is
  the trade being accepted, and it is the safe side of it.
- **The floor is not bypassable, and the ramp target is the saved level, not
  0 dB** (implemented): `streamer-play` is the only thing that starts audio; it
  sets `STREAMER_VOL_FLOOR` (−30) with a failure check before playback, then
  ramps in steps from 1 s after audio starts toward the volume the previous
  session saved (`volume=` in `/data/streamer/progress`).
  `STREAMER_VOL_TARGET` (−20) is only the fallback when nothing was saved, and
  `STREAMER_VOL_MAX` (+6) clamps both ends, so a stale progress file can neither
  silence the box nor ask for full power. All of it goes through cliamp's dB, so
  there is still exactly one volume path.
- **A saved level at or below the floor counts as a parked control, not a
  preference** (§8.3): the volume control bottoms out at the floor, so replaying
  it means a permanently inaudible box after the next power cycle. That level is
  replaced by the configured default, and the substitution is written to
  `boot.log`. Deliberately quiet is `streamer stop`, which is a different thing.
- **Pi 5 note:** the IQaudIO/RPi DAC+ driver had a real Pi 5 bug (designware-i2s
  "Missing dma channel", LP #2060240) on non-Raspberry-Pi-OS kernels; it worked
  on Bookworm-based Raspberry Pi OS. Pi 5 stays bench-only (§12.3), so this is
  gated behind the Pi 5 image decision, not a v1 blocker.

## 7. Storage & power-cut safety

Architecture as built (the overlayroot/EROFS idea was dropped: it hides which
partition is writable at exactly the moment you need to know, and it gets
corruptable itself if the cut lands mid-overlay-writeback):

- **p1** vfat `/boot/firmware`, mounted read-write (it has to be: the firmware
  reads it). **p2** ext4 `/`, mounted `ro`. **p3** ext4 `/data`, the only
  writable filesystem with state in it. `build.sh` writes the p3 *partition
  table entry only*; `streamer-firstboot` grows it to the end of the card, makes
  the filesystem, seeds `/data/{streamer,bin,cliamp}` and `/data/.ready`,
  appends `,ro` to the root fstab line and installs the sudoers drop-in, then
  reboots once.
- The `/data` fstab entry is derived, not copied: `build.sh` takes the
  `label-id` from `sfdisk -d`, appends `-03`, and dies if that disagrees with the
  stock root line (`PARTUUID=<8hex>-02`). It uses `nofail` and fsck fields `0 0`.
- Writable content that must survive a cut, all on `/data`: cliamp config and
  credentials (`/data/cliamp`, symlinked from `~/.config/cliamp`), the appliance
  intent (`/data/streamer/state`: `mode`/`kind`/`target`, written only by the
  `streamer` command), playback position (`/data/streamer/progress`:
  `position=`/`index=`/`volume=`, written by `streamer-save` on a 1-minute
  timer), boot self-healing (`/data/streamer/attempt` + `last-good`) and
  `/data/streamer/boot.log`.
- **journald stays deliberately volatile** (`Storage=volatile`,
  `RuntimeMaxUse=32M` in `/etc/journald.conf.d/streamer.conf`). A durable journal
  on `/data` would be left dirty at exactly the instant of a hard cut — the one
  thing this design is supposed to avoid — and journald running before
  `local-fs.target` cannot reach a `/data` bind mount anyway. The durable record
  is `boot.log`: one line per event, appended and trimmed by the single writer
  `streamer-bootlog`, read back with `streamer boots`.
- **Boot self-healing**: every boot hashes `config.txt` + `cmdline.txt` and
  counts attempts in `/data/streamer/attempt`. Three failed boots of the same
  hash roll both files back to the last known-good copy kept in
  `/data/streamer/last-good`, which `streamer-booted` writes once the player is
  actually up. So a bad `streamer audio dac` on a box with no screen attached is
  self-correcting rather than a brick, and the counter resets on the next good
  boot.
- Nothing is deleted from the base image that merely looks unused:
  cloud-init, wifi/bt and the resize units are neutralised by config
  (`disable-wifi`/`disable-bt` overlays, `resize` stripped from `cmdline.txt`)
  rather than removed, because a stock unit that turns out to matter is cheaper
  to keep than to debug. `rpi-resize.service` was verified to be
  `ExecStart=/usr/bin/true` plus self-disable.
- **Updating a binary without remounting:** `/usr/local/bin` holds the pinned
  `cliamp` and `ffmpeg` that came from the image, and the daemon's `PATH` puts
  `/data/bin` in front of it. So `scp new-ffmpeg pi@streamer.local:/data/bin/`
  is enough to try a newer one, with the image copy as the fallback, and nothing
  ever needs `streamer rw` except the rare edit to the root filesystem itself.
- Factory reset = `mkfs.ext4` p3 (or `streamer forget` + wipe), reboot → back to
  first-boot state: providers logged out, defaults restored.

## 8. Player software

`cliamp` (github.com/bjarneo/cliamp), Go TUI player. Key integration facts:

- **Daemon mode**: `cliamp --daemon` — headless, same engine, owns the IPC
  socket; no tmux/screen needed. The unit's `ExecStart` is
  `/usr/local/bin/streamer-daemon`, a four-line wrapper that pins
  `--vol "$STREAMER_VOL_FLOOR"`, buffer and sample rate and exports the PATH
  that finds ffmpeg (§7). It deliberately does **not** start playback: only
  `streamer-play` does, which is what makes the floor and the ramp
  unbypassable.
- **IPC**: newline-delimited JSON over `~/.config/cliamp/cliamp.sock`; verbs
  `play/pause/toggle/next/prev/status --json/volume/seek/load/eq/device`,
  v2 `remote state|capabilities|events`. This is the integration surface. The
  socket path is capped at 107 characters, which is why a short config dir can
  matter (`CLIAMP_CONFIG_DIR`); here the path is `/data/cliamp/cliamp.sock`
  behind the symlink, comfortably short.
- **No HTTP frontend.** Player control is socket+MPRIS only. (`cliamp-server`
  is a radio broadcast server, unrelated.)
- **MPRIS2 on D-Bus** (`org.mpris.MediaPlayer2.cliamp`) is published by the
  daemon *when a session bus exists*. On this appliance it does not: the daemon
  is a system service with `User=pi` and no login session, so `playerctl` is
  not expected to work and nothing in the design depends on it. If it is ever
  wanted, `DBusSessionMode=up` on `streamer-cliamp.service` is the one-line
  experiment (PRD §9.2). Control from the desktop goes through the socket.

### 8.1 Radio
- Radio Browser directory + custom stations in
  `~/.config/cliamp/radios.toml`. Nothing is baked into the image here: the
  box starts from one default station (`STREAMER_START_TARGET` in
  `/etc/streamer.conf`, the built-in `https://radio.cliamp.stream/lofi/stream`)
  and `streamer station <url>` records what you actually want, on `/data`.
  `streamer stations` reads the built-in list at `STREAMER_STATION_LIST`
  rather than duplicating it in the image, so the two cannot drift.
- `yt-dlp` (YouTube/YouTube-Music extras) is **excluded from the Pi 4 image**:
  slow on Cortex-A72, it's the fattest optional dependency (Python stack), and
  it rots on a monthly cadence against a pinned read-only root. Radio, Tidal
  and local files need only ffmpeg.
- Deferred YouTube path, documented here so re-adding it is a decision, not a
  discovery: the omarchy-remote-cliamp control path splits the work but does
  not eliminate it — **search** runs desktop-side (Omarchy ships yt-dlp, only
  URLs cross the wire), but **playback resolves on the Pi** with the Pi's own
  yt-dlp. If YouTube becomes a requirement: install the official
  `yt-dlp_linux_aarch64` binary to `/data/bin/` on the **writable partition**,
  which `streamer-daemon` already searches before PATH (§7), so it is
  self-updatable without touching the read-only root — rather than the stale
  apt package. Expect multi-second resolution per track on the Pi 4 and accept
  upstream breakage as a support cost.

### 8.2 Tidal
- Device-code OAuth (`link.tidal.com`). **Credentials are never part of the
  image.** First-run flow: SSH to the streamer, run `cliamp --provider tidal`
  (or `cliamp setup`), visit the printed URL, enter the code. Credentials
  land in `~/.config/cliamp/tidal_credentials.json`, which sits on the
  overlay partition and therefore survives power-cuts and reflashes of the
  read-only root.
- Quality caveat: FLAC is served for tracks with a hi-res ("Max") master;
  tracks without one are downgraded server-side to AAC 320. Accept as known
  limitation.
- Risk: Tidal periodically revokes shared OAuth client IDs; config supports
  `client_id`/`client_secret` override as escape hatch.

### 8.3 Auto-play & resume policy (implemented)
- Requirement: every cold boot resumes what was playing at last power-off —
  same provider context, station/playlist, volume state. Live stream position is
  not applicable; for finite tracks/albums, resuming mid-track is best-effort,
  acceptable to restart the track.
- cliamp's own resume state (`~/.config/cliamp/resume.json`) is **not** enough:
  a headless radio start bypasses it (`main.go:113-118`), so the appliance keeps
  its own two files on `/data` and replays them — `state` for *what* to play,
  `progress` for *where* it was and at what level.
- **Resume order matters, and is the one thing that was got wrong in design
  review:** loading a source parks cliamp on row 0, so the live `index` is only
  a "something is loaded" gate. What actually restores an album is
  `queue.play {"index": <saved row>}` and *then*
  `seek.absolute {"value": <saved position>}`. Seeking before selecting the row,
  or trusting the live index, plays track one from the top.
- Volume interacts with the boot floor (§6.4) on purpose: start at −30 dBFS,
  then ramp toward the saved level from a second after audio starts rather than
  instantly, so a power-cut can never produce a full-power first sample even
  when the saved level was loud. Resume must not, and cannot, bypass the floor.
- What each boot did is recorded in `/data/streamer/boot.log`, written by the
  single appender `streamer-bootlog`: an `OK <kind> <target> at N dB (target M)`
  line or a `FAIL …` line, read back with `streamer boots`. It is also where
  intent changes and audio-output switches are logged, so the file reads as the
  box's history rather than only its failures.

## 9. Control surface

### 9.1 On the box (`streamer`, over SSH)

One command, and its own help text is the reference: `streamer help`. The
groups: transport (`play`/`pause`/`toggle`/`next`/`prev`/`stop`), level
(`vol <dB>`, `up`/`down <N>`, all going through cliamp's dB — §6.4), what to
play (`station <url>`, `playlist <name>`, `stations`, `last`, `mode
last|stop`, `forget`), diagnostics (`status`, `log`, `boots`), maintenance
(`reload`, `audio [jack|dac]`, `rw`/`ro`, `save`). The privileged ones
re-run themselves under sudo and say so; the first boot installs the sudoers
drop-in that makes that passwordless.

### 9.2 From the desktop (day 1)

Omarchy bar panel `omarchy-remote-cliamp`
(github.com/orsa86/omarchy-remote-cliamp): one `ssh -N -L` tunnel to the Pi's
cliamp socket, search + transport + volume from the desktop. Requirements:
passwordless `ssh -o BatchMode=yes` from the desktop, cliamp ≥1.63 on the Pi.
Two things to set in the widget's entry in `~/.config/omarchy/shell.json`,
because this image is not a stock pip user install:

```json
{ "id": "orsa.remote-cliamp",
  "servers": [ { "label": "streamer", "sshTarget": "pi@streamer.local",
                 "remoteCliamp": "/usr/local/bin/cliamp" } ] }
```

- `remoteCliamp`: the panel looks in `~/.local/bin/cliamp` by default; this
  image keeps the binary at `/usr/local/bin/cliamp` in the read-only root.
- `remoteSocket`: leave it alone. The panel probes a path relative to the remote
  home, and `~/.config/cliamp` is a symlink to `/data/cliamp` (§7), so
  `.config/cliamp/cliamp.sock` resolves. The M1 check is that it does.
- YouTube search from the panel needs a recent `yt-dlp` **on the Pi**; that is
  deliberately out of v1 (§8.1) — the panel works without it.
- The desktop may pull the level to +6 dB, which this box treats as a legal but
  loud setting; the panel's "urgent above 0 dB" warning is the user's cue.

`playerctl`/MPRIS: cliamp does expose MPRIS when the daemon runs, but that is a
D-Bus **session** bus thing and this daemon starts from a system unit with no
login session, so it is not expected to work out of the box. Not a requirement —
every control above rides the socket — and if MPRIS turns out to be wanted,
`DBusSessionMode=up` on the unit is the one-line experiment.

### 9.3 Later (stretch)

Thin HTTP→socket bridge (~50 lines, documented v2 protocol in
`docs/remote-control.md`) for phone/room control, plus physical power: consider
a soft-latch power button or a Wake-on-LAN-style policy instead of a dumb strip.
Out of scope for v1.

## 10. Acceptance criteria

1. Fresh flash → **second** boot reaches a playing source in **≤ 10 s**
   power-on-to-audio (cold boot, measured with a stopwatch at 5V application;
   log `systemd-analyze` + firmware timestamps as evidence). The first boot is
   excluded by design: it lays out `/data`, makes `/` read-only and reboots
   (§7), so it is setup, not runtime.
2. 20 consecutive hard power-cuts (strip off, any moment after boot): 21st
   boot succeeds, **auto-plays the source that was playing before the first
   cut**, and favorites/credentials are intact. If the saved position cannot be
   read, the fallback is the saved intent, never silence, and
   `streamer boots` says which happened.
3. `streamer toggle` and `cliamp toggle` over SSH work from the desktop with no
   interactive prompts (key auth), and the bar panel drives the Pi instance.
4. Bar panel controls the Pi instance (search + transport + volume).
5. First-boot Tidal login via SSH completes, and the album plays start-to-
   finish with correct hi-res where the master allows; credentials live on
   `/data`, so they survive any change to the read-only root (a full-card
   reflash, by contrast, is a factory reset — §7).
6. Rebuilding the image from this repo by a scripted path reproduces a
   working card on a second SD of the same size.
7. Boot behavior (§8.3) is deterministic: the same source resumes after every
   cut, verified over the §10.1 torture sequence.
8. `streamer audio jack` ↔ `streamer audio dac` changes the audio output on a
   running box with no reflash, leaves the rest of `config.txt` untouched, and
   is idempotent: switching to the output already in use changes nothing.
9. A deliberately broken `config.txt` (a bad audio line) is rolled back to the
   last known-good copy after three failed boots, and the rollback is visible
   in `streamer boots`.

### 10.1 Test tiers

These criteria are not all verified the same way, and the distinction matters
when reading a green result:

- **Script level** (automated, on the build host, no root, no Pi):
  `tests/appliance-scripts.sh`, eleven scenarios — ramp from the floor, resume at a
  saved row/position/level, the save round-trip, boot-count rollback, recording
  a known-good config, `mode=stop`, volume clamped at the ceiling, a player that
  never comes up, the `streamer` command's reporting, the jack/dac splice, and a
  saved level parked at the floor.
  It runs the real scripts with only their paths redirected, against a stand-in
  for the player's IPC and stubs for `systemctl`/`mount`. Covers criteria 2 (the
  logic), 7 (the logic), 8 and 9 (the mechanics).
- **On-device** (M1+): partition layout, `ro` root, systemd ordering, the
  first-boot grow-and-reboot, real cliamp IPC, timing, dithering, the relay.
  Nothing in the script suite stands in for these; they are criterion 1, 3, 5, 6
  and the on-hardware half of 2, 7 and 9.
- **Torture** (M4): the 20 hard cuts of criterion 2, cut at arbitrary moments
  including mid-write of the progress file, plus the rollback of criterion 9.

## 11. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| ≤10s not reached on stock-Debian userspace (Pi 4 SD I/O) | Goal miss | Critical-chain work is incremental; fallback ladder: faster SD → USB3 SSD → trimmed userspace, in that order, before considering Buildroot. A2 microSD is the starting point; the SSD is bought only if the first five-boot median misses |
| Resume-last (§8.3) not natively supported by cliamp | Feature gap | Built and tested here: the appliance keeps its own `state`/`progress` files and replays them through IPC. What M1 still has to confirm is the IPC shape — that `cliamp load <name>` resolves a playlist by name and `queue.play {"index":N}` takes a row number (`cliamp remote call capabilities` lists the parameter hints) |
| Tidal revokes shared OAuth client IDs | Provider breakage | `client_id`/`client_secret` override in config; re-login path documented; alert on status code in logs |
| cliamp updates change socket protocol (1.x → 2.x was a breaking change) | Control breakage | Pin cliamp version in image; upgrade deliberately via reflash/overlay update |
| HAT EEPROM misdetection | No audio | `force_eeprom_read=0` plus an explicit `dtoverlay=iqaudio-dacplus` matched to the black board bought (§6.4); `/proc/device-tree/hat/product` confirms it on first boot, and `streamer audio jack` is one command away if it is wrong |
| Ground-loop hum Pi→amp (a 1993 amp bonding the Pi's SMPS earth into its own analog ground) | Audible defect | Quality PSU; test before buying a galvanic isolator; isolate only if present. Note the cheap fix (inline 1:1 transformer) rolls off bass below ~40 Hz, so with full-range speakers the acceptable remedies are a proper isolator or breaking the loop at the PSU/mains side |
| `/data` wear from state writes | SD wear-out | State is written on intent change and once a minute by `streamer-save` (a few bytes, ≈4 MB/day worst case); the journal is volatile, so nothing else is written to the card at all (§7) |
| Loud surprise at power-on: the amp's volume knob is a physical setting that survives a hard power cut | UX / possible speaker damage | Boot volume floor −30 dBFS (§6.4) bounds the worst case at ≤13 W even with the knob at maximum. The amp's own speaker-protection delay closes before the Pi produces audio, so there are no relay-clipped first seconds (§5.2) |
| cliamp's software volume is undithered truncation, raising the hiss floor at low listening levels | Sound quality | Measured in M1 (§6.4); fallback is the codec's dithered digital volume driven from the same control surface |

## 12. Open questions

1. USB SSD vs A2 microSD for the v1 acceptance boot time on Pi 4 — decide
   after first bench measurement (§11 ladder).
2. Local-file (USB stick) playback: include mount plumbing in v1 or defer?
3. Pi 5 support depth: same image with `[pi4]/[pi5]` gated config (likely
   sufficient) vs a separate documented variant.
4. Physical power strategy long-term: dumb strip (current) vs soft-latch/
   Wake-on-LAN — tracked as stretch in §9.

## 13. Milestones

- **M0 — Image build (done on the build host, not on a Pi)**: pinned base image,
  cliamp and ffmpeg fetched and hash-verified, appliance payload installed, boot
  files patched, both filesystems checked. The payload's logic is covered by
  `tests/appliance-scripts.sh`, a regression suite that runs the real scripts
  against a stand-in player and a sandbox for `/data` and `/boot/firmware`.
  Not covered by it: anything that touches real block devices, systemd, or real
  cliamp — that is M1.
- **M1 — Bench bring-up (Pi 4, 3.5mm jack first)**: write the card, let
  `streamer-firstboot` lay out `/data`, confirm `ro` root and SSH-by-key, and get
  music out of the jack while the HAT is in the post. Then, on the bench:
  `cliamp remote call capabilities` to confirm the IPC forms the resume code
  assumes (§8.3); what `cliamp radio --list` and the station list actually print;
  whether cliamp's dB is dithered at 16-bit output (§6.4); the −30 dBFS floor and
  ramp at a reference dial position; the amp's speaker-relay close time
  (§5.2). Measure the baseline boot number here, before any tuning.
- **M2 — I2S bring-up (Pi-DAC+, arrives 20.11.2026)**: `streamer audio dac` on
  the running box (or `build.sh --audio dac` for a fresh card), confirm the HAT
  in `/proc/device-tree/hat/product` and `aplay -l`, `unmute_amp` only if the
  card enumerates but is silent, then check the 58×65 mm outline against the case.
- **M3 — Boot tuning (Pi 4)**: §6 applied, one unit at a time, 5 cold boots per
  config, median ≤10s; decide SD vs USB SSD on that number (§12.1).
- **M4 — Appliance hardening**: power-cut torture test incl. resume-last
  (§10.1), factory reset, the boot-failure rollback on real hardware,
  first-boot provider login flow.
- **M5 — Control**: bar panel wired up (`omarchy-remote-cliamp`); stretch: HTTP
  bridge, `yt-dlp` on `/data` (§8.1).

## 14. References

- cliamp repo & docs: github.com/bjarneo/cliamp (`docs/remote-control.md`,
  `docs/headless.md`, `docs/tidal.md`, `docs/radio.md`)
- omarchy-remote-cliamp: github.com/orsa86/omarchy-remote-cliamp
- Raspberry Pi boot-time whitepaper: RP-010196
- Raspberry Pi: DAC+ product page (MPN SC2078, obsolescence floor January 2028);
  audio boards documentation; "Four new products: IQaudio is now Raspberry Pi"
  (2020 acquisition — explains the IQaudIO/Raspberry Pi dual branding)
- `raspberrypi/linux`: `arch/arm/boot/dts/overlays/README` — authoritative
  overlay names and params (`rpi-dacplus`, `iqaudio-dacplus`,
  `24db_digital_gain`, `unmute_amp`/`auto_mute_amp`)
- Launchpad #2060240 — Pi 5 `designware-i2s` "Missing dma channel" failure of
  the IQaudIO driver (Pi 5 gating context, §6.4)
- Sony TA-F535R: service manual (TA-F435R/F535R, spec pages) and HifiEngine
  data sheet — line sensitivity 150 mV / 50 kΩ, 75 W into 8 Ω, line SNR 103 dB,
  residual noise <170 µV (§5.2 numbers)
- HiFiBerry (alternative-board path only): DAC2 Pro datasheet; "Changes in
  HiFiBerry drivers" (overlay split, kernel 6.1.77); "Configuring Linux 4.x or
  higher"

