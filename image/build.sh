#!/usr/bin/env bash
# Build the streamer appliance card image.
#
#   image/build.sh [--audio jack|dac] [--output DIR]
#                  [--ssh-key PATH | --new-key] [--hostname NAME] [--tz ZONE]
#                  [--keep-raw] [--no-compress]
#
# The partition work needs root, because it mounts filesystems. The script
# therefore does the fetching and the key handling as the invoking user and
# then re-runs itself under sudo. Run it from a terminal, where sudo can ask
# for a password.
#
# What it does, in order:
#   1. Fetch and verify the pinned base image, cliamp release and ffmpeg
#      build. A SHA256 mismatch stops the build; nothing comes from a floating
#      "latest" tag.
#   2. Set up SSH access: an existing public key, or a freshly generated
#      keypair whose private half stays on this machine.
#   3. Copy the base image, add the /data partition entry without a filesystem
#      (its real size is only known once the card it lands on is known), and
#      read back the PARTUUID the fstab entry will use.
#   4. Mount both populated partitions and install the appliance payload:
#      units, scripts, binaries, ssh authorisation, the /data fstab line.
#   5. Patch the firmware partition: audio setup, boot options.
#   6. Check both filesystems, read the patched firmware files back, compress.
#
# Everything that depends on the real card size happens on the first boot, in
# /usr/local/bin/streamer-firstboot.

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

# BtbN autobuild, pinned to a named release rather than latest. The binary
# needs only libraries the base image already ships.
FFMPEG_TAG=autobuild-2026-11-17-12-40
FFMPEG_ASSET=ffmpeg-N-129000-g64f6bcffaf-linuxarm64-gpl.tar.xz
FFMPEG_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/$FFMPEG_TAG/$FFMPEG_ASSET
FFMPEG_SHA=6cdd6eae6bdb4ce8be9a751d17209cd1a0f237bc8fcc866ddbc92a501df0e8e0

# The /data partition entry written into the image: a slot, not a filesystem.
# streamer-firstboot grows it to the end of the card and makes the ext4 on the
# first boot, so this size only has to be big enough for the partition table to
# be valid. 32 MiB keeps the image small.
DATA_SECTORS=65536

# --- paths and defaults -----------------------------------------------------------------------

SELF=$(realpath "$0")
REPO=$(dirname "$(dirname "$SELF")")
CONFIG=$REPO/config
CACHE=$REPO/.cache
OUT_DIR=$REPO/output
STAGE=$CACHE/stage

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
usage: image/build.sh [options]

  --audio jack|dac   which output is live on the first boot (default jack)
  --output DIR       where the finished image goes (default output/)
  --ssh-key PATH     public key to authorise for the appliance user
  --new-key          generate a keypair instead, under <output>/keys/
  --hostname NAME    appliance hostname, for ssh <name>.local (default streamer)
  --tz ZONE          timezone, for example Europe/Bratislava
  --keep-raw         keep the uncompressed .img next to the .xz
  --no-compress      leave the image uncompressed
EOF
    exit 2
}

# --- arguments --------------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case $1 in
        --audio)       AUDIO=${2:?--audio needs jack or dac};        shift 2 ;;
        --output)      OUT_DIR=$(realpath -m "${2:?--output needs a directory}"); shift 2 ;;
        --ssh-key)     SSH_KEY=$(realpath -e "${2:?--ssh-key needs a file}");     shift 2 ;;
        --new-key)     NEW_KEY=1;                                    shift ;;
        --hostname)    NEW_HOSTNAME=${2:?--hostname needs a name};   shift 2 ;;
        --tz)          TZONE=${2:?--tz needs a zone};                shift 2 ;;
        --keep-raw)    KEEP_RAW=1;                                   shift ;;
        --no-compress) COMPRESS=0;                                   shift ;;
        -h|--help)     usage ;;
        *)             die "unknown option: $1" ;;
    esac
done

case $AUDIO in
    jack|dac) ;;
    *) die "--audio is jack or dac" ;;
esac
[ -f "$CONFIG/etc/streamer/audio-$AUDIO.txt" ] || die "no audio fragment for $AUDIO"
case $NEW_HOSTNAME in
    *[!a-z0-9-]*|'') die "hostname has to be lower case letters, digits and dashes: $NEW_HOSTNAME" ;;
esac
for tool in curl sfdisk losetup blkid e2fsck tune2fs fsck.fat bsdtar xz ssh-keygen; do
    command -v "$tool" >/dev/null || die "$tool is missing"
done

# Arguments for the sudo pass, with whatever gets resolved here filled in, so
# nothing is asked twice and nothing is downloaded twice.
RUN_ARGS=(--audio "$AUDIO" --output "$OUT_DIR" --hostname "$NEW_HOSTNAME")
[ -z "$TZONE" ]     || RUN_ARGS+=(--tz "$TZONE")
[ "$KEEP_RAW" = 0 ] || RUN_ARGS+=(--keep-raw)
[ "$COMPRESS" = 1 ] || RUN_ARGS+=(--no-compress)

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
# sidecar records: anything else gets uncompressed again from the verified .xz.
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
    # headless box.
    log "  extracting bin/ffmpeg from the pinned autobuild"
    tmp=$(mktemp -d "$CACHE/ff.XXXXXX")
    bsdtar -xJf "$FFMPEG_TARBALL" -C "$tmp" "*/bin/ffmpeg"
    found=$(find "$tmp" -type f -name ffmpeg | head -1)
    [ -n "$found" ] || die "no bin/ffmpeg inside $FFMPEG_ASSET"
    mv -f "$found" "$FFMPEG"
    rm -rf "$tmp"
fi
chmod 755 "$CLIAMP" "$FFMPEG"
log "  cliamp $(du -h "$CLIAMP" | cut -f1), ffmpeg $(du -h "$FFMPEG" | cut -f1)"

# --- ssh access -------------------------------------------------------------------------------

step "ssh access"
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
    SSH_KEY=$KEY_PRIVATE.pub
}

if [ -n "$SSH_KEY" ]; then
    looks_like_pubkey "$SSH_KEY" || die "$SSH_KEY is not a public key file"
    log "  authorising the key in $SSH_KEY"
elif [ "$NEW_KEY" = 1 ]; then
    make_keypair
elif [ -t 0 ]; then
    log "Which SSH public key should be able to log in? Press Enter to have a
new keypair generated instead."
    printf 'path: ' >&2
    read -r answer
    if [ -n "$answer" ]; then
        answer=${answer/#\~/$HOME}
        SSH_KEY=$(realpath -e -- "$answer" 2>/dev/null) ||
            die "$answer is not a readable file"
        looks_like_pubkey "$SSH_KEY" || die "$SSH_KEY is not a public key file"
    else
        make_keypair
    fi
else
    die "no SSH public key given, and there is no terminal to ask on.
Pass --ssh-key /path/to/id_ed25519.pub, or --new-key to make a keypair."
fi
log "  $(ssh-keygen -lf "$SSH_KEY")"
RUN_ARGS+=(--ssh-key "$SSH_KEY")

# --- from here on the script needs root --------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    log ""
    log "the rest of the build writes a partition table and mounts filesystems"
    exec sudo -E "$SELF" "${RUN_ARGS[@]}"
fi

# --- work image -------------------------------------------------------------------------------

step "work image"
mkdir -p "$STAGE"
IMG=$STAGE/card.img
LOOP=""
cleanup() {
    set +e
    umount "$STAGE/fw" 2>/dev/null
    umount "$STAGE/root" 2>/dev/null
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    [ -n "$IMG" ] && rm -f "$IMG"
    rmdir "$STAGE" 2>/dev/null
}
trap cleanup EXIT
rm -f "$IMG"

# reflink where the filesystem supports it, which makes the 3 GB copy close to
# free; a plain copy elsewhere.
cp --reflink=auto "$RAW" "$IMG"

# The stock image leaves no free sectors after the root partition, so the image
# file has to grow before a partition can be added to it.
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
sectors=$(( $(stat -c%s "$IMG") / 512 ))
[ -n "$p1_start" ] && [ -n "$p2_start" ] && [ -n "$p2_size" ] ||
    die "cannot read the partition table of the base image:
$parts"
[ "$sectors" -ge $((p3_start + DATA_SECTORS)) ] ||
    die "$sectors sectors is not enough room for /data at $p3_start"

log "  firmware  start=$p1_start size=$(field "$first" size)"
log "  root      start=$p2_start size=$p2_size"
log "  data      start=$p3_start size=$DATA_SECTORS (no filesystem yet)"

# Rewriting the whole table from the dump is what keeps the disk identifier,
# the partition types and the boot flag of the firmware partition exactly as
# the vendor left them. The device: line in the dump names the file the dump
# came from, so it goes: sfdisk gets the target on its command line. The new
# entry is named the way the existing ones are, so its partition number is
# unambiguous.
last_name=${last%% *}
new_name="${last_name%2}3"
{
    printf '%s\n' "$dump" | grep -vE '^([[:space:]]*(#|$)|device:)'
    printf '%s : start=%s, size=%s, type=83\n' "$new_name" "$p3_start" "$DATA_SECTORS"
} | sfdisk -q "$IMG"

log "the new partition table:"
sfdisk -d "$IMG" | grep ' : start=' |
    awk -F' : ' '{split($1, a, "/"); printf "  %-12s %s\n", a[length(a)], $2}' >&2

# --- mount ------------------------------------------------------------------------------------

step "mount"
LOOP=$(losetup -Pf --show "$IMG")
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && [ -b "${LOOP}p3" ] && break
    sleep 0.2
done
[ -b "${LOOP}p3" ] || die "udev created no partition devices for $LOOP"

R=$STAGE/root
FW=$STAGE/fw
mkdir -p "$R" "$FW"
mount -o noatime "${LOOP}p2" "$R"
mount -o noatime "${LOOP}p1" "$FW"
log "$LOOP: p2 -> $R, p1 -> $FW"

DISK_ID=$(printf '%s\n' "$dump" | sed -n 's/^label-id:[[:space:]]*0x\([0-9a-fA-F]*\)$/\1/p' | tr 'A-F' 'a-f')
[ -n "$DISK_ID" ] || die "the base image has no DOS disk identifier in its partition table"
# A DOS table spells a partition's PARTUUID as the disk identifier plus the
# partition number, which is exactly what udev puts in /dev/disk/by-partuuid on
# the card. Deriving it here means the fstab entry cannot point at some other
# card, and it does not depend on what blkid chooses to report for a partition
# that has no filesystem yet.
DATA_UUID="$DISK_ID-03"
log "/data PARTUUID $DATA_UUID"

# --- root filesystem payload ------------------------------------------------------------------

step "appliance payload"

install -d "$R/etc/streamer" "$R/usr/local/bin"
cp -a "$CONFIG/etc/systemd/system/." "$R/etc/systemd/system/"
cp -a "$CONFIG/etc/streamer/." "$R/etc/streamer/"
install -m 644 "$CONFIG/etc/streamer.conf" "$R/etc/streamer.conf"
for script in "$CONFIG"/usr/local/bin/*; do
    install -m 755 "$script" "$R/usr/local/bin/$(basename "$script")"
done
install -m 755 "$CLIAMP" "$R/usr/local/bin/cliamp"
install -m 755 "$FFMPEG" "$R/usr/local/bin/ffmpeg"
log "cliamp and ffmpeg in /usr/local/bin, plus $(ls "$CONFIG"/usr/local/bin | wc -l) scripts"

# Enabling the units: these are the symlinks systemctl enable would create.
# Creating them here keeps the build independent of this host's systemd, and
# the [Install] sections in the unit files say the same thing.
enable() { # enable <unit> <target>
    install -d "$R/etc/systemd/system/$2.wants"
    ln -sfn "/etc/systemd/system/$1" "$R/etc/systemd/system/$2.wants/$1"
    log "  $1 -> $2"
}
enable streamer.target            multi-user.target
enable streamer-cliamp.service    streamer.target
enable streamer-play.service      streamer.target
enable streamer-firstboot.service sysinit.target
enable streamer-bootcount.service basic.target
enable streamer-booted.service    multi-user.target
enable streamer-save.timer        timers.target
# Stock Raspberry Pi OS leaves ssh switched off unless a /boot/firmware/ssh
# marker happens to exist at boot. There is no screen or keyboard on this box,
# so ssh comes up on its own from the first boot.
install -d "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/ssh.service "$R/etc/systemd/system/multi-user.target.wants/ssh.service"
log "  ssh.service -> multi-user.target"

# And one stock unit switched off. userconfig.service is the first-boot dialog
# that asks on /dev/tty8 for a password and a user name: on a box with no
# screen it can only be a stall, and it is free to rename the uid 1000 account
# the units assume. Access here is the SSH key installed below, so the dialog
# has nothing to do. The unit file stays where it is: removing the symlink is
# exactly what systemctl enable would undo.
rm -f "$R/etc/systemd/system/multi-user.target.wants/userconfig.service"
log "  userconfig.service -> not started"

# The appliance user is whatever account Raspberry Pi OS made with uid 1000.
# The stock image gives it /usr/sbin/nologin as its shell, which lets ssh
# authenticate and then hang up straight away: unusable.
user_home=$(awk -F: '$3 == 1000 {print $6; exit}' "$R/etc/passwd")
[ -n "$user_home" ] || die "the base image has no uid 1000 account"
# The player units say User=pi and Environment=HOME=/home/pi, because that is
# the account Raspberry Pi OS makes. If a future base image names it something
# else, the units would fail to start with no obvious reason, so the build says
# so here instead.
user_name=$(awk -F: '$3 == 1000 {print $1; exit}' "$R/etc/passwd")
[ "$user_name" = pi ] || die "the uid 1000 account is called $user_name, but the
   player units assume pi: update User=/Group=/HOME= in
   $CONFIG/etc/systemd/system/streamer-*.service"
awk -F: -v OFS=: '$3 == 1000 { $7 = "/bin/bash" } 1' "$R/etc/passwd" >"$R/etc/passwd.new"
install -m 644 "$R/etc/passwd.new" "$R/etc/passwd"
rm -f "$R/etc/passwd.new"
log "uid 1000 home $user_home, shell /bin/bash"

# Key-only login: no password of any kind is written into the image, and the
# account password stays locked.
install -d -m 700 -o 1000 -g 1000 "$R$user_home/.ssh"
install -m 600 -o 1000 -g 1000 "$SSH_KEY" "$R$user_home/.ssh/authorized_keys"
log "authorised the key in $user_home/.ssh/authorized_keys"

# cliamp keeps its configuration, and the Tidal credentials, on the writable
# partition. Until first boot makes /data/cliamp this link dangles, which is
# fine: nothing runs cliamp before /data is ready.
install -d -m 755 -o 1000 -g 1000 "$R$user_home/.config"
ln -sfn /data/cliamp "$R$user_home/.config/cliamp"
chown -h 1000:1000 "$R$user_home/.config/cliamp"

# The /data fstab line is generated from the PARTUUID of this image. A copied
# one would point at some other card, and the box would then be silent forever.
# The stock root line says what this image's own disk identifier is, so use it
# as a check on the derivation above: if the two ever disagree, the fstab the Pi
# boots from is not the one the partition table belongs to.
install -d -m 755 "$R/data"
root_uuid=$(sed -n 's/^PARTUUID=\([0-9a-f]\{8\}\)-02[[:space:]]\+\/[[:space:]].*/\1/p' "$R/etc/fstab" | head -1)
if [ -n "$root_uuid" ] && [ "$root_uuid" != "$DISK_ID" ]; then
    die "the partition table says the disk identifier is $DISK_ID, but /etc/fstab mounts
  / from PARTUUID=$root_uuid-02. The cached base image and the pins in $SELF
  no longer describe the same file: re-check them."
fi
if ! grep -qsE '^[^#][^[:space:]]+[[:space:]]+/data[[:space:]]' "$R/etc/fstab"; then
    {
        printf '\n# streamer data partition: cliamp state, playlists, downloads.\n'
        printf '# The filesystem itself is made on the first boot, and nofail keeps a\n'
        printf '# card that is not laid out yet from stopping the boot. The last two fields\n'
        printf '# are zero on purpose: a boot-time fsck would otherwise try to check a\n'
        printf '# partition that has no filesystem in it while streamer-firstboot is busy\n'
        printf '# making one.\n'
        printf 'PARTUUID=%s  /data  ext4  defaults,nofail,noatime  0  0\n' "$DATA_UUID"
    } >>"$R/etc/fstab"
fi
grep -qsE '^[^#][^[:space:]]+[[:space:]]+/data[[:space:]]' "$R/etc/fstab" ||
    die "the /data fstab line did not land"
sed -n '/streamer data partition/,$p' "$R/etc/fstab" | sed 's/^/  /' >&2

# The root filesystem stays writable for the first boot, which is the one that
# has to write to it. streamer-firstboot appends ,ro for every boot after that.

if [ -n "$NEW_HOSTNAME" ]; then
    printf '%s\n' "$NEW_HOSTNAME" >"$R/etc/hostname"
    if grep -qs '^127\.0\.1\.1' "$R/etc/hosts"; then
        sed -i "s/^\(127\.0\.1\.1[[:space:]]\+\).*/\1$NEW_HOSTNAME/" "$R/etc/hosts"
    else
        printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >>"$R/etc/hosts"
    fi
    log "hostname $NEW_HOSTNAME, so ssh to $NEW_HOSTNAME.local"
fi
if [ -n "$TZONE" ]; then
    [ -f "$R/usr/share/zoneinfo/$TZONE" ] || die "no zoneinfo entry for $TZONE"
    ln -sfn "/usr/share/zoneinfo/$TZONE" "$R/etc/localtime"
    printf '%s\n' "$TZONE" >"$R/etc/timezone"
    log "timezone $TZONE"
fi

step "journal"
# journald kept in memory, which is what a read-only root without /var/log/
# journal already implies. Saying it out loud is the point: the alternative is
# logs on the writable partition, and a hard power cut is exactly the moment
# that journal gets left dirty, on a card that is being written to by the
# player at the same time. The journald that starts before local-fs.target
# could not reach a /data bind mount either way.
#
# What survives a power cut is instead the one-line-per-boot record in
# /data/streamer/boot.log, written by streamer-bootcount and streamer-play:
# small, append-only, and the thing worth having after the box was yanked.
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
# fragment is dropped in between the two markers, which is the block
# `streamer audio jack|dac` rewrites later on.
sed '/^# --- streamer audio begin ---$/,$d' "$CONFIG/boot/appliance-config.txt" >>"$CFG"
printf '# --- streamer audio begin ---\n' >>"$CFG"
cat "$CONFIG/etc/streamer/audio-$AUDIO.txt" >>"$CFG"
printf '# --- streamer audio end ---\n' >>"$CFG"
log "audio for the first boot: $AUDIO"

# The Raspberry Pi OS initrd honours a resize token; this box resizes nothing at
# boot, and ro matches what streamer-firstboot puts in fstab.
line=$(tr -d '\n\r' <"$CMDLINE")
line=${line// resize/}
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
sync

# A vfat partition edited through Linux usually needs its FS info sector
# tidied; it is worth knowing the Pi firmware is not being handed a dirty one.
fsck.fat -n "${LOOP}p1" >"$STAGE/fat.log" 2>&1 || true
if grep -qiE 'dirty|should be removed|correcting|errors' "$STAGE/fat.log"; then
    log "fsck.fat: $(tail -1 "$STAGE/fat.log")"
    fsck.fat -a "${LOOP}p1"
fi
fsck.fat -n "${LOOP}p1" >/dev/null || die "the firmware partition fails fsck.fat:
$(cat "$STAGE/fat.log")"
log "firmware partition passes fsck.fat"

e2fsck -fy "${LOOP}p2" >/dev/null || die "the root partition fails e2fsck"
# Reset the forced-check bookkeeping so the first real boot is not the one that
# decides to fsck: -C 0 clears the mount counter, -i 0 disables the periodic
# check interval, -T now stamps the superblock as just checked. (`-T never` is
# not a thing: `never` is only a keyword for -c/-i, and e2fsprogs 1.47.4 takes
# the usage line and exits non-zero on it.)
tune2fs -C 0 -i 0 -T now "${LOOP}p2" >/dev/null \
    || die "tune2fs could not reset the root partition's check counters"
log "root partition passes e2fsck, forced-check counters reset"

# Read the patched files back through a fresh mount: what matters is what the
# Pi firmware will read, not what this script thinks it wrote.
mount -o ro "${LOOP}p1" "$FW"
log "config.txt, the block the Pi will apply:"
sed -n '/^# --- streamer appliance ---$/,/^# --- streamer audio end ---$/p' "$FW/config.txt" |
    grep -vE '^[[:space:]]*(#|$)' | sed 's/^/  /' >&2
log "cmdline.txt: $(cat "$FW/cmdline.txt")"
umount "$FW"

losetup -d "$LOOP"
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
if [ -n "${SUDO_UID:-}" ]; then
    chown -R "$SUDO_UID:${SUDO_GID:-0}" "$OUT_DIR" 2>/dev/null || true
fi

log ""
ls -1sh "$OUT_DIR" | grep -v '^total' | sed 's/^/  /' >&2
log ""
log "login: ssh -i <key> pi@$NEW_HOSTNAME.local"
if [ -n "$KEY_PRIVATE" ]; then
    log "  the private key is $KEY_PRIVATE, and is not anywhere in the image"
    log "  keep a copy: it is the only way in"
fi
log ""
log "write the card, checking the device name first:"
log "  sudo xz -dc $OUT_DIR/$name.img.xz | sudo dd of=/dev/sdX bs=8M status=progress conv=fsync"
log "  (or pick the .xz in Raspberry Pi Imager: use it as a custom image)"
log ""
log "first boot lays out /data and reboots; the second boot plays."
log "then, over ssh: cliamp          # to sign in to Tidal (link.tidal.com)"
