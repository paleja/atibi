#!/usr/bin/env python3
"""Mutation check for tests/appliance-scripts.sh.

Each entry breaks one behaviour the appliance is supposed to guarantee, runs the
harness, and requires it to go red on the check that cares about that behaviour.
A suite that is always green proves nothing, so this is how the suite itself
gets checked. It is not a test of the appliance: run it by hand when the harness
or the scripts change.

    python3 tests/mutation-check.py

Two things make this safe to leave running unattended:

* The unmutated text of every file the run can touch is read once, before the
  first mutation, and the restore in the finally block writes that text back. It
  is not re-read from disk for each mutation: a baseline read from disk would be
  whatever the last iteration left behind, so damage from a hard-killed run would
  quietly become the truth and the next run would restore the damage instead of
  undoing it. That happened once: a payload script lost its #! line and stayed
  lost, which is the exact defect the packaging scenario exists to catch.
* On the way out, the tree is compared with that baseline twice more: once for a
  mutation that escaped its own restore, once for a scenario that turns out to
  write into the code it is meant to only read. Either is repaired and reported,
  and the run fails, because a clean verdict over a changed tree is worth
  nothing.
* A journal under /tmp/opencode names the file being mutated, the mutation
  applied to it, and its original text. If the process is killed hard enough to
  skip the finally block, the next run restores from the journal first and says
  so, rather than leaving a half-mutated tree behind. It restores only when the
  file on disk still holds exactly what that mutation would have written: a
  journal from a run that died in an earlier session is not permission to
  overwrite work done since, and an unmatched one is discarded with a warning.

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
BOOTLOG = "config/usr/local/bin/streamer-bootlog"
HTTP = "config/usr/local/bin/streamer-http"
META = "tests/mutation-check.py"
BUILD = "image/build.sh"
FSTAB_AWK = "image/fstab-ro.awk"

# what gets broken, which file, the anchor, the replacement, and the check label
# that has to go red
MUTATIONS = [
    # The image recipe. Nothing in the sandbox runs a disk tool: the suite reads
    # build.sh and runs the recipe itself, so these mutations are how we find out
    # whether that reading is worth anything. Each one is a flag or a tool that
    # looked obvious and was wrong, which is how the first real card ended up
    # booting with no /data at all.
    ("the build invents a blockdev flag again", BUILD,
     'back=$(sfdisk -d "$IMG" | grep \' : start=\')',
     'back=$(blockdev --getstart "${LOOP}p3"; sfdisk -d "$IMG" | grep \' : start=\')',
     "no blockdev --getstart in the build recipe"),
    ("the build stops reading the partition table back", BUILD,
     'back=$(sfdisk -d "$IMG" | grep \' : start=\')',
     'back=',
     "the build reads the partition table back after writing it"),
    ("the build lets mkfs choose the block size", BUILD,
     'mkfs.ext4 -q -F -b 4096',
     'mkfs.ext4 -q -F',
     "the command the build runs asks for 4096-byte blocks"),
    ("the build patches the spliced volume through debugfs", BUILD,
     "debugfs -R 'ls -l /'",
     "debugfs -w -R 'ls -l /'",
     "the build never writes through debugfs"),

    # streamer, the command a person types over SSH. What is worth breaking here
    # is the damage it can do: the data partition, and the read-only root.
    ("reset wipes without being asked twice", CTRL,
     'if [ "${1:-}" != --yes ]; then',
     "if false; then",
     "without --yes it refuses, exit 2"),
    ("reset clears the data partition with a shell glob", CTRL,
     'find "$STREAMER_DATA" -mindepth 1 -maxdepth 1 -exec rm -rf {} +',
     'rm -rf "$STREAMER_DATA"/*',
     "and so is the dotfile, which is why this does not use a glob"),
    ("reset wipes under a player that is still running", CTRL,
     "systemctl stop streamer-play.service streamer-cliamp.service",
     "true",
     "the player is stopped first, then both units come back"),
    ("streamer ro leaves the root writable", CTRL,
     "        mount -o remount,ro /\n",
     "        mount -o remount,rw /\n",
     "streamer rw then ro leaves the root read-only, in that order"),
    # The durable boot log is the only record of a boot that survives a hard
    # power cut, because the journal on this appliance is deliberately volatile.
    ("the boot log is never trimmed", BOOTLOG,
     'if [ "$lines" -gt "$STREAMER_BOOTLOG_KEEP" ]; then',
     "if false; then",
     "boot.log keeps the configured window"),


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

    ("the provider list is fetched as a local playlist", PLAY,
     'if ! cliamp remote call provider.load \\\n             --params "{\\"provider\\":\\"$esc_p\\",\\"playlist\\":\\"$esc_t\\"}" --wait; then',
     'if ! cliamp load "$target"; then',
     "the boot asked the player for the provider playlist"),

    ("the boot starts a row provider.load already started", PLAY,
     'if [ "$(jstr "$(status)" state)" != playing ]; then',
     "if true; then",
     "provider.load started it, so the boot did not start it again"),

    ("the boot reads a provider playlist as an unknown kind", PLAY,
     "    provider)\n",
     "    provider-not-implemented)\n",
     "it does not pretend the target was unknown"),

    ("a provider boot skips the network wait because a bare playlist id has no host in it", PLAY,
     'if [ -n "$host" ] || [ "$kind" = provider ]; then',
     'if [ -n "$host" ]; then',
     "FAIL no network route for provider pl-42"),

    ("a provider boot probes for the provider by name, which the target never names", PLAY,
     "        ip route get 1.1.1.1 >/dev/null 2>&1\n",
     '        getent hosts "$target" >/dev/null 2>&1\n',
     "a lease that arrives late does not fail the boot"),

    ("the network budget for a provider boot is divided by four", PLAY,
     '        [ "$i" -gt "$((STREAMER_NET_WAIT * 4))" ] && {',
     '        [ "$i" -gt "$STREAMER_NET_WAIT" ] && {',
     "inside the seconds it was given, not one more"),

    ("the status reader insists on no space after the colon again", PLAY,
     'sed -n "s/.*\\"$2\\": *\\(-\\{0,1\\}[0-9][0-9.]*\\).*/\\1/p" | tail -n 1',
     'sed -n "s/.*\\"$2\\":\\(-\\{0,1\\}[0-9][0-9.]*\\).*/\\1/p" | tail -n 1',
     "boot.log says the level came from elsewhere"),

    ("the station list looks for a url key again", CTRL,
     r"""grep -o '"stream":"[^"]*"'""",
     r"""grep -o '"url":"[^"]*"'""",
     "stations pairs each name with its stream"),

    # Saving on change: the level and the target are written by the streamer
    # command when a person changes them, and each write carries on what the
    # previous one recorded. Without that, turning the volume down would forget
    # the station, and the two guards in the ramp would have no level to guard.
    ("a volume change is played but never written down", CTRL,
     '        save_level\n        ;;\n    up|down)',
     '        ;;\n    up|down)',
     "the change is written down at once"),

    ("a step up or down is played but never written down", CTRL,
     'cliamp remote call volume.adjust --params "{\\"value\\":$sign$n}" --wait >/dev/null\n        save_level\n',
     'cliamp remote call volume.adjust --params "{\\"value\\":$sign$n}" --wait >/dev/null\n',
     "a step up or down is remembered the same way"),

    ("the level is read back with a pattern that fits nothing the real player prints", CTRL,
     'sed -n "s/.*\\"$2\\": *\\(-\\{0,1\\}[0-9][0-9.]*\\).*/\\1/p" | tail -n 1',
     'sed -n "s/.*\\"$2\\":\\(-\\{0,1\\}[0-9][0-9.]*\\).*/\\1/p" | tail -n 1',
     "the change is written down at once"),

    ("recording a new playlist drops the level that was saved with it", CTRL,
     '        [ -n "$cur_vol" ] && printf \'volume=%s\\n\' "$cur_vol"\n',
     "",
     "the level survives the rewrite"),

    ("recording a provider playlist drops the provider it belongs to", CTRL,
     '        [ -n "$provider" ] && printf \'provider=%s\\n\' "$provider"\n',
     "",
     "on that provider"),

    ("remembering the next boot also restarts what is playing now", CTRL,
     '            playlist)\n                playlist_target "${2:?usage: streamer remember playlist <name>}"\n                save_state last "$pl_kind" "$pl_name" "$pl_provider"\n                ;;\n',
     '            playlist)\n                playlist_target "${2:?usage: streamer remember playlist <name>}"\n                save_state last "$pl_kind" "$pl_name" "$pl_provider"\n                systemctl restart streamer-play.service\n                ;;\n',
     "and recording it did not restart the player"),

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
    ("the boot hands an https target to TLS with the clock still wrong", PLAY,
     'while [ ! -f "$sync_flag" ]; do',
     "while false; do",
     "the warning says the clock is what was missing"),

    # The LAN control server: its guarantees are the token, the scheme guards
    # around anything that reaches the player or the boot intent, and the fact
    # that the intent file is only ever written by the streamer command.
    ("the LAN server lets anyone on the network drive it", HTTP,
     """    def check_token(self, candidate):
        return bool(candidate) and hmac.compare_digest(""",
     """    def check_token(self, candidate):
        return True or hmac.compare_digest(""",
     "no token: the API says no"),
    ("the token is left readable by everyone on the card", HTTP,
     "os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)",
     "os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)",
     "the token file is readable only by its owner"),
    ("the station guard lets any string become next boot's target", HTTP,
     'if not target.startswith(("http://", "https://")):',
     "if False:",
     "a non-http station target is refused before anything is written"),
    ("the url.load guard stops checking the scheme", HTTP,
     'if not url.startswith(("http://", "https://")):',
     "if False:",
     "a non-http url.load is refused too"),
    ("the intent route skips the sanctioned writer", HTTP,
     'out = run_streamer("station", target)',
     'out = ""',
     "the intent file says the new station plays next boot"),
    ("the page sets the level on the player only, so the next boot does not know it", HTTP,
     'self._json_out({"ok": True, "streamer": run_streamer("vol", repr(db))})',
     'self._json_out(self._op("volume", {"value": db}))',
     "and it is the level the next boot will start at"),
    ("a playlist tapped on the phone plays once and is never remembered", HTTP,
     'self._json_out({"ok": True,\n                            "streamer": run_streamer("remember", "playlist",\n                                                     "%s:%s" % (provider, pid))})',
     'self._json_out({"ok": True})',
     "that tap is what the next boot will load, as a provider target"),
    ("the submit envelope nests its operation inside params, as the fixture "
     "used to allow and the real player never did", HTTP,
     'reply = ipc("operation.submit", params, id_hint="h",\n'
     '                envelope={"operation": operation})',
     'reply = ipc("operation.submit",\n'
     '                {"operation": operation, "params": params or {}}, id_hint="h")',
     "the provider list names Tidal"),
    ("job.get looks for its id inside params, where the real player says it "
     "is not", HTTP,
     'reply = ipc("job.get", id_hint=hint_base + ".j%d" % tries,\n'
     '                    envelope={"job_id": job["id"]})',
     'reply = ipc("job.get", {"job_id": job["id"]},\n'
     '                    id_hint=hint_base + ".j%d" % tries)',
     "Tidal's playlists list over the API"),
    ("the job poller stops waiting between checks, as it did when the 0.5 s "
     "budget was only a comment", HTTP,
     'time.sleep(0.5)  # the comment about 0.5 s per try only means\n'
     '                             # something if the loop actually waits',
     "pass",
     "the job poller waits between checks instead of giving up at once"),
    ("the build stops checking payload interpreters against the base image", BUILD,
     'die "$(basename "$script") runs python3, which this base image does not ship: "',
     'log "$(basename "$script") is probably fine"',
     "the build cross-checks every unit's interpreter against the base image"),

    # fstab-ro.awk is the one program the build runs against a file whose whole
    # job is to keep the root read-only, which is the thing that makes pulling
    # the power out safe. The expected output is written by hand, so a mutation
    # here is a bug in a program, not a change of mind about a design.
    ("the fstab editor leaves the root writable", FSTAB_AWK,
     'if ($4 !~ /(^|,)ro(,|$)/) $0 = addro($0, $4)',
     "if (0) { }",
     "it makes the root and the firmware partition read-only and touches nothing else"),
    ("the fstab editor rebuilds the line from its fields", FSTAB_AWK,
     'return substr(line, 1, at + length(opts) - 1) ",ro" substr(line, at + length(opts))',
     'return $1 " " $2 " " $3 " " $4 ",ro" " " $5 " " $6',
     "it makes the root and the firmware partition read-only and touches nothing else"),
    ("the fstab editor makes the data partition read-only too", FSTAB_AWK,
     '$2 == "/" || $2 == "/boot/firmware"',
     '$2 == "/" || $2 == "/boot/firmware" || $2 == "/data"',
     "and the data partition, which is meant to be written, stays writable"),

    # The tool that breaks things on purpose is also a program that writes into
    # this repository, and scenario 18 checks its two guards. The journal is the
    # one that can cost work: it holds the text a payload had when a sweep was
    # killed, and applying it without looking writes that older text over
    # whatever the file holds now.
    ("a killed run's journal is applied whatever the file looks like now", META,
     "    current = path.read_text() if path.is_file() else None\n"
     "    if entry is not None and current == original.replace(entry[2], entry[3], 1):",
     "    current = path.read_text() if path.is_file() else None\n"
     "    if entry is not None and current is not None:",
     "a journal from an older run cannot overwrite the file as it is now"),

    ("the anchor pass stops counting how many places a mutation points at", META,
     "        n = path.read_text().count(old)\n        if n != 1:",
     "        n = path.read_text().count(old)\n        if n == 0:",
     "every mutation names one line of a payload, and a check owns its label"),

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
    """Undo a mutation left behind by a previous run that was killed hard.

    The journal records one file's text at one moment, so it has to be matched
    against the file before it is used. A run killed hard enough to skip the
    finally block leaves one in /tmp, and work may be done to that file
    afterwards: restoring the journal then quietly reverts that work, which is
    what happened once, with a payload script losing a whole feature with no
    message. So the journal is applied only when the file still holds exactly
    what that run would have written; anything else means the journal is stale,
    and the file wins.
    """
    if not JOURNAL.exists():
        return
    rel, what, original = JOURNAL.read_text().split("\n", 2)
    path = ROOT / rel
    entry = next((m for m in MUTATIONS if m[0] == what), None)
    current = path.read_text() if path.is_file() else None
    if entry is not None and current == original.replace(entry[2], entry[3], 1):
        path.write_text(original)
        print("restored %s from the previous run's journal" % rel)
    else:
        print("left %s alone: the journal from a killed run describes a mutation "
              "that is not in the file, so it was discarded rather than applied"
              % rel, file=sys.stderr)
    JOURNAL.unlink()
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
    # Every file this run can touch, read once, before anything is broken. The
    # restore below writes exactly this text. Reading the file again for each
    # mutation would make the baseline whatever the last iteration left behind: a
    # mutation that escaped its own restore (a hard-killed run, a scenario that
    # wrote somewhere it should not have) would then quietly become the truth,
    # and the next run would restore the damage instead of undoing it. That is
    # not hypothetical: one run ended with a payload script missing its #! line,
    # which is the exact defect the packaging scenario exists to catch.
    clean = {}
    for _, rel, _, _, _ in MUTATIONS:
        if rel not in clean:
            clean[rel] = (ROOT / rel).read_text()
    missed = 0
    for what, rel, old, new, must_notice in MUTATIONS:
        path = ROOT / rel
        original = clean[rel]
        if old not in original:
            print("ANCHOR MISSING, not applied: %-46s" % what)
            missed += 1
            continue
        JOURNAL.write_text(rel + "\n" + what + "\n" + original)
        path.write_text(original.replace(old, new, 1))
        began = time.time()
        try:
            rc, red = run_suite()
        finally:
            path.write_text(original)
            JOURNAL.unlink()
            if path.read_text() != original:
                print("INTEGRITY: %s is not what it was after mutating it for %r"
                      % (rel, what), file=sys.stderr)
                sys.exit(1)
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

    # Two integrity sweeps around the last run: one for a mutation that escaped
    # its restore, one for a suite that turns out to write into the payload it is
    # supposed to only read. Both fix the tree on the way out and make the run
    # fail, because a passing verdict over a changed tree is worth nothing.
    def untouched(when):
        left = [rel for rel, text in sorted(clean.items())
                if (ROOT / rel).read_text() != text]
        for rel in left:
            (ROOT / rel).write_text(clean[rel])
        if left:
            print("INTEGRITY: %s %s; restored from the copy taken before the run"
                  % (", ".join(left), when), file=sys.stderr)
        return len(left)

    damage = untouched("were still mutated after their own run")
    rc, red = run_suite()
    damage += untouched("were changed by the unmutated suite itself")
    print("%-7s %-52s %s" % ("clean" if rc == 0 and not damage else "DIRTY",
                             "everything restored",
                             "all checks pass" if rc == 0 and not damage else str(red)))
    return 1 if missed or rc or damage else 0


if __name__ == "__main__":
    sys.exit(main())
