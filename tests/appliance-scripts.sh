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
FIX=$PWD/tests/fixtures

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

rm -rf "$T/logs" "$T/data" "$T/fw" "$T/home"
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
chmod +x "$T/bin/cliamp" "$T/bin/systemctl" "$T/bin/mount" "$T/bin/curl"

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
        -e 's#^\. /etc/streamer.conf#. '$T'/streamer.conf#' \
        -e 's#/etc/streamer/audio-#'$T'/audio-#g' \
        -e 's#/boot/firmware/config.txt#'$T'/fw/config.txt#g' \
        -e 's#^boot_dir=/boot/firmware$#boot_dir='$T'/fw#' \
        -e 's;/usr/local/bin/streamer;'"$T"'/streamer;g' \
        "$CFG/usr/local/bin/$1" >"$T/$1"
    chmod +x "$T/$1"
}
for s in streamer-bootlog streamer-play streamer-save streamer-bootcount streamer-booted streamer; do
    sandbox "$s"
done

reset() { # a clean /data/streamer, a player as a live daemon has it, fresh boot files
    rm -rf "$T"/data/streamer/* "$T/state.json"
    mkdir -p "$T/data/streamer/last-good"
    "$T/bin/cliamp" --default-state >"$T/state.json"
    rm -f "$T/player.log"
    fw_seed jack
    # The counter file exists after any boot, good or bad, so a sandbox that
    # pretends to be a running system has one. Most scenarios want to start from
    # "this boot is attempt 3" rather than from nothing.
    printf 'attempt=2\nconfig=%s\n' "$(fw_hash)" >"$T/data/streamer/attempt"
}

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
        ck_eq "the newest event is the one kept last" \
            "$(sed -n 4p "$T/data/streamer/boot.log")" "$(date -u +%Y-%m-%dT%H:%M:%SZ) line 7"
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
    15) note "15. tool contract: every blockdev option the payload uses really exists"
        # A flag that *looks* obvious but does not exist survives every green
        # sandbox run, because no stub validates flags, and dies only on real
        # hardware. That is exactly how `blockdev --getstart` reached the first
        # real card: streamer-firstboot crashed before laying out /data, and
        # every unit with Requires=data.mount reported 'Dependency failed'.
        # The build host runs the same util-linux family as the card (2.41.x),
        # so blockdev --help here is the truth the scripts have to match.
        used=$(grep -rhoE 'blockdev --[a-z]+' "$CFG/usr/local/bin" |
            sed 's/.*blockdev --//' | sort -u | tr '\n' ' ')
        missing=""
        for o in $used; do
            blockdev --help 2>&1 | grep -qF -- "--$o" || missing="$missing --$o"
        done
        echo "  blockdev options used:$used"
        ck "the payload really calls blockdev (the check is not vacuous)" \
            "[ -n \"$used\" ]"
        ck "every blockdev option used exists on a real util-linux" \
            "[ -z \"$missing\" ]"
        # And the one real start-sector source: sysfs, not a blockdev flag.
        ck_in "the firstboot start sector comes from sysfs" \
            "$CFG/usr/local/bin/streamer-firstboot" "/sys/class/block/" ;;
    *) echo "no scenario $1" >&2; return 2 ;;
    esac
    log_tail
}

echo "sandbox: $T"
if [ $# -gt 0 ]; then
    for n in "$@"; do run "$n"; done
else
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do run "$n"; done
fi

printf '\n%d checks, %d failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
