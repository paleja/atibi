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
- Read-only root + overlay (§7) — safe to pull the plug at any moment.
- `cliamp` in headless daemon mode, autostarted via systemd, auto-play and
  resume of the last-played source; radio favorites baked into the image.
  No service credentials in the image — providers are logged in on first use
  over SSH (§8.2).
- Correct audio bring-up for the Pi DAC+ HAT (§5, §6.4).
- Wired Ethernet only, SSH enabled for maintenance.
- Image build is scripted (repo-based, e.g. `raspi-imager` customization /
  unattended post-install script), so a fresh SD card can be rebuilt from
  this repo.

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
- `cmdline.txt`: `quiet log_level=3`, single line.
- Mask Bluetooth, CUPS/avahi if unused, `systemd-networkd-wait-online` as a
  global gate; order the cliamp unit against `network-online.target` itself.
- No initramfs if booting plain ext4+squashfs directly is viable; otherwise
  zstd-compressed minimal initramfs.
- Method: measure with `systemd-analyze critical-chain` (not `blame`), change
  one unit at a time, 5 cold boots per config, report median.

### 6.4 Audio bring-up (Raspberry Pi DAC+ / IQaudIO Pi-DAC+)
- **Two overlay names for one electrically identical board.** Green
  Raspberry Pi-branded boards use `dtoverlay=rpi-dacplus`; black
  IQaudIO-branded stock uses `dtoverlay=iqaudio-dacplus`. Both exist in the
  kernel overlay catalogue; the EEPROM contents differ, which is what selects
  between them. Elecom's listing is labelled IQaudIO but carries the Raspberry
  Pi MPN/EAN, so the branding of the shipped unit is unresolved.
  **M1 task:** `cat /proc/device-tree/hat/product vendor` on the bench unit and
  pin the matching overlay in the image rather than relying on auto-detect.
- `force_eeprom_read=0` + explicit overlay (same rule as before: HAT EEPROM
  misdetection is a documented failure mode, and skipping the firmware 1-wire
  read is also boot-time budget, §6.2).
- `iqaudio-dacplus` additionally accepts `unmute_amp` / `auto_mute_amp`
  (GPIO-driven mute line handling). Not expected to be needed on the DAC+ —
  its RCA mute is the headphone-detect switch, not a GPIO amp enable — but if
  the bench unit comes up silent with the card visible in `aplay -l`, that
  parameter is the first thing to try.
- ALSA default = card 0 via `/etc/asound.conf` (`type hw card 0`), or rely on
  cliamp's own device selection (`cliamp device ...`).
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
- **Pi 5 note:** the IQaudIO/RPi DAC+ driver had a real Pi 5 bug (designware-i2s
  "Missing dma channel", LP #2060240) on non-Raspberry-Pi-OS kernels; it worked
  on Bookworm-based Raspberry Pi OS. Pi 5 stays bench-only (§12.3), so this is
  gated behind the Pi 5 image decision, not a v1 blocker.

## 7. Storage & power-cut safety

- Read-only squashfs/EROFS root + writable overlay (official `raspi-config`
  overlay FS option is the baseline implementation; a custom EROFS build is the
  optimization stage).
- Consequences: no fsck, no journal replay, no SD corruption on cold cut,
  boot-time win from skipping fsck entirely.
- Writable content that must survive (lives on the overlay partition):
  cliamp config (`~/.config/cliamp/`), provider credentials incl.
  `tidal_credentials.json`, radio favorites, resume-state (what to auto-play,
  §8.3), recent-play state, logs (tmpfs where possible).
- Factory reset = wipe overlay partition, reboot → back to first-boot state
  (providers logged out, defaults restored).

## 8. Player software

`cliamp` (github.com/bjarneo/cliamp), Go TUI player. Key integration facts:

- **Daemon mode**: `cliamp --daemon` — headless, same engine, owns the IPC
  socket; no tmux/screen needed. Unit: `ExecStart=cliamp --daemon` with
  resume policy per §8.3.
- **IPC**: newline-delimited JSON over `~/.config/cliamp/cliamp.sock`; verbs
  `play/pause/toggle/next/prev/status --json/volume/seek/load/eq/device`,
  v2 `remote state|capabilities|events`. This is the integration surface.
- **No HTTP frontend.** Player control is socket+MPRIS only. (`cliamp-server`
  is a radio broadcast server, unrelated.)
- **MPRIS2 on D-Bus** (`org.mpris.MediaPlayer2.cliamp`) → `playerctl` works.
  Needs a D-Bus session bus in the systemd unit (`User=`,
  `Type=dbus`/`Restart=` policy TBD).

### 8.1 Radio
- Radio Browser directory + custom stations in
  `~/.config/cliamp/radios.toml`. Favorites baked into the image.
- `yt-dlp` (YouTube/YouTube-Music extras) is **excluded from the Pi 4 image**:
  slow on Cortex-A72, it's the fattest optional dependency (Python stack), and
  it rots on a monthly cadence against a pinned read-only root. Radio, Tidal
  and local files need only ffmpeg.
- Deferred YouTube path, documented here so re-adding it is a decision, not a
  discovery: the omarchy-remote-cliamp control path splits the work but does
  not eliminate it — **search** runs desktop-side (Omarchy ships yt-dlp, only
  URLs cross the wire), but **playback resolves on the Pi** with the Pi's own
  yt-dlp. If YouTube becomes a requirement: install the official
  `yt-dlp_linux_aarch64` binary to `~/.local/bin/yt-dlp` on the **overlay
  partition** (looked up before PATH), self-updatable without touching the
  read-only root, rather than the stale apt package. Expect multi-second
  resolution per track on the Pi 4 and accept upstream breakage as a support
  cost.

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

### 8.3 Auto-play & resume policy (decided)
- Requirement: every cold boot resumes what was playing at last power-off —
  same provider context, station/playlist, shuffle/repeat/volume state.
  Live stream position is not applicable; for finite tracks/albums, resuming
  mid-track is best-effort, acceptable to restart the track.
- Implementation is cliamp-capability-dependent: verify whether session
  restore is built in (status/state persistence across daemon restarts). If
  not sufficient, the systemd unit captures `cliamp status --json` on
  shutdown/hangup (via `ExecStop` or a pre-poweroff hook) and replays it at
  boot through IPC (`cliamp load` + play). Spike this in M1/M2 — flagged as
  the main unknown of the software stack.
- Volume interacts with the boot floor (§6.4) on purpose: start at −30 dBFS,
  then apply the resumed session volume a second after audio starts rather than
  instantly, so a power-cut can never produce a full-power first sample even
  when the saved level was loud. Resume must not bypass the floor.

## 9. Control surface

- Day 1: SSH + `cliamp <verb>` IPC commands; `playerctl` over SSH.
- Day 1 (desktop): Omarchy bar panel `omarchy-remote-cliamp`
  (github.com/orsa86/omarchy-remote-cliamp) — SSH tunnel to the Pi's cliamp
  socket; search, transport, volume from the desktop. Requires
  passwordless SSH from the desktop and cliamp ≥1.63 on the Pi.
- Later (stretch): thin HTTP→socket bridge (~50 lines, documented v2 protocol
  in `docs/remote-control.md`) for phone/room control, plus physical power:
  consider a soft-latch power button or a Wake-on-LAN-style policy instead of a
  dumb strip. Out of scope for v1.

## 10. Acceptance criteria

1. Fresh flash → first boot: reaches playing radio station with **≤ 10 s**
   power-on-to-audio (cold boot, measured with a stopwatch at 5V application;
   log `systemd-analyze` + firmware timestamps as evidence).
2. 20 consecutive hard power-cuts (strip off, any moment after boot): 21st
   boot succeeds, **auto-plays the source that was playing before the first
   cut**, and favorites/credentials are intact.
3. `cliamp toggle` / `playerctl play-pause` over SSH works from the desktop
   with no interactive prompts (key auth).
4. Bar panel controls the Pi instance (search + transport + volume).
5. First-boot Tidal login via SSH completes, and the album plays start-to-
   finish with correct hi-res where the master allows; credentials persist
   across a reflash of the read-only root.
6. Rebuilding the image from this repo by a scripted path reproduces a
   working card on a second SD of the same size.
7. Boot behavior (§8.3) is deterministic: the same source resumes after every
   cut, verified over the §10.2 torture sequence.

## 11. Risks & mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| ≤10s not reached on stock-Debian userspace (Pi 4 SD I/O) | Goal miss | Critical-chain work is incremental; fallback ladder: faster SD → USB3 SSD → custom EROFS/minimal-init image, in that order, before considering Buildroot |
| Resume-last (§8.3) not natively supported by cliamp | Feature gap | Capture/replay via IPC in systemd unit (designed in §8.3); spike in M1 so the cost is known early |
| Tidal revokes shared OAuth client IDs | Provider breakage | `client_id`/`client_secret` override in config; re-login path documented; alert on status code in logs |
| cliamp updates change socket protocol (1.x → 2.x was a breaking change) | Control breakage | Pin cliamp version in image; upgrade deliberately via reflash/overlay update |
| HAT EEPROM misdetection, or green/black board variant picking the wrong overlay | No audio | `force_eeprom_read=0` + explicit overlay matched to the board after reading `/proc/device-tree/hat` in M1 (§6.4) |
| Ground-loop hum Pi→amp (a 1993 amp bonding the Pi's SMPS earth into its own analog ground) | Audible defect | Quality PSU; test before buying a galvanic isolator; isolate only if present. Note the cheap fix (inline 1:1 transformer) rolls off bass below ~40 Hz, so with full-range speakers the acceptable remedies are a proper isolator or breaking the loop at the PSU/mains side |
| Overlay partition wear (state/resume writes) | SD wear-out | tmpfs for logs; resume-state written on clean shutdown/power-loss hook, not continuously; image is cheap to replace |
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

- **M1 — Bench bring-up (Pi 4 + Pi DAC+, stock OS)**: audio out (including
  resolving the `rpi-dacplus` vs `iqaudio-dacplus` EEPROM/overlay question,
  §6.4), cliamp daemon, SSH, IPC. Establish baseline boot number. Measure the
  amp's speaker-relay close time and characterise cliamp's volume implementation
  (§5.2, §6.4). **Spike: resume-last capability of cliamp (§8.3).**
- **M2 — Boot tuning (Pi 4)**: §6 applied, overlay FS on, measure to ≤10s;
  confirm the −30 dBFS boot floor is unobtrusive at the reference dial position
  and tune the ramp to the resumed level.
- **M3 — Appliance hardening**: power-cut torture test incl. resume-last,
  factory-reset, scripted image build, first-boot provider login flow.
- **M4 — Control**: bar panel wired up; stretch: HTTP bridge.

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

