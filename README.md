# rpi-streamer

Purpose-built Raspberry Pi appliance image: a music streamer (cliamp on a Pi 4
with an I2S DAC HAT) that boots from a cold power cut to audible music in under
10 seconds and survives hard power-cuts indefinitely.

- Product requirements: [docs/PRD.md](docs/PRD.md)
- Verified facts about the base image, cliamp and the kernel overlays, plus the
  open questions for the first run on real hardware:
  [docs/HANDOFF-2026-11-17.md](docs/HANDOFF-2026-11-17.md)

## Layout

- `image/build.sh` — the whole build. Fetches and hash-verifies the pinned base
  image, cliamp and ffmpeg; copies the base image; adds the third partition
  entry; installs the appliance payload into the root partition; patches the
  firmware partition; checks both filesystems and compresses. It mounts
  filesystems, so it re-runs itself under sudo: run it from a terminal.
- `config/` — the payload that goes into the image, in the shape of the root
  filesystem:
  - `etc/streamer.conf` — the knobs: what to play by default, the volume floor
    and the ramp, the boot-failure thresholds, where the state files live
  - `etc/systemd/system/` — the units: the daemon, the boot-time play, the
    position-save timer, the boot counter and its rollback, first boot
  - `etc/streamer/audio-{jack,dac}.txt` — the two audio setups (3.5mm jack, I2S
    DAC HAT); `streamer audio jack|dac` swaps one into `config.txt`
  - `boot/appliance-config.txt` — the block appended to `/boot/firmware/config.txt`
  - `usr/local/bin/streamer*` — the player daemon, the boot-time play, the save
    and boot-accounting helpers, and the `streamer` command people actually use
  - `usr/local/bin/streamer-bootlog` — one durable line per event; it is the
    only record that outlives a power cut

  Things `build.sh` writes into the root itself, so they have no file here: the
  `/data` line it appends to `/etc/fstab` (by a derived PARTUUID, `nofail`, no
  boot fsck), `/etc/journald.conf.d/streamer.conf` (keeps the journal volatile,
  on purpose), the hostname if you pass `--hostname`, the SSH `authorized_keys`,
  and the `systemctl enable` symlinks for the units above. The root `,ro` and
  `/etc/sudoers.d/streamer` come later, from first boot.
- `tests/appliance-scripts.sh` — the regression suite for those scripts, eleven
  scenarios: the first-boot ramp from the floor, resuming at a saved row and
  position and level, the save round-trip, the boot-failure counter and the
  boot-file rollback, `mode=stop`, the volume ceiling and a level parked at the
  floor, a player that never comes up, the `streamer` command's own reporting,
  and the jack/dac switch leaving the rest of `config.txt` alone. No root, no Pi
  and no real cliamp: a stand-in covers the parts of the player the scripts talk
  to, and a sandbox stands in for `/data` and `/boot/firmware`. The scripts under
  test are the real ones, only their paths are redirected.
- `docs/` — PRD, handoff notes, and the measurement logs once the box exists
- `.cache/` — downloaded artefacts, kept so a rebuild does not re-fetch
- `output/` — the finished `.img.xz` and its SHA256

## Build

    ./image/build.sh --audio jack --ssh-key ~/.ssh/id_ed25519.pub \
        --hostname streamer --tz Europe/Bratislava

`--audio dac` builds for the I2S HAT instead of the 3.5mm jack. If you give
neither `--ssh-key` nor `--new-key`, the script asks. The image authorises a
public key and leaves the account password locked; there is no password in the
image to guess. With `--new-key` the private half is generated under
`output/keys/` and never goes near the image.

Then the card is written by hand, and the script prints the command once it is
done. First boot lays out `/data`, makes `/` read-only and reboots; the second
boot plays.

## Using it

    ssh -i <key> pi@streamer.local
    cliamp              # first time only: sign in to Tidal, link.tidal.com
    streamer            # status; `streamer help` lists the rest

Music starts by itself on every boot, at a volume that ramps up from a floor,
resuming whatever was playing when the power was last pulled. `streamer station
<url>` and `streamer playlist <name>` choose what the next boot plays.
