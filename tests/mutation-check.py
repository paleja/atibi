#!/usr/bin/env python3
"""Mutation check for tests/appliance-scripts.sh.

Each entry breaks one behaviour the appliance is supposed to guarantee, runs the
harness, and requires it to go red on the scenario that cares about that
behaviour. A suite that is always green proves nothing, so this is how the suite
itself gets checked. It is not a test of the appliance: run it by hand when the
harness or the scripts change.

    python3 tests/mutation-check.py

Only the file being mutated is held in memory and written back, so an
interrupted run cannot lose appliance code.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLAY = "config/usr/local/bin/streamer-play"
CTRL = "config/usr/local/bin/streamer"
BOOTCOUNT = "config/usr/local/bin/streamer-bootcount"

# what gets broken, which file, the anchor, the replacement, and the scenario
# title fragment that has to go red
MUTATIONS = [
    ("a parked volume is replayed verbatim", PLAY,
     r"""elif awk -v l="$level" -v f="$STREAMER_VOL_FLOOR" 'BEGIN{ exit (l+0 <= f+0) ? 0 : 1 }'; then""",
     "elif false; then",
     "at or below the floor"),

    ("the volume ceiling is dropped", PLAY,
     r"""'BEGIN{ if (l+0 < f+0) l=f+0; if (l+0 > h+0) l=h+0; printf "%g", l }')""",
     r"""'BEGIN{ if (l+0 < f+0) l=f+0; printf "%g", l }')""",
     "clamped to STREAMER_VOL_MAX"),

    ("url.load falls back to plain queueing", PLAY,
     r"""cliamp remote call url.load --params "{\"path\":\"$esc\",\"play\":true}" --wait""",
     'cliamp queue "$target"',
     "first boot"),

    ("the seconds from a refused row are replayed anyway", PLAY,
     "            saved_pos=0\n",
     "",
     "falls back to row 0"),

    ("the station list looks for a url key again", CTRL,
     r"""grep -o '"stream":"[^"]*"'""",
     r"""grep -o '"url":"[^"]*"'""",
     "the SSH-facing control"),

    ("the ramp has no step budget", PLAY,
     '[ "$steps" -ge "$STREAMER_RAMP_MAX_STEPS" ]',
     '[ 0 -ge "$STREAMER_RAMP_MAX_STEPS" ]',
     "step budget"),

    ("the ramp ignores a level that will not move", PLAY,
     """            'BEGIN{ d=a-n; if (d<0) d=-d; exit (d < 0.01) ? 0 : 1 }'; then""",
     """            'BEGIN{ exit 1 }'; then""",
     "step budget"),

    ("boot rollback never fires", BOOTCOUNT,
     r"""[ "$n" -ge "$RECOVERY_AT" ]""",
     r"""[ "$n" -ge 99 ]""",
     "rolls boot files back"),
]


def run_suite():
    """Returns (exit status, {scenario title: [failed check labels]})."""
    p = subprocess.run(["bash", "tests/appliance-scripts.sh"], cwd=str(ROOT),
                       capture_output=True, text=True, timeout=400)
    where, red = "", {}
    for ln in p.stdout.splitlines():
        if ln.startswith("=== "):
            where = ln[4:]
        elif ln.startswith("  FAIL "):
            red.setdefault(where, []).append(ln[7:])
    return p.returncode, red


def main():
    missed = 0
    for what, rel, old, new, scenario in MUTATIONS:
        path = ROOT / rel
        original = path.read_text()
        if old not in original:
            print("ANCHOR MISSING, not applied: %-46s" % what)
            missed += 1
            continue
        path.write_text(original.replace(old, new, 1))
        try:
            rc, red = run_suite()
        finally:
            path.write_text(original)
        hit = [s for s in red if scenario in s]
        total = sum(len(v) for v in red.values())
        if rc != 0 and hit:
            verdict = "caught"
        else:
            verdict, missed = "MISSED", missed + 1
        print("%-7s %-46s exit %d, %2d red, scenario: %s"
              % (verdict, what, rc, total, hit[0] if hit else "(none)"))

    rc, red = run_suite()
    print("%-7s %-46s %s" % ("clean" if rc == 0 else "DIRTY", "everything restored",
                             "all checks pass" if rc == 0 else str(red)))
    return 1 if missed or rc else 0


if __name__ == "__main__":
    sys.exit(main())
