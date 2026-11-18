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
- `cliamp` in headless daemon mode, autostarted via systemd, auto-play of
  whatever source the listener last chose at the level they last set; radio
  favorites baked into the image.
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
- On every boot the streamer auto-plays the source the listener last chose
  (radio station, saved playlist, or streaming-service playlist) at the level
  they last set. Position is not resumed: a live stream has none, and coming up
  mid-playlist is a detail rather than a feature (§8.3).
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
- `cmdline.txt`: one line, the stock one, with the bare `resize` token stripped
  and `ro` appended. The `ro` here is intent, not the mechanism: an fstab line
  that says `defaults` overrides it, which is how the first card ran with a
  writable root (§7). The build script prints the resulting line so it can be
  eyeballed.
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
- **The sound stack is bare ALSA on the delivered card** (verified on the first
  real card, 2026-11-18: no PipeWire, no WirePlumber, no `pactl` in
  `raspios_lite_arm64-2026-10-06`; nothing audio-related runs at boot;
  cliamp logs one harmless `pactl: executable file not found` probe line and
  falls through to ALSA). That is one volume path, not two — cliamp's dB on
  top, the codec's ALSA control underneath. The earlier "PipeWire confirmed in
  the base image" note was wrong (the grep must have hit config fragments, not
  installed binaries). If PipeWire ever shows up (desktop-based image, §12),
  re-derive this: the chain would gain a sink volume in between.
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
  ramps in steps from 1 s after audio starts toward the volume the listener
  last set (`volume=` in `/data/streamer/state`, written when the level
  changes — see §8.3).
  `STREAMER_VOL_TARGET` (−20) is only the fallback when nothing was saved, and
  `STREAMER_VOL_MAX` (+6) clamps both ends, so a stale record can neither
  silence the box nor ask for full power. All of it goes through cliamp's dB, so
  there is still exactly one volume path.
- **The ramp cannot outlive the boot, and it yields to a hand on the volume.**
  Three guards, all of them writing one line to `boot.log` so the reason is
  legible after the fact:
  *a level that will not move* — if a step leaves the reported level unchanged,
  the output device has its own limit and continuing would be a loop that ends
  only when the unit's start timeout kills it, so the ramp stops where the
  device stops it;
  *a step budget* (`STREAMER_RAMP_MAX_STEPS`, 16, which covers the floor-to-
  ceiling worst case inside the 10 s boot budget) as the backstop for anything
  else;
  *a level set elsewhere* — if the reported level lands more than one ramp step
  away from where the boot's own adjustment left it, somebody used the bar
  panel or an SSH session, their setting wins, and the boot does not climb back
  over it. A level that was already there before the boot began is not this
  case: that is simply the level the ramp starts from.
- **A saved level at or below the floor counts as a parked control, not a
  preference**: the volume control bottoms out at the floor, so replaying it
  means a permanently inaudible box after the next power cycle. That level is
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

- **p1** vfat `/boot/firmware`, mounted **read-only**. **p2** ext4 `/`, mounted
  **read-only**. **p3** ext4 `/data`, the only writable filesystem, and the only
  one that holds anything the player would miss. Nothing else on the card is
  ever written while it runs, so pulling the power out has one possible
  consequence: a dirty `/data` that fsck repairs at the next boot.
- **The read-only is done in fstab, not on the kernel command line.** That is
  the part that was wrong the first time: the stock fstab lines say `defaults`,
  and `systemd-remount-fs` applies fstab on top of a cmdline that says `ro`, so
  the first card ran with a writable root while every comment said otherwise. The
  build appends `,ro` to the option field of the `/` and `/boot/firmware` lines,
  idempotently, in place, keeping the column alignment that makes the file
  readable by eye over SSH. The program that does it is `image/fstab-ro.awk` —
  a file rather than a quote inside the build script, so the suite can run it
  against the fstab a real card shipped (`tests/fixtures/fstab.orig`) and show
  what it changes, instead of trusting a program in a script nobody can run
  without root and a card. The `ro` in `cmdline.txt` (§6.3) is intent and boot-time
  early-mount behaviour; fstab is the mechanism.
- **p3 is a finished filesystem, made at build time, at a fixed size.** `build.sh`
  builds it in a plain file with one command —
  `mkfs.ext4 -q -F -b 4096 -L streamer-data -m 0 -d "$SEED" "$fsimg"` — then
  `e2fsck`s it, zeroes the check counters with `tune2fs -C 0 -i 0 -T now`, and
  splices it into the image with a single `dd` at the start sector the new
  partition entry names. No mount, no loop device, no filesystem driver written
  by hand: the tree it starts with is a directory on disk (`$STAGE/seed`, the one
  source of truth for the shape of a fresh `/data`), and `-d` is what puts it in.
  `-b 4096` is not decoration: block size is what makes a 1 GiB volume's block
  count predictable, and it is a flag the recipe has to keep.
  Shipping a *mounted-ready* partition rather than an empty one is also a
  decision: an empty p3 means `data.mount` fails, which means every player unit
  that asks for it fails, which means silence on first boot.
- **1 GiB, fixed, by `--data-size`.** No resizing on the card, at any point, ever:
  a boot that rewrites a partition table is a boot that can be interrupted
  halfway through writing it, on the one disk that has everything on it. The old
  design did that (and needed three boots, a geometry hand-off file and a boot
  counter to do it), and the whole mechanism is gone. Room for cliamp's state,
  playlists and a small local library, not a music collection. Giving an existing
  card more is a manual, once-in-its-life step taken with the box in hand:
  `growpart /dev/mmcblk0 3 && resize2fs /dev/mmcblk0p3`.
- **The fstab entry mounts by filesystem label**, `LABEL=streamer-data`, because
  the label is inside the filesystem: it was set minutes earlier by the same
  build that wrote the partition entry, and it stays true whatever the partition
  number or disk identifier turns out to be. No derived `PARTUUID`, no check
  against the stock root line, nothing to get wrong. `nofail` so a `/data` that
  cannot be mounted does not stop the boot — the player units ask for
  `data.mount` and fail with it, and the box stays reachable over SSH to be
  fixed. fsck pass `2`, so the stock `systemd-fsck` at boot looks at it and
  repairs it: that is the entire power-cut recovery protocol, and it is the
  distro's own, not a script of ours.
- Writable content that must survive a cut, all on `/data`: cliamp config and
  credentials (`/data/cliamp`, symlinked from `~/.config/cliamp`), the
  appliance's record of what to play next boot and at what level
  (`/data/streamer/state`: `mode`/`kind`/`target`, plus `provider=` and
  `volume=` when those apply), and `/data/streamer/boot.log`. That record has
  exactly one writer — the `streamer` command, at the moment a person changes
  something. Nothing in the image writes it on a timer, which is what keeps it
  an intent rather than a position snapshot, and keeps every `intent set` line
  in the durable log traceable to an action. Everything sits at the top of
  `/data`, which is what makes a clean slate one command.
- **journald stays deliberately volatile** (`Storage=volatile`,
  `RuntimeMaxUse=32M` in `/etc/journald.conf.d/streamer.conf`). A durable journal
  on `/data` would be left dirty at exactly the instant of a hard cut — the one
  thing this design is supposed to avoid — and journald running before
  `local-fs.target` cannot reach a `/data` bind mount anyway. The durable record
  is `boot.log`: one line per event, appended and trimmed as one operation by the
  single writer `streamer-bootlog`, under a lock held on the log file itself —
  no second lock file to litter the partition or get its ownership wrong —
  because a boot that keeps failing writes it from attempts that overlap. That
  writer also puts the log's ownership right whenever it can, since a log first
  written by a root SSH session would otherwise close its lines out to the
  service, which runs as `pi`: it chowns the file, and where the mode will not
  allow that it replaces the file through the directory, which the boot user owns,
  keeping what could be read of it. A log it cannot reach at all is dropped
  quietly — one message per unwritable line filled the journal on the card. Read
  back with `streamer boots`.
- **Boot self-healing was removed** (a boot counter, a known-good copy of
  `config.txt`/`cmdline.txt`, and a unit that rolled them back after three bad
  boots). It protected against one scenario — a `streamer audio dac` on a box
  with no screen, which stops the Pi booting at all — and it cost two units, two
  scripts and a state file to do it. On a read-only root the same protection is
  one SSH session and `streamer audio jack`, and if the card really will not
  boot, the firmware partition is writable from any card reader. Not rebuilding
  that is a decision, recorded here so it stays one.
- Nothing is deleted from the base image that merely looks unused:
  cloud-init, wifi/bt and the resize units are neutralised by config
  (`disable-wifi`/`disable-bt` overlays, `resize` stripped from `cmdline.txt`,
  the `.wants` symlinks for `userconfig.service`, `apt-daily*` and `e2scrub_all`
  removed) rather than removed, because a stock unit that turns out to matter is
  cheaper to keep than to debug. `rpi-resize.service` was verified to be
  `ExecStart=/usr/bin/true` plus self-disable.
- **Updating a binary without remounting:** `/usr/local/bin` holds the pinned
  `cliamp` and `ffmpeg` that came from the image, and the daemon's `PATH` puts
  `/data/bin` in front of it. So `scp new-ffmpeg pi@streamer.local:/data/bin/`
  is enough to try a newer one, with the image copy as the fallback, and nothing
  ever needs `streamer rw` except the rare edit to the root filesystem itself.
- **Factory reset = `streamer reset --yes`**: stop the player units, clear
  `/data` with `find -mindepth 1 -maxdepth 1 -exec rm -rf {} +` (not a glob, so
  dotfiles go too), copy the template back from
  `/usr/share/streamer/seed` — the same tree `build.sh` seeded the partition
  with, which is why there is one seed directory and not two — re-own it,
  `sync`, and restart the units. Providers logged out, defaults restored, the
  card playing the built-in station again. Reformatting the partition instead
  would need a remount to do it safely and would not restore the tree; the
  template is the thing that makes a reset and a fresh card identical.
- **Identity is per build, not per vendor image.** Three things a stock Raspberry
  Pi OS expects its own first boot to write, and a read-only root from the first
  boot means there is no such write to fall back on: `machine-id` (the base image
  ships one, stamped when the vendor built it, and it leaks into DHCP requests
  and mDNS names), the SSH host keys (the base image ships those in the clear, so
  every streamer answering with the same private host key makes the first session
  to any of them one somebody else could have set up), and the root partition's
  UUID, which a stock image shares across cards. The build regenerates all three
  and saves the ed25519 host key's public half next to the image, so the
  fingerprint ssh shows on first login is worth comparing once. The stock login
  banner ("SSH may not work until a valid user has been set up") is rewritten
  with a note: this box has a user, with a key, so that message is wrong on every
  login and would have every reader of this project checking whether their card
  was broken.

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
- Requirement: every cold boot starts what the listener last chose, at the level
  they last set — station, saved playlist, or streaming-service playlist, with
  the provider context, plus the listening level. Position inside a playlist or
  a track is deliberately **not** part of it: this is a radio, and a boot that
  came up three rows into a playlist from Tuesday is indistinguishable from one
  that lost its place. So the appliance records *what* and *how loud*, never
  *where*.
- cliamp's own resume state (`~/.config/cliamp/resume.json`) is still not
  enough: a headless radio start bypasses it (`main.go:113-118`), so the
  appliance keeps its own record on `/data` and replays it through IPC.
- **Saved on change, not on a timer.** `streamer play`, `station`, `playlist`,
  `remember`, `mode`, `stop`, `vol` and `up|down`, and the LAN page's equivalents,
  each rewrite the whole record, with arguments they were not given carried over
  from what is already stored: turning the level down cannot forget the station,
  choosing a station cannot forget the level. The periodic writer
  that used to do this (`streamer-save` on a one-minute timer, and the
  `position=`/`index=` it stored) is gone: it bought a detail nobody asked for
  at the cost of a unit, a timer, a second file, and a boot that resumed in the
  middle of things.
- The level is read back **from the player**, not recorded from what was asked
  for: cliamp has its own floor and ceiling, and the value it settled at is the
  one the next boot should aim at. Getting that value out of `cliamp status
  --json` is where the first real card caught the suite out — the fixtures
  printed compact JSON, the real cliamp pretty-prints with two-space indent,
  and every extractor that insisted on no space after the colon returned an
  empty string, which made both ramp guards inert without failing a single
  check. The fixtures pretty-print like the real player now, and a mutation
  entry puts the compact pattern back to prove the suite would notice.
- A playlist that lives on a streaming service is stored as `kind=provider`
  with `provider=` and the bare list id, and fetched at boot by
  `cliamp remote call provider.load --params {"provider":…,"playlist":…}`;
  `cliamp load <name>` only resolves playlists saved on the card. Passing a
  Tidal list id to `load` was why the box stayed silent on a Tidal playlist.
  Since `provider.load` starts playing, the boot starts row 0 only if the
  player is not already playing.
- A streaming-service list cannot be fetched before the card has an address, and
  a provider target is a bare list id with no hostname in it, so the name
  resolution the boot already waits for has nothing to work on there. On the
  2026-11-18 card the DHCP lease landed at 02:27:51 and `provider.load` was
  asked for at 02:27:43; cliamp could not refresh its Tidal session and answered
  `sign-in required`. The boot now waits for what a provider target actually
  needs — a route and a source address, which is what `ip route get` answers —
  inside `STREAMER_NET_WAIT`, the same budget the name check uses, and gives up
  with `FAIL no network route for provider <id>` in boot.log rather than
  spending the call. A wait that actually waits writes one `WARN network not up,
  waiting Ns for <kind> <target>` line, once rather than once per probe: the
  journal is volatile here, so a boot that spent seconds without a route is
  otherwise invisible after the fact. No retry: the wait is the fix, and
  `Restart=on-failure` on the unit stays as the backstop for transients nobody
  predicted, not as the designed path.
- `streamer remember <what> <target>` records intent without touching playback.
  The page needs it: a tapped playlist has already started the music, and
  `streamer playlist` on top of that restarts the boot sequence underneath it —
  a second start and a trip back to the volume floor in the middle of a track.
- Volume interacts with the boot floor (§6.4) on purpose: start at −30 dBFS,
  then ramp toward the saved level from a second after audio starts rather than
  instantly, so a power-cut can never produce a full-power first sample even
  when the saved level was loud. Resume must not, and cannot, bypass the floor.
- What each boot did is recorded in `/data/streamer/boot.log`, written by the
  single appender `streamer-bootlog`, which locks the file against the other
  attempts of a boot that keeps failing (§7): an `OK <kind> <target> at N dB
  (target M)` line or a `FAIL …` line, read back with `streamer boots`. It is
  also where intent changes and audio-output switches are logged, so the file
  reads as the box's history rather than only its failures.

## 9. Control surface

### 9.1 On the box (`streamer`, over SSH)

One command, and its own help text is the reference: `streamer help`, or
`streamer nonsense` for the same list and a non-zero exit. The groups: transport (`play`/`pause`/`toggle`/`next`/`prev`/`stop`), level
(`vol <dB>`, `up`/`down <N>`, all going through cliamp's dB and all recorded for
the next boot — §6.4, §8.3), what to play (`station <url>`, `playlist <name>`,
`playlist <provider>:<id>`, `stations`, `last`, `mode last|stop`,
`remember <what> <target>` for next boot without touching what is playing),
diagnostics (`status`, `log`, `boots`), maintenance
(`reload`, `audio [jack|dac]`, `rw`/`ro`, `reset --yes`). The privileged ones
re-run themselves under sudo and say so; the sudoers drop-in that makes that
passwordless is written by `build.sh`, so it is there on the first boot.

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

1. Fresh flash → the **first** boot reaches a playing source in **≤ 10 s**
   power-on-to-audio (cold boot, measured with a stopwatch at 5V application;
   log `systemd-analyze` + firmware timestamps as evidence). There is no setup
   boot any more: `/data` is made, seeded and checked inside the image, so the
   first time this box is powered on is a runtime boot like every other one.
2. 20 consecutive hard power-cuts (strip off, any moment after boot): 21st
   boot succeeds, **auto-plays the source that was playing before the first
   cut**, at the level it was at, and favorites/credentials are intact. If the
   saved level is missing or unusable, the fallback is the configured default,
   never silence, and `streamer boots` says which happened.
3. `streamer toggle` and `cliamp toggle` over SSH work from the desktop with no
   interactive prompts (key auth), and the bar panel drives the Pi instance.
4. Bar panel controls the Pi instance (search + transport + volume).
5. First-boot Tidal login via SSH completes, and the album plays start-to-
   finish with correct hi-res where the master allows; credentials live on
   `/data`, so they survive any change to the read-only root (a full-card
   reflash, by contrast, is a factory reset — §7).
6. Rebuilding the image from this repo by a scripted path reproduces a
   working card on a second SD of the same size.
7. Boot behavior (§8.3) is deterministic: the same source starts, at the saved
   level, after every cut, verified over the §10.1 torture sequence.
8. `streamer audio jack` ↔ `streamer audio dac` changes the audio output on a
   running box with no reflash, leaves the rest of `config.txt` untouched, and
   is idempotent: switching to the output already in use changes nothing.
9. `config.txt` can only be damaged deliberately (`streamer audio jack|dac` is
   the only thing that writes it, and it remounts the partition itself), and the
   recovery path is proportional: an overlay the firmware cannot apply usually
   still boots, in which case `streamer audio jack` over SSH puts it right with
   no reflash; if the box genuinely will not boot, the partition is vfat and the
   file is one edit from any card reader. Boot-time rollback of `config.txt` was
   built and then removed (§7), so this criterion is a bench check, not an
   automated one.

### 10.1 Test tiers

These criteria are not all verified the same way, and the distinction matters
when reading a green result:

- **Script level** (automated, on the build host, no root, no Pi, no network):
  `tests/appliance-scripts.sh`, twenty scenarios and 277 assertions — ramp from
  the floor (including that the floor reaches the player *before* anything is
  told to make a sound), starting from a saved target and level, saving on change
  (the level a person set lands in the record at once, a playlist tapped on a
  phone is remembered without restarting the music, and the next boot fetches it
  as a provider list rather than a local one), `mode=stop`, volume clamped at the
  ceiling, a player that never comes up, a provider the card has no credentials
  for, the `streamer` command's reporting (including `stations` pairing
  names with `stream`, never `tracks_url`, and the level the next boot starts at),
  the jack/dac splice leaving the rest
  of `config.txt` alone and being idempotent, a saved level parked at the floor,
  the three ramp guards of §6.4, a provider boot that waits for a route before
  asking the service for its list, the durable boot log keeping its window and
  its whole lines when a boot that keeps failing writes it from several attempts
  at once, and that same log when a root session has closed it out to the boot
  user, the factory reset of §7, the packaging: every
  script a unit execs names its interpreter on its first line and parses as
  shell, and every `ExecStart` in every unit points at a file the payload
  actually ships, and the mutation tool's own two guards: its anchor pass has to
  report a doubled anchor, a missing anchor and a label nothing carries, and the
  journal it keeps against a killed run may only be applied when the file still
  holds exactly the damage that journal describes.
  It runs the real scripts with only their paths redirected, against a stand-in
  for the player's IPC and stubs for `systemctl`/`mount`/`chown`/`curl`/`ip`. The
  `ip` stub answers the route probe the build host may or may not be able to
  answer, and a scenario's `net-down` file takes that answer away, because a
  check that "waits for the network" is worthless if the network is whatever the
  laptop running the suite happens to have. The
  stand-in's volume ceiling is deliberately *above* `STREAMER_VOL_MAX`, so a
  script that forgot to clamp is caught rather than hidden. Covers criteria 2
  (the logic), 7 (the logic) and 8 (the mechanics).
- **Build contract** (the same suite, scenario 13, still no root and no Pi): the
  disk work the image recipe does, done for real on an image file. The real
  `sfdisk` writes a third partition entry, `mkfs.ext4 -d` seeds a filesystem out
  of a directory with no mount and no loop device, `e2fsck`/`blkid`/`dumpe2fs`/
  `debugfs` read the result back, `dd` splices it at the start sector and `dd`s
  it out again, and `cmp` proves the volume that came out is the volume that
  went in. The scenario does not run *its own* mkfs command: it lifts the one
  `build.sh` writes out of the script with `sed` and `eval`s it, so a flag the
  recipe asks for is a flag that has been seen to work and one the recipe
  quietly drops turns this red. The same scenario runs `image/fstab-ro.awk`
  against the fstab a real card shipped and compares it with a file somebody
  wrote by hand — the only difference allowed is the letters `ro`, in the right
  place — and checks it is idempotent, because a build re-run over its own
  output must not produce `defaults,ro,ro`. It also checks that every option the
  recipe asks of each tool it calls really exists, against that tool's own
  `--help`, and that the build reads back the partition table, the spliced
  volume and the seeded tree rather than assuming them.
  This exists because the sandbox cannot imitate the disk work: no loop devices
  without root, and a stub that invents a flag (`blockdev --getstart`, `sfdisk
  -u=S`) proves nothing except that the author believed it. Running the real
  tools on an image file is the only way to check that belief short of a card.
- **Meta level** (automated): `tests/mutation-check.py` breaks one shipped
  behaviour at a time (fifty-two: the boot floor and the order it is set in, the
  parked-level rule, the ceiling, `url.load` versus plain queueing, a provider
  list fetched as a local playlist, a second start on top of a provider list that
  `provider.load` already started, a provider playlist stored as a kind nothing
  handles, a status reader that insists on compact JSON, the `"stream"` key, a
  level or a playlist that gets played but never written down, a rewrite that
  drops the level or the provider saved with it, `remember` reaching for the
  player instead of only the record, both ramp guards, the set-elsewhere guard,
  an https target handed to TLS with the clock still wrong, a provider playlist
  fetched with no route to fetch it over, a provider route probe that asks for a
  hostname the target never names, a network budget divided by four, a wait for
  the network that leaves no trace in the logs, the boot-log window under a pile
  of writers, a log whose owner was not the boot user, a helper that gives up when
  the log is closed to it, and one that answers a closed log with noise,
  the reset asking before it wipes / using a glob / wiping under a running
  player, `streamer ro`, the LAN server's token and station guards, the page
  setting the level on the player but not in the record, a tapped playlist that
  plays once and is never remembered, the submit envelope nesting its operation,
  `job.get` looking in the wrong place, the job poll budget, an invented
  `blockdev` flag, a partition table no longer read back, `mkfs` allowed to pick
  its own block size, `debugfs` used as a writer, payload interpreters no longer
  checked against the base image, three in the fstab editor: leaving root
  writable, rebuilding the line from its fields instead of editing the text, and
  catching `/data` as well; and two aimed at the tool itself: a journal applied
  whatever the file looks like now, and an anchor pass that stopped counting how
  many places a mutation points at) and requires the suite to go red on the
  check that owns that behaviour. A mutation that hangs the suite counts as
  caught — an unbounded loop in the boot script is exactly what those guards
  prevent. Two entries came back MISSED the first time they were written, and the
  fault was in the harness rather than the checks: a script that wrote no state
  file made the next line of the transcript fail its input redirection under
  `set -e`, so the run exited non-zero with no failed check to name and every
  check after it never ran. A suite that dies is not a suite that notices, so
  `-e` is now off inside a scenario and promised files are read through a helper
  that reports a missing one: the damage shows up as the red check it is. The harness keeps the unmutated text of every file it touches in
  memory and restores that text, never a fresh read from disk, and sweeps the
  tree against the baseline on the way out: a run that ends with a changed tree
  fails, because a clean verdict over a tree that was quietly modified means
  nothing. This is what makes a green suite mean something: without it, a passing
  check is only as good as its ability to fail.
- **On-device** (M1+): partition layout, `ro` root *as systemd actually mounts
  it*, systemd ordering, real cliamp IPC, timing, dithering, the relay. Nothing
  in the script suite stands in for these; they are criterion 1, 3, 5, 6, and the
  on-hardware half of 2 and 7. The fstab edit is checked offline, but only a real
  boot shows whether something else in the distro overrides it — which is exactly
  the bug the first card had.
- **Torture** (M4): the 20 hard cuts of criterion 2, cut at arbitrary moments
  including mid-write of the state file, and checking that the stock
  `systemd-fsck` at boot repairs a volume left dirty rather than the box coming
  up with an unmounted `/data` and three failed units.

## 11. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| ≤10s not reached on stock-Debian userspace (Pi 4 SD I/O) | Goal miss | Critical-chain work is incremental; fallback ladder: faster SD → USB3 SSD → trimmed userspace, in that order, before considering Buildroot. A2 microSD is the starting point; the SSD is bought only if the first five-boot median misses |
| Resume-last (§8.3) not natively supported by cliamp | Feature gap | Built and tested here: the appliance keeps its own `state` record and replays it through IPC. Checked against a live cliamp 2.4.1: `status --json` pretty-prints with two-space indent, and a streaming-service playlist needs `provider.load` — `cliamp load` only resolves lists saved on the card. What still has to be seen on the card is `cliamp remote call capabilities` confirming that `provider.load` takes exactly `{"provider":…,"playlist":…}` |
| A cold boot's DHCP lease arrives after the boot script asks the service for its list | Silent card, one failed unit in that boot's journal | Seen on the 2026-11-18 card: `provider.load` eight seconds before the lease, answered `sign-in required`. Fixed as §8.3 describes: the boot waits for a route within `STREAMER_NET_WAIT` before asking, scenario 18 checks both the late lease and no lease at all, and four mutation entries cover the wait, the probe, its budget and the log line the wait leaves. Seen fixed on the card: lease at `02:27:51.09`, `provider.load` created at `02:27:51.389` and succeeded 0.5s later, boot.log `OK provider … at -4 dB`, 0 failed units, 0 `sign-in required` in the whole cliamp log |
| Overlapping attempts of a failing boot write `/data/streamer/boot.log` at once | The one durable record of a boot comes back with holes in it, or stops coming at all | Seen on the 2026-11-18 card: 384 NUL bytes mid-file, where two lines used to be, after a boot loop (`FAIL no network route`, retried every `RestartSec`) ran the trim's rename under a writer still appending at its old offset, and two trims raced on one shared `.tmp` name. Fixed by making the append and the trim one `flock`-guarded operation, with a per-process temp name and the lock held on the log file itself: a separate lock file turned out to be a way to lose lines rather than a way to keep them, because one created by a root SSH session could not be opened by the service that runs as `pi`. The same card then showed the ownership hole directly — a root-owned, root-only-readable log left the service unable to add a line, and answered it with one journal message per attempt. The writer now puts the log back in the boot user's hands, replacing it through the directory that belongs to them if its mode will not do, and stays silent about a log it cannot write. Scenario 19 checks the visible effects (the window holds, whole lines, no NULs, nothing but the log left on the partition, the closed log replaced and still carrying the lines that could be read of it, and no stderr); the races themselves are device observations, not something a build host reproduces. Seen fixed on the card: 210 writers into a window of 200 left 200 distinct whole lines, 0 NULs, one file in `/data/streamer`, and a root-owned log came back `pi:pi` with its earlier line kept and 0 bytes on stderr |
| Tidal revokes shared OAuth client IDs | Provider breakage | `client_id`/`client_secret` override in config; re-login path documented; alert on status code in logs |
| cliamp updates change socket protocol (1.x → 2.x was a breaking change) | Control breakage | Pin cliamp version in image; upgrade deliberately via reflash/overlay update |
| HAT EEPROM misdetection | No audio | `force_eeprom_read=0` plus an explicit `dtoverlay=iqaudio-dacplus` matched to the black board bought (§6.4); `/proc/device-tree/hat/product` confirms it on first boot, and `streamer audio jack` is one command away if it is wrong |
| Ground-loop hum Pi→amp (a 1993 amp bonding the Pi's SMPS earth into its own analog ground) | Audible defect | Quality PSU; test before buying a galvanic isolator; isolate only if present. Note the cheap fix (inline 1:1 transformer) rolls off bass below ~40 Hz, so with full-range speakers the acceptable remedies are a proper isolator or breaking the loop at the PSU/mains side |
| `/data` wear from state writes | SD wear-out | The state file is rewritten only when a person changes something — a station, a playlist, a level — a few hundred bytes through a temp file and a rename, so even a day of fiddling with the volume on the phone is kilobytes, not the megabytes the old one-minute timer wrote. The journal is volatile, so nothing else is written to the card at all (§7) |
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
- **M1 — Bench bring-up (Pi 4, 3.5mm jack first)**: write the card, confirm on the
  first boot that `/data` is already mounted and seeded, that root really is `ro`
  as systemd mounted it, and that SSH answers by key only — then music out of the
  jack while the HAT is in the post. Then, on the bench:
  `cliamp remote call capabilities` to confirm the IPC forms §8.3 assumes (the
  pretty-printed `status --json` and the `provider.load` shape are already
  confirmed on the running card); what `cliamp radio --list` and the station list actually print;
  whether cliamp's dB is dithered at 16-bit output (§6.4); the −30 dBFS floor and
  ramp at a reference dial position; the amp's speaker-relay close time
  (§5.2). Measure the baseline boot number here, before any tuning.
- **M2 — I2S bring-up (Pi-DAC+, arrives 20.11.2026)**: `streamer audio dac` on
  the running box (or `build.sh --audio dac` for a fresh card), confirm the HAT
  in `/proc/device-tree/hat/product` and `aplay -l`, `unmute_amp` only if the
  card enumerates but is silent, then check the 58×65 mm outline against the case.
- **M3 — Boot tuning (Pi 4)**: §6 applied, one unit at a time, 5 cold boots per
  config, median ≤10s; decide SD vs USB SSD on that number (§12.1).
- **M4 — Appliance hardening**: power-cut torture test incl. resume-last (§10.1),
  `streamer reset --yes` on real hardware, the `config.txt` recovery path of
  criterion 9, and the first-boot provider login flow over SSH.
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

