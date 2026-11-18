#!/usr/bin/env python3
"""Mutation check for tests/appliance-scripts.sh.

Each entry breaks one behaviour the appliance is supposed to guarantee, runs the
harness, and requires it to go red on the check that cares about that behaviour.
A suite that is always green proves nothing, so this is how the suite itself
gets checked. It is not a test of the appliance: run it by hand when the harness
or the scripts change.

    python3 tests/mutation-check.py

Two things make this safe to leave running unattended:

* The unmutated text of each file is held in memory and restored in a finally
  block, so a scenario that hangs cannot leave the appliance code broken.
* A journal under /tmp/opencode names the file being mutated before it is
  touched and the original text. If the process is killed hard enough to skip
  the finally block, the next run restores from the journal first and says so,
  rather than leaving a half-mutated tree behind.

Only the one file being mutated is ever written.
"""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JOURNAL = Path("/tmp/opencode/rpi-streamer-mutation.journal")
PLAY = "config/usr/local/bin/streamer-play"
CTRL = "config/usr/local/bin/streamer"
BOOTCOUNT = "config/usr/local/bin/streamer-bootcount"
FIRSTBOOT = "config/usr/local/bin/streamer-firstboot"
FIRSTBOOT_UNIT = "config/etc/systemd/system/streamer-firstboot.service"

# what gets broken, which file, the anchor, the replacement, and the check label
# that has to go red
MUTATIONS = [
    ("firstboot invents a blockdev flag again", FIRSTBOOT,
     'disk_sectors=$(blockdev --getsz "$DISK_DEV")',
     'disk_sectors=$(blockdev --getstart "$DISK_DEV")',
     "every blockdev option used exists on a real util-linux"),
    ("firstboot revives the dead -u=S sfdisk flag", FIRSTBOOT,
     'sfdisk -q -f -N "$PART" "$DISK_DEV"; then',
     'sfdisk -q -f -u=S -N "$PART" "$DISK_DEV"; then',
     "no dead -u=S flag on an sfdisk command line"),
    ("firstboot treats a no-op resize as a note again", FIRSTBOOT,
     '    if [ "$disk_size" != "$want" ]; then',
     "    if false; then",
     "a resize that quietly did nothing stops the boot"),

    # The read-back has to come off the sectors. The kernel keeps the old
    # geometry after a write to a busy disk, so asking it what just happened
    # reports the size from before the write and stops a boot that worked.
    ("firstboot reads the new size back from the kernel", FIRSTBOOT,
     """    disk_size=$(sfdisk -d "$DISK_DEV" |
        awk -v pat="${DISK}p$PART :" '$0 ~ pat {
            if (match($0, /size=[[:space:]]*[0-9]+/))
                print substr($0, RSTART + 5, RLENGTH - 5) + 0 }')""",
     '    disk_size=$(blockdev --getsz "$DATA_DEV")',
     "the provisioning boot ends cleanly"),

    # The blocks comparison is what stops the unit doing an e2fsck and a
    # resize2fs on every single boot: a partition is 512-byte sectors and an
    # ext4 is 4096-byte blocks, and the slack of an odd sector count can never
    # be filled. Comparing bytes looks equivalent and never settles.
    ("filesystem size is compared in bytes, not blocks", FIRSTBOOT,
     '    if [ "$fs_blocks" -lt "$part_blocks" ]; then',
     '    if [ "$((fs_blocks * fs_bsize))" -lt "$(( $(blockdev --getsz "$DATA_DEV") * 512 ))" ]; then',
     "a mature boot touched no tool that moves data"),

    # Two halves of the same hand-off: firstboot records the geometry it asked
    # for, bootcount measures the kernel against that record and asks for the
    # extra boot. Losing either end leaves a card sitting on a 256 MiB /data
    # forever, and a record whose keys are not one per line is read as garbage.
    ("firstboot writes the geometry record on one line", FIRSTBOOT,
     """    {
        printf 'dev=%s\\n'    "$DATA_DEV"
        printf 'disk=%s\\n'   "$DISK"
        printf 'part=%s\\n'   "$PART"
        printf 'start=%s\\n'  "$part_start"
        printf 'want=%s\\n'   "$want"
    } > /etc/streamer/geometry-target""",
     """    printf 'dev=%s disk=%s part=%s start=%s want=%s\\n' \\
        "$DATA_DEV" "$DISK" "$PART" "$part_start" "$want" \\
        > /etc/streamer/geometry-target""",
     "a data partition still short of its record asks for one more boot"),
    ("bootcount ignores the geometry record", BOOTCOUNT,
     "if [ -f /etc/streamer/geometry-target ]; then",
     "if false; then",
     "a data partition still short of its record asks for one more boot"),
    ("bootcount trusts the record even when the kernel agrees", BOOTCOUNT,
     'if [ -n "$geo_now" ] && [ "$geo_now" -lt "$geo_want" ]; then',
     'if [ -n "$geo_now" ]; then',
     "asks for no second boot"),
    ("firstboot never records the geometry it asked for", FIRSTBOOT,
     """if [ "$grew" = 1 ]; then
    # mkdir -p on an existing directory succeeds even on a read-only root""",
     """if false; then
    # mkdir -p on an existing directory succeeds even on a read-only root""",
     "boot A says a second boot is owed"),
    ("the hand-off is a flag in /etc that a later boot must clear", FIRSTBOOT,
     """if [ "$grew" = 1 ]; then
    # mkdir -p on an existing directory succeeds even on a read-only root""",
     """if [ "$grew" = 1 ]; then
    rm -f /etc/streamer/geometry-target
    # mkdir -p on an existing directory succeeds even on a read-only root""",
     "nothing tries to remove that record from the scripts"),
    ("firstboot remounts the root writable on every boot", FIRSTBOOT,
     'if [ "$root_dirty" = 1 ]; then\n    # The kernel command line mounts the root read-only',
     'if true; then\n    # The kernel command line mounts the root read-only',
     "the provisioning boot is the only one that made the root writable"),
    ("firstboot decides the tree is there without looking at the partition",
     FIRSTBOOT,
     '[ -f "$DATA_MNT/.ready" ] && seeded=1',
     "seeded=1",
     "the tree is on the data partition, not on its mount point"),
    ("firstboot seeds through the /data mount point, which the mount buries",
     FIRSTBOOT,
     """    for d in cliamp state bin music; do
        mkdir -p "$DATA_MNT/$d"
    done""",
     """    for d in /data/cliamp /data/state /data/bin /data/music; do
        mkdir -p "$d"
    done
    mkdir -p "$DATA_MNT\"""",
     "the tree is on the data partition, not on its mount point"),
    ("the firstboot unit is gated on provisioning again", FIRSTBOOT_UNIT,
     "DefaultDependencies=no",
     "DefaultDependencies=no\nConditionPathExists=!/etc/streamer/provisioned",
     "the firstboot unit is not gated on /etc/streamer/provisioned"),

    # fsck's exit status is a protocol (0 clean, 1 fixed something, 2+ needs a
    # human), and reading it wrongly goes two ways: treating a repair as a
    # failure, which under `set -e` happens just by writing `cmd; var=$?`, and
    # treating something unfixable as merely untidy.
    ("firstboot aborts when fsck has repaired the data volume", FIRSTBOOT,
     '        ec=0; e2fsck -fy "$DATA_DEV" >/dev/null || ec=$?',
     '        e2fsck -fy "$DATA_DEV" >/dev/null; ec=$?',
     "a filesystem that fsck repaired still gets grown"),
    ("a data volume that will not mount is never checked", FIRSTBOOT,
     """    echo "mounting $DATA_DEV failed: checking it while nothing else holds it" >&2
    ec=0; e2fsck -fy "$DATA_DEV" >/dev/null || ec=$?""",
     """    echo "mounting $DATA_DEV failed: checking it while nothing else holds it" >&2
    ec=0""",
     "the check really ran once more than before"),
    ("a data volume fsck could not fix is mounted anyway", FIRSTBOOT,
     """    [ "$ec" -le 1 ] || { echo "e2fsck on $DATA_DEV reports $ec" >&2; exit 1; }
    mount "$DATA_DEV" "$DATA_MNT" ||""",
     """    [ "$ec" -le 9 ] || { echo "e2fsck on $DATA_DEV reports $ec" >&2; exit 1; }
    mount "$DATA_DEV" "$DATA_MNT" ||""",
     "an unfixable data partition stops the boot"),

    ("a parked volume is replayed verbatim", PLAY,
     r"""elif awk -v l="$level" -v f="$STREAMER_VOL_FLOOR" 'BEGIN{ exit (l+0 <= f+0) ? 0 : 1 }'; then""",
     "elif false; then",
     "the parked -30 dB became the fallback"),

    ("the volume ceiling is dropped", PLAY,
     r"""'BEGIN{ if (l+0 < f+0) l=f+0; if (l+0 > h+0) l=h+0; printf "%g", l }')""",
     r"""'BEGIN{ if (l+0 < f+0) l=f+0; printf "%g", l }')""",
     "the ceiling held"),

    ("url.load falls back to plain queueing", PLAY,
     r"""cliamp remote call url.load --params "{\"path\":\"$esc\",\"play\":true}" --wait""",
     'cliamp queue "$target"',
     "that row is the one playing, not row 0"),

    ("the seconds from a refused row are replayed anyway", PLAY,
     "            saved_pos=0\n",
     "",
     "the seconds from the vanished row are not replayed on row 0"),

    ("the station list looks for a url key again", CTRL,
     r"""grep -o '"stream":"[^"]*"'""",
     r"""grep -o '"url":"[^"]*"'""",
     "stations pairs each name with its stream"),

    ("the ramp has no step budget", PLAY,
     '[ "$steps" -ge "$STREAMER_RAMP_MAX_STEPS" ]',
     '[ 0 -ge "$STREAMER_RAMP_MAX_STEPS" ]',
     "two steps of 3 dB above the floor"),

    ("the ramp ignores a level that will not move", PLAY,
     """            'BEGIN{ d=a-n; if (d<0) d=-d; exit (d < 0.01) ? 0 : 1 }'; then""",
     """            'BEGIN{ exit 1 }'; then""",
     "boot.log says where it got stuck"),

    ("the ramp argues with a volume set elsewhere", PLAY,
     """            'BEGIN{ d=a-e; if (d<0) d=-d; print (d > s+0.02) ? 1 : 0 }')""",
     """            'BEGIN{ print 0 }')""",
     "the level the person actually set is what plays"),

    ("the boot never sets the floor before it makes a sound", PLAY,
     'if ! cliamp volume "$STREAMER_VOL_FLOOR"; then',
     "if true; then",
     "the boot floor is set on the player"),

    ("boot rollback never fires", BOOTCOUNT,
     r"""[ "$n" -ge "$RECOVERY_AT" ]""",
     r"""[ "$n" -ge 99 ]""",
     "restored the DAC fragment"),
]


def run_suite(timeout=90):
    """Returns (exit status, {scenario title: [failed check labels]}).

    The suite gets its own process group so a mutated script that loops can be
    killed outright; a leftover child holding the output pipes open is what
    turns a broken check into a hung run.
    """
    p = subprocess.Popen(["bash", "tests/appliance-scripts.sh"], cwd=str(ROOT),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        out, err = p.communicate()
        return 124, {"(timed out after %ds)" % timeout: ["still running"]}
    where, red = "", {}
    for ln in out.splitlines():
        if ln.startswith("=== "):
            where = ln[4:]
        elif ln.startswith("  FAIL "):
            red.setdefault(where, []).append(ln[7:])
    return p.returncode, red


def recover():
    """Undo a mutation left behind by a previous run that was killed hard."""
    if not JOURNAL.exists():
        return
    rel, _, text = JOURNAL.read_text().split("\n", 2)
    (ROOT / rel).write_text(text)
    JOURNAL.unlink()
    print("restored %s from the previous run's journal" % rel)
    sys.stdout.flush()


def preflight():
    """Every mutation has to point at exactly one place. Worth checking before
    anything is broken, because two failure modes look like something else:

      - an anchor that occurs twice gets replaced at its first occurrence, so the
        mutation quietly tests a different line and may still be reported as
        caught, for the wrong reason;
      - an anchor that occurs nowhere is a mutation that changes nothing, which
        reads as a gap in the suite rather than as a typo in this file.

    The match is a substring test, which is how this bites: an anchor that starts
    with four spaces also matches the same line with eight of them. And a label
    that no check carries means a caught result is impossible by construction, so
    both are reported here.
    """
    suite = (ROOT / "tests/appliance-scripts.sh").read_text()
    problems = 0
    for what, rel, old, new, must_notice in MUTATIONS:
        path = ROOT / rel
        if not path.is_file():
            print("preflight: %s: no such file %s" % (what, rel), file=sys.stderr)
            problems += 1
            continue
        n = path.read_text().count(old)
        if n != 1:
            print("preflight: %s: anchor found %d times in %s"
                  % (what, n, rel), file=sys.stderr)
            problems += 1
        if must_notice not in suite:
            print("preflight: %s: no check is labelled %r"
                  % (what, must_notice), file=sys.stderr)
            problems += 1
    return problems


def main():
    recover()
    bad = preflight()
    if bad:
        print("%d mutation definition(s) need fixing; nothing was broken" % bad)
        return 2
    missed = 0
    for what, rel, old, new, must_notice in MUTATIONS:
        path = ROOT / rel
        original = path.read_text()
        if old not in original:
            print("ANCHOR MISSING, not applied: %-46s" % what)
            missed += 1
            continue
        JOURNAL.write_text(rel + "\n" + original)
        path.write_text(original.replace(old, new, 1))
        began = time.time()
        try:
            rc, red = run_suite()
        finally:
            path.write_text(original)
            JOURNAL.unlink()
        took = time.time() - began
        # red is {scenario title: [failed check labels]}, and it is the label
        # that has to go red: a mutation that breaks something else is not this
        # suite noticing the thing it is supposed to notice.
        hit = [lab for labs in red.values() for lab in labs if must_notice in lab]
        total = sum(len(v) for v in red.values())
        if rc == 124:
            # The suite never finished. For these mutations that is the failure
            # mode: an unbounded loop in the boot script, which is what the
            # guard being mutated exists to prevent.
            verdict, hit = "caught (hung)", ["(the suite hung on this mutation)"]
        elif rc != 0 and hit:
            verdict = "caught"
        else:
            verdict, missed = "MISSED", missed + 1
        print("%-7s %-52s %5.1fs exit %3d, %2d red, check: %s"
              % (verdict, what, took, rc, total,
                 hit[0] if hit else
                 # A suite that went red somewhere else is worth naming: it is
                 # usually a sign the label being looked for has drifted, or that
                 # the mutation broke the boot in a way nobody expected.
                 ("(none); red: " + "; ".join(lab for labs in red.values()
                                              for lab in labs[:2]) if total
                 else "(none)")))
        sys.stdout.flush()

    rc, red = run_suite()
    print("%-7s %-52s %s" % ("clean" if rc == 0 else "DIRTY", "everything restored",
                             "all checks pass" if rc == 0 else str(red)))
    return 1 if missed or rc else 0


if __name__ == "__main__":
    sys.exit(main())
