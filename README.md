# rpi-streamer

Purpose-built Raspberry Pi appliance image: a music streamer (cliamp on a Pi 4
with an I2S DAC HAT) that comes back playing whatever was going when the power
was pulled, and survives being unplugged without warning.

- Product requirements: [docs/PRD.md](docs/PRD.md)
- Verified facts about the base image, cliamp and the kernel overlays, plus the
  open questions for the first run on real hardware:
  [docs/HANDOFF-2026-11-17.md](docs/HANDOFF-2026-11-17.md)

## How it is put together

Everything that has to be true when the card boots is written into the image by
`image/build.sh`. There is no setup script, no resizing at boot and no first-run
step: the card plays the first time it is powered on. The one thing you do after
that is sign in to Tidal over SSH, because no password or token of yours ever
goes into the image.

Power-cut safety comes from the layout: the root and the boot partition are
mounted read-only, and the only partition that is ever written to is `/data`,
which holds nothing but small files the player can do without. If the power goes
out mid-write, the worst case is a corrupt `/data` that fsck fixes at the next
boot.

## Layout

- `image/build.sh` — the whole build, and the only thing you run. It fetches and
  hash-verifies the pinned base image, cliamp and ffmpeg; settles SSH access;
  makes the tree `/data` starts with; writes a third partition entry and puts a
  finished, seeded, checked ext4 filesystem in it at a size decided here rather
  than on the card; mounts the two stock partitions and installs the appliance
  into the root; patches the firmware partition; then checks both filesystems,
  reads back what it patched, and compresses. It mounts filesystems, so it
  re-runs itself under sudo: start it from a terminal.
- `image/fstab-ro.awk` — the program `build.sh` uses to make the root and the
  boot partition read-only in `/etc/fstab`. A file rather than a quote inside
  the build script, so the suite can run it against the fstab a real card
  shipped (`tests/fixtures/`) and show what it does.
- `config/` — the payload that goes into the image, in the shape of the root
  filesystem:
  - `etc/streamer.conf` — the knobs: what to play by default, the volume floor
    and the ramp, where the state files live, and the user and group that own
    them
  - `etc/systemd/system/` — the units: the player daemon, the boot-time play, the
    position-save timer, and the target that ties them together
  - `etc/streamer/audio-{jack,dac}.txt` — the two audio setups (3.5mm jack, I2S
    DAC HAT); `streamer audio jack|dac` swaps one into `config.txt`
  - `boot/appliance-config.txt` — the block appended to `/boot/firmware/config.txt`
  - `usr/local/bin/streamer` — the command people actually use, over SSH
  - `usr/local/bin/streamer-{daemon,play,save}` — the player daemon, the
    boot-time play, and the position save
  - `usr/local/bin/streamer-bootlog` — one durable line per event; it is the only
    record that outlives a power cut

  Things `build.sh` writes into the root itself, so they have no file here: the
  `/etc/fstab` changes (read-only root and boot partition, plus a `/data` line
  that mounts by filesystem label, `nofail`, and fscks only when a power cut
  left the volume dirty), `/etc/journald.conf.d/streamer.conf` (keeps the journal
  volatile, on purpose), the hostname and timezone if you ask for them, the SSH
  `authorized_keys`, a fresh machine-id and SSH host keys for this build, and the
  `systemctl enable` symlinks for the units above.
- `tests/appliance-scripts.sh` — the regression suite for those scripts: fifteen
  scenarios, each one asserting rather than merely running. It checks the
  boot-time ramp from the floor (including that the floor is set before the
  player is told to make a sound), resuming at a saved row and position and
  level, the save round-trip, `mode=stop`, the volume ceiling and its floor, a
  level parked below it, a saved row that no longer exists, the ramp's own
  guards (a level that will not move, a step budget, a volume somebody else
  moved mid-ramp), the jack/dac switch leaving the rest of `config.txt` alone,
  the `streamer` command's reporting, the factory reset, the packaging
  (every script that systemd starts names its interpreter, and every unit points
  at a file that exists), and the image recipe itself: the real `sfdisk`,
  `mkfs.ext4 -d`, `e2fsck`, `tune2fs`, `blkid`, `dumpe2fs` and `dd`, run without
  root on an image file, plus the fstab editor run against a real fstab. No root,
  no Pi and no real cliamp: a stand-in covers the parts of the player the scripts
  talk to, and a sandbox stands in for `/data` and `/boot/firmware`. The scripts
  under test are the real ones, only their paths are redirected. The verdict is
  the last line, `N checks, M failed`, and the exit status;
  `bash tests/appliance-scripts.sh` runs all of them, or pass scenario numbers to
  run a few.
- `tests/mutation-check.py` — the test of the tests. It deliberately breaks one
  shipped behaviour at a time (twenty-one of them) and requires the suite to go
  red on the check that cares about that behaviour; anything it misses is a check
  that looks meaningful and is not. `python3 tests/mutation-check.py`, a few
  minutes, and it restores every file it touched even if a scenario hangs.
- `tests/fixtures/` — the shape `https://radio.cliamp.stream/stations` really
  answers with, and the `/etc/fstab` a real card shipped (`fstab.orig`, input)
  next to what the editor is expected to make of it (`fstab.expected`, written by
  hand). The comments in `fstab.orig` are the ones the previous build wrote, so
  the pair also shows that the editor leaves a comment alone.
- `docs/` — PRD, handoff notes, and the measurement logs once the box exists
- `.cache/` — downloaded artefacts, kept so a rebuild does not re-fetch
- `output/` — the finished `.img.xz`, its SHA256, and the SSH host key this build
  generated

## Build

    ./image/build.sh --audio jack --ssh-key ~/.ssh/streamer.pub \
        --hostname streamer --tz Europe/Bratislava

`--audio dac` builds for the I2S HAT (an IQaudIO Pi-DAC+ or anything else that
takes `dtoverlay=iqaudio-dacplus`) instead of the 3.5mm jack. If you give
neither `--ssh-key` nor `--new-key`, the script asks. The image authorises a
public key and leaves the account password locked; there is no password in the
image to guess. With `--new-key` the private half is generated under
`output/keys/` and never goes near the image. Keep a copy either way: that key is
the only way in.

`/data` is 1 GiB unless you pass `--data-size`. That is room for cliamp's state,
playlists and a small local library, not for a music collection, and it is
deliberately fixed: a partition the card never has to grow is a partition that
cannot be half-grown by an interrupted boot. To give an existing card more, grow
it from the shell (`growpart /dev/mmcblk0 3 && resize2fs /dev/mmcblk0p3`), which
is a step you take once with the box open, not something the boot does.

The script finishes by printing the smallest card that image fits on, the command
to write it, and the SSH host key fingerprint this build generated. The public
half of that key is saved next to the image as `<name>.ssh_host_ed25519.pub`, so
the fingerprint ssh shows you on first login is worth comparing once: it is how
you know the card you are talking to is the card you built.

## Writing the card

Check the device name first; `dd` writes to whatever you give it.

    sudo xz -dc output/streamer-jack-20261118.img.xz |
        sudo dd of=/dev/sdX bs=8M status=progress conv=fsync

Raspberry Pi Imager works too: choose the `.xz` as a custom image.

## Using it

    ssh -i <key> pi@streamer.local
    cliamp                      # first time only: sign in to Tidal, link.tidal.com
    streamer stations           # what the built-in radio list offers
    streamer station <url>      # play this one from now on, next boot too
    streamer                    # status; `streamer nonsense` lists the commands

Music starts by itself on every boot, at a level that ramps up from a quiet floor
so a hard power cut never wakes an amp at full volume, resuming whatever was
playing when the power was last pulled. `streamer reset --yes` wipes `/data` and
puts back exactly the tree the card shipped with, which is the same tree a fresh
card starts from; it stops the player first and asks you to mean it.
