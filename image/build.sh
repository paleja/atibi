#!/usr/bin/env bash
# build.sh - make the card image this appliance boots from.
#
#   ./image/build.sh [--audio jack|dac] [--ssh-key PATH | --new-key]
#                    [--hostname streamer] [--tz Europe/Bratislava]
#                    [--data-size 1024] [--output DIR] [--keep-raw] [--no-compress]
#
# It needs root, because it mounts filesystems. Run it from a terminal and it
# asks for your password first, and then for an SSH key if you did not name one
# on the command line.
#
# What it does, in order:
#   1. become root, re-running with the same options, so nothing is asked twice.
#   2. settle SSH access: an existing public key, or a freshly generated
#      keypair whose private half stays on this machine.
#   3. fetch and verify the pinned base image, cliamp release and ffmpeg build.
#      A SHA256 mismatch stops the build; nothing here comes from a floating
#      "latest" tag.
#   4. make the tree /data starts with, as one directory, once.
#   5. copy the base image, add a third partition entry, and put a finished,
#      seeded, checked ext4 filesystem in it. The size is decided here, at
#      build time, and the card never changes it.
#   6. mount the two stock partitions and install the appliance: units, scripts,
#      the player binaries, the SSH key, the sudoers rule, /etc/fstab, hostname
#      and timezone, and the few things a read-only root cannot make later.
#   7. patch the firmware partition: the audio setup and the boot options.
#   8. check both filesystems, read the patched boot files back, compress.
#
# Everything that has to be true when the card boots is written here, into the
# image. There is no first-boot setup script, no resizing at boot, and nothing
# that has to go right on the card before the first note is audible: the card
# plays the first time it is powered on.

set -euo pipefail

# --- pins -------------------------------------------------------------------------------------
# Change these together and by hand: the hashes are what makes a rebuild months
# from now mean the same thing it means today.

BASE_DATE=2026-10-06
BASE_NAME=raspios_lite_arm64-$BASE_DATE
BASE_URL=https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-$BASE_DATE/$BASE_NAME.img.xz
# The hash of the compressed download, as Raspberry Pi publish it.
BASE_SHA=483db18a48da399b5b7022ffae9a07bc6d99daab30e593aedac09b69ff422843

CLIAMP_TAG=v2.4.1
CLIAMP_URL=https://github.com/bjarneo/cliamp/releases/download/$CLIAMP_TAG/cliamp-linux-arm64
CLIAMP_SHA=f4e591542bb834fdff2ca21a85101e9b41a1dd35e28756eccfa1a42c265babb3

# BtbN autobuild, pinned to a named release rather than latest. The binary needs
# only libraries the base image already ships. Never johnvansickle.com: it
# returns 403 to curl and has no named releases to pin.
FFMPEG_TAG=autobuild-2026-11-17-12-40
FFMPEG_ASSET=ffmpeg-N-129000-g64f6bcffaf-linuxarm64-gpl.tar.xz
FFMPEG_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/$FFMPEG_TAG/$FFMPEG_ASSET
FFMPEG_SHA=6cdd6eae6bdb4ce8be9a751d17209cd1a0f237bc8fcc866ddbc92a501df0e8e0

# --- paths and defaults -----------------------------------------------------------------------

SELF=$(realpath "$0")
REPO=$(dirname "$(dirname "$SELF")")
CONFIG=$REPO/config
CACHE=$REPO/.cache
OUT_DIR=$REPO/output
STAGE=$CACHE/stage
# Where the public half of this build's ssh host key is kept while the root
# partition is still mounted: see the identity step and the output step.
hostkey=$STAGE/ssh_host_ed25519_key.pub

# The starting tree on the writable partition, and the same tree on the read-only
# root as a template for a factory reset (see `streamer reset`). Everything
# belongs to the appliance user, and everything sits at the top of /data, so a
# single `rm -rf /data/*` is a clean slate: nested directories invite
# half-cleaned state.
#   cliamp   the player's configuration, its Tidal credentials, its socket, its
#            log, and where it had got to in a local playlist
#   bin      your own scripts, on PATH ahead of /usr/local/bin
#   music    local files, if you put any there
#   streamer state, the file that says what to play next boot, plus boot.log,
#            the one record of a boot that outlives a power cut
DATA_DIRS="cliamp bin music streamer"

# /data, in MiB. Fixed at build time, and never changed on the card: cliamp's
# state is a few hundred kilobytes, so this is room for playlists and a small
# local library, not for a music collection. A card is sold as 8 GB and holds
# 7.4 GiB, so 1024 leaves room on anything you can buy. If you want more, pass
# --data-size and use a bigger card; if you want to grow an existing card's
# /data later, `growpart` and `resize2fs` do it from the shell.
DATA_SIZE_MIB=1024

AUDIO=jack
SSH_KEY=""
NEW_KEY=0
NEW_HOSTNAME=streamer
TZONE=""
KEEP_RAW=0
COMPRESS=1

log()  { printf '%s\n' "$*" >&2; }
step() { printf '\n=== %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage: ./image/build.sh [options]

  --audio jack|dac     which output is live on the first boot (default jack)
  --ssh-key PATH       public key to authorise for the appliance user
  --new-key            generate a keypair instead, under <output>/keys/
  --hostname NAME      appliance hostname, for ssh <name>.local (default streamer)
  --tz ZONE            timezone, for example Europe/Bratislava
  --data-size MIB      size of the /data partition in MiB (default 1024)
  --output DIR         where the finished image goes (default output/)
  --keep-raw           keep the uncompressed .img next to the .xz
  --no-compress        leave the image uncompressed

The base image, cliamp and ffmpeg are downloaded once into .cache/ and checked
against the hashes pinned at the top of this file.
EOF
    exit 2
}

# --- arguments --------------------------------------------------------------------------------

# The options below are shifted away as they are read, and the build then runs
# itself again as root. Keep what was typed so the second run gets the same
# options: a re-exec that passes nothing would silently build the default
# configuration, and ask for the SSH key a second time.
RAW_ARGS=("$@")

while [ $# -gt 0 ]; do
    case $1 in
        --audio)      AUDIO=${2:?--audio needs jack or dac};                   shift 2 ;;
        --ssh-key)    SSH_KEY=${2:?--ssh-key needs a file};                    shift 2 ;;
        --new-key)    NEW_KEY=1;                                               shift ;;
        --hostname)   NEW_HOSTNAME=${2:?--hostname needs a name};              shift 2 ;;
        --tz)         TZONE=${2:?--tz needs a zone};                           shift 2 ;;
        --data-size)  DATA_SIZE_MIB=${2:?--data-size needs a number of MiB};   shift 2 ;;
        --output)     OUT_DIR=$(realpath -m "${2:?--output needs a directory}"); shift 2 ;;
        --keep-raw)   KEEP_RAW=1;                                              shift ;;
        --no-compress) COMPRESS=0;                                             shift ;;
        -h|--help)    usage ;;
        *)            die "unknown option: $1" ;;
    esac
done

# --- before anything is downloaded or written -------------------------------------------------

case $AUDIO in
    jack|dac) ;;
    *) die "--audio is jack or dac" ;;
esac
[ -f "$CONFIG/etc/streamer/audio-$AUDIO.txt" ] || die "no audio fragment for $AUDIO"
case $NEW_HOSTNAME in
    *[!a-z0-9-]*|'') die "hostname has to be lower case letters, digits and dashes: $NEW_HOSTNAME" ;;
esac
case $DATA_SIZE_MIB in
    ''|*[!0-9]*) die "--data-size is a number of MiB: $DATA_SIZE_MIB" ;;
esac
[ "$DATA_SIZE_MIB" -ge 64 ] || die "--data-size below 64 MiB leaves no room for lost+found and a fsck log"
DATA_SECTORS=$((DATA_SIZE_MIB * 2048))

for tool in curl sfdisk losetup blkid e2fsck tune2fs mkfs.ext4 dumpe2fs debugfs fsck.fat dd sudo \
            truncate mount umount bsdtar xz ssh-keygen sha256sum stat awk sed grep; do
    command -v "$tool" >/dev/null || die "$tool is missing"
done

# Every script a systemd unit starts has to name its interpreter on the first
# line. A file that is executable but has no #! line is handed to execve() and
# dies with "Exec format error" (status 203), which on a headless box means a
# silent speaker and one journal line nobody reads. This check has earned its
# place: one such file, lost in a commit, cost a whole afternoon of chasing a
# card that was otherwise built correctly.
for script in "$CONFIG"/usr/local/bin/*; do
    [ "$(head -c 2 "$script")" = "#!" ] ||
        die "$(basename "$script") has no #! line: systemd cannot start it"
done

# The build also edits a file on the card with a program of its own. Checking for
# it here is dull, and much clearer than awk's error a hundred lines into a
# session that has the card's partitions mounted.
[ -f "$REPO/image/fstab-ro.awk" ] ||
    die "image/fstab-ro.awk is missing: this script edits /etc/fstab with it"

# --- root ------------------------------------------------------------------------------------

# Partition tables, loop devices and mounts: there is no way to do any of that
# unprivileged, and a build that fails halfway because the password was never
# asked for is worse than one that asks up front. Re-running with the options as
# they were typed is what keeps the SSH key question from being asked twice.
if [ "$(id -u)" -ne 0 ]; then
    # Only ever one re-exec: if sudo hands back a shell that is still not root,
    # say so instead of asking for the password forever.
    [ -z "${STREAMER_BECAME_ROOT:-}" ] || die "sudo ran the build again, still without root privileges"
    log ""
    log "the build writes a partition table and mounts filesystems: asking for sudo now"
    STREAMER_BECAME_ROOT=1 exec sudo -E "$SELF" ${RAW_ARGS[@]+"${RAW_ARGS[@]}"}
fi

# --- ssh access -------------------------------------------------------------------------------

step "ssh access"
# No password is written into the image, in any form: the account password stays
# locked and the only way in is the key chosen here. That is why this is a
# question and not a default - an image with a password baked into it is an
# image everybody can log into.
KEYS=$OUT_DIR/keys
KEY_PRIVATE=""

looks_like_pubkey() {
    grep -qE '^(ssh-(rsa|ed25519|dss|ecdsa)|ecdsa-sha2-[0-9a-z-]+|sk-(ssh|ecdsa)-)[[:space:]]' "$1"
}

make_keypair() {
    KEY_PRIVATE=$KEYS/$NEW_HOSTNAME
    if [ -f "$KEY_PRIVATE" ]; then
        log "  reusing the keypair for $NEW_HOSTNAME: $KEY_PRIVATE"
    else
        install -d -m 700 "$KEYS"
        ssh-keygen -q -t ed25519 -C "$NEW_HOSTNAME" -f "$KEY_PRIVATE" -N ''
        log "  generated a keypair: $KEY_PRIVATE"
    fi
    # The build runs as root, and a private key only root can read is no use to
    # the person who just built the image.
    if [ -n "${SUDO_USER:-}" ]; then chown -R "$SUDO_USER" "$KEYS"; fi
    SSH_KEY=$KEY_PRIVATE.pub
}

# Resolve one answer into a public key. Returns 1 when it is not one, so the
# question gets asked again instead of a typo ending the build.
use_key_file() {
    local path=${1/#\~/$HOME}
    path=$(realpath -e -- "$path" 2>/dev/null) || return 1
    looks_like_pubkey "$path" || return 1
    SSH_KEY=$path
}

if [ -n "$SSH_KEY" ]; then
    given=$SSH_KEY
    use_key_file "$given" || die "$given is not a readable public key file"
    log "  authorising the key in $SSH_KEY"
elif [ "$NEW_KEY" = 1 ]; then
    make_keypair
elif [ -t 0 ]; then
    log "The account on the appliance has no password, so with no authorised key the
first login needs a monitor and a keyboard. Name a public key to authorise, for
example ~/.ssh/id_ed25519.pub, or press Enter for a new keypair in $KEYS."
    while :; do
        printf 'path: ' >&2
        IFS= read -r answer || die "no SSH public key given, and the terminal closed.
Pass --ssh-key /path/to/id_ed25519.pub, or --new-key to make a keypair."
        if [ -z "$answer" ]; then
            make_keypair
            break
        fi
        if use_key_file "$answer"; then
            log "  authorising the key in $SSH_KEY"
            break
        fi
        log "
  $answer is not a readable public key: check the path, or press Enter for a
  new keypair."
    done
else
    die "no SSH public key given, and there is no terminal to ask on.
Pass --ssh-key /path/to/id_ed25519.pub, or --new-key to make a keypair."
fi
log "  $(ssh-keygen -lf "$SSH_KEY")"

# --- fetch and verify -------------------------------------------------------------------------

sha_check() { # sha_check <file> <expected>
    have=$(sha256sum "$1" | cut -d' ' -f1)
    [ "$have" = "$2" ] && return 0
    die "SHA256 mismatch for $1
  expected $2
  found    $have
If the download was truncated, delete the file from $CACHE and run again.
If upstream really has changed, update the pin at the top of $SELF."
}

fetch() { # fetch <url> <target> <sha>
    if [ -f "$2" ]; then
        sha_check "$2" "$3"
        log "  cached  $(basename "$2")"
        return 0
    fi
    log "  getting $1"
    curl -fL --retry 3 --retry-delay 2 -o "$2.part" "$1"
    sha_check "$2.part" "$3"
    mv -f "$2.part" "$2"
}

step "artefacts"
mkdir -p "$CACHE" "$OUT_DIR"

BASE_XZ=$CACHE/$BASE_NAME.img.xz
RAW=$CACHE/raw.img
CLIAMP=$CACHE/cliamp-$CLIAMP_TAG-arm64
FFMPEG_TARBALL=$CACHE/$FFMPEG_ASSET
FFMPEG=$CACHE/ffmpeg-$FFMPEG_TAG

fetch "$BASE_URL" "$BASE_XZ" "$BASE_SHA"
# The pin is the hash of the compressed download, which is what Raspberry Pi
# publish. The uncompressed working copy underneath it is only trusted when it
# was made by this script while that same pin was in force, which is what the
# sidecar records: anything else is uncompressed again from the verified .xz.
RAW_SHA=$CACHE/raw.img.sha256
if [ ! -f "$RAW" ] || ! cmp -s "$RAW_SHA" <(printf '%s  raw.img\n' "$BASE_SHA"); then
    log "  uncompressing the base image"
    xz -dc "$BASE_XZ" >"$RAW.part"
    mv -f "$RAW.part" "$RAW"
    printf '%s  raw.img\n' "$BASE_SHA" >"$RAW_SHA"
else
    log "  cached  $(basename "$RAW")"
fi

fetch "$CLIAMP_URL" "$CLIAMP" "$CLIAMP_SHA"
fetch "$FFMPEG_URL" "$FFMPEG_TARBALL" "$FFMPEG_SHA"
if [ ! -f "$FFMPEG" ]; then
    # Only the decoder is wanted: ffprobe and ffplay are dead weight on a
    # headless box. bsdtar unpacks one member out of a 30 MB tarball.
    log "  extracting bin/ffmpeg from the pinned autobuild"
    tmp=$(mktemp -d "$CACHE/ff.XXXXXX")
    bsdtar -xJf "$FFMPEG_TARBALL" -C "$tmp" "*/bin/ffmpeg"
    found=$(find "$tmp" -type f -name ffmpeg | head -1)
    [ -n "$found" ] || die "no bin/ffmpeg inside $FFMPEG_ASSET"
    mv -f "$found" "$FFMPEG"
    rm -rf "$tmp"
fi
chmod 755 "$CLIAMP" "$FFMPEG"
# A friendly check on the two downloaded binaries: an x86 binary in
# /usr/local/bin on a Pi fails with "Exec format error", which for the player
# means a silent speaker. Only a warning, because this machine cannot run an
# arm64 binary to prove it.
if command -v file >/dev/null; then
    for b in "$CLIAMP" "$FFMPEG"; do
        file "$b" | grep -q 'ARM aarch64' ||
            log "  warning: $(basename "$b") does not look like an arm64 binary"
    done
fi
log "  cliamp $(du -h "$CLIAMP" | cut -f1), ffmpeg $(du -h "$FFMPEG" | cut -f1)"

# --- the tree /data starts with ---------------------------------------------------------------

step "the /data tree"
# Made once, here, as a plain directory. Two things are built from it: the
# filesystem that goes into the image, and the copy that stays on the read-only
# root as the template for `streamer reset`. That is deliberate: a reset and a
# fresh card end up with exactly the same starting tree, and there is one place
# where that tree is defined.
#
# It belongs to uid/gid 1000, which is the appliance user on Raspberry Pi OS,
# because mkfs.ext4 -d copies the ownership it sees, and so does cp -a on the
# card later. A tree owned by whoever ran this script would leave the player
# unable to write its own configuration directory.
SEED=$STAGE/seed
rm -rf "$SEED"
install -d -m 755 -o 1000 -g 1000 "$SEED"
for d in $DATA_DIRS; do
    install -d -m 775 -o 1000 -g 1000 "$SEED/$d"
done
cat >"$SEED/README" <<EOF
This is what the data partition held when the card was built, and the template a
factory reset copies back over an emptied data partition:

    streamer reset --yes

Everything in it is lost by that command, including the Tidal sign-in. The
template lives in the read-only part of the image, at /usr/share/streamer/seed.

The directories at the top of the data partition:

    cliamp   the player's configuration and its Tidal credentials, its socket,
             its log, and where it had got to in a local playlist
    bin      your own scripts, on PATH ahead of /usr/local/bin
    music    local files, if you put any there
    streamer state, the file that says what to play next boot, plus boot.log,
             the one record of a boot that outlives a power cut

A card that has never been set up plays the station named in /etc/streamer.conf.
EOF
log "  $(find "$SEED" -mindepth 1 -maxdepth 1 -type d | wc -l) directories, owned by 1000:1000"

# --- work image -------------------------------------------------------------------------------

step "work image"
mkdir -p "$STAGE"
IMG=$STAGE/card.img
LOOP=""

# Anything the desktop's volume manager has put on this loop device has to go
# before the loop device can be released: udisks2 on a desktop Linux mounts a
# new labelled ext4 partition read-write under /run/media the moment its node
# appears, and a busy loop device cannot be detached, which is how several work
# images once ended up stranded on the machine this was developed on.
drop_automounts() {
    local m
    [ -n "$LOOP" ] || return 0
    for m in $(awk -v l="$LOOP" '$3 == l || $3 ~ "^" l "p[0-9]+$" {print $2}' /proc/mounts |
                   sort -r); do
        log "  unmounting what the volume manager mounted at $m"
        umount "$m" 2>/dev/null || true
    done
}

cleanup() {
    set +e
    umount "$STAGE/fw" 2>/dev/null
    umount "$STAGE/root" 2>/dev/null
    drop_automounts
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    [ -n "$IMG" ] && rm -f "$IMG"
    rm -f "$STAGE/data-fs.img" "$hostkey"
}
trap cleanup EXIT
rm -f "$IMG"

# reflink where the filesystem supports it, which makes the 3 GB copy close to
# free; a plain copy elsewhere.
cp --reflink=auto "$RAW" "$IMG"

# The stock image leaves no free sectors after the root partition, so the image
# file has to grow before a third partition can be added to it. This is the only
# size the image ever is: nothing on the card resizes anything at boot.
truncate -s +$((DATA_SECTORS * 512)) "$IMG"

dump=$(sfdisk -d "$IMG")
# sfdisk spells the partition names differently depending on how it was asked
# for the table, so match on what every partition line has and nothing else has.
parts=$(printf '%s\n' "$dump" | grep ' : start=')
nparts=$(printf '%s\n' "$parts" | grep -c '.')
[ "$nparts" -eq 2 ] || die "the base image has $nparts partitions, expected 2:
$parts"

field() { # field <line> <name>
    printf '%s\n' "$1" | sed -n "s/.*${2}=[[:space:]]*\([0-9]*\).*/\1/p"
}
first=$(printf '%s\n' "$parts" | head -1)
last=$(printf '%s\n' "$parts" | tail -1)
p1_start=$(field "$first" start)
p2_start=$(field "$last" start)
p2_size=$(field "$last" size)
p3_start=$((p2_start + p2_size))
p3_end=$((p3_start + DATA_SECTORS))
sectors=$(( $(stat -c%s "$IMG") / 512 ))
[ -n "$p1_start" ] && [ -n "$p2_start" ] && [ -n "$p2_size" ] ||
    die "cannot read the partition table of the base image:
$parts"
[ "$sectors" -ge "$p3_end" ] ||
    die "$sectors sectors is not enough room for /data at $p3_start"

log "  firmware  start=$p1_start size=$(field "$first" size)"
log "  root      start=$p2_start size=$p2_size"
log "  data      start=$p3_start size=$DATA_SECTORS"

# Rewriting the whole table from the dump is what keeps the disk identifier, the
# partition types and the boot flag of the firmware partition exactly as the
# vendor left them. The device: line in the dump names the file the dump came
# from, so it goes: sfdisk gets the target on its command line. The new entry is
# named the way the existing ones are, so its partition number is unambiguous.
last_name=${last%% *}
new_name="${last_name%2}3"
{
    printf '%s\n' "$dump" | grep -vE '^([[:space:]]*(#|$)|device:)'
    printf '%s : start=%s, size=%s, type=83\n' "$new_name" "$p3_start" "$DATA_SECTORS"
} | sfdisk -q "$IMG"

# Read the table back, and stop if it is not the table that was asked for. This
# is the one place where a silent no-op would be unrecoverable later on the
# card, and sfdisk has versions that answer a partial request by changing
# nothing and exiting 0.
back=$(sfdisk -d "$IMG" | grep ' : start=')
[ "$(printf '%s\n' "$back" | grep -c 'start=')" -eq 3 ] ||
    die "the partition table did not gain a third entry:
$back"
# Compare the numbers, not the text: sfdisk pads the values it writes back
# (start=     6012928), so a literal match against what was asked for fails on a
# table that is correct.
third=$(printf '%s\n' "$back" | tail -1)
[ "$(field "$third" start)" = "$p3_start" ] &&
    [ "$(field "$third" size)" = "$DATA_SECTORS" ] ||
    die "the third partition is not where it was asked for:
  asked for  start=$p3_start size=$DATA_SECTORS
  found      $third"
log "the new partition table:"
printf '%s\n' "$back" | awk -F' : ' '{split($1, a, "/"); printf "  %-12s %s\n", a[length(a)], $2}' >&2

# --- the /data filesystem ---------------------------------------------------------------------

step "the /data filesystem"
# Built in a plain file, and spliced into the image at the partition's offset:
# identical bytes to the ones the card will hold, and a file cannot be
# automounted by a volume manager, which is what makes it possible to run
# e2fsck on it here.
#
# That p3 ships as a finished, mountable filesystem is a decision, and the first
# card paid for the opposite: a partition entry with nothing in it means
# data.mount fails, every unit that asks for data.mount fails with it, and the
# one script that could undo the damage cannot run, because the password-free
# sudo rule it writes lives on the far side of that same failure. A card that
# ships with a working /data can only ever be left with a small /data, never an
# unbootable one.
fsimg=$STAGE/data-fs.img
rm -f "$fsimg"
truncate -s $((DATA_SECTORS * 512)) "$fsimg"
# -b 4096 is not decoration: mkfs.ext4 sizes its block size from what it is
# handed, and on a plain file it picked 1 KiB blocks for a small filesystem.
# -d seeds the tree without mounting or copying anything: the directories are
# written straight into the fresh filesystem with the ownership they have.
# -m 0 skips the 5% root reserve, which on a data volume of this size is simply
# space the player is not allowed to use.
mkfs.ext4 -q -F -b 4096 -L streamer-data -m 0 -d "$SEED" "$fsimg" >"$STAGE/data-mkfs.log" 2>&1 ||
    die "making the ${DATA_SIZE_MIB} MiB /data filesystem failed:
$(cat "$STAGE/data-mkfs.log")"
# e2fsck exits 0 for clean and 1 for "errors corrected"; 1 is a pass here, and
# anything above means the filesystem this card boots with is not sound.
ec=0
e2fsck -fy "$fsimg" >"$STAGE/data-fsck.log" 2>&1 || ec=$?
[ "$ec" -le 1 ] || die "the fresh /data filesystem fails e2fsck (status $ec):
$(cat "$STAGE/data-fsck.log")"
# Stamp it as just checked, with the counters cleared, so the fsck the stock
# fstab pass asks for stays asleep until something actually leaves the volume
# dirty. (`-T never` is not a thing: `never` is only a keyword for -c/-i.)
tune2fs -C 0 -i 0 -T now "$fsimg" >"$STAGE/data-tune.log" 2>&1 ||
    die "tune2fs could not reset the /data filesystem's check counters:
$(cat "$STAGE/data-tune.log")"
if [ $((p3_start % 2048)) -eq 0 ]; then
    dd if="$fsimg" of="$IMG" bs=1M seek=$((p3_start / 2048)) conv=notrunc status=none ||
        die "could not splice the /data filesystem into the image at sector $p3_start"
else
    dd if="$fsimg" of="$IMG" bs=512 seek="$p3_start" conv=notrunc status=none ||
        die "could not splice the /data filesystem into the image at sector $p3_start"
fi
rm -f "$fsimg"
log "  ext4, ${DATA_SIZE_MIB} MiB, seeded from $SEED, e2fsck clean, spliced in at sector $p3_start"

# --- mount ------------------------------------------------------------------------------------

step "mount"
LOOP=$(losetup -Pf --show "$IMG")
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && [ -b "${LOOP}p3" ] && break
    sleep 0.2
done
[ -b "${LOOP}p3" ] || die "udev created no partition devices for $LOOP"
drop_automounts

R=$STAGE/root
FW=$STAGE/fw
mkdir -p "$R" "$FW"
mount -o noatime "${LOOP}p2" "$R"
mount -o noatime "${LOOP}p1" "$FW"
log "$LOOP: p2 -> $R, p1 -> $FW"

# --- the appliance ----------------------------------------------------------------------------

step "files"
install -d "$R/etc/streamer" "$R/usr/local/bin" "$R/data"
cp -a "$CONFIG/etc/systemd/system/." "$R/etc/systemd/system/"
cp -a "$CONFIG/etc/streamer/." "$R/etc/streamer/"
install -m 644 "$CONFIG/etc/streamer.conf" "$R/etc/streamer.conf"
for script in "$CONFIG"/usr/local/bin/*; do
    install -m 755 "$script" "$R/usr/local/bin/$(basename "$script")"
done
install -m 755 "$CLIAMP" "$R/usr/local/bin/cliamp"
install -m 755 "$FFMPEG" "$R/usr/local/bin/ffmpeg"
# A unit that names an interpreter the base image does not ship comes up as
# 203/EXEC, which on this box is a silent speaker and one journal line. The
# payload's scripts all name /bin/sh except the HTTP control server, which is
# python3, so the card has to have python3. RasPiOS Lite happens to ship it;
# "happens to" is exactly what a build check exists to turn into a fact.
for script in "$R"/usr/local/bin/*; do
    shebang=$(head -1 "$script")
    case $shebang in
        "#!/bin/sh")
            [ -x "$R/bin/sh" ] ||
                die "$(basename "$script") wants /bin/sh and the base image has none" ;;
        "#!/usr/bin/env python3")
            [ -x "$R/usr/bin/python3" ] ||
                die "$(basename "$script") runs python3, which this base image does not ship: "
                    "the HTTP control server cannot start" ;;
        *)
            die "$(basename "$script") names an unexpected interpreter: $shebang" ;;
    esac
done
# The same reaching check for the one base-image tool a payload script calls:
# streamer-daemon trims the DAC's codec volume with amixer, from alsa-utils.
# Absent it, the daemon's trim fails silently every boot and the board plays
# at 0 dB while every knob says otherwise.
[ -x "$R/usr/bin/amixer" ] ||
    die "streamer-daemon trims the codec with amixer, which this base image does not ship"
# The factory-reset template, the same directories the filesystem above was
# made from. It sits on the read-only root, owned by the appliance user, so that
# `cp -a` of it onto /data lands with the ownership the player needs. The path
# is the one `streamer reset` and /data/README name.
rm -rf "$R/usr/share/streamer"
install -d -m 755 "$R/usr/share/streamer/seed"
cp -a "$SEED/." "$R/usr/share/streamer/seed/"
log "  $(ls "$CONFIG"/usr/local/bin | wc -l) scripts, cliamp and ffmpeg in /usr/local/bin"
log "  reset template in /usr/share/streamer"

step "units"
# Enabling the units: these are the symlinks `systemctl enable` would create.
# Creating them here keeps the build independent of this host's systemd, and the
# [Install] sections in the unit files say the same thing.
enable() { # enable <unit> <target>
    install -d "$R/etc/systemd/system/$2.wants"
    ln -sfn "/etc/systemd/system/$1" "$R/etc/systemd/system/$2.wants/$1"
    log "  $1 -> $2"
}
enable streamer.target         multi-user.target
enable streamer-cliamp.service streamer.target
enable streamer-play.service   streamer.target
enable streamer-http.service   streamer.target

# Stock Raspberry Pi OS leaves ssh switched off unless a /boot/firmware/ssh
# marker happens to exist at boot. There is no screen or keyboard on this box,
# so ssh comes up on its own from the first boot.
ln -sfn /usr/lib/systemd/system/ssh.service "$R/etc/systemd/system/multi-user.target.wants/ssh.service"
log "  ssh.service -> multi-user.target"

# And stock units switched off, because on a read-only root they are writers
# with nothing useful to write:
#   userconfig.service  the first-boot dialog that asks on /dev/tty8 for a
#     password and a user name. On a box with no screen it can only stall, and
#     it is free to rename the uid 1000 account the units assume. Access here is
#     the SSH key installed below, so it has nothing to do.
#   apt-daily timers    fetch indexes and upgrade packages, which means a
#     background writer that can turn a read-only root into a half-written one
#     at a moment nobody chose. Updating this box is `streamer rw` and apt, by
#     hand.
#   e2scrub_all.timer   checks LVM thin volumes; this box has no LVM.
#   console-setup       sets a console font and keymap for a box that has no
#     console to look at, and failed every boot writing its state into a
#     read-only /etc/console-setup.
#   dpkg-db-backup.timer stamps a backup of the dpkg database into /var, which a
#     read-only root forbids: it failed on the day it fired.
#   logrotate.timer    the same story one day later: logrotate cannot create its
#     stub state file under /var on a read-only root, so it exits 3 and the
#     service fails. There are no rotating logs on this appliance to rotate:
#     journald is volatile and the appliance's own boot.log is trimmed by
#     streamer-bootlog, not logrotate.
#   rpi-resize.service  grows the last partition when the kernel command line
#     says `resize`. That token is stripped from cmdline.txt below and /data is
#     already the size it will ever be, but the unit still pulls
#     systemd-growfs-root.service into every boot, which fails against a
#     read-only root.
# The unit files stay where the packages put them: removing the symlinks is
# exactly what `systemctl disable` does.
for off in userconfig.service apt-daily.timer apt-daily-upgrade.timer e2scrub_all.timer \
           console-setup.service dpkg-db-backup.timer logrotate.timer rpi-resize.service; do
    rm -f "$R/etc/systemd/system/"*".target.wants/$off"
    log "  $off -> not started"
done

# Two stock subsystems go one step further, because they are wired in afresh by
# a boot generator every time, and there is no wants symlink anywhere to remove:
# disabling a generator is a symlink to /dev/null in
# /etc/systemd/system-generators.
#   cloud-init-generator  hangs cloud-init.target off multi-user.target from
#     /run/systemd/generator.early, and the five services behind it are writers
#     through and through - machine-id, hosts, network config - exactly what
#     this build decides once and hands to the card read-only. All five failed.
#     The /etc wants symlinks the package left behind go with them.
#   rpi-swap-generator    manufactures the stock swap stack from
#     /etc/rpi/swap.conf at every boot: dev-zram0.swap, rpi-setup-loop@var-swap,
#     a zram writeback timer, and rpi-resize-swap-file behind them. Every piece
#     of it wants to write /var/swap, which a read-only root forbids, so it
#     failed and was retried again and again. Without it the box runs with no
#     swap at all, which one headless audio stream on a gigabyte of RAM does
#     not notice; the alternative would be swap on /data, which is exactly the
#     partition a power cut is most likely to leave dirty.
install -d "$R/etc/systemd/system-generators"
for gen in cloud-init-generator rpi-swap-generator; do
    ln -sfn /dev/null "$R/etc/systemd/system-generators/$gen"
    log "  $gen -> /dev/null"
done
rm -rf "$R/etc/systemd/system/cloud-init.target.wants" \
       "$R/etc/systemd/system/cloud-config.target.wants"

step "the appliance user"
# The appliance user is whatever account Raspberry Pi OS made with uid 1000. The
# stock image gives it /usr/sbin/nologin as its shell, which lets ssh
# authenticate and then hang up straight away: unusable.
user_name=$(awk -F: '$3 == 1000 {print $1; exit}' "$R/etc/passwd")
user_home=$(awk -F: '$3 == 1000 {print $6; exit}' "$R/etc/passwd")
[ -n "$user_home" ] || die "the base image has no uid 1000 account"
# The player units say User=pi and Environment=HOME=/home/pi, because that is
# the account Raspberry Pi OS makes. If a future base image names it something
# else, the units would fail to start with no obvious reason, so the build says
# so here instead.
[ "$user_name" = pi ] || die "the uid 1000 account is called $user_name, but the
   player units assume pi: update User=/Group=/HOME= in
   $CONFIG/etc/systemd/system/streamer-*.service"
awk -F: -v OFS=: '$3 == 1000 { $7 = "/bin/bash" } 1' "$R/etc/passwd" >"$R/etc/passwd.new"
install -m 644 "$R/etc/passwd.new" "$R/etc/passwd"
rm -f "$R/etc/passwd.new"
log "  $user_name, home $user_home, shell /bin/bash"

install -d -m 700 -o 1000 -g 1000 "$R$user_home/.ssh"
install -m 600 -o 1000 -g 1000 "$SSH_KEY" "$R$user_home/.ssh/authorized_keys"
log "  authorised $(ssh-keygen -lf "$SSH_KEY")"

# cliamp keeps its configuration, and the Tidal credentials with it, on the
# writable partition, so that signing in to Tidal survives a reflash of the card
# and nothing in the home directory ever needs a writable root.
install -d -m 755 -o 1000 -g 1000 "$R$user_home/.config"
ln -sfn /data/cliamp "$R$user_home/.config/cliamp"
chown -h 1000:1000 "$R$user_home/.config/cliamp"

# Password-free sudo for the appliance user. The account has no password and the
# only way in is an SSH key, so a password prompt here is not a security
# boundary, it is an obstacle: `streamer audio dac` and `streamer rw` both
# re-run themselves through sudo, and there is no screen to type a password
# into. NOPASSWD is all that is needed for that: sudo only wants a terminal when
# it has to ask for a password, and `requiretty` is off by default in the sudo
# Raspberry Pi OS ships, so a line for it could only ever be wrong. visudo is
# used when this machine has it, because a sudoers file with a syntax error
# locks everybody out of a box that has no password.
step "sudoers"
tmp=$(mktemp)
printf '%s\n' "$user_name ALL=(ALL) NOPASSWD:ALL" >"$tmp"
if command -v visudo >/dev/null; then
    visudo -cf "$tmp" >/dev/null || die "the sudoers fragment this script writes is invalid"
else
    log "  no visudo on this machine, so the fragment goes in unchecked"
fi
install -d "$R/etc/sudoers.d"
install -m 0440 "$tmp" "$R/etc/sudoers.d/streamer"
rm -f "$tmp"
log "  $user_name ALL=(ALL) NOPASSWD:ALL"
rm -f "$tmp"
log "  streamer commands need no password"

step "fstab"
# Two changes to the file the vendor shipped, and no new syntax.
#
# The root and the firmware partition go read-only. That is what makes pulling
# the power out of this box safe: nothing is ever left mid-write on the card,
# and the only partition that is ever written to is /data, which holds nothing
# but small files the player can do without. It is written here because fstab is
# what mounts them: a kernel command line that says ro is overridden by an
# fstab line that says defaults, which is how the first card ended up running
# with a writable root while every comment said otherwise.
#
# /data is mounted by its filesystem label, because the label is inside the
# filesystem: it was set when the volume was made a few minutes ago, and it
# stays true whatever the partition number or the disk identifier happens to be.
#
# nofail: a /data that cannot be mounted must not stop the boot. The player
# units ask for data.mount and fail with it, and the box stays reachable over
# ssh so somebody can fix it.
#
# The last field of the /data line is 2, so the stock fsck at boot looks at the
# volume if something left it dirty. fsck.repair=yes is already on the kernel
# command line, so it repairs without asking, and there is no keyboard on this
# box to answer a prompt.
#
# Editing the text rather than rebuilding the lines from fields keeps the column
# alignment that makes this file readable by eye over SSH.
#
# The program is a file, not a quote inside this script: the suite runs it
# against the fstab a real card shipped (tests/fixtures/fstab.orig) and shows
# what it does, instead of trusting a program buried in a build script that
# nobody can run without a card and root.
awk -f "$REPO/image/fstab-ro.awk" "$R/etc/fstab" >"$R/etc/fstab.new"
for mp in / /boot/firmware; do
    got=$(awk -v m="$mp" '$2 == m { print ($4 ~ /(^|,)ro(,|$)/) ? "ro" : "rw"; exit }' "$R/etc/fstab.new")
    [ "$got" = ro ] || die "the $mp line of $R/etc/fstab did not gain ro (got: ${got:-nothing})"
done
install -m 644 "$R/etc/fstab.new" "$R/etc/fstab"
rm -f "$R/etc/fstab.new"

if ! grep -qsE '^[^#][^[:space:]]+[[:space:]]+/data[[:space:]]' "$R/etc/fstab"; then
    {
        printf '\n# streamer data partition: the player state, and nothing else.\n'
        printf '# Made at build time, %s MiB, labelled streamer-data: the label lives\n' "$DATA_SIZE_MIB"
        printf '# inside the filesystem, so this line is true whatever the card is.\n'
        printf '# nofail: a /data that cannot be mounted must not stop the boot.\n'
        printf '# fsck runs here only when the volume was left dirty by a power cut.\n'
        printf 'LABEL=streamer-data  /data  ext4  defaults,nofail,noatime  0  2\n'
    } >>"$R/etc/fstab"
fi
grep -qsE '^[^#][^[:space:]]+[[:space:]]+/data[[:space:]]' "$R/etc/fstab" ||
    die "the /data line did not land in $R/etc/fstab"
install -d -m 755 "$R/data"
sed -n '/streamer data partition/,$p' "$R/etc/fstab" | sed 's/^/  /' >&2

step "identity"
if [ -n "$NEW_HOSTNAME" ]; then
    printf '%s\n' "$NEW_HOSTNAME" >"$R/etc/hostname"
    if grep -qs '^127\.0\.1\.1' "$R/etc/hosts"; then
        sed -i "s/^\(127\.0\.1\.1[[:space:]]\+\).*/\1$NEW_HOSTNAME/" "$R/etc/hosts"
    else
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >>"$R/etc/hosts"
    fi
    log "  hostname $NEW_HOSTNAME, so ssh to $NEW_HOSTNAME.local"
fi
if [ -n "$TZONE" ]; then
    [ -f "$R/usr/share/zoneinfo/$TZONE" ] || die "no zoneinfo entry for $TZONE"
    ln -sfn "/usr/share/zoneinfo/$TZONE" "$R/etc/localtime"
    printf '%s\n' "$TZONE" >"$R/etc/timezone"
    log "  timezone $TZONE"
fi

# Three things a stock Raspberry Pi OS expects its own first boot to make, and
# a read-only root from the first boot means there is no such write to fall back
# on. Doing them here also means a published image is not a shared secret:
#
#   machine-id     the base image ships one, stamped when the vendor built it,
#     so every stock card on earth starts with the same. It leaks into DHCP
#     requests and mDNS names.
#   ssh host keys  the base image ships these too, in the clear for anyone who
#     downloads it. If every streamer on a network answered with the same
#     private host key, the first ssh session to any of them is a session
#     somebody else could have set up. Regenerating them per build is the fix,
#     and printing the fingerprint at the end is what lets you check it landed.
#   ssh login banner  the stock /etc/ssh/sshd_config.d/rename_user.conf prints
#     "SSH may not work until a valid user has been set up" on every login.
#     This box has a user, with a key, so the message is wrong every time and
#     would have every reader of this project checking whether their card was
#     broken. sshd takes the first value it finds for Banner, so the drop-in has
#     to be replaced rather than overridden. It is package-owned, so it is
#     rewritten with a note instead of deleted; an update of that package can
#     bring the message back.
if [ -s "$R/etc/machine-id" ]; then
    log "  machine-id: replacing the one the base image shipped"
fi
od -An -tx1 -N16 /dev/urandom | tr -d ' \n' >"$R/etc/machine-id"
rm -f "$R"/etc/ssh/ssh_host_*_key "$R"/etc/ssh/ssh_host_*_key.pub
install -d -m 755 "$R/etc/ssh"
ssh-keygen -q -A -f "$R"
# The root partition is unmounted before it can be checked, and the loop device
# that carries it is released afterwards, so nothing can be read out of it any
# more by the time the image gets its name. Take the public half out now, while
# it is still reachable: the fingerprint printed at the end is only worth
# comparing if it comes from the key that is really in this image.
install -m 644 "$R/etc/ssh/ssh_host_ed25519_key.pub" "$hostkey"
log "  ssh host keys generated for this build"
if [ -f "$R/etc/ssh/sshd_config.d/rename_user.conf" ]; then
    printf '%s\n' \
        '# streamer: the stock banner talks about setting up a user. This box has' \
        '# one, and it is reached with an SSH key. See image/build.sh.' >"$R/etc/ssh/sshd_config.d/rename_user.conf"
    log "  stock ssh login banner replaced"
fi

# One state directory a unit cannot make for itself once the root is read-only.
# systemd-logind declares StateDirectory=systemd/linger, and systemd creates a
# unit's state directory when the unit starts: on a read-only root that mkdir
# fails, logind dies with status 238/STATE_DIRECTORY, and every ssh login then
# waits the full 25 s D-Bus activation timeout inside pam_systemd before the
# shell opens. Writing the directory into the image costs one line, and logind
# needs nothing else writable: its session state lives in /run, which is tmpfs.
step "login state"
install -d -m 755 "$R/var/lib/systemd/linger"
log "  /var/lib/systemd/linger: systemd-logind cannot make it once / is read-only"

# The same trade as the linger directory, at smaller scales. These are all
# things a stock system makes somewhere under /var on some later boot, which a
# read-only root never gets: each one logs an err or warn line on every single
# boot until it is baked into the image, and each cost here is one line. The
# list came from reading a real card's journal, so it is the set the card
# actually complains about, not a guess at what could.
step "first-boot state"
#   /var/lib/dbus/machine-id  tmpfiles wants this symlink to /etc/machine-id.
#     dbus reads /etc/machine-id fine without it, but tmpfiles logs "Failed to
#     create symlink" at level err on every boot when it is not already there.
install -d -m 755 "$R/var/lib/dbus"
ln -sfn /etc/machine-id "$R/var/lib/dbus/machine-id"
#   /var/lib/udisks2  udisks2 ships with the base image and starts enabled;
#     its first act is mkdir under /var, which fails there and is logged. An
#     empty directory is all it ever wants at boot.
install -d -m 755 "$R/var/lib/udisks2"
#   /var/lib/NetworkManager/secret_key  NetworkManager generates a machine-
#     unique key at startup when none exists, then cannot write it, so it
#     warns and starts over from a fresh random one every boot. Baking one in
#     costs nothing, matches the per-build host keys, and takes the warning
#     out of the journal.
install -d -m 755 "$R/var/lib/NetworkManager"
(umask 077; head -c 32 /dev/urandom >"$R/var/lib/NetworkManager/secret_key")
#   /etc/resolv.conf  the vendor ships a plain file with a static nameserver
#     8.8.8.8 in it - Raspberry Pi OS has baked that line since before NM
#     existed. Leaving it there means every card resolves through a public
#     resolver with no cache, whatever the network's DHCP hands out, and that
#     is what makes cliamp's lookups time out on WAN hiccups. NM wants to
#     rewrite that file after every DHCP event, but / is read-only, so the
#     rewrite fails and the journal fills with warnings. The way out is
#     rc-manager=symlink: NM writes its nameservers to its own file under
#     /run, which is tmpfs and writable every boot, and /etc/resolv.conf is a
#     symlink to it. Replace the vendor's file with that symlink here, so a
#     card resolves with the DNS its network actually provides.
install -d -m 755 "$R/etc/NetworkManager/conf.d"
cat >"$R/etc/NetworkManager/conf.d/10-ro-root.conf" <<'EOF'
[main]
# streamer: / is read-only, so NM must not write /etc/resolv.conf directly;
# rc-manager=symlink has it write /run/NetworkManager/resolv.conf instead,
# which the image bakes /etc/resolv.conf as a symlink to. See image/build.sh.
# Both keys live in [main]; putting them under [global] only earns an
# "unknown key" warn.
rc-manager=symlink
EOF
ln -sfn /run/NetworkManager/resolv.conf "$R/etc/resolv.conf"
# Three vendor tmpfiles.d entries re-assert every boot rather than create when
# missing, so they hit the read-only wall and log errors even though what
# they want is already true on the card:
#   debian.conf       L+ /etc/mtab recreates the symlink that is already there
#     and correct; plain L would leave it alone, L+ forces it.
#   systemd.conf      the a+ lines re-apply the ACLs under /var/log/journal on
#     every boot. The ACLs are baked in and right, and this image runs
#     journald volatile anyway (see the journal step), so those lines can
#     only ever fail here.
#   journal-nocow.conf  the h line re-stamps the no-CoW attribute on
#     /var/log/journal, warning "cannot set file attributes ... ignoring" on
#     every boot. The same reasoning: the directory is only ever touched from
#     /run on this box, and the attribute cannot be set on a read-only fs.
sed -i '\|^L+ /etc/mtab|d' "$R/usr/lib/tmpfiles.d/debian.conf"
sed -i '/^a+ \/var\/log\/journal/d' "$R/usr/lib/tmpfiles.d/systemd.conf"
sed -i '/^h \/var\/log\/journal/d' "$R/usr/lib/tmpfiles.d/journal-nocow.conf"
#   90-alsa-restore.rules  the alsa-utils udev rule runs `alsactl restore`
#     for every sound card that appears. This box has never saved a card
#     state, so every card logs a failed restore - plus two level-err lines
#     for a GOTO label missing from the vendor file itself. udev reads only
#     the highest-priority file with a given basename, so an empty file in
#     /etc turns the whole rule off. Nothing on this appliance saves or
#     restores a card state through alsactl: cliamp owns the playing volume,
#     ramped by streamer-play, and streamer-daemon pins the DAC's codec trim
#     with amixer directly at every start rather than through a stored state.
install -d "$R/etc/udev/rules.d"
: >"$R/etc/udev/rules.d/90-alsa-restore.rules"
# netplan generate runs at boot and warns about every config file it reads
# that is world-readable; the vendor NetworkManager yaml ships 644 and the
# warning's own advice is 600, so give it 600. The file's location varies by
# netplan version - /usr/lib/netplan on this base, /etc/netplan or
# /lib/netplan on others - so take whichever this tree has.
found=0
for f in "$R"/usr/lib/netplan/*.yaml "$R"/etc/netplan/*.yaml "$R"/lib/netplan/*.yaml; do
    if [ -f "$f" ]; then
        chmod 600 "$f"
        found=1
    fi
done
[ "$found" -eq 1 ] || log "  note: no netplan yaml in the tree to tighten"
log "  dbus machine-id, udisks2, NM secret key, NM hands off resolv.conf: baked in"
log "  mtab, journal-ACL and journal-attr tmpfiles lines, and the alsa restore rule: off"

# journald kept in memory, which is what a read-only root without
# /var/log/journal already implies. Saying it out loud is the point: the
# alternative is logs on the writable partition, and a hard power cut is exactly
# the moment that journal gets left dirty, on a card the player is writing to at
# the same time. The journald that starts before local-fs.target could not reach
# a /data bind mount either way.
#
# What survives a power cut is instead the one-line-per-boot record in
# /data/streamer/boot.log, written by the scripts at both ends of the boot:
# small, append-only, and the thing worth having after the box was yanked.
step "journal"
install -d -m 755 "$R/etc/journald.conf.d"
cat >"$R/etc/journald.conf.d/streamer.conf" <<'EOF'
[Journal]
# Read-only root: /var/log/journal cannot be written to. The appliance keeps
# its own durable record on /data instead; see /etc/streamer.conf.
Storage=volatile

# /run is tmpfs: about half of RAM by default on a 1 GB Pi, and the player
# units are the only thing talking to the journal.
RuntimeMaxUse=32M
EOF
log "  journald: volatile, 32M in /run"
log "  durable per-boot line: /data/streamer/boot.log"

# --- firmware partition -----------------------------------------------------------------------

step "firmware config"
CFG=$FW/config.txt
CMDLINE=$FW/cmdline.txt

# The stock audio lines are commented out rather than deleted: the file still
# reads as what the vendor shipped, with the appliance saying what it replaced.
awk '
    $0 == "dtparam=audio=on" {
        print "# streamer: the audio setup lives in the appliance block at the end"
        print "# of this file, so the stock line below is switched off."
        print "#dtparam=audio=on"
        next
    }
    $0 == "dtoverlay=vc4-kms-v3d" { print "#dtoverlay=vc4-kms-v3d"; next }
    { print }
' "$CFG" >"$CFG.new"
install -m 644 "$CFG.new" "$CFG"
rm -f "$CFG.new"

# config.txt is read top to bottom and a later section overrides an earlier one,
# so the appliance block goes at the end, under its own [all] header. The audio
# text from etc/streamer/audio-<output>.txt is spliced into it between the two
# markers, which is the block `streamer audio jack|dac` rewrites later on.
tail_new=$(mktemp)
{
    sed -e '/^# --- streamer audio begin ---$/,/^# --- streamer audio end ---$/d' \
        "$CONFIG/boot/appliance-config.txt"
    printf '# --- streamer audio begin ---\n'
    cat "$CONFIG/etc/streamer/audio-$AUDIO.txt"
    printf '# --- streamer audio end ---\n'
} >"$tail_new"
# Anything of ours from an earlier run goes first, from our own header to the
# end of the file, so a config.txt never ends up with two appliance blocks.
awk '/^# --- streamer appliance ---$/ { exit } { print }' "$CFG" >"$CFG.new"
cat "$tail_new" >>"$CFG.new"
install -m 644 "$CFG.new" "$CFG"
rm -f "$CFG.new" "$tail_new"
log "audio for the first boot: $AUDIO"

# Raspberry Pi OS puts a bare `resize` token on the kernel command line, and its
# initrd acts on it by growing the last partition of the card at boot. Ours is
# the /data partition and it is already the size it will ever be, so the token
# goes: leaving it in means a second, uncontrolled writer of the partition table
# at every boot until it notices it has nothing to do. `ro` matches fstab.
#
# Splitting the line into words and rebuilding it is why the token cannot come
# back as part of another word. A kernel command line has no quoting in it, so
# there is nothing to lose by splitting.
line=$(tr '\n\r' '  ' <"$CMDLINE")
kept=""
for word in $line; do
    [ "$word" = resize ] && continue
    kept="$kept $word"
done
line=${kept# }
case " $line " in
    *" ro "*) ;;
    *) line="$line ro" ;;
esac
printf '%s\n' "$line" >"$CMDLINE"
log "cmdline: $line"

# --- checks -----------------------------------------------------------------------------------

step "checks"
umount "$FW"
umount "$R"
drop_automounts
sync

# A vfat partition edited through Linux usually needs its FS info sector tidied;
# it is worth knowing the Pi firmware is not being handed a dirty one.
fsck.fat -n "${LOOP}p1" >"$STAGE/fat.log" 2>&1 || true
if grep -qiE 'dirty|should be removed|correcting|errors' "$STAGE/fat.log"; then
    log "fsck.fat: $(tail -1 "$STAGE/fat.log")"
    fsck.fat -a "${LOOP}p1"
fi
fsck.fat -n "${LOOP}p1" >/dev/null || die "the firmware partition fails fsck.fat:
$(cat "$STAGE/fat.log")"
log "firmware partition passes fsck.fat"

# e2fsck again: 0 is clean, 1 is "problems corrected", and anything above that
# means the filesystem the Pi would boot from is not sound. Output goes to a
# log, because a die message that says only "fails e2fsck" is how this build
# once lost half an hour to a volume manager.
ec=0
e2fsck -fy "${LOOP}p2" >"$STAGE/root-fsck.log" 2>&1 || ec=$?
[ "$ec" -le 1 ] || die "the root partition fails e2fsck (status $ec):
$(cat "$STAGE/root-fsck.log")"
# One tune2fs run, on the partition while it is unmounted:
#   -U random  a fresh filesystem UUID, so two cards from this build are never
#              the same filesystem to whatever mounts them
#   -C 0       clears the mount counter
#   -i 0       disables the periodic check, which on this box could only ever
#              fire on a boot that is already racing a timer
#   -T now     stamps the superblock as just checked
tune2fs -U random -C 0 -i 0 -T now "${LOOP}p2" >"$STAGE/root-tune.log" 2>&1 \
    || die "tune2fs could not give the root partition a fresh UUID and reset its
check counters:
$(cat "$STAGE/root-tune.log")"
log "root partition passes e2fsck, UUID and forced-check counters reset"

# The one state directory the card can never make for itself, read back the same
# way the seeded /data tree is read back below: through debugfs, without ever
# mounting the partition. If this line is missing, sshd answers logins 25
# seconds late and systemd sits in degraded, and nothing on the card can say so.
linger=$(debugfs -R 'ls -l /var/lib/systemd' "${LOOP}p2" 2>/dev/null |
    awk '{ print $NF }' | grep -cx 'linger' || true)
[ "${linger:-0}" -eq 1 ] ||
    die "the root filesystem does not hold /var/lib/systemd/linger:
systemd-logind will fail at boot and every ssh login will stall 25 seconds"
log "  /var/lib/systemd/linger is in the image"

# The baked-in first-boot state, read back the same read-only way. Each piece
# stands for a journal line: no dbus symlink and tmpfiles cries about the
# symlink every boot, no NM key and NM re-randomises and warns every boot,
# and so on. Better to find out here than to ship a card that starts its
# journal with complaints.
baked=$(debugfs -R 'ls -l /var/lib' "${LOOP}p2" 2>/dev/null | awk '{ print $NF }' |
    grep -cxE 'dbus|udisks2|NetworkManager' || true)
[ "${baked:-0}" -eq 3 ] ||
    die "the root filesystem is missing baked-in /var/lib state (found $baked of 3: dbus, udisks2, NetworkManager)"
# debugfs ls -l never shows a symlink's target, but stat prints it for a fast
# link (target stored in the inode, which /etc/machine-id at 15 characters is).
dbus_link=$(debugfs -R 'stat /var/lib/dbus/machine-id' "${LOOP}p2" 2>/dev/null |
    grep -c 'Fast link dest: "/etc/machine-id"' || true)
[ "${dbus_link:-0}" -eq 1 ] ||
    die "the root filesystem does not hold the /var/lib/dbus/machine-id -> /etc/machine-id symlink"
nm_key=$(debugfs -R 'ls -l /var/lib/NetworkManager' "${LOOP}p2" 2>/dev/null |
    awk '{ print $NF }' | grep -cx 'secret_key' || true)
[ "${nm_key:-0}" -eq 1 ] ||
    die "the root filesystem does not hold /var/lib/NetworkManager/secret_key"
log "  baked-in /var/lib state reads back from the image"

# The other half of that step: the vendor edits. Reading the shipped files back
# and looking for the offending lines is the only way to know the seds ran
# against a file that still had those lines in the same shape - a vendor update
# to the base image can rewrite these files, and then the journal fills up with
# the complaints the seds exist to remove.
for f in debian.conf systemd.conf journal-nocow.conf; do
    debugfs -R "cat /usr/lib/tmpfiles.d/$f" "${LOOP}p2" 2>/dev/null >"$STAGE/$f" || true
    if grep -qE '^(L\+ /etc/mtab|a\+ /var/log/journal|h /var/log/journal)' "$STAGE/$f"; then
        die "the root filesystem still carries a re-asserting tmpfiles line in $f"
    fi
done
rot=$(debugfs -R 'ls -l /etc/systemd/system/timers.target.wants' "${LOOP}p2" 2>/dev/null |
    grep -c 'logrotate.timer' || true)
[ "${rot:-0}" -eq 0 ] || die "logrotate.timer is still enabled in the image"
nmconf=$(debugfs -R 'cat /etc/NetworkManager/conf.d/10-ro-root.conf' "${LOOP}p2" 2>/dev/null || true)
printf '%s\n' "$nmconf" | grep -q '^rc-manager=symlink' ||
    die "the image does not carry the NetworkManager resolv.conf hand-off"
# The other half of the hand-off: if the vendor's static resolv.conf survived
# next to the new conf, NM would write to /run and nothing would read it,
# which is the silent half of a half-done fix.
reslink=$(debugfs -R 'ls -l /etc/resolv.conf' "${LOOP}p2" 2>/dev/null || true)
printf '%s\n' "$reslink" | grep -q -- '-> /run/NetworkManager/resolv.conf' ||
    die "/etc/resolv.conf in the image is not the symlink to NetworkManager's /run file"
log "  vendor tmpfiles edits, logrotate off, NM hand-off: read back from the image"

# The data partition's filesystem was made, seeded, checked and stamped as a
# file a few minutes ago. Here it is only read back, to prove the splice landed
# where the partition table says it did, and that the label fstab mounts by is
# really on it. Nothing writes to a loop partition a desktop may have mounted.
data_type=$(blkid -o value -s TYPE "${LOOP}p3")
data_label=$(blkid -o value -s LABEL "${LOOP}p3")
[ "$data_type" = ext4 ] && [ "$data_label" = streamer-data ] ||
    die "the data partition is $data_type/$data_label, expected ext4/streamer-data"
# Read-only debugfs: this is the one place the build looks *inside* the spliced
# filesystem without mounting it, to prove the seeded tree really is in there.
# Nothing is ever written through debugfs: writes that matter go through a real
# mount, by tools that check the filesystem afterwards.
seeded=$(debugfs -R 'ls -l /' "${LOOP}p3" 2>/dev/null | awk '{ print $NF }' |
    grep -cxE 'cliamp|bin|music|streamer' || true)
[ "${seeded:-0}" -eq 4 ] ||
    die "the /data filesystem does not hold the seeded tree (found $seeded of 4 directories):
the filesystem did not land at sector $p3_start"
data_blocks=$(dumpe2fs -h "${LOOP}p3" 2>/dev/null |
    sed -n 's/^Block count:[[:space:]]*\([0-9]*\)$/\1/p')
[ "${data_blocks:-0}" -gt 0 ] || die "the data partition has no readable ext4 superblock:
the filesystem did not land at sector $p3_start"
log "data partition reads back as $data_label ($data_type), $data_blocks blocks, ${DATA_SIZE_MIB} MiB, seeded"

# Read the patched files back through a fresh mount: what matters is what the Pi
# firmware will read, not what this script thinks it wrote.
mount -o ro "${LOOP}p1" "$FW"
log "config.txt, the block the Pi will apply:"
sed -n '/^# --- streamer appliance ---$/,/^# --- streamer audio end ---$/p' "$FW/config.txt" |
    grep -vE '^[[:space:]]*(#|$)' | sed 's/^/  /' >&2
log "cmdline.txt: $(cat "$FW/cmdline.txt")"
umount "$FW"

# Reap anything the volume manager mounted in the meantime, or losetup -d fails
# and the loop device is left holding this image for the rest of the session.
drop_automounts
losetup -d "$LOOP" || die "could not release the loop device $LOOP: something still
holds one of its partitions"
LOOP=""

# --- output -----------------------------------------------------------------------------------

step "output"
mkdir -p "$OUT_DIR"
name=$NEW_HOSTNAME-$AUDIO-$(date +%Y%m%d)
final=$OUT_DIR/$name.img
mv -f "$IMG" "$final"
IMG=""

printf '%s  %s\n' "$(sha256sum "$final" | cut -d' ' -f1)" "$(basename "$final")" >"$final.sha256"
if [ "$COMPRESS" = 1 ]; then
    log "compressing"
    xz -1 -T0 -k "$final"
    printf '%s  %s\n' "$(sha256sum "$final.xz" | cut -d' ' -f1)" "$(basename "$final").xz" >"$final.xz.sha256"
    [ "$KEEP_RAW" = 1 ] || rm -f "$final"
fi

# The public host key of this build, next to the image. On first login ssh
# prints a fingerprint of its own; comparing it against this file, once, is how
# you know the card you are talking to is the card you built.
cp "$hostkey" "$OUT_DIR/$name.ssh_host_ed25519.pub"
fpr=$(ssh-keygen -lf "$OUT_DIR/$name.ssh_host_ed25519.pub" | awk '{print $2}')

# This script ran as root, so the files it made belong to root: give them back to
# whoever asked for the build.
if [ -n "${SUDO_UID:-}" ]; then
    chown -R "$SUDO_UID:${SUDO_GID:-0}" "$OUT_DIR" "$CACHE" 2>/dev/null || true
fi

min_bytes=$(awk -v s="$p3_end" 'BEGIN { printf "%.1f", s * 512 / 1e9 }')

log ""
ls -1sh "$OUT_DIR" | grep -v '^total' | sed 's/^/  /' >&2
log ""
log "this image needs a card of at least ${min_bytes} GB (use 8 GB or bigger)."
log "write it, checking the device name first:"
log "  sudo xz -dc $OUT_DIR/$name.img.xz | sudo dd of=/dev/sdX bs=8M status=progress conv=fsync"
log "  (or pick the .xz in Raspberry Pi Imager, as a custom image)"
log ""
log "it plays the first time it is powered on, with no setup step in between."
log "then, over ssh:"
log "  ssh -i <key> pi@$NEW_HOSTNAME.local"
log "  cliamp            # sign in to Tidal: https://link.tidal.com/<code>"
log "  streamer stations # pick a radio station"
log "  streamer station <url>"
if [ -n "$KEY_PRIVATE" ]; then
    log ""
    log "the private key is $KEY_PRIVATE, and is nowhere in the image."
    log "keep a copy: it is the only way in."
fi
log ""
log "this build's ssh host key fingerprint, which ssh shows once and can then be"
log "checked against $OUT_DIR/$name.ssh_host_ed25519.pub:"
log "  $fpr"
