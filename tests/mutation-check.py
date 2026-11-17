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

# what gets broken, which file, the anchor, the replacement, and the check label
# that has to go red
MUTATIONS = [
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


def main():
    recover()
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
              % (verdict, what, took, rc, total, hit[0] if hit else "(none)"))
        sys.stdout.flush()

    rc, red = run_suite()
    print("%-7s %-52s %s" % ("clean" if rc == 0 else "DIRTY", "everything restored",
                             "all checks pass" if rc == 0 else str(red)))
    return 1 if missed or rc else 0


if __name__ == "__main__":
    sys.exit(main())
