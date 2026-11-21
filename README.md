# atibi

Purpose-built Raspberry Pi appliance image: a music streamer (cliamp on a Pi 4
with an I2S DAC HAT) that comes back playing the chosen source, and survives 
being unplugged without warning.

- Requirements and design decisions: [docs/PRD.md](docs/PRD.md)
- Repo layout and how to work on this codebase: [AGENTS.md](AGENTS.md)
- License: MIT ([LICENSE](LICENSE)); what the finished card also carries from
  others: [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md)

Everything that has to be true when the card boots is written into the image at
build time: no setup script, no resizing at boot, no first-run step. The card
plays the first time it is powered on. The only thing you do after that is sign
in to Tidal over SSH, because no password or token of yours ever goes into the
image.

Power-cut safety comes from the layout: the root and boot partitions are
mounted read-only, and the only partition ever written is `/data`, which holds
nothing but small files the player can do without. If the power goes out
mid-write, the worst case is a dirty `/data` that fsck fixes at the next boot.

On every boot music starts by itself, at a level that ramps up from a quiet
floor so a hard power cut never wakes an amplifier at full volume, resuming
whatever was playing when the power was last pulled.

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

    sudo xz -dc output/atibi-jack-20261118.img.xz |
        sudo dd of=/dev/sdX bs=8M status=progress conv=fsync

Raspberry Pi Imager works too: choose the `.xz` as a custom image.

The public half of the build's SSH host key is saved next to the image as
`<name>.ssh_host_ed25519.pub`. The fingerprint ssh shows on first login is
worth comparing once: it is how you know the card you are talking to is the
card you built.

## First boot

    ssh -i <key> pi@atibi.local
    cliamp --provider tidal   # first time only: visit the printed URL, enter the code

Credentials land on `/data`.

## Using it

    atibi stations           # what the built-in radio list offers
    atibi station <url>      # play this one from now on, next boot too
    atibi                    # status

Transport, level, playlists and what to play next boot, the jack/dac audio
output switch, diagnostics and a factory reset all hang off this one command;
`atibi help` is the reference.

The card also serves a control page to anything on the LAN: open
`http://atibi.local:8077/` and the page asks for the token, made once at
first boot and kept at `/data/atibi/http.token` (owner-readable only, and
printed once to the journal, so `atibi log` shows the full signed-in URL for
the first phone that connects). From that page: transport, volume, shuffle and
repeat, the queue, the radio list, and browsing, playlists and search on every
provider the player has, Tidal included.

Whatever route a change takes — SSH or the web page — the volume floor, the
boot ramp and the boot log always apply: boot intent goes through one command.

`atibi reset --yes` wipes `/data` and puts back exactly the tree a fresh
card ships with.
