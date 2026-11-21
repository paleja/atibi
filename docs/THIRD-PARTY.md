# Third-party terms

`LICENSE` speaks for the files in this repo: the build recipe, the payload, the
tests, the notes. It does not speak for the artefact the repo produces, which is
a card containing software someone else wrote. This page says whose and from where,
so the pins at the top of `image/build.sh` carry a licence with them.

- **cliamp** — the player the appliance drives. `v2.4.1`, MIT, from cliamp's
  GitHub releases (`cliamp-linux-arm64`), installed as `/usr/local/bin/cliamp`.
  MIT is why shipping that binary on a card you hand out is unproblematic.
- **ffmpeg** — the decoder cliamp calls for AAC, ALAC, Opus and WMA. The
  `BtbN/FFmpeg-Builds` autobuild pinned in the recipe; its asset name ends in
  `-gpl`, so although ffmpeg itself is LGPL, this build links GPL components and
  the binary the build installs is GPL. GPL asks that the corresponding source
  be findable: the pinned tag, the asset name and the hash in `build.sh` name
  it, and BtbN publishes the source behind each autobuild.
- **the base image** — `raspios_lite_arm64-2026-10-06`, pinned by SHA256 and
  fetched from `downloads.raspberrypi.com`. Raspberry Pi OS is Debian-based: the
  packages on the root partition carry many licences, which Debian's own terms
  put on Debian to satisfy. This repo fetches the image rather than
  redistributing it, so nothing is asked of it here.
- **the vendor's own files** — `/boot/firmware/config.txt` and the firmware
  partition belong to Raspberry Pi's image and are edited in place by the build,
  not authored here. The marker block the build splices into `config.txt` is
  mine; the rest of the file is the vendor's.

Anything in this repo that was taken from another project rather than written
here keeps its attribution where it was taken; the MIT grant covers this repo's
own work, and a citation in `docs/PRD.md` — the Raspberry Pi boot-time whitepaper,
an amp's service manual — is a reference, not a copy.

## If you ever publish a card image

Publishing the `.img.xz` in `output/` rather than the recipe that builds it changes
what you are distributing: a compiled system containing GPL binaries. Then the
sources for the GPL parts have to be as available as the binaries — which is what
`build.sh` already gives you: the URL, the tag and the hash of each artefact, so
anyone can fetch the same ones and build the same card from this repo instead.
