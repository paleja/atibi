#!/bin/bash
# Regression harness for the appliance boot scripts.
#
#   tests/appliance-scripts.sh            all scenarios
#   tests/appliance-scripts.sh 3 4        just those
#
# It needs no root and no Pi: the scripts are re-written in a sandbox so their
# paths point at directories under here, and a stub `cliamp` stands in for the
# player. Each scenario prints what happened and then checks it: the exit status
# of this script, and only that, is the verdict.
#
# The stub models cliamp 2.4.1 where the behaviour matters, not only the verbs.
# That is not decoration: an earlier stub let `cliamp queue <url>` replace the
# playlist, which is what the appliance code assumed and what the real player
# does not do. A live daemon boots with the cliamp radio channels already loaded
# and no row current, queueing only appends, and url.load is the verb that plays
# the row it adds. The stub encodes all of that, and scenario 1 and 12 fail if
# the scripts ever go back to assuming row 0 is the one to play.

set -eu
cd "$(dirname "$0")/.."
CFG=$PWD/config
BUILD=$PWD/image/build.sh
FIX=$PWD/tests/fixtures

# The real block tools, remembered before the sandbox's PATH is put in front of
# them. Scenario 15 asks them what options they support, which is only a check
# if it is asking the same util-linux the card runs.
REAL_BLOCKDEV=$(command -v blockdev || true)
REAL_SFDISK=$(command -v sfdisk || true)

[ -n "${TESTDEBUG:-}" ] && set -x

fail=0
pass=0
good()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
ck()    { # ck <label> <shell condition>: the condition runs with the count safe
    if eval "$2"; then good "$1"; else bad "$1"; fi; }
ck_eq() { # ck_eq <label> <got> <want>
    if [ "$2" = "$3" ]; then good "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
ck_in() { # ck_in <label> <file> <fixed text>
    if grep -qF -- "$3" "$2" 2>/dev/null; then good "$1";
    else bad "$1 (no '$3' in $(basename "$2"))"; fi; }
ck_not() { # ck_not <label> <file> <fixed text>
    if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1 ('$3' is present)";
    else good "$1"; fi; }
jnum() { # jnum <key>: number for that key in the stand-in player's state.
         # Normalised because the stub stores JSON floats: -20.0 and -20 are the
         # same level, and a check should not be about the spelling.
    sed -n 's/.*"'"$1"'":\(-\?[0-9][0-9.]*\).*/\1/p' "$T/state.json" | head -1 |
        awk '{ printf "%g", $1 }'; }
jstr() { # jstr <key>: string value for that key
    sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$T/state.json" | head -1; }
pln() { # pln <pattern>: line number of the first transcript entry that matches,
        # or 0 if the boot never asked for it. Lets a check be about the order
        # the player gets told things in, not only about what it ends up as.
    grep -n -- "$1" "$T/player.log" 2>/dev/null | head -1 | cut -d: -f1; }
jrow() { # jrow <n>: the n-th row of the live playlist, as the stub spells it
    python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
q = d.get("queue", [])
print(q[int(sys.argv[2])] if int(sys.argv[2]) < len(q) else "")' "$T/state.json" "$1"; }

C=$PWD/config/etc/streamer.conf
T=${TESTSANDBOX:-/tmp/opencode/rpi-streamer-playtest}

# Everything a scenario can leave behind that another scenario reads. Running
# one scenario on its own must not decide what a later full run sees: the
# geometry record scenario 16 leaves in /etc/streamer, for instance, makes
# scenario 4 reboot instead of rolling the boot files back.
rm -rf "$T/logs" "$T/data" "$T/fw" "$T/home" "$T/etc-streamer" "$T/sudoers.d" \
       "$T/dev" "$T/sys" "$T/fstab" "$T/run"
mkdir -p "$T/bin" "$T/fw" "$T/home/.config/cliamp" \
         "$T/data/streamer/last-good" "$T/logs"
cp "$CFG"/etc/streamer/audio-*.txt "$T/"

# --- the stand-in player ------------------------------------------------------
# Holds its whole state in state.json, so a scenario can read back what the
# script under test actually asked the player to do.
cat >"$T/bin/cliamp" <<'PYEOF'
#!/usr/bin/env python3
import json, os, re, sys
S = os.path.join(os.environ["TESTROOT"], "state.json")
# What a real daemon preloads. Row 0 is what a naive "play" would start.
PRELOAD = ["cliamp radio: Omarchy", "cliamp radio: Chiptunes",
           "cliamp radio: Amiga", "cliamp radio: Lofi", "cliamp radio: Synthwave"]
def fresh():
    return {"state": "stopped", "position": 0, "volume": -30,
            "index": -1, "queue": list(PRELOAD)}
def load():
    if os.path.exists(S):
        d = json.load(open(S))
        for key, value in fresh().items():   # a hand-seeded state stays valid
            d.setdefault(key, value)
        elsewhere(d)
        return d
    return fresh()
def elsewhere(d):
    # Somebody reached for the volume a moment after the boot started turning it
    # up: the bar panel, an SSH session, a remote. The marker holds a dB figure.
    # It takes effect only once the boot has made its first adjustment, because
    # that is the window the guard exists for. A level set before the boot began
    # is simply the level the boot ramps from, and climbing on from there to the
    # saved setting is the correct thing to do. What matters is that mid-ramp,
    # the person who actually touched the volume wins: the boot stops rather
    # than arguing with them.
    if d.get("adjustments", 0) < 1:
        return
    p = os.path.join(os.environ["TESTROOT"], "set-elsewhere")
    if os.path.exists(p) and not d.get("elsewhere_applied"):
        d["volume"] = float(open(p).read().strip())
        d["elsewhere_applied"] = True
        save(d)
def save(d): json.dump(d, open(S, "w"), separators=(",", ":"))
def out(d): sys.stdout.write(json.dumps(d, separators=(",", ":")) + "\n")
def stuck_at():
    # A stand-in for a hardware limit: PipeWire or the codec clamping the level
    # below where cliamp believes it is. The scenario drops this file with a dB
    # figure in it, and the player stops responding to requests past that point.
    p = os.path.join(os.environ["TESTROOT"], "stuck-at")
    if os.path.exists(p):
        return float(open(p).read().strip())
    return None
def cap(d, v):
    # cliamp has its own ceiling, and it is deliberately above the appliance's
    # STREAMER_VOL_MAX: if the stand-in clamped at the same figure the appliance
    # aims for, a boot script that forgot its own ceiling would still look
    # correct, and the check would be about the stand-in rather than the script.
    # The stuck-at file stands in for a limit further down still, which is what
    # an output device with a ceiling of its own gets you into.
    top = min(12.0, v)
    s = stuck_at()
    if s is not None:
        top = min(top, s)
    return max(-50.0, top)
def arg(flag): return sys.argv[sys.argv.index(flag) + 1]
def num(name):
    m = re.search('"%s":(-?[0-9.]+)' % name, arg("--params"))
    if not m: sys.exit("fake cliamp: no %s in params" % name)
    return float(m.group(1))
def sarg(name):
    m = re.search('"%s":"([^"]*)"' % name, arg("--params"))
    if not m: sys.exit("fake cliamp: no %s in params" % name)
    return m.group(1)
a = sys.argv[1:]
# Order matters as much as the commands themselves: the boot has to make the
# level quiet before it makes any sound. So every call gets recorded, apart from
# the harness setting up the state of play.
if a[:1] != ["--default-state"]:
    with open(os.path.join(os.environ["TESTROOT"], "player.log"), "a") as f:
        f.write(" ".join(a) + "\n")
if a[:1] == ["--daemon"]: sys.exit(0)
if a[:1] == ["--version"]: print("fake-cliamp 9.9.9"); sys.exit(0)
if a[:1] == ["--default-state"]: out(fresh()); sys.exit(0)
if a[:1] == ["status"]:   out(load()); sys.exit(0)
if a[:1] == ["logs"]:     sys.exit(0)
if a[:1] in (["pause"], ["toggle"], ["next"], ["previous"], ["save"]):
    d = load()
    if a[:1] == ["pause"]: d["state"] = "paused"
    d["saved"] = True
    save(d); sys.exit(0)
if a[:1] == ["stop"]:
    d = load(); d["state"] = "stopped"; save(d); sys.exit(0)
if a[:1] == ["radio"]:
    print("Lofi Girl            https://lofi.girl/stream")
    sys.exit(0)
if a[:2] == ["playlist", "list"]:
    print(json.dumps([{"name": "Late Night", "tracks": 42},
                      {"name": "Focus", "tracks": 18}], separators=(",", ":")))
    sys.exit(0)
if a[:1] == ["volume"]:
    d = load(); d["volume"] = cap(d, float(a[1])); save(d); sys.exit(0)
if a[:1] == ["queue"]:
    # append only: the row it adds does not become the current one
    d = load(); d["queue"] = d.get("queue", []) + [a[1]]; save(d); sys.exit(0)
if a[:1] == ["load"]:
    # replaces the playlist, and leaves no row current until something plays
    d = load(); d["queue"] = ["%s: row %d" % (a[1], i) for i in range(12)]
    d["index"] = -1; d["name"] = a[1]; save(d); sys.exit(0)
if a[:1] == ["play"]:
    d = load()
    if d["index"] < 0:
        if not d.get("queue"): sys.exit(1)   # nothing loaded: refuse
        d["index"] = 0
    d["state"] = "playing"; save(d); sys.exit(0)
if a[:3] == ["remote", "call", "volume.adjust"]:
    d = load()
    d["volume"] = cap(d, d["volume"] + num("value"))
    d["adjustments"] = d.get("adjustments", 0) + 1
    save(d); sys.exit(0)
if a[:3] == ["remote", "call", "queue.list"]:
    d = load()
    out({"ok": True, "index": d["index"], "total": len(d.get("queue", []))}); sys.exit(0)
if a[:3] == ["remote", "call", "queue.play"]:
    d = load(); i = int(num("index")); q = d.get("queue", [])
    if i < 0 or i >= len(q): sys.exit("fake cliamp: index %d out of range" % i)
    d["index"] = i; d["state"] = "playing"; save(d); sys.exit(0)
if a[:3] == ["remote", "call", "url.load"]:
    url, play = sarg("path"), '"play":true' in arg("--params")
    d = load(); d["queue"] = d.get("queue", []) + [url]
    if play:
        d["index"] = len(d["queue"]) - 1; d["state"] = "playing"
    save(d); sys.exit(0)
if a[:3] == ["remote", "call", "seek.absolute"]:
    d = load(); d["position"] = num("value"); save(d); sys.exit(0)
sys.stderr.write("fake cliamp: unhandled: %r\n" % (a,)); sys.exit(1)
PYEOF
# systemctl and mount are not things a sandbox run should really do: the fw
# directory is not a mountpoint, so a real remount would fail for reasons that
# have nothing to do with the logic under test.
cat >"$T/bin/systemctl" <<'EOF'
#!/bin/sh
echo "  [systemctl $*]" >&2
exit 0
EOF
cat >"$T/bin/mount" <<'EOF'
#!/bin/sh
echo "  [mount $*]" >&2
# The one mount call whose consequences the sandbox has to model is a remount
# of the root filesystem, because the read-only root is the whole power-cut
# design: a stub that only echoed would let a script quietly make the root
# writable on every boot and nothing would notice. It records the remount
# instead of doing it, and scenario 16 reads the record back. Matching is on
# the mount point being "/" exactly, so a remount of the boot directory in
# another script never counts.
case " $* " in
    *" -o remount,rw / "*|*" -o remount,rw /"*) printf 'rw\n' >>"$TESTROOT/mount-root" ;;
    *" -o remount,ro / "*|*" -o remount,ro /"*) printf 'ro\n' >>"$TESTROOT/mount-root" ;;
esac
# The other mount worth modelling is the data volume, which streamer-firstboot
# makes itself, before data.mount, in order to seed the appliance's tree on the
# partition rather than through its unmounted mount point. There are no real
# mounts in the sandbox, so the mount point directory stands in for the
# volume's own contents and stays put across boots. One failure is worth
# modelling, because the answer to it only exists if it can happen: a volume
# that will not mount at all.
case $1 in
    "$TESTROOT"/dev/*)
        . "$TESTROOT/bin/devstate.sh"
        if [ "${mount_fail_once:-no}" = yes ]; then
            printf 'mount_fail_once=no\n' >>"$TESTROOT/bin/devstate.sh"
            echo "  (refused: the stand-in volume will not mount)" >&2
            exit 1
        fi ;;
esac
exit 0
EOF
cat >"$T/bin/umount" <<'EOF'
#!/bin/sh
# streamer-firstboot mounts the data partition on a mount point of its own, in
# order to look at the tree on it and seed it if it is not there, and lets go
# again so that data.mount can have the partition. Nothing is really mounted in
# the sandbox, and the contents of that directory stand in for the partition's
# own contents, which is why this shim must not remove anything: it only has to
# be the tool's name, and to record that the call was made.
echo "  [umount $*]" >&2
exit 0
EOF
# The station list belongs to the radio service, so a build host with no network
# would otherwise fail for the wrong reason. The fixture is the shape that
# service really answers with, captured from https://radio.cliamp.stream/
# stations: each station has a "name", a "stream", and a "tracks_url" that must
# not be mistaken for the stream.
cat >"$T/bin/curl" <<EOF
#!/bin/sh
case "\$*" in
    *stations*) cat "$FIX/stations.json"; exit 0 ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$T/bin/cliamp" "$T/bin/systemctl" "$T/bin/mount" "$T/bin/umount" "$T/bin/curl"

# The block-device tools. A sandbox run cannot resize a real disk, and the
# point of testing streamer-firstboot is the decisions it makes about sizes,
# not the syscalls. So these stand-ins keep the card's geometry in one file and
# obey the two rules the real tools taught us on hardware: sfdisk -N writes the
# table (and nothing tells the kernel, because a busy disk refuses BLKRRPART),
# and sfdisk -d reads the table back from the sectors, which is why it is the
# only honest read-back in a boot where the kernel still sees the old one.
# blkid reports the *kernel's* view, dumpe2fs the filesystem's, blockdev the
# kernel's: those three disagreeing is the whole problem the script solves.
cat >"$T/bin/devstate.sh" <<'EOF'
# geometry, in sectors, as the kernel currently sees the card
k_start=6012928
k_size=524288
disk=24522752            # whole card
on_disk=524288           # size in the table that is actually on the sectors
fs=524288                # size the ext4 covers, in sectors
fs_present=yes
sfdisk_lies=no
fsck_calls=0
resize_calls=0
mkfs_calls=0
sfdisk_calls=0
EOF
cat >"$T/bin/blockdev" <<'EOF'
#!/bin/sh
. "$TESTROOT/bin/devstate.sh"
case "$1" in
    --getsz) case "$2" in
        *p3) echo "$k_size" ;;
        *)   echo "$disk" ;;
    esac ;;
    --flushbufs) exit 0 ;;
    *) echo "sandbox blockdev: unhandled $*" >&2; exit 1 ;;
esac
EOF
cat >"$T/bin/sfdisk" <<'EOF'
#!/bin/sh
. "$TESTROOT/bin/devstate.sh"
case "$*" in
    -d*)
        echo "label: dos"
        echo "device: mmcblk0"
        echo "unit: sectors"
        echo
        echo "mmcblk0p1 : start=          16384, size=      1048576, type=c"
        echo "mmcblk0p2 : start=       1064960, size=      4947968, type=83"
        echo "mmcblk0p3 : start=      $k_start, size=     $on_disk, type=83"
        exit 0 ;;
esac
# a write: stdin carries "start=N, size=M, type=83" for the one partition
sfdisk_calls=$((sfdisk_calls + 1))
IFS= read -r spec
want_start=$(printf '%s' "$spec" | sed -n 's/.*start=\([0-9]*\).*/\1/p')
want_size=$(printf '%s' "$spec" | sed -n 's/.*size=\([0-9]*\).*/\1/p')
case "$*" in
    *"-N 3"*) ;;                       # the only partition this script resizes
    *) echo "sandbox sfdisk: unhandled write: $*" >&2; exit 1 ;;
esac
if [ -z "$want_start" ] || [ -z "$want_size" ]; then
    # The real -q -N form with no size is a silent no-op: rc=0, nothing written.
    echo "sandbox sfdisk: no explicit size, so nothing happens (rc=0)" >&2
    exit 0
fi
if [ "$want_start" != "$k_start" ]; then
    echo "sandbox sfdisk: start $want_start does not match $k_start" >&2
    exit 1
fi
if [ "$want_size" -gt $((disk - k_start - 1)) ]; then
    echo "sandbox sfdisk: $want_size sectors past the end of the card" >&2
    exit 1
fi
if [ "$sfdisk_lies" = yes ]; then
    # The shape of the bug util-linux 2.41 produces for `-N 3` with only a
    # start=: success, and a table that says the same size as before.
    echo "sandbox sfdisk: rc=0, table unchanged" >&2
    exit 0
fi
on_disk=$want_size
printf 'on_disk=%d\n' "$on_disk" >>"$TESTROOT/bin/devstate.sh"
printf 'sfdisk_calls=%d\n' "$sfdisk_calls" >>"$TESTROOT/bin/devstate.sh"
exit 0
EOF
cat >"$T/bin/blkid" <<'EOF'
#!/bin/sh
. "$TESTROOT/bin/devstate.sh"
case "$*" in
    *"LABEL $TESTROOT/dev/mmcblk0p3"*) [ "$fs_present" = yes ] && echo streamer-data; exit 0 ;;
    *"TYPE $TESTROOT/dev/mmcblk0p3"*)  [ "$fs_present" = yes ] && echo ext4; exit 0 ;;
    *) exit 2 ;;
esac
EOF
cat >"$T/bin/dumpe2fs" <<'EOF'
#!/bin/sh
. "$TESTROOT/bin/devstate.sh"
[ "$fs_present" = yes ] || exit 1
# A real dumpe2fs -h reports the filesystem's own units, so the numbers have to
# be consistent: a 4096-byte block is eight sectors.
echo "Block count:              $((fs / 8))"
echo "Block size:               4096"
EOF
cat >"$T/bin/e2fsck" <<'EOF'
#!/bin/sh
. "$TESTROOT/bin/devstate.sh"
fsck_calls=$((fsck_calls + 1))
printf 'fsck_calls=%d\n' "$fsck_calls" >>"$TESTROOT/bin/devstate.sh"
# Which device was checked, recorded rather than echoed into the caller's log:
# the caller sends fsck's output to /dev/null, so the only way to see what it
# pointed at is to watch the call itself.
printf 'fsck_dev=%s\n' "$2" >>"$TESTROOT/bin/devstate.sh"
# fsck's exit status is a small protocol rather than a pass/fail: 1 means it
# fixed something and the result is usable, 4 means it could not. The second is
# the one streamer-firstboot has to treat as fatal, so it is worth being able to
# ask for.
if [ "${fsck_really_fails:-no}" = yes ]; then exit 4; fi
if [ "${fsck_fixed:-no}" = yes ]; then exit 1; fi
exit 0
EOF
cat >"$T/bin/resize2fs" <<'EOF'
#!/bin/sh
. "$TESTROOT/bin/devstate.sh"
fs=$k_size            # grow to whatever the kernel says the partition is
printf 'fs=%d\n' "$fs" >>"$TESTROOT/bin/devstate.sh"
resize_calls=$((resize_calls + 1))
printf 'resize_calls=%d\n' "$resize_calls" >>"$TESTROOT/bin/devstate.sh"
EOF
cat >"$T/bin/mkfs.ext4" <<'EOF'
#!/bin/sh
. "$TESTROOT/bin/devstate.sh"
fs=$k_size                # a fresh filesystem only covers the kernel's size
fs_present=yes
printf 'fs=%d\nfs_present=yes\n' "$fs" >>"$TESTROOT/bin/devstate.sh"
mkfs_calls=$((mkfs_calls + 1))
printf 'mkfs_calls=%d\n' "$mkfs_calls" >>"$TESTROOT/bin/devstate.sh"
EOF
cat >"$T/bin/udevadm" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$T/bin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$T/bin/visudo" <<'EOF'
#!/bin/sh
# The real visudo -cf parses the fragment; a syntax error in sudoers on a box
# with no password is a locked door, so the check has to be real enough to
# notice a fragment that sudo itself would refuse.
case "$1" in
    -cf) grep -qE '^[A-Za-z0-9_.-]+[[:space:]]+ALL=\(ALL[[:space:]]*\)[[:space:]]+NOPASSWD:ALL$' "$2" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/devstate.sh" "$T/bin/blockdev" "$T/bin/sfdisk" "$T/bin/blkid" \
    "$T/bin/dumpe2fs" "$T/bin/e2fsck" "$T/bin/resize2fs" "$T/bin/mkfs.ext4" \
    "$T/bin/udevadm" "$T/bin/chown" "$T/bin/visudo"

# Every absolute path the scripts use comes from one of two places: the knobs
# in /etc/streamer.conf, or a literal /usr/local/bin or /boot/firmware in the
# script itself. So the sandbox is two rewrites, and nothing else: the logic
# under test is otherwise byte-for-byte what ships.
cat >"$T/streamer.conf" <<EOF
$(sed -e 's#=/data/#='$T'/data/#' "$CFG/etc/streamer.conf")
# The default target points at localhost: a boot test that reached for the real
# radio service would fail on an offline build host for reasons that have
# nothing to do with the scripts. What matters here is that *some* URL start
# gets a row of its own, and that row is the one that plays.
STREAMER_START_TARGET=http://localhost/x.mp3
# Small on purpose: one scenario checks that the log keeps its window and drops
# the oldest lines, and that is cheaper to see with four than with two hundred.
# The budgets are shortened too: the scenario where the player never comes up
# has to sit through them.
STREAMER_BOOTLOG_KEEP=4
STREAMER_SOCKET_WAIT=1
STREAMER_PLAY_WAIT=1
# A ramp this fast costs the suite nothing; MAX_STEPS stays at the shipped 16
# except in the one scenario that deliberately runs the budget out.
STREAMER_RAMP_START=0.05
STREAMER_RAMP_DELAY=0.05
STREAMER_RAMP_MAX_STEPS=16
EOF
sandbox() { # sandbox <script name>
    sed \
        -e 's#^\. /etc/streamer\.conf$#. '$T'/streamer.conf#' \
        -e 's#/etc/streamer\.conf#'$T'/streamer.conf#g' \
        -e 's#/etc/streamer/audio-#'$T'/audio-#g' \
        -e 's#/etc/streamer#'$T'/etc-streamer#g' \
        -e 's#/boot/firmware/config.txt#'$T'/fw/config.txt#g' \
        -e 's#^boot_dir=/boot/firmware$#boot_dir='$T'/fw#' \
        -e 's;/usr/local/bin/streamer;'"$T"'/streamer;g' \
        "$CFG/usr/local/bin/$1" >"$T/$1"
    chmod +x "$T/$1"
}
sandbox_data() { # sandbox_data: streamer-firstboot, the one script that talks to
                 # block devices, /etc/fstab, sudoers, and another user's home.
                 # Nothing in it is stubbed out: the paths are moved, and the
                 # tools it calls are the stand-ins defined above.
    sed \
        -e 's#^\. /etc/streamer\.conf$#. '$T'/streamer.conf#' \
        -e 's#/etc/streamer\.conf#'$T'/streamer.conf#g' \
        -e 's#/etc/streamer#'$T'/etc-streamer#g' \
        -e 's#/etc/fstab#'$T'/fstab#g' \
        -e 's#/etc/sudoers.d#'$T'/sudoers.d#g' \
        -e 's#/dev/disk/by-partuuid/#'$T'/dev/disk/by-partuuid/#g' \
        -e 's#^DISK_DEV=/dev/\$DISK$#DISK_DEV='$T'/dev/$DISK#' \
        -e 's#/sys/class/block/#'$T'/sys/class/block/#g' \
        -e 's#/data/cliamp#'$T'/data/cliamp#g' \
        -e 's#/data/state#'$T'/data/state#g' \
        -e 's#/data/bin#'$T'/data/bin#g' \
        -e 's#/data/music#'$T'/data/music#g' \
        -e 's#^DATA_MNT=/run/streamer-data$#DATA_MNT='$T'/run/data#' \
        -e 's#/home/pi/.config#'$T'/home/pi/.config#g' \
        "$CFG/usr/local/bin/streamer-firstboot" >"$T/streamer-firstboot"
    chmod +x "$T/streamer-firstboot"
    # The card as this one is: mmcblk0p3 with the PARTUUID the build derived,
    # and the start sector sysfs reports for it. The stand-in sfdisk writes a
    # new table without telling the kernel, exactly as the real one does.
    mkdir -p "$T/dev/disk/by-partuuid" "$T/sys/class/block/mmcblk0p3" \
             "$T/etc-streamer" "$T/sudoers.d" "$T/home/pi/.config"
    : >"$T/dev/mmcblk0"
    : >"$T/dev/mmcblk0p3"
    ln -sfn "$T/dev/mmcblk0p3" "$T/dev/disk/by-partuuid/27b94958-03"
    printf '6012928\n' >"$T/sys/class/block/mmcblk0p3/start"
}
devcounter() { # devcounter <key>: the last value a block tool recorded for it
    sed -n 's/^'"$1"'=//p' "$T/bin/devstate.sh" | tail -1; }
reset_geo() { # reset_geo: back to the geometry a freshly written image presents
    cat >"$T/bin/devstate.sh" <<'EOF'
k_start=6012928
k_size=524288
disk=24522752
on_disk=524288
fs=524288
fs_present=yes
sfdisk_lies=no
fsck_calls=0
resize_calls=0
mkfs_calls=0
sfdisk_calls=0
EOF
}
for s in streamer-bootlog streamer-play streamer-save streamer-bootcount streamer-booted streamer; do
    sandbox "$s"
done

reset() { # a clean /data/streamer, a player as a live daemon has it, fresh boot files
    rm -rf "$T"/data/streamer/* "$T/state.json"
    # The provisioning boot records the geometry it asked for, and bootcount
    # acts on that record whenever the kernel has not caught up with it. A
    # scenario that counts boots must start without one, whatever ran before it.
    rm -f "$T"/etc-streamer/geometry-* "$T/mount-root"
    mkdir -p "$T/data/streamer/last-good"
    "$T/bin/cliamp" --default-state >"$T/state.json"
    rm -f "$T/player.log"
    fw_seed jack
    # The counter file exists after any boot, good or bad, so a sandbox that
    # pretends to be a running system has one. Most scenarios want to start from
    # "this boot is attempt 3" rather than from nothing.
    printf 'attempt=2\nconfig=%s\n' "$(fw_hash)" >"$T/data/streamer/attempt"
}

runas() { # runas: run a command whose PATH sees the sandbox shims first. The
          # block-device stand-ins in $T/bin are what a real card would be for
          # streamer-firstboot, and PATH already starts with $T/bin.
    "$@"; }

fw_seed() { # fw_seed <jack|dac>: the boot partition as image/build.sh leaves it,
            # appliance block and all, with the audio fragment already spliced in
    {
        printf 'initramfs initramfs.img\nauto cfg.txt followdtbs boot/initrd.img\n[all]\n'
        printf '#dtparam=audio=on\n#dtoverlay=vc4-kms-v3d\n'
        awk -v f="$CFG/etc/streamer/audio-$1.txt" '
            /^# --- streamer audio begin ---$/ {
                print; while ((getline l < f) > 0) print l; skip = 1; next
            }
            /^# --- streamer audio end ---$/   { skip = 0; print; next }
            { if (!skip) print }
        ' "$CFG/boot/appliance-config.txt"
    } >"$T/fw/config.txt"
    printf 'console=serial0,115200 initrd=initramfs.img rootwait ro\n' >"$T/fw/cmdline.txt"
}
export HOME=$T/home TESTROOT=$T PATH=$T/bin:$PATH STREAMER_SUDO=1
sock=$HOME/.config/cliamp/cliamp.sock
socket_on() { # the player is up: streamer-play only checks that the socket is there
    rm -f "$sock"
    # Detached from the harness's own stdout/stderr, and watching for its own
    # socket to vanish: a leftover listener holding the output pipes open would
    # keep a caller reading long after the scenarios finished, and a scenario
    # that forgets socket_off would otherwise sit here for two minutes.
    python3 -c 'import os, socket, time
p = os.path.expandvars("$HOME/.config/cliamp/cliamp.sock")
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(1)
for _ in range(300):          # 60 s at most, and gone as soon as the file is
    if not os.path.exists(p): break
    time.sleep(0.2)
' </dev/null >"/dev/null" 2>&1 &
    socketpid=$!
    i=0
    while [ ! -S "$sock" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
}
socket_off() {
    rm -f "$sock"
    [ -n "${socketpid:-}" ] && kill "$socketpid" 2>/dev/null
    socketpid=
    return 0
}
# Whatever a scenario forgets, the fake player must not outlive the harness.
trap 'socket_off' EXIT
fw_hash() { # the way streamer-bootcount hashes the boot partition
    { cat "$T/fw/config.txt"; [ -f "$T/fw/cmdline.txt" ] && cat "$T/fw/cmdline.txt"; } |
        sha256sum | cut -d' ' -f1
}
count_markers() { # exact marker lines only: the appliance block also mentions
                   # them in prose, which the awk splice does not match
    grep -cE '^# --- streamer audio (begin|end) ---$' "$T/fw/config.txt"; }
audio_lines() { grep -E '^(dtparam=audio|dtoverlay=(vc4-kms-v3d|iqaudio))' "$T/fw/config.txt" |
    tr '\n' ' '; }
note() { printf '\n=== %s\n' "$1"; }
player() { printf 'player: state=%s row=%s rows=%s position=%s volume=%s\n' \
    "$(jstr state)" "$(jnum index)" "$(rows)" "$(jnum position)" "$(jnum volume)"; }
rows() { # how many rows the stand-in player has loaded
    python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("queue", [])))' \
        <"$T/state.json"; }
log_tail() { printf 'boot.log:\n'; sed 's/^/  /' "$T/data/streamer/boot.log" 2>/dev/null || echo "  (none)"; }

# Every scenario ends with its checks. The transcripts are there to read when a
# check fails, not as the verdict on their own.
run() { # run <scenario number>
    case "$1" in
    1) note "1. first boot: no saved state, the default station, ramp to the fallback level"
        reset; socket_on
        if "$T/streamer-play" >"$T/logs/s1" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s1"; echo "  exit $rc"
        player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the target URL got a row of its own" "$(jrow 5)" "http://localhost/x.mp3"
        ck_eq "that row is the one playing, not row 0" "$(jnum index)" "5"
        ck_eq "playing" "$(jstr state)" "playing"
        ck "the boot floor is set on the player, and set before it makes a sound" \
            "[ $(pln 'volume -30') -gt 0 ] && [ $(pln 'volume -30') -lt $(pln 'url.load') ]"
        ck_eq "ramped to the fallback level" "$(jnum volume)" "-20"
        ck_in "boot.log records the play" "$T/data/streamer/boot.log" "OK url http://localhost/x.mp3"
        ck_in "boot.log records the level it reached" "$T/data/streamer/boot.log" "(target -20)"
        ck_in "it says the level came from the fallback" "$T/logs/s1" "no saved volume" ;;
    2) note "2. resume: playlist 'Late Night', row 7, 412s in, at the saved -9 dB"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'position=412\nindex=7\nvolume=-9\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s2" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s2"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the preloaded channels were replaced" "$(jrow 0)" "Late Night: row 0"
        ck_eq "row 7 is playing" "$(jnum index)" "7"
        ck_eq "back to the saved position" "$(jnum position)" "412"
        ck_eq "the saved level is replayed" "$(jnum volume)" "-9"
        ck_in "boot.log records the resume" "$T/data/streamer/boot.log" "resumed at row 7"
        ck_in "boot.log records the play" "$T/data/streamer/boot.log" "OK playlist Late Night"
        ck_in "boot.log records the level it reached" "$T/data/streamer/boot.log" "(target -9)" ;;
    3) note "3. streamer-save while playing, then a resume from what it wrote"
        reset; socket_on
        "$T/streamer-play" >/dev/null 2>&1
        # Move the stand-in to a mid-album spot, the way a real session would be
        # when the timer fires, and check the saved file says the same thing.
        "$T/bin/cliamp" remote call queue.play --params '{"index":4}' --wait >/dev/null
        "$T/bin/cliamp" remote call seek.absolute --params '{"value":613.7}' --wait >/dev/null
        "$T/streamer-save"; echo "  exit $?"
        echo "  progress: $(tr '\n' ' ' <"$T/data/streamer/progress")"
        ck_in "progress keeps the row" "$T/data/streamer/progress" "index=4"
        ck_in "progress keeps the position" "$T/data/streamer/progress" "position=613"
        ck_in "progress keeps the level" "$T/data/streamer/progress" "volume=-20"
        echo "  and a resume from it:"
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        if "$T/streamer-play" >/dev/null 2>&1; then rc=0; else rc=$?; fi
        player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the row it saved is the row it plays" "$(jnum index)" "4"
        ck_eq "the position it saved is the position it seeks" "$(jnum position)" "613" ;;
    4) note "4. streamer-bootcount: the third failure of a bad config rolls boot files back"
        reset; socket_on
        # last-good is a config the box really had booted: the DAC fragment,
        # whole files, hashed the way the script hashes them. The live config is
        # then switched to the jack one, given a cmdline.txt that would not
        # boot, and failed three times in a row, so the restore is visible in
        # both boot files.
        fw_seed dac
        cp "$T/fw/config.txt"  "$T/data/streamer/last-good/config.txt"
        cp "$T/fw/cmdline.txt" "$T/data/streamer/last-good/cmdline.txt"
        { cat "$T/data/streamer/last-good/config.txt"
          cat "$T/data/streamer/last-good/cmdline.txt"; } |
            sha256sum | cut -d' ' -f1 >"$T/data/streamer/last-good/hash"
        fw_seed jack
        printf 'console=serial0,115200 initrd=there-is-no-such-initrd.img rootwait ro\n' \
            >"$T/fw/cmdline.txt"
        printf 'attempt=2\nconfig=%s\n' "$(fw_hash)" >"$T/data/streamer/attempt"
        echo "  audio lines before: $(audio_lines)"
        echo "  cmdline before:     $(cat "$T/fw/cmdline.txt")"
        "$T/streamer-bootcount" 2>&1 | sed 's/^/  /'
        echo "  audio lines after:  $(audio_lines)"
        echo "  cmdline after:      $(cat "$T/fw/cmdline.txt")"
        echo "  attempt: $(tr '\n' ' ' <"$T/data/streamer/attempt")"
        socket_off
        ck_eq "the counter reached three" "$(sed -n 's/^attempt=//p' "$T/data/streamer/attempt")" "3"
        ck_in "the third failure restored the DAC fragment" "$T/fw/config.txt" "dtoverlay=iqaudio-dacplus"
        ck_eq "the jack fragment it had been using is gone" \
            "$(grep -c '^dtparam=audio=on$' "$T/fw/config.txt")" "0"
        ck_eq "the restored file kept the markers intact" "$(count_markers)" "2"
        ck_eq "cmdline.txt came back from last-good" "$(cat "$T/fw/cmdline.txt")" "$(cat "$T/data/streamer/last-good/cmdline.txt")"
        ck_in "boot.log says what was tried" "$T/data/streamer/boot.log" "boot attempt 3 config"
        ck_in "boot.log says why the boot files changed" "$T/data/streamer/boot.log" "failed 3 times, restoring last-good" ;;
    5) note "5. streamer-booted: this config is known-good, the counter resets"
        reset; socket_on
        "$T/streamer-bootcount" >/dev/null 2>&1
        echo "  counter before: $(tr '\n' ' ' <"$T/data/streamer/attempt")"
        "$T/streamer-booted" 2>&1 | sed 's/^/  /'
        after_booted=$(sed -n 's/^attempt=//p' "$T/data/streamer/attempt")
        echo "  last-good config.txt: $(wc -l <"$T/data/streamer/last-good/config.txt") lines"
        echo "  attempt after:  $(tr '\n' ' ' <"$T/data/streamer/attempt")"
        echo "  and the next boot of it counts as 1:"
        "$T/streamer-bootcount" 2>&1 | sed 's/^/  /'
        next_boot=$(sed -n 's/^attempt=//p' "$T/data/streamer/attempt")
        socket_off
        ck_eq "the counter goes back to zero" "$after_booted" "0"
        ck_eq "last-good is the live boot partition" \
            "$(sha256sum <"$T/data/streamer/last-good/config.txt" | cut -d' ' -f1)" \
            "$(sha256sum <"$T/fw/config.txt" | cut -d' ' -f1)"
        ck_in "boot.log records the good boot" "$T/data/streamer/boot.log" "reached multi-user, counter reset"
        ck_eq "the next boot counts as 1" "$next_boot" "1" ;;
    6) note "6. stop mode: stay quiet"
        reset; socket_on
        printf 'mode=stop\nkind=url\ntarget=http://localhost/x.mp3\n' >"$T/data/streamer/state"
        if "$T/streamer-play" >"$T/logs/s6" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s6"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "nothing started" "$(jstr state)" "stopped"
        ck_eq "no row was picked" "$(jnum index)" "-1"
        ck_not "the default station was not queued" "$T/state.json" "http://localhost/x.mp3"
        ck_in "boot.log says it stayed quiet on purpose" "$T/data/streamer/boot.log" "stop mode, nothing started" ;;
    7) note "7. a saved level of +99 dB is clamped to STREAMER_VOL_MAX"
        reset; socket_on
        printf 'mode=last\nkind=url\ntarget=http://localhost/x.mp3\n' >"$T/data/streamer/state"
        printf 'position=0\nindex=-1\nvolume=99\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s7" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s7"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the ceiling held" "$(jnum volume)" "6"
        ck_in "and the clamp is in the log" "$T/data/streamer/boot.log" "(target 6)" ;;
    8) note "8. the player never comes up: fail loudly, and say so in boot.log"
        reset; socket_off
        if "$T/streamer-play" >"$T/logs/no-socket" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/no-socket"
        echo "  exit $rc (non-zero is the point: systemd records it and moves on)"
        ck "exit status is non-zero" "[ $rc -ne 0 ]"
        ck_in "boot.log says what was waited for" "$T/data/streamer/boot.log" "FAIL no cliamp socket" ;;
    9) note "9. streamer, the SSH-facing control: what it reports"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'position=412\nindex=7\nvolume=-9\n' >"$T/data/streamer/progress"
        echo "-- streamer last"; "$T/streamer" last >"$T/logs/last" 2>&1; sed 's/^/  /' "$T/logs/last"
        echo "-- streamer status"; "$T/streamer" status | sed 's/^/  /'
        echo "-- streamer audio, with no argument, reports the live block"
        "$T/streamer" audio | grep -v '^#' | grep -v '^$' | sed 's/^/  /'
        echo "-- streamer stations, from the list in STREAMER_STATION_LIST"
        "$T/streamer" stations >"$T/logs/stations" 2>&1; sed 's/^/  /' "$T/logs/stations"
        echo "-- streamer boots, the durable log"
        printf 'mode=last\nkind=url\ntarget=http://localhost/x.mp3\n' >"$T/data/streamer/state"
        if "$T/streamer-play" >/dev/null 2>&1; then rc=0; else rc=$?; fi
        ck_eq "the url start came up" "$rc" "0"
        "$T/streamer" boots >"$T/logs/boots" 2>&1; sed 's/^/  /' "$T/logs/boots"
        socket_off
        echo "-- streamer nonsense is refused, with the usage text"
        # set -e would abort the harness on a command meant to fail, so the
        # status is captured in the condition itself.
        if "$T/streamer" nonsense >"$T/logs/nonsense" 2>&1; then rc=0; else rc=$?; fi
        echo "  exit $rc, $(wc -l <"$T/logs/nonsense") lines, first: $(sed -n 1p "$T/logs/nonsense")"
        echo "-- seven events into a boot.log that keeps four"
        for i in 1 2 3 4 5 6 7; do "$T/streamer-bootlog" "line $i"; done
        echo "  lines kept: $(wc -l <"$T/data/streamer/boot.log")"
        ck_in "last reports the saved intent" "$T/logs/last" "Late Night"
        ck_eq "stations pairs each name with its stream, one per line" \
            "$(grep -c "	https://radio.cliamp.stream/.*/stream$" "$T/logs/stations")" "4"
        ck_in "and the pairing is the right way round" "$T/logs/stations" \
            "$(printf 'Chiptunes\thttps://radio.cliamp.stream/chiptune/stream')"
        ck_not "a tracks_url is never mistaken for a stream" "$T/logs/stations" "/tracks"
        ck_in "boots reads the durable log back" "$T/logs/boots" "OK url http://localhost/x.mp3"
        ck_eq "nonsense is refused with exit 2" "$rc" "2"
        ck_eq "the usage text is more than one line" "$([ "$(wc -l <"$T/logs/nonsense")" -gt 3 ] && echo yes)" "yes"
        ck_in "usage starts with the synopsis" "$T/logs/nonsense" "streamer [command]"
        ck_in "usage lists the audio switch" "$T/logs/nonsense" "streamer audio [jack|dac]"
        ck_eq "boot.log keeps the configured window" "$(wc -l <"$T/data/streamer/boot.log")" "4"
        # The timestamp is compared as a prefix, never as a whole line: the log
        # line and the expected value are stamped a moment apart, and an exact
        # second-for-second match turns the suite into a coin toss whenever the
        # boot.log writes straddle a second boundary (it went red on the
        # mutation tool's own final clean run for exactly that reason).
        ck_eq "every kept line is stamped with today, in UTC" \
            "$(cut -c1-20 "$T/data/streamer/boot.log" |
              grep -c "^$(date -u +%Y-%m-%dT)")" "4"
        ck_eq "the newest event is the one kept last" \
            "$(sed -n 4p "$T/data/streamer/boot.log" | cut -c22-)" "line 7"
        ck_in "and the oldest of the seven is gone" "$T/data/streamer/boot.log" "line 4"
        ck_not "the lines before it did not survive" "$T/data/streamer/boot.log" "line 3" ;;
    10) note "10. streamer audio jack|dac: only the marked block of config.txt moves"
        reset
        untouched_before=$(grep -vE 'audio|kms-v3d' "$T/fw/config.txt" | tr '\n' '|')
        echo "  start (a jack build): $(audio_lines)"
        echo "  markers in config.txt: $(count_markers)"
        "$T/streamer" audio dac
        echo "  after dac:  $(audio_lines)"
        after_dac=$(audio_lines)
        ck_in "dac switched in the DAC overlay" "$T/fw/config.txt" "dtoverlay=iqaudio-dacplus"
        ck_eq "dac took the analog output away" \
            "$(grep -cxF 'dtparam=audio=on' "$T/fw/config.txt")" "0"
        ck_eq "still exactly one begin/end pair after the switch" "$(count_markers)" "2"
        "$T/streamer" audio dac
        echo "  after dac again, unchanged: $(audio_lines)"
        ck_eq "switching to what it already was changed nothing" "$after_dac" "$(audio_lines)"
        ck_eq "and no markers were duplicated" "$(count_markers)" "2"
        "$T/streamer" audio jack
        echo "  back to jack: $(audio_lines)"
        ck_in "jack switched back to the analog output" "$T/fw/config.txt" "dtparam=audio=on"
        ck_eq "everything outside the marked block survived all three writes" \
            "$(grep -vE 'audio|kms-v3d' "$T/fw/config.txt" | tr '\n' '|')" "$untouched_before"
        ck_eq "the stock analog line stays commented" \
            "$(grep -c '^#dtparam=audio=on' "$T/fw/config.txt")" "1"
        ck_eq "each switch is one boot.log line" \
            "$(grep -c 'audio output set to' "$T/data/streamer/boot.log")" "3" ;;
    11) note "11. a saved level at or below the floor is treated as parked, not replayed"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'position=0\nindex=0\nvolume=-30\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s11a" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s11a"
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the parked -30 dB became the fallback" "$(jnum volume)" "-20"
        ck_in "and boot.log says so" "$T/data/streamer/boot.log" "saved volume -30 at the floor, using -20"
        printf 'position=0\nindex=0\nvolume=-99\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s11b" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s11b"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "a level below the floor became the fallback too" "$(jnum volume)" "-20"
        ck_in "and boot.log says so" "$T/data/streamer/boot.log" "saved volume -99 at the floor, using -20" ;;
    12) note "12. a saved row that no longer exists falls back to row 0, and still plays"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'position=412\nindex=99\nvolume=-9\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s12" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s12"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "something is playing" "$(jstr state)" "playing"
        ck_eq "row 0 after the refused row 99" "$(jnum index)" "0"
        ck_eq "the seconds from the vanished row are not replayed on row 0" \
            "$(jnum position)" "0"
        ck_in "boot.log records the refused jump" "$T/data/streamer/boot.log" "FAIL queue.play index=99"
        ck_in "boot.log still records the play" "$T/data/streamer/boot.log" "OK playlist Late Night" ;;
    13) note "13. the ramp never outlives the boot: a step budget, and a level that will not move"
        reset; socket_on
        # 13a. The player will not go past -12 dB: a hardware limit, standing in
        # for the PipeWire sink or the codec clamping below where cliamp thinks
        # the level is. Without a guard the loop would climb forever, and the
        # unit's start timeout is what would end it.
        printf -- '-12\n' >"$T/stuck-at"
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'position=0\nindex=0\nvolume=-9\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s13a" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s13a"; player
        ck_eq "the boot still ends cleanly" "$rc" "0"
        ck_eq "music is playing" "$(jstr state)" "playing"
        ck_eq "the level stopped where the device stopped it" "$(jnum volume)" "-12"
        ck_in "boot.log says where it got stuck" "$T/data/streamer/boot.log" "volume stuck at -12.0 dB, ramp stops"
        ck_in "boot.log still records the play" "$T/data/streamer/boot.log" "OK playlist Late Night"
        rm -f "$T/stuck-at"
        # 13b. Nothing refuses, and there is simply too much to climb: the
        # budget is what stops it, so the ramp cannot eat the boot budget.
        sed -i 's/^STREAMER_RAMP_MAX_STEPS=.*$/STREAMER_RAMP_MAX_STEPS=2/' "$T/streamer.conf"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'position=0\nindex=0\nvolume=-9\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s13b" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s13b"; player
        socket_off
        ck_eq "the boot still ends cleanly" "$rc" "0"
        ck_eq "two steps of 3 dB above the floor" "$(jnum volume)" "-24"
        ck_in "boot.log says the budget ran out" "$T/data/streamer/boot.log" "ramp budget of 2 steps exhausted at -24.0 dB"
        # The sandbox conf is written once for the whole run, so put the shipped
        # budget back: a two-step limit leaking into the scenarios after this one
        # makes them fail for a reason that has nothing to do with what they are
        # about.
        sed -i 's/^STREAMER_RAMP_MAX_STEPS=.*$/STREAMER_RAMP_MAX_STEPS=16/' "$T/streamer.conf" ;;
    14) note "14. volume moved elsewhere mid-ramp: the person wins, the ramp backs off"
        reset; socket_on
        # The boot is climbing from the floor toward the saved -9 dB, and a
        # moment after the music starts somebody reaches for the volume and
        # takes it down to -40. That is a jump of far more than one ramp step,
        # which is how the boot tells it apart from its own adjustment. The
        # mistake being guarded against is the boot deciding it knows better and
        # climbing straight back over a level someone has just set by hand.
        printf -- '-40\n' >"$T/set-elsewhere"
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'position=0\nindex=0\nvolume=-9\n' >"$T/data/streamer/progress"
        if "$T/streamer-play" >"$T/logs/s14" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s14"; player
        socket_off; rm -f "$T/set-elsewhere"
        ck_eq "the boot still ends cleanly" "$rc" "0"
        ck_eq "the level the person actually set is what plays" "$(jnum volume)" "-40"
        ck_eq "the ramp did not climb to the saved target" "$(jnum volume)" "-40"
        ck_eq "and it got there in a single step, not by arguing" "$(jnum adjustments)" "1"
        ck_in "boot.log says the level came from elsewhere" "$T/data/streamer/boot.log" "volume set elsewhere to -40.0 dB, ramp stops"
        ck_in "boot.log still records the play" "$T/data/streamer/boot.log" "OK playlist Late Night" ;;
    15) note "15. tool contract: every blockdev/sfdisk option the payload uses really exists"
        # A flag that *looks* obvious but does not exist survives every green
        # sandbox run, because no stub validates flags, and dies only on real
        # hardware. That is exactly how `blockdev --getstart` reached the first
        # real card: streamer-firstboot crashed before laying out /data, and
        # every unit with Requires=data.mount reported 'Dependency failed'.
        # The build host runs the same util-linux family as the card (2.41/2.42),
        # so blockdev --help and sfdisk --help here are the truth the scripts
        # have to match. (Verified on the card itself: sfdisk 2.41.5 rejects
        # `-u=S` with "unsupported unit '='" exactly like 2.42.4 here.)
        # Comments are excluded: the payload quotes the flags it does *not* use
        # to explain why, and a check that read those would trip on its own
        # documentation. Only command lines count.
        used=$(grep -hv '^[[:space:]]*#' "$CFG"/usr/local/bin/* |
            grep -hoE 'blockdev --[a-z]+' |
            sed 's/.*blockdev --//' | sort -u | tr '\n' ' ')
        missing=""
        for o in $used; do
            "$REAL_BLOCKDEV" --help 2>&1 | grep -qF -- "--$o" || missing="$missing --$o"
        done
        echo "  blockdev options used:$used"
        ck "blockdev --help is readable on this host (the check is not vacuous)" \
            "\"$REAL_BLOCKDEV\" --help >/dev/null 2>&1"
        ck "the payload really calls blockdev (the check is not vacuous)" \
            "[ -n \"$used\" ]"
        ck "every blockdev option used exists on a real util-linux" \
            "[ -z \"$missing\" ]"
        # And the one real start-sector source: sysfs, not a blockdev flag.
        ck_in "the firstboot start sector comes from sysfs" \
            "$CFG/usr/local/bin/streamer-firstboot" "/sys/class/block/"
        # sfdisk: -u is a deprecated no-op whose '=' parser kills both util-linux
        # versions we run, and there is no "extend to end of device" -N form any
        # more (it rc=0s leaving the old size), so the grow must be explicit
        # size= plus a hard read-back.
        sused=$(grep -hv '^[[:space:]]*#' "$CFG"/usr/local/bin/* |
            grep -hoE 'sfdisk -[a-zA-Z-]+( -[a-zA-Z=-]+)*' |
            sed 's/^sfdisk //' | tr ' ' '\n' | sed 's/=.*//' |
            grep '^-' | sort -u | tr '\n' ' ')
        smissing=""
        for o in $sused; do
            # The help spells short options as " -N, --partno", so match the
            # option followed by a comma or a space.
            "$REAL_SFDISK" --help 2>&1 | grep -qE -- "(^|[[:space:]])${o}[[:space:],]" ||
                smissing="$smissing $o"
        done
        echo "  sfdisk options used: $sused"
        ck "sfdisk --help is readable on this host (the check is not vacuous)" \
            "\"$REAL_SFDISK\" --help >/dev/null 2>&1"
        ck "the payload really calls sfdisk (the check is not vacuous)" \
            "[ -n \"$sused\" ]"
        ck "every sfdisk option used exists on a real sfdisk" \
            "[ -z \"$smissing\" ]"
        # Only the command lines matter: the script's own comments quote -u=S to
        # explain why it is gone, and a check on the whole file would trip on
        # that explanation forever.
        ck_not "no dead -u=S flag on an sfdisk command line" \
            "$CFG/usr/local/bin/streamer-firstboot" "sfdisk -q -f -u=S"
        # The old fallback ("start= only, means to the end of the device") is a
        # silent no-op on both versions: rc=0, size unchanged. So the only
        # defence is reading the size back and treating a shortfall as fatal.
        ck_in "a resize that reports OK but leaves the size alone stops the boot" \
            "$CFG/usr/local/bin/streamer-firstboot" "sfdisk said OK but"
        # The read-back has to come from the sectors, not the kernel: a busy
        # disk (root is p2 of the same card) refuses BLKRRPART, and sfdisk's own
        # source discards the answer to the reread after a write. sfdisk -d
        # opens the device read-only and parses the label off the sectors, so it
        # is the only source that tells the truth at that moment in the boot.
        # Checked against real output rather than a guess about its format: the
        # spacing between fields and the exact spelling of size= are both things
        # a parser gets wrong. sfdisk 2.42.4 spells the row as
        # "mmcblk0p3 : start=     6012928, size=     6278451, type=83".
        truncate -s 4G "$T/contract.img"
        ck_in "the read-back after a resize reads the table off the disk" \
            "$CFG/usr/local/bin/streamer-firstboot" "sfdisk -d"
        {
            printf 'label: dos\nlabel-id: 0x27b94958\n'
            printf 'start=16384,size=1048576,type=c\n'
            printf 'start=1064960,size=4947968,type=83\n'
            printf 'start=6012928,size=524288,type=83\n'
        } | "$REAL_SFDISK" -q "$T/contract.img" 2>/dev/null
        got=$("$REAL_SFDISK" -d "$T/contract.img" |
            awk -v pat="contract.img3 :" '$0 ~ pat {
                if (match($0, /size=[[:space:]]*[0-9]+/))
                    print substr($0, RSTART + 5, RLENGTH - 5) + 0 }')
        ck_eq "the awk that reads that dump really pulls 524288 out of real sfdisk output" \
            "$got" "524288"
        # The filesystem side of the script: dumpe2fs is what says how big the
        # ext4 is, and it is not in the build host's usual tool list, so it is
        # worth knowing the payload only asks it for the two fields it parses.
        ck_in "the filesystem size comes from dumpe2fs -h" \
            "$CFG/usr/local/bin/streamer-firstboot" "dumpe2fs -h"
        ck_not "dumpe2fs is never asked for the full dump (only -h is parsed)" \
            "$CFG/usr/local/bin/streamer-firstboot" "dumpe2fs \"\$DATA_DEV\""
        ck "dumpe2fs parses exactly the fields its output has" \
            "grep -q 'Block count' \"\$CFG/usr/local/bin/streamer-firstboot\" &&
             grep -q 'Block size' \"\$CFG/usr/local/bin/streamer-firstboot\""
        # A bare resize2fs means "grow to the partition": naming a size would
        # risk shrinking, which destroys a filesystem rather than fixing one.
        ck_in "resize2fs is asked to fill the partition, never a size" \
            "$CFG/usr/local/bin/streamer-firstboot" "resize2fs \"\$DATA_DEV\""
        # e2fsck -fy: forced, because a clean journal makes the tool skip the
        # check otherwise, and -y rather than the interactive prompt, since
        # there is no console on this box.
        ck_in "e2fsck runs forced and answered automatically" \
            "$CFG/usr/local/bin/streamer-firstboot" "e2fsck -fy"
        # The record that asks for the second boot has to be a fact both scripts
        # can see, or the two ends of the hand-off cannot meet.
        ck_in "firstboot records the geometry it asked for when it rewrites the table" \
            "$CFG/usr/local/bin/streamer-firstboot" "/etc/streamer/geometry-target"
        ck_in "bootcount is the one that compares it and asks for the extra boot" \
            "$CFG/usr/local/bin/streamer-bootcount" "/etc/streamer/geometry-target"
        # And it has to be a record rather than a request. Clearing a flag is
        # not an option here: the boot where the comparison first succeeds is
        # the boot after the table was written, and by then fstab has made the
        # root read-only, so removing a file in /etc early in that boot needs a
        # writable root at exactly the moment the box promised it would not
        # have one. That is how the marker design was wrong, and it was invisible
        # in the sandbox, where /etc is writable and nothing enforces fstab.
        ck_not "nothing tries to remove that record from the scripts" \
            "$CFG/usr/local/bin/streamer-firstboot" "rm -f /etc/streamer/geometry"
        ck_not "bootcount does not clear it either" \
            "$CFG/usr/local/bin/streamer-bootcount" "rm -f /etc/streamer/geometry"
        # The unit must not be gated on the provisioning marker any more: boot 2
        # is the boot that resizes the filesystem, and a marker written on boot
        # 1 would skip exactly that.
        ck_not "the firstboot unit is not gated on /etc/streamer/provisioned" \
            "$CFG/etc/systemd/system/streamer-firstboot.service" \
            "ConditionPathExists=!/etc/streamer/provisioned"
        # fstab is where /data's PARTUUID comes from (there is no data.mount
        # unit), so firstboot and fstab have to describe the same partition.
        ck_in "the build's fstab line mounts /data by PARTUUID" \
            "$BUILD" "PARTUUID=%s  /data  ext4"
        ck_in "firstboot finds that same partition by PARTUUID" \
            "$CFG/usr/local/bin/streamer-firstboot" "/dev/disk/by-partuuid" ;;
    16) note "16. first boot and provisioning: the two-stage growth of /data"
        # streamer-firstboot is the script with the most ways to go wrong, and
        # the three bugs that reached real hardware were all about sizes and
        # tools: a blockdev flag that does not exist, an sfdisk option that
        # kills the script, and a resize that reports OK while changing nothing.
        # The worst one is structural rather than a flag: laying out /data from
        # scratch on first boot, where a failure takes data.mount and every unit
        # behind it down with no writable root and no sudo left to repair it.
        # The stand-in card is the geometry this card really has, read over SSH:
        # mmcblk0 with 24522752 sectors, p3 starting at 6012928. The stand-in
        # models the one fact that makes this hard: after sfdisk writes a new
        # table, the kernel keeps the old geometry, because it refuses
        # BLKRRPART on a disk whose partitions are mounted - and root is p2 of
        # this same card. So the partition grows in one boot and the filesystem
        # catches up in the next.
        sandbox_data
        rm -f "$T/etc-streamer"/* "$T/sudoers.d"/* "$T/home/pi/.config/cliamp" \
              "$T/mount-root"
        cp "$FIX/fstab.orig" "$T/fstab"
        reset_geo
        # Boot A starts from a partition that has never been seeded: the probe
        # mount point is where the sandbox keeps the stand-in partition's own
        # contents between boots, so clearing it is the only way to say "this
        # filesystem has no appliance tree on it yet".
        rm -rf "$T/run/data"
        mkdir -p "$T/logs"
        if "$T/streamer-firstboot" >"$T/logs/f-a" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-a"
        ck_eq "the provisioning boot ends cleanly" "$rc" "0"
        ck_eq "the partition table was rewritten once" \
            "$(devcounter sfdisk_calls)" "1"
        ck_in "boot A grows the partition to the end of the card" \
            "$T/bin/devstate.sh" "on_disk=18509823"
        ck_eq "boot A resized nothing, because the kernel still sees the old size" \
            "$(devcounter resize_calls)" "0"
        ck_not "boot A did not claim to grow the filesystem" \
            "$T/logs/f-a" "growing the ext4 on"
        ck_in "boot A says a second boot is owed" "$T/logs/f-a" \
            "one more boot to grow the filesystem"
        # The record is the hand-off to streamer-bootcount, and it carries the
        # real numbers: a change in how they are derived shows up here instead
        # of on the card. It also names the node to measure, which is what lets
        # bootcount check the kernel's answer without guessing device names.
        ck_in "the record names the partition it changed" \
            "$T/etc-streamer/geometry-target" "part=3"
        ck_in "the record carries the start sector sysfs gave" \
            "$T/etc-streamer/geometry-target" "start=6012928"
        ck_in "the record carries the size the table now holds" \
            "$T/etc-streamer/geometry-target" "want=18509823"
        ck_in "the record says which node to measure, so bootcount needs no guessing" \
            "$T/etc-streamer/geometry-target" "dev=$T/dev/mmcblk0p3"
        # The shape matters as much as the values: bootcount reads the keys with
        # `sed -n 's/^key=//p'`, which swallows the rest of a single-line record
        # and would make the record useless without any check failing. Five keys,
        # five lines, is the contract between the two scripts.
        ck_eq "the record holds one key per line, as bootcount reads it" \
            "$(grep -c '^[a-z]*=' "$T/etc-streamer/geometry-target")" "5"
        # The seed pass is what makes the box usable over SSH afterwards: an
        # fstab that makes the root read-only, and a sudoers fragment that lets
        # `streamer audio dac` re-exec through sudo on a box with no password.
        # The real fstab is the fixture, boot partition first: a rewrite that
        # mistook /boot/firmware for / would take the wrong line read-only.
        ck_in "the root line gained ro" "$T/fstab" \
            "PARTUUID=27b94958-02  /               ext4    defaults,noatime,ro"
        ck_not "the boot partition stays writable" "$T/fstab" \
            "/boot/firmware  vfat    defaults,ro"
        ck_in "the /data line is untouched" "$T/fstab" \
            "PARTUUID=27b94958-03  /data  ext4  defaults,nofail,noatime  0  0"
        ck_in "the sudoers fragment gives pi password-free sudo" \
            "$T/sudoers.d/streamer" "pi ALL=(ALL) NOPASSWD:ALL"
        ck "the cliamp config link is in the daemon's home" \
            "[ -L '$T/home/pi/.config/cliamp' ]"
        ck_in "the marker for the flash date records the partition it is on" \
            "$T/etc-streamer/flash-info" "flashed="
        # Where the appliance's tree lands is the one thing about this script
        # that no amount of tool-contract checking can catch, because the sandbox
        # has no mounts: firstboot runs before data.mount, so /data is a plain
        # directory on the root, and seeding through it writes files that the
        # mount buries a second later. The box then looks set up in the boot that
        # set it up and comes back empty in every boot after it, with the
        # player's ConditionPathExists=/data/.ready keeping it silent forever.
        # So: four names on the mounted partition, none of them on the root's
        # /data directory. That is one check, and it fails if the seed goes to
        # the wrong place or does not happen at all.
        ck_eq "the tree is on the data partition, not on its mount point" \
            "$(for f in cliamp state bin music .ready; do
                   [ -e "$T/run/data/$f" ] && printf x
                   [ -e "$T/data/$f" ] && printf y
               done)" "xxxxx"
        ck_in "boot A reaches the partition through a mount point of its own" \
            "$T/logs/f-a" "[mount $T/dev/mmcblk0p3 $T/run/data]"
        ck_in "and lets go of it again, so data.mount can have it" \
            "$T/logs/f-a" "[umount $T/run/data]"
        # Boot B: the kernel has read the table the previous boot wrote, so the
        # partition finally looks big and the shipped ext4 has to catch up.
        sed -i 's/^k_size=.*/k_size=18509823/' "$T/bin/devstate.sh"
        if "$T/streamer-firstboot" >"$T/logs/f-b" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-b"
        ck_eq "the resize boot ends cleanly" "$rc" "0"
        ck_eq "the filesystem was checked before it was moved" \
            "$(devcounter fsck_calls)" "1"
        ck_eq "the filesystem was grown once" \
            "$(devcounter resize_calls)" "1"
        ck_in "the resize boot says how big /data became" "$T/logs/f-b" \
            "grown to 9037 MiB"
        # The record is a fact about the layout, not a request that gets
        # consumed, so it survives. What matters is that bootcount reads it and
        # finds nothing left to do about it, which the bootcount checks below
        # cover from the other side.
        ck_in "the geometry record survives the resize untouched" \
            "$T/etc-streamer/geometry-target" "want=18509823"
        ck_eq "the provisioning boot is the only one that made the root writable" \
            "$(grep -c '^rw$' "$T/mount-root" 2>/dev/null || echo 0)" "1"
        # Boot C: a mature system. The unit runs on every boot now, so it has to
        # find nothing to do, and it must not make the root writable while doing
        # so - that would quietly undo the read-only design, one boot at a time.
        if "$T/streamer-firstboot" >"$T/logs/f-c" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-c"
        ck_eq "a mature boot ends cleanly" "$rc" "0"
        ck_in "a mature boot says so" "$T/logs/f-c" "nothing left to do"
        ck_not "a mature boot leaves the root read-only" "$T/logs/f-c" \
            "remount,rw /"
        ck_eq "and the mount record agrees that nothing remounted it since" \
            "$(grep -c '^rw$' "$T/mount-root" 2>/dev/null || echo 0)" "1"
        ck_eq "a mature boot touched no tool that moves data" \
            "$(devcounter sfdisk_calls):$(devcounter resize_calls):$(devcounter mkfs_calls)" \
            "1:1:0"
        # A factory reset: p3 is reformatted (or wiped), and the card is booted
        # again. This is the case the /etc marker used to get wrong for good -
        # the marker was on the root, so it survived the wipe, firstboot decided
        # the work was done, /data stayed empty, and nothing but a reflash could
        # bring the player back. Wiping the stand-in partition's contents is how
        # the sandbox says the same thing.
        rm -rf "$T/run/data"
        if "$T/streamer-firstboot" >"$T/logs/f-w" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-w"
        ck_eq "a wiped data partition is set up again" "$rc" "0"
        ck_eq "and the tree is on it again, on the partition this time" \
            "$(for f in cliamp state bin music .ready; do
                   [ -e "$T/run/data/$f" ] && printf x
                   [ -e "$T/data/$f" ] && printf y
               done)" "xxxxx"
        ck "the cliamp socket's directory belongs to pi again" \
            "[ -d '$T/run/data/cliamp' ]"
        # The root is not involved in a factory reset: everything it would have
        # to write is already there, so the read-only promise holds through the
        # whole thing. This is the check the old design failed: the marker was
        # gone, so it wanted a writable root for a boot whose root had long
        # since been made read-only.
        ck_not "a reset boot never asks for a writable root" "$T/logs/f-w" \
            "remount,rw /"
        ck_eq "and the mount record agrees the root has stayed read-only since boot A" \
            "$(grep -c '^rw$' "$T/mount-root" 2>/dev/null || echo 0)" "1"
        ck_eq "a reset boot moves no partition and no filesystem" \
            "$(devcounter sfdisk_calls):$(devcounter resize_calls):$(devcounter mkfs_calls)" \
            "1:1:0"
        # A /data that comes back too corrupt to mount. This is the failure the
        # read-only design has no answer for on its own: /data's fstab entry has
        # `nofail` and pass 0, so nothing in the boot ever checks that volume,
        # and the player is gated on /data/.ready. A firstboot that stopped at a
        # failed mount would leave the box silent on every boot for the rest of
        # the card's life, with no root writable and nothing to repair it with.
        # This unit is the one moment the partition is idle, so it is the moment
        # the check belongs. The stand-in refuses the mount once and then takes
        # it, which is what a corrected filesystem does.
        rm -rf "$T/run/data"
        printf 'mount_fail_once=yes\n' >>"$T/bin/devstate.sh"
        fsck_before=$(devcounter fsck_calls)
        if "$T/streamer-firstboot" >"$T/logs/f-x" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-x"
        ck_eq "a mount that fails is recovered rather than given up on" "$rc" "0"
        ck_in "the boot says the volume is being checked" "$T/logs/f-x" \
            "checking it while nothing else holds it"
        ck_eq "the check ran, on the data partition" \
            "$(devcounter fsck_dev)" "$T/dev/mmcblk0p3"
        ck_eq "the check really ran once more than before" \
            "$(devcounter fsck_calls)" "$((fsck_before + 1))"
        ck_in "and the mount is attempted a second time" "$T/logs/f-x" \
            "mount $T/dev/mmcblk0p3 $T/run/data"
        ck_eq "the tree is on the partition even after a mount that was refused" \
            "$(for f in cliamp state bin music .ready; do
                   [ -e "$T/run/data/$f" ] && printf x
                   [ -e "$T/data/$f" ] && printf y
               done)" "xxxxx"
        ck_eq "the second mount is released again for data.mount" \
            "$(grep -c "^  \[umount $T/run/data\]" "$T/logs/f-x")" "1"
        # A volume that cannot be saved: the mount is refused again and this time
        # fsck reports 4 (uncorrectable). Stopping with a clear journal line is
        # right here, because carrying on would seed into a directory that is not
        # a filesystem at all, and the box would look set up while /data stayed
        # empty.
        printf 'mount_fail_once=yes\n' >>"$T/bin/devstate.sh"
        printf 'fsck_really_fails=yes\n' >>"$T/bin/devstate.sh"
        if "$T/streamer-firstboot" >"$T/logs/f-y" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-y"
        ck_eq "an unfixable data partition stops the boot" "$rc" "1"
        ck_in "and says what is wrong with it" "$T/logs/f-y" \
            "e2fsck on $T/dev/mmcblk0p3 reports 4"
        printf 'fsck_really_fails=no\n' >>"$T/bin/devstate.sh"
        # A card written from an older image: the partition entry is there but
        # nothing was ever laid out on it. Making a filesystem is the legacy
        # path, and it must only happen when there really is no filesystem -
        # mkfs on a mounted /data would erase someone's playlists.
        printf 'fs_present=no\n' >>"$T/bin/devstate.sh"
        if "$T/streamer-firstboot" >"$T/logs/f-d" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-d"
        ck_eq "a card with an unlaid-out partition still comes up" "$rc" "0"
        ck_eq "the missing filesystem is made" \
            "$(sed -n 's/^mkfs_calls=//p' "$T/bin/devstate.sh" | tail -1)" "1"
        ck_eq "a filesystem made on a partition the kernel already sees as big fills it at once" \
            "$(devcounter fs)" "18509823"
        # dumpe2fs reports the filesystem in its own blocks, and mkfs takes the
        # whole partition (the metadata lives inside those blocks), so the
        # blocks comparison finds nothing to do here: unlike the grown-table
        # case, the kernel already reports the big partition.
        ck_eq "and a filesystem made on an already-big partition needs no resize" \
            "$(devcounter resize_calls)" "1"
        printf 'fs_present=yes\n' >>"$T/bin/devstate.sh"
        # The same volume checked on the resize path, and this time it reports 1:
        # it found something wrong and fixed it. That is the ordinary outcome on
        # a card that lost power, and fsck's 1 is a pass, not a failure. It is
        # also the case that a `set -e` script gets wrong by writing
        # `e2fsck ...; ec=$?`, because the bare failing command ends the script
        # with fsck's status and no message at all - so the resize never happens,
        # the geometry record stays unsatisfied, and the boot counter takes the
        # box into a reboot loop it cannot think its way out of.
        cat >>"$T/bin/devstate.sh" <<'EOF'
k_size=18509823
on_disk=18509823
fs=524288
fsck_fixed=yes
EOF
        resize_before=$(devcounter resize_calls)
        if "$T/streamer-firstboot" >"$T/logs/f-z" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-z"
        ck_eq "a filesystem that fsck repaired still gets grown" "$rc" "0"
        ck_not "a repaired filesystem is not reported as a failure" "$T/logs/f-z" \
            "e2fsck on $T/dev/mmcblk0p3 reports"
        ck_eq "and the resize still runs" \
            "$(devcounter resize_calls)" "$((resize_before + 1))"
        printf 'fsck_fixed=no\n' >>"$T/bin/devstate.sh"
        # The failure mode that used to be a silent green run: sfdisk rc=0 with
        # the size unchanged. util-linux 2.41 answers `-N 3` with only a start=
        # exactly that way, so the table read back off the disk has to disagree
        # with the requested size for the boot to stop. This is the geometry of
        # a fresh image again, because that is the only state where a resize is
        # attempted at all.
        reset_geo
        printf 'sfdisk_lies=yes\n' >>"$T/bin/devstate.sh"
        if "$T/streamer-firstboot" >"$T/logs/f-e" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-e"
        ck_eq "a resize that quietly did nothing stops the boot" "$rc" "1"
        ck_in "and the boot says which tool lied about it" "$T/logs/f-e" \
            "sfdisk said OK but the table on"
        ck_not "a lie about the table never reaches the point of trusting it" \
            "$T/logs/f-e" "one more boot to grow the filesystem"
        # streamer-bootcount is the other half of the hand-off. It runs later in
        # the same boot, once the filesystems are mounted, which is the first
        # moment `systemctl reboot` is actually reachable.
        # The record it reads is the one streamer-firstboot wrote in boot A
        # above, not one invented here: the point of these checks is that the two
        # scripts agree on the file's shape and meaning, and a synthetic record
        # would hide a change to how it is written. So no reset here either -
        # boot A's record has to survive into these boots. The geometry is put
        # back to a freshly written image's, which is the state where the record
        # and the kernel disagree.
        reset_geo
        ck_in "boot A's record is still the one bootcount reads" \
            "$T/etc-streamer/geometry-target" "want=18509823"
        printf 'attempt=4\nconfig=%s\n' "$(fw_hash)" >"$T/data/streamer/attempt"
        if "$T/streamer-bootcount" >"$T/logs/f-g" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-g"
        ck_eq "the boot counter comes up" "$rc" "0"
        ck_in "a data partition still short of its record asks for one more boot" \
            "$T/logs/f-g" "systemctl --no-block reboot"
        ck_in "and records the sizes it compared in the log that outlives a power cut" \
            "$T/data/streamer/boot.log" "data partition is 524288 sectors, wants 18509823"
        ck_not "it does not also roll the boot config back in the same breath" \
            "$T/data/streamer/boot.log" "restoring last-good"
        # The settled case, and the reason the hand-off is a record rather than
        # a flag: the same record, a kernel that now agrees with it, and the
        # comparison simply stops being true. Nothing had to be cleared, which
        # is what makes it work on a boot whose root is read-only. The evidence
        # is the durable log, not the script's stdout: the reboot request only
        # ever exists as a boot.log line, because the stub systemctl is what the
        # sandbox sees and a real one would have taken the box away under it.
        sed -i 's/^k_size=.*/k_size=18509823/' "$T/bin/devstate.sh"
        printf 'attempt=4\nconfig=%s\n' "$(fw_hash)" >"$T/data/streamer/attempt"
        if "$T/streamer-bootcount" >"$T/logs/f-g2" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-g2"
        ck_eq "the boot where the kernel agrees ends cleanly" "$rc" "0"
        ck_eq "a kernel that agrees with the record asks for no second boot" \
            "$(grep -c 'booting once more' "$T/data/streamer/boot.log")" "1"
        ck_in "the record itself is untouched by a settled boot" \
            "$T/etc-streamer/geometry-target" "want=18509823"
        sed -i 's/^k_size=.*/k_size=524288/' "$T/bin/devstate.sh"
        # The same GIVEUP_AT ceiling as every other reboot this box takes: a
        # resize that never succeeds must not spin the card forever. The counter
        # is written outright: GIVEUP_AT is a fixed number in the shipped config,
        # and a scenario that walked there one boot at a time would break when
        # the shipped ceiling changed.
        printf 'attempt=5\nconfig=%s\n' "$(fw_hash)" >"$T/data/streamer/attempt"
        if "$T/streamer-bootcount" >"$T/logs/f-h" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/f-h"
        ck_in "the sixth boot stops asking" "$T/logs/f-h" "boot attempt 6"
        ck_not "the box never asks for a seventh boot" "$T/logs/f-h" \
            "systemctl --no-block reboot"
        ck_eq "and the durable log gained no further reboot request" \
            "$(grep -c 'booting once more' "$T/data/streamer/boot.log")" "1"
        ck_not "a boot that asks for geometry never also grows the filesystem" \
            "$T/logs/f-g" "growing the ext4"
        ck_in "the geometry record is still there at the end of it" \
            "$T/etc-streamer/geometry-target" "want=18509823" ;;
    *) echo "no scenario $1" >&2; return 2 ;;
    esac
    log_tail
}

echo "sandbox: $T"
if [ $# -gt 0 ]; then
    for n in "$@"; do run "$n"; done
else
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do run "$n"; done
fi

printf '\n%d checks, %d failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
