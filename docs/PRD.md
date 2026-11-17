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
- Correct audio bring-up for the HiFiBerry DAC2 Pro HAT (§5, §6.4).
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
| DAC | HiFiBerry DAC2 Pro (€44.90) | I2S HAT, line-level RCA out, dual low-jitter clocks, PCM up to 24/192; Pi 4 + Pi 5 compatible |
| Storage | A2-class microSD (primary). USB3 SSD possible on Pi 4 if boot time needs it | Pi 4 has no PCIe/NVMe boot; USB mass storage boot works via USB EEPROM but adds a boot stage — microSD first, measure |
| Network | Wired Ethernet | Wi-Fi adds 3–5s of untunable association+DHCP variance |
| PSU | Quality 5V/3A USB-C supply | Ground-loop hum vs amp is the known failure mode; isolate only if measured |
| Case | HiFiBerry Steel case (Pi 4 variant) or stack-and-go bare | DAC2 Pro stacks directly on Pi 4 GPIO, no cooler conflict at radio/Tidal loads |

Onboard 3.5mm jack is not a product output: PWM+RC output, ~9–10 effective
bits, poor THD, RFI leakage. The DAC2 Pro replaces it entirely.

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
- `force_eeprom_read=0` (also required for reliable DAC2 Pro detection, §6.4)
- `dtparam=audio=off`, `dtoverlay=vc4-kms-v3d,noaudio`

### 6.3 Kernel / systemd
- `cmdline.txt`: `quiet log_level=3`, single line.
- Mask Bluetooth, CUPS/avahi if unused, `systemd-networkd-wait-online` as a
  global gate; order the cliamp unit against `network-online.target` itself.
- No initramfs if booting plain ext4+squashfs directly is viable; otherwise
  zstd-compressed minimal initramfs.
- Method: measure with `systemd-analyze critical-chain` (not `blame`), change
  one unit at a time, 5 cold boots per config, report median.

### 6.4 Audio bring-up (HiFiBerry DAC2 Pro)
- `dtoverlay=hifiberry-dacplus-pro` (kernel ≥ 6.1.77; the legacy
  `hifiberry-dacplus` overlay must NOT be used — it silently slave-clocks the
  Pro card on Pi 4, losing the board's own low-jitter clocks).
- `force_eeprom_read=0` + explicit overlay is the known-reliable combo
  (HAT EEPROM misdetection is a documented failure mode).
- ALSA default = card 0 via `/etc/asound.conf` (`type hw card 0`), or rely on
  cliamp's own device selection (`cliamp device ...`).
- ALSA mixer left at 0 dB; all volume via cliamp's dB control so
  `playerctl`/bar panel is the single volume path.

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
  slow on Cortex-A72 and it's the fattest optional dependency. Revisit only if
  actually wanted.

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
| DAC2 Pro HAT EEPROM misdetection | No audio | `force_eeprom_read=0` + explicit overlay (validated failure mode, §6.4) |
| Ground-loop hum Pi→amp | Audible defect | Quality PSU; test before buying a galvanic isolator; isolate only if present |
| Overlay partition wear (state/resume writes) | SD wear-out | tmpfs for logs; resume-state written on clean shutdown/power-loss hook, not continuously; image is cheap to replace |
| Auto-play into a cold-starting amp = first seconds clipped by amp relay, or loud surprise at high amp volume | UX / annoyance | Fixed moderate boot volume (cliamp `--vol`); measure actual audio-ready vs amp-ready during M2 tuning and document the overlap |

## 12. Open questions

1. USB SSD vs A2 microSD for the v1 acceptance boot time on Pi 4 — decide
   after first bench measurement (§11 ladder).
2. Local-file (USB stick) playback: include mount plumbing in v1 or defer?
3. Pi 5 support depth: same image with `[pi4]/[pi5]` gated config (likely
   sufficient) vs a separate documented variant.
4. Physical power strategy long-term: dumb strip (current) vs soft-latch/
   Wake-on-LAN — tracked as stretch in §9.

## 13. Milestones

- **M1 — Bench bring-up (Pi 4 + DAC2 Pro, stock OS)**: audio out, cliamp
  daemon, SSH, IPC. Establish baseline boot number. **Spike: resume-last
  capability of cliamp (§8.3).**
- **M2 — Boot tuning (Pi 4)**: §6 applied, overlay FS on, measure to ≤10s;
  settle auto-play volume and audio-ready-vs-amp-ready overlap.
- **M3 — Appliance hardening**: power-cut torture test incl. resume-last,
  factory-reset, scripted image build, first-boot provider login flow.
- **M4 — Control**: bar panel wired up; stretch: HTTP bridge.

## 14. References

- cliamp repo & docs: github.com/bjarneo/cliamp (`docs/remote-control.md`,
  `docs/headless.md`, `docs/tidal.md`, `docs/radio.md`)
- omarchy-remote-cliamp: github.com/orsa86/omarchy-remote-cliamp
- Raspberry Pi boot-time whitepaper: RP-010196
- HiFiBerry: DAC2 Pro datasheet; "Changes in HiFiBerry drivers" (Pi 5 overlay
  split, kernel 6.1.77); "Configuring Linux 4.x or higher"
