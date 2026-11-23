# atibi

A whole home music system you can build yourself, on one SD card: a
Raspberry Pi image that is a finished appliance the moment you flash it
— playing within seconds of power-on, and after any reboot back on its
own with the source and the level you last saved, even when the power
was pulled without warning.

- **Streams** from Tidal, Qobuz and Spotify, from internet radio and from
  your own files through cliamp — hi-res where the service has it — signed
  in by you over SSH, because no password or token of yours is ever baked
  into the image.
- **Hi-Fi** out through an I2S DAC HAT (or the 3.5mm jack on the workbench),
  rising from a quiet floor so a hard cut never wakes the amp at full volume.
- **A control page** for anything on the LAN, and the **Omarchy bar
  panel** (`omarchy-remote-cliamp`) on your desktop driving the same
  appliance through one SSH tunnel.
- **Reliable** by construction: root and boot are mounted read-only, and
  the only partition ever written is `/data`.
- **Yours to customise**: one config file of knobs, one command to build
  your own card.

- Requirements and design decisions, including how the desktop panel is
  wired to the card: [docs/PRD.md](docs/PRD.md)
- Repo layout and how to work on this codebase: [AGENTS.md](AGENTS.md)
- License: MIT ([LICENSE](LICENSE)); what the finished card also carries from
  others: [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md)

Everything that has to be true when the card boots is decided at build
time: no setup script, no first-run step, nothing resized or repaired on
the card. `/data` holds only what a person chose — the boot record, the
log, credentials, playlists — so the worst a power cut can cost is a dirty
`/data`, which the distro's own fsck repairs at the next boot.

## Build

    ./image/build.sh --audio jack --ssh-key ~/.ssh/atibi.pub \
        --hostname atibi --tz Europe/Bratislava

`--audio dac` builds for the I2S HAT (an IQaudIO Pi-DAC+ or anything else that
takes `dtoverlay=iqaudio-dacplus`) instead of the 3.5mm jack. If you give
neither `--ssh-key` nor `--new-key`, the script asks. The image authorises a
public key and leaves the account password locked; there is no password in the
image to guess. With `--new-key` the private half is generated under
`output/keys/` and never goes near the image. Keep a copy either way: that key
is the only way in.

`/data` is 1 GiB unless you pass `--data-size`. That is room for cliamp's
state, playlists and a small local library, not for a music collection, and it
is deliberately fixed: a partition the card never has to grow is a partition
that cannot be half-grown by an interrupted boot. To give an existing card
more, grow it from the shell (`growpart /dev/mmcblk0 3 && resize2fs
/dev/mmcblk0p3`), once, with the box in hand.

The build fetches and hash-verifies the pinned base image, cliamp and ffmpeg
(cached under `.cache/`), assembles the card, and verifies what it produced.
The finished image, its SHA256 and the SSH host key this build generated land
in `output/`. It also prints the smallest card the image fits on and the `dd`
command to write it. The script mounts filesystems, so it re-runs itself under
sudo: start it from a terminal.

## Writing the card

Check the device name first; `dd` writes to whatever you give it.

    xz -dc output/atibi-jack-20261118.img.xz |
        sudo dd of=/dev/sdX bs=8M status=progress conv=fsync

Raspberry Pi Imager works too: choose the `.xz` as a custom image.

The public half of the build's SSH host key is saved next to the image as
`<name>.ssh_host_ed25519.pub`. The fingerprint ssh shows on first login is
worth comparing once: it is how you know the card you are talking to is the
card you built.

## First boot

    ssh -i <key> pi@atibi.local
    cliamp --provider tidal   # first time only: visit the printed URL, enter the code

## Using it

    atibi stations            # what the built-in radio list offers
    atibi boot station <url>  # play this one from now on, next boot too
    atibi boot now            # next boot = what is playing now, level with it
    atibi                     # status

Transport, level, playlists and what to play next boot, the jack/dac audio
output switch, diagnostics and a factory reset all hang off this one command;
`atibi help` is the reference.

Open the page on any device on the LAN: `http://atibi.local:8077/`. It
asks for the token, made once at first boot and kept at `/data/atibi/http.token`
(owner-readable only, and printed once to the journal, so `atibi log` shows
the full signed-in URL for the first phone that connects). From that page:
transport, volume, shuffle and repeat, the queue, the radio list, and browsing,
playlists and search on every provider the player has.

Play and boot are separate verbs on both routes: `play` is what sounds
now, `boot` is what sounds next boot, and it is the saving that carries
over a reboot.

`atibi reset --yes` wipes `/data` and puts back exactly the tree a fresh
card ships with.
