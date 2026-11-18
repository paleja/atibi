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
ck_has() { # ck_has <label> <string> <fixed text>: ck_in for values, not files
    case "$2" in *"$3"*) good "$1";; *) bad "$1 (no '$3' in: $(printf '%s' "$2" | head -c 120))";; esac; }
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

# Everything a scenario can leave behind that another scenario reads: the
# sandbox is wiped and rebuilt before each run, so a file one scenario
# writes cannot decide what a later one sees. (It used to matter: a
# geometry record left in /etc/streamer changed what the next boot did.)
rm -rf "$T/bin" "$T/logs" "$T/data" "$T/fw" "$T/home" "$T/etc-streamer"
mkdir -p "$T/bin" "$T/fw" "$T/home/.config/cliamp" "$T/data/streamer" "$T/logs"

# The factory template `streamer reset` copies back over the data partition.
# build.sh makes one of these and feeds it to mkfs.ext4 -d, so the directory
# names are read out of the build script instead of repeated here: a knob
# that changes there has to show up in both.
DATA_DIRS=$(sed -n 's/^DATA_DIRS="\(.*\)"$/\1/p' "$BUILD")
seed_tree() { # seed_tree: the template, as build.sh has it at build time
    rm -rf "$T/share/streamer/seed"
    install -d "$T/share/streamer/seed"
    for d in $DATA_DIRS; do install -d "$T/share/streamer/seed/$d"; done
    printf '%s\n' "the template a factory reset copies back" >\
        "$T/share/streamer/seed/README"
}
seed_tree
cp "$CFG"/etc/streamer/audio-*.txt "$T/"

# --- the stand-in player ------------------------------------------------------
# Holds its whole state in state.json, so a scenario can read back what the
# script under test actually asked the player to do.
cat >"$T/bin/cliamp" <<'PYEOF'
#!/usr/bin/env python3
import json, os, re, sys, time
S = os.path.join(os.environ["TESTROOT"], "state.json")
# What a real daemon preloads. Row 0 is what a naive "play" would start.
PRELOAD = ["cliamp radio: Omarchy", "cliamp radio: Chiptunes",
           "cliamp radio: Amiga", "cliamp radio: Lofi", "cliamp radio: Synthwave"]
# The card has credentials for one streaming service and not the others, and so
# does the stand-in: provider.load is refused for anything not on this list, the
# way cliamp refuses a provider it was never configured with.
CONFIGURED_PROVIDERS = ("tidal",)
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
def view(d):
    # The real 2.4.1 `cliamp status --json` pretty-prints, spells the row number
    # twice (inside "track" and at the top level), and keeps "index" out of the
    # output entirely until a row is current. The stand-in used to print its own
    # storage dict, compact and single-line, and a key lookup written only for
    # that shape silently returned nothing on the card: every number the boot
    # script read from the player came back empty. Same lesson as the IPC
    # envelope: the stand-in has to lie as little as possible.
    q = d.get("queue", [])
    i = d.get("index", -1)
    v = {"ok": True, "state": d.get("state", "stopped")}
    if 0 <= i < len(q):
        v["track"] = {"title": q[i], "artist": "fake artist",
                      "path": "fake://row/%d" % i, "index": i, "stream": True}
    if d.get("name"):
        v["playlist"] = "%s:%s" % (d.get("provider") or "local", d["name"])
    v["total"] = len(q)
    v["shuffle"] = False
    v["repeat"] = "Off"
    v["position"] = d.get("position", 0)
    v["volume"] = d.get("volume", 0)
    if i >= 0:
        v["index"] = i
    sys.stdout.write(json.dumps(v, indent=2) + "\n")
if a[:1] == ["--default-state"]: out(fresh()); sys.exit(0)
if a[:1] == ["status"]:   view(load()); sys.exit(0)
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
if a[:3] == ["remote", "call", "provider.load"]:
    # provider.load pulls a playlist that lives on a streaming service into the
    # live list, and starts playing it. That is what the boot does for a
    # kind=provider target and what the phone does when one is tapped, so the
    # stand-in has to answer both the same way.
    prov, pid = sarg("provider"), sarg("playlist")
    if prov not in CONFIGURED_PROVIDERS:
        # The card has credentials for some services and not others, and cliamp
        # says so by refusing the call. A boot that ignored that answer would
        # log a clean play of a playlist nobody can hear.
        sys.exit("Error: no credentials configured for provider %s" % prov)
    d = load(); d["queue"] = ["%s: row %d" % (pid, i) for i in range(8)]
    d["index"] = 0; d["name"] = pid; d["provider"] = prov
    d["state"] = "playing"; save(d); sys.exit(0)
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
# Recording every call is how a scenario asserts that a command which has
# to stop the player before wiping the ground under it really did.
printf '%s\n' "$*" >>"$TESTROOT/systemctl"
exit 0
EOF
cat >"$T/bin/mount" <<'EOF'
#!/bin/sh
echo "  [mount $*]" >&2
# The one mount call whose consequences the sandbox has to model is a remount
# of the root filesystem, because the read-only root is the whole power-cut
# design: a stub that only echoed would let a script quietly make the root
# writable on every boot and nothing would notice. It records the remount
# instead of doing it, and scenario 7 reads the record back. Matching is on
# the mount point being "/" exactly, so a remount of the boot directory in
# another script never counts.
case " $* " in
    *" -o remount,rw / "*|*" -o remount,rw /"*) printf 'rw\n' >>"$TESTROOT/mount-root" ;;
    *" -o remount,ro / "*|*" -o remount,ro /"*) printf 'ro\n' >>"$TESTROOT/mount-root" ;;
esac
exit 0
EOF
cat >"$T/bin/ip" <<'EOF'
#!/bin/sh
# The network as a build host has it: usable, unless a scenario says otherwise.
# A stream URL is checked by resolving its host, but a playlist on a streaming
# service has no host in its target, so streamer-play falls back to asking for a
# route and an address. Neither answer should depend on the machine running the
# suite, which may have neither iproute2 nor a default route: so the answer is
# here, and the file net-down is how a scenario takes it away. Each call is
# counted, because "it waited for the network" is only a check if the number of
# asks is visible.
printf '%s\n' "$*" >>"$TESTROOT/ip.log"
[ -f "$TESTROOT/net-down" ] && exit 1
echo "1.1.1.1 dev eth0 table main src 192.168.88.7"
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
chmod +x "$T/bin/cliamp" "$T/bin/systemctl" "$T/bin/mount" "$T/bin/ip" "$T/bin/curl"

cat >"$T/bin/chown" <<'EOF'
#!/bin/sh
# recorded, not performed: the sandbox has one user, so ownership itself cannot
# be tested here. What can be tested is that a script asked for it.
echo "$*" >>"$TESTROOT/chown.log"
exit 0
EOF
chmod +x "$T/bin/chown"

# Every absolute path the scripts use comes from one of two places: the knobs
# in /etc/streamer.conf, or a literal /usr/local/bin or /boot/firmware in the
# script itself. So the sandbox is two rewrites, and nothing else: the logic
# under test is otherwise byte-for-byte what ships.
cat >"$T/streamer.conf" <<EOF
$(sed -e 's#^STREAMER_DATA=/data$#STREAMER_DATA='$T'/data/#' \
    -e 's#^STREAMER_SEED=.*#STREAMER_SEED='$T'/share/streamer/seed#' \
    -e 's#\$STREAMER_DATA#'$T'/data#g' "$CFG/etc/streamer.conf")
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
        -e 's#/usr/share/streamer#'"$T"'/share/streamer#g' \
        "$CFG/usr/local/bin/$1" >"$T/$1"
    chmod +x "$T/$1"
}
for s in streamer-bootlog streamer-play streamer streamer-http; do
    sandbox "$s"
done

reset() { # the data partition as the card ships it, a player as a live daemon
          # has it, fresh boot files. It wipes $T/data rather than only
          # data/streamer, because a scenario that tests the factory reset puts
          # files all over that partition, and the next scenario is entitled to
          # the clean card the build gave it.
    rm -rf "$T/data" "$T/state.json" "$T/mount-root" "$T/systemctl"
    for d in $DATA_DIRS; do install -d "$T/data/$d"; done
    "$T/bin/cliamp" --default-state >"$T/state.json"
    rm -f "$T/player.log"
    rm -f "$T/ip.log" "$T/net-down" "$T/chown.log"
    fw_seed jack
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
trap 'socket_off; ipc_off; http_stop' EXIT

# --- the LAN server's stand-ins (scenario 17) --------------------------------
# The real daemon's socket protocol, faked well enough that the HTTP server
# cannot pass by accidentally: state persists, and every operation is written
# down for read-back. Process groups, because a Python http.server is not one
# process, and a stray listener outlives the harness otherwise.
ipc_start() {
    rm -f "$T/ipc.log"
    setsid python3 "$FIX/fake-ipc.py" "$sock" "$T/state.json" "$T/ipc.pid" \
        "$T/ipc.log" </dev/null >/dev/null 2>&1 &
    i=0
    while [ ! -S "$sock" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
}
ipc_off() {
    # setsid detaches: the child is in a session of its own, invisible to this
    # shell's $!. It writes its own pid at startup, and a whole session (not
    # just the listener) is what has to die, because every accepted connection
    # gets its own thread inside the one process.
    if [ -f "$T/ipc.pid" ]; then
        kill -- "-$(cat "$T/ipc.pid")" 2>/dev/null
        rm -f "$T/ipc.pid"
    fi
    rm -f "$sock"
    return 0
}
http_start() {
    export http_port
    http_port=$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    STREAMER_CONF="$T/streamer.conf" \
        STREAMER_HTTP_PORT="$http_port" \
        STREAMER_HTTP_PIDFILE="$T/http.pid" \
        STREAMER_CLIAMP_SOCKET="$sock" \
        STREAMER_EXECUTABLE="$T/streamer" \
        setsid "$T/streamer-http" </dev/null >"$T/logs/http.out" 2>&1 &
    i=0
    until http_raw GET / >/dev/null 2>&1; do
        i=$((i + 1)); [ $i -gt 100 ] && break; sleep 0.05
    done
}
http_stop() {
    if [ -f "$T/http.pid" ]; then
        kill -- "-$(cat "$T/http.pid")" 2>/dev/null
        rm -f "$T/http.pid"
    fi
    return 0
}
# curl in this sandbox is a stub for `streamer stations`: it answers one URL
# shape and fails every other one. So the HTTP client here is Python, one
# request per call, and the token goes in as a header exactly the way the
# browser sends it.
http_raw() { # http_raw GET|POST <path> [body] [token]: real curl is not trusted
             # here; this is the request, raw, on stdout
    python3 -c 'import sys, urllib.request
method, path, body, tok = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
port = __import__("os").environ["http_port"]
req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path), method=method)
if tok: req.add_header("X-Token", tok)
if body:
    req.add_header("Content-Type", "application/json")
    req.data = body.encode()
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        sys.stderr.write(str(r.status) + "\n")
        sys.stdout.buffer.write(r.read())
except urllib.error.HTTPError as e:
    sys.stderr.write(str(e.code) + "\n")
    sys.stdout.buffer.write(e.read())' "$1" "$2" "${3:-}" "${4:-}"
}
http() { # http GET|POST <path> [json body]: with the server's own token
    local tok=""
    [ -f "$T/data/streamer/http.token" ] && tok=$(cat "$T/data/streamer/http.token")
    http_raw "$1" "$2" "${3:-}" "$tok" 2>/dev/null
}
http_code() { # http_code GET|POST <path> [json body] [token]: status only.
              # No token is sent unless one is named: that is the whole point
              # of the "no token: the API says no" check below.
    http_raw "$1" "$2" "${3:-}" "${4:-}" 2>&1 >/dev/null | head -1
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
oneline() { # oneline <file>: that file on one line, or a note that it is not there.
    # Reading what a script was supposed to write has to work when the script
    # did not write it: that is a failed check, and a check has to be runnable
    # to fail. `tr '\n' ' ' <file` dies on the spot instead, and a dead harness
    # reports nothing after the line it died on.
    if [ -f "$1" ]; then tr '\n' ' ' <"$1"; else printf '(no %s)' "${1##*/}"; fi; }

# Every scenario ends with its checks. The transcripts are there to read when a
# check fails, not as the verdict on their own.
run() { # run <scenario number>
    # -e stays off inside a scenario. A command that fails is a thing the checks
    # are there to notice; letting it abort the harness loses every check after
    # it, in this scenario and in all the later ones, and the run then exits
    # non-zero for a reason no check owns. Two mutation entries found this: a
    # level that is played but never written down killed the run on the display
    # line that tried to read the missing state file, so the check that should
    # have gone red never ran. -u stays on.
    set +e
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
    2) note "2. resume: playlist 'Late Night' at the saved -9 dB"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\nvolume=-9\n' >"$T/data/streamer/state"
        if "$T/streamer-play" >"$T/logs/s2" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s2"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the preloaded channels were replaced" "$(jrow 0)" "Late Night: row 0"
        ck_eq "row 0 plays: the appliance keeps what, not where" "$(jnum index)" "0"
        ck_not "it does not reach back into the playlist" "$T/player.log" "seek.absolute"
        ck_eq "the saved level is replayed" "$(jnum volume)" "-9"
        ck_not "it does not claim there was no saved level" "$T/logs/s2" "no saved volume"
        ck_in "boot.log records the play" "$T/data/streamer/boot.log" "OK playlist Late Night"
        ck_in "boot.log records the level it reached" "$T/data/streamer/boot.log" "(target -9)" ;;
    3) note "3. saving on change: the level a person set, and a playlist the phone started"
        reset; socket_on
        "$T/streamer-play" >/dev/null 2>&1
        # A session in progress: something is playing, and the level is wherever
        # the boot left it. Nothing writes the record on a timer, so the file is
        # still without a level line at this point.
        echo "  before anyone touches anything:"
        oneline "$T/data/streamer/state"; echo
        ck_not "nothing has recorded a level yet" "$T/data/streamer/state" "volume="
        if "$T/streamer" vol -12 >"$T/logs/vol" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/vol"
        echo "  after streamer vol -12:"; oneline "$T/data/streamer/state"; echo
        ck_eq "setting the level on a running player exits 0" "$rc" "0"
        ck_in "the change is written down at once" "$T/data/streamer/state" "volume=-12"
        ck_in "the boot target is recorded alongside it" "$T/data/streamer/state" "target=http://localhost/x.mp3"
        if "$T/streamer" down 3 >"$T/logs/down" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/down"
        echo "  after streamer down 3:"; oneline "$T/data/streamer/state"; echo
        ck_eq "stepping the level down exits 0" "$rc" "0"
        ck_in "a step up or down is remembered the same way" "$T/data/streamer/state" "volume=-15"
        # The phone tapping a Tidal playlist: playback is started over IPC, and
        # the boot target is written through the streamer command with the
        # provider:id spelling, without restarting the sequence underneath it.
        if "$T/streamer" remember playlist tidal:e407f56e >"$T/logs/rem" 2>&1; then
            rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/rem"
        echo "  after remember playlist tidal:e407f56e:"; oneline "$T/data/streamer/state"; echo
        ck_eq "recording next boot exits 0" "$rc" "0"
        ck_in "the playlist is what plays next boot" "$T/data/streamer/state" "kind=provider"
        ck_in "on that provider" "$T/data/streamer/state" "provider=tidal"
        ck_in "by that id" "$T/data/streamer/state" "target=e407f56e"
        ck_in "the level survives the rewrite" "$T/data/streamer/state" "volume=-15"
        ck_not "and recording it did not restart the player" "$T/systemctl" "restart streamer-play.service"
        echo "  and a boot from it, with the player as it is after a reboot:"
        rm -f "$T/state.json" "$T/player.log"
        "$T/bin/cliamp" --default-state >"$T/state.json"
        if "$T/streamer-play" >"$T/logs/s3" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s3"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_not "a network that is already up is not waited for" "$T/logs/s3" "network not up"
        ck_has "the boot asked the player for the provider playlist" "$(cat "$T/player.log")" "provider.load"
        ck_eq "the provider playlist is loaded" "$(jrow 0)" "e407f56e: row 0"
        ck "provider.load started it, so the boot did not start it again" \
            "[ -z \"$(pln 'queue.play')\" ]"
        ck_eq "and the level came back to the -15 dB that was saved" "$(jnum volume)" "-15"
        ck_in "boot.log names the provider playlist" "$T/data/streamer/boot.log" "OK provider e407f56e" ;;
    4) note "4. stop mode: stay quiet"
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
    5) note "5. a saved level of +99 dB is clamped to STREAMER_VOL_MAX"
        reset; socket_on
        printf 'mode=last\nkind=url\ntarget=http://localhost/x.mp3\n' >"$T/data/streamer/state"
        printf 'volume=99\n' >>"$T/data/streamer/state"
        if "$T/streamer-play" >"$T/logs/s7" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s7"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the ceiling held" "$(jnum volume)" "6"
        ck_in "and the clamp is in the log" "$T/data/streamer/boot.log" "(target 6)" ;;
    6) note "6. the player never comes up: fail loudly, and say so in boot.log"
        reset; socket_off
        if "$T/streamer-play" >"$T/logs/no-socket" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/no-socket"
        echo "  exit $rc (non-zero is the point: systemd records it and moves on)"
        ck "exit status is non-zero" "[ $rc -ne 0 ]"
        ck_in "boot.log says what was waited for" "$T/data/streamer/boot.log" "FAIL no cliamp socket" ;;
    7) note "7. streamer, the SSH-facing control: what it reports"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'volume=-9\n' >>"$T/data/streamer/state"
        echo "-- streamer last"; "$T/streamer" last >"$T/logs/last" 2>&1; sed 's/^/  /' "$T/logs/last"
        echo "-- streamer status"; "$T/streamer" status >"$T/logs/status" 2>&1; sed 's/^/  /' "$T/logs/status"
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
        echo "-- streamer rw, then ro: the read-only root is the point of the"
        echo "   whole power-cut design, so those two have to be the record"
        "$T/streamer" rw >/dev/null 2>&1 || true
        "$T/streamer" ro >/dev/null 2>&1 || true
        sed 's/^/  /' "$T/mount-root" 2>/dev/null | sed 's/^/  /'
        echo "-- streamer nonsense is refused, with the usage text"
        # set -e would abort the harness on a command meant to fail, so the
        # status is captured in the condition itself.
        if "$T/streamer" nonsense >"$T/logs/nonsense" 2>&1; then rc=0; else rc=$?; fi
        echo "  exit $rc, $(wc -l <"$T/logs/nonsense") lines, first: $(sed -n 1p "$T/logs/nonsense")"
        echo "-- seven events into a boot.log that keeps four"
        for i in 1 2 3 4 5 6 7; do "$T/streamer-bootlog" "line $i"; done
        echo "  lines kept: $(wc -l <"$T/data/streamer/boot.log")"
        ck_in "last reports the saved intent" "$T/logs/last" "Late Night"
        ck_in "and the level the next session starts at" "$T/logs/last" "at -9 dB"
        ck_in "status repeats the saved level" "$T/logs/status" "boot level:  -9 dB"
        ck_in "status repeats the saved target" "$T/logs/status" "boot target: playlist Late Night"
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
        ck_in "usage lists what gets remembered for the next boot" "$T/logs/nonsense" \
            "streamer remember <what> <target>"
        ck_not "and no longer offers to drop a position that is not kept" "$T/logs/nonsense" \
            "forget"
        ck_eq "streamer rw then ro leaves the root read-only, in that order" \
            "$(tr '\n' ' ' <"$T/mount-root")" "rw ro "
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
    8) note "8. streamer audio jack|dac: only the marked block of config.txt moves"
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
    9) note "9. a saved level at or below the floor is treated as parked, not replayed"
        reset; socket_on
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'volume=-30\n' >>"$T/data/streamer/state"
        if "$T/streamer-play" >"$T/logs/s11a" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s11a"
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "the parked -30 dB became the fallback" "$(jnum volume)" "-20"
        ck_in "and boot.log says so" "$T/data/streamer/boot.log" "saved volume -30 at the floor, using -20"
        printf 'volume=-99\n' >>"$T/data/streamer/state"
        if "$T/streamer-play" >"$T/logs/s11b" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s11b"; player
        socket_off
        ck_eq "exit status 0" "$rc" "0"
        ck_eq "a level below the floor became the fallback too" "$(jnum volume)" "-20"
        ck_in "and boot.log says so" "$T/data/streamer/boot.log" "saved volume -99 at the floor, using -20" ;;
    10) note "10. a provider the player has no credentials for: the boot says which one, and stops"
        reset; socket_on
        printf 'mode=last\nkind=provider\ntarget=pl-42\nprovider=qobuz\nvolume=-9\n' >"$T/data/streamer/state"
        if "$T/streamer-play" >"$T/logs/s12" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s12"; player
        socket_off
        ck "exit status is non-zero" "[ $rc -ne 0 ]"
        ck_eq "nothing is playing" "$(jstr state)" "stopped"
        ck_in "boot.log names the provider and the list it could not fetch" \
            "$T/data/streamer/boot.log" "FAIL provider.load qobuz pl-42"
        ck_not "it does not pretend the target was unknown" \
            "$T/data/streamer/boot.log" "FAIL unknown kind provider"
        ck_not "and it does not quietly swap in the default station" \
            "$T/player.log" "url.load" ;;
    11) note "11. the ramp never outlives the boot: a step budget, and a level that will not move"
        reset; socket_on
        # 13a. The player will not go past -12 dB: a hardware limit, standing in
        # for the PipeWire sink or the codec clamping below where cliamp thinks
        # the level is. Without a guard the loop would climb forever, and the
        # unit's start timeout is what would end it.
        printf -- '-12\n' >"$T/stuck-at"
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'volume=-9\n' >>"$T/data/streamer/state"
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
        printf 'volume=-9\n' >>"$T/data/streamer/state"
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
    12) note "12. volume moved elsewhere mid-ramp: the person wins, the ramp backs off"
        reset; socket_on
        # The boot is climbing from the floor toward the saved -9 dB, and a
        # moment after the music starts somebody reaches for the volume and
        # takes it down to -40. That is a jump of far more than one ramp step,
        # which is how the boot tells it apart from its own adjustment. The
        # mistake being guarded against is the boot deciding it knows better and
        # climbing straight back over a level someone has just set by hand.
        printf -- '-40\n' >"$T/set-elsewhere"
        printf 'mode=last\nkind=playlist\ntarget=Late Night\n' >"$T/data/streamer/state"
        printf 'volume=-9\n' >>"$T/data/streamer/state"
        if "$T/streamer-play" >"$T/logs/s14" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s14"; player
        socket_off; rm -f "$T/set-elsewhere"
        ck_eq "the boot still ends cleanly" "$rc" "0"
        ck_eq "the level the person actually set is what plays" "$(jnum volume)" "-40"
        ck_eq "the ramp did not climb to the saved target" "$(jnum volume)" "-40"
        ck_eq "and it got there in a single step, not by arguing" "$(jnum adjustments)" "1"
        ck_in "boot.log says the level came from elsewhere" "$T/data/streamer/boot.log" "volume set elsewhere to -40.0 dB, ramp stops"
        ck_in "boot.log still records the play" "$T/data/streamer/boot.log" "OK playlist Late Night" ;;
    13) note "13. build contract: the disk tools the image recipe calls really take those options"
        # A flag that *looks* obvious survives every green sandbox run, because
        # nothing in the sandbox runs a disk tool, and it dies only on the one
        # machine where it matters: the one with sudo. That is how
        # `blockdev --getstart` reached the first real card: it does not exist,
        # the provisioning script died on it before /data was laid out, and
        # every unit with Requires=data.mount reported 'Dependency failed'.
        # So the options the recipe uses are written out here and asked of the
        # real tools. The build host runs the same util-linux and e2fsprogs
        # families as the card (2.41/2.42 and 1.47), close enough to be the
        # truth to match against; the card itself confirmed that sfdisk 2.41.5
        # rejects `-u=S` with "unsupported unit '='" exactly as 2.42.4 does here.
        # The knobs the recipe lays out /data with are read out of the build
        # script rather than repeated here, so a change to one shows up in both.
        DATA_DIRS=$(sed -n 's/^DATA_DIRS="\(.*\)"$/\1/p' "$BUILD")
        DATA_MIB=$(sed -n 's/^DATA_SIZE_MIB=\([0-9]*\)$/\1/p' "$BUILD" | head -1)
        echo "  /data as the image makes it: ${DATA_DIRS}"
        ck "the build script says which directories /data starts with" \
            "[ -n \"$DATA_DIRS\" ]"
        ck "and how large it is" "[ -n \"$DATA_MIB\" ]"
        # The usage texts disagree with each other, which is what makes this
        # fiddly: e2fsprogs clusters its bare letters ("[-jnqvDFSV]", so -F and
        # -q are never spelled out) and then lists the ones that take a value
        # ("[-L volume-label]"), while util-linux lists every one apart, with a
        # long name beside it. Turning the text into words and keeping the words
        # that start with '-' covers both, and a cluster becomes one word whose
        # letters can be looked up one at a time.
        opt_forms() { # opt_forms <tool>: the option spellings its help offers
            # GNU coreutils decorates its help with ANSI colours and OSC-8
            # hyperlink escapes, and the '-s' in "\e]8;;url\e\s[-\e[1m-s, --size"
            # is only readable once those sequences are gone.
            "$1" --help 2>&1 |
                sed -e 's/\x1b\][^\x07]*\x07//g' -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' |
                tr -c 'A-Za-z0-9-[]' '\n' | tr -d '[]' |
                grep -E '^--?[A-Za-z]' | sort -u || true
        }
        check_opts() { # check_opts <path to tool> <name> <options...>
            path=$1; name=$2; shift 2
            if [ -z "$path" ]; then
                bad "$name is not on this host, so its options went unchecked"
                return
            fi
            forms=$(opt_forms "$path")
            if [ -z "$forms" ]; then
                bad "$name prints no usage text here, so its options went unchecked"
                return
            fi
            shorts=$(printf '%s\n' "$forms" | grep -E '^-[^-]' | tr -d '\n-' || true)
            miss=""
            for o in "$@"; do
                case $o in
                    --*)
                        printf '%s\n' "$forms" | grep -qxF -- "$o" || miss="$miss $o" ;;
                    -[A-Za-z]*)
                        # a cluster on the command line (-fy, -Pf) is one request
                        # for two options, and the help only promises the letters
                        for l in $(printf '%s' "${o#-}" | sed 's/./& /g'); do
                            case $shorts in
                                *"$l"*) ;;
                                *) miss="$miss -$l" ;;
                            esac
                        done ;;
                    *) miss="$miss $o" ;;
                esac
            done
            echo "  $name: $*"
            if [ -n "$miss" ]; then echo "    not offered: $miss"; fi
            ck "$name really takes every option the image recipe passes it" \
                "[ -z \"$miss\" ]"
        }
        check_opts "$(command -v sfdisk || true)" sfdisk -d -q
        check_opts "$(command -v mkfs.ext4 || true)" mkfs.ext4 -b -d -F -L -m -q
        check_opts "$(command -v tune2fs || true)" tune2fs -C -i -T -U
        check_opts "$(command -v e2fsck || true)" e2fsck -f -y
        check_opts "$(command -v blkid || true)" blkid -o -s
        check_opts "$(command -v debugfs || true)" debugfs -R
        check_opts "$(command -v dumpe2fs || true)" dumpe2fs -h
        check_opts "$(command -v fsck.fat || true)" fsck.fat -a -n
        check_opts "$(command -v losetup || true)" losetup -d -f -P --show
        check_opts "$(command -v truncate || true)" truncate -s
        # The flags that turned out to be fiction, spelled out so they stay out.
        # They are quoted here, so this is a check about code rather than prose:
        # build.sh mentions -u=S in a comment to explain why it is not used, and
        # a looser check would trip on that explanation forever. One check per
        # line rather than a loop: a check's label is how tests/mutation-check.py
        # finds the check that should notice a given broken line, and a label
        # assembled from a loop variable is invisible to it.
        ck_not "no blockdev --getstart in the build recipe" \
            "$BUILD" "blockdev --getstart"
        ck_not "no sfdisk -u=S in the build recipe" "$BUILD" "sfdisk -u=S"
        ck_not "no sfdisk --part-size in the build recipe" \
            "$BUILD" "sfdisk --part-size"
        ck_not "no tune2fs -T never in the build recipe" \
            "$BUILD" "tune2fs -T never"
        # blockdev is not needed at all any more: nothing on the card resizes a
        # partition, so there is no start sector to ask for and no flag to get
        # wrong. A check that it stays out of the payload is cheaper than the
        # afternoon it would otherwise cost.
        ck_not "no blockdev call left in the payload" \
            "$CFG/usr/local/bin/streamer" "blockdev"
        # The read-back build.sh does after writing the partition table parses
        # `sfdisk -d`. That is only worth believing against real output, so make
        # a real dos table with the real sfdisk and read it the way the script
        # does. sfdisk 2.42.4 spells the row as
        # "card.img3 : start=     6012928, size=     2097152, type=83".
        truncate -s 4G "$T/contract.img"
        {
            printf 'label: dos\nlabel-id: 0x27b94958\n'
            printf 'start=16384,size=1048576,type=c\n'
            printf 'start=1064960,size=4947968,type=83\n'
            printf 'start=6012928,size=%s,type=83\n' "$((DATA_MIB * 2048))"
        } | "$(command -v sfdisk)" -q "$T/contract.img" 2>/dev/null
        back=$("$(command -v sfdisk)" -d "$T/contract.img" |
            awk -v img="$T/contract.img" '
                $1 == img "3" {
                    if (match($0, /start=[[:space:]]*[0-9]+/))
                        s = substr($0, RSTART + 6, RLENGTH - 6) + 0
                    if (match($0, /size=[[:space:]]*[0-9]+/))
                        z = substr($0, RSTART + 5, RLENGTH - 5) + 0
                }
                END { print s + 0, z + 0 }')
        echo "  sfdisk -d read back: $back"
        ck_eq "the awk build.sh reads the table with finds both fields in real output" \
            "$back" "6012928 $((DATA_MIB * 2048))"
        # The heart of the recipe, and the part no sandbox can imitate: a seeded
        # ext4, checked by the real fsck, spliced into the image by dd at the
        # partition's start sector, and read back. It has to work before a card
        # can boot at all, because an empty partition means data.mount fails and
        # the recovery path sits behind that same failure. None of it needs sudo,
        # which is the only reason it can be run here rather than on a card.
        seed="$T/contract-seed"
        rm -rf "$seed"; mkdir -p "$seed"
        for d in $DATA_DIRS; do mkdir -p "$seed/$d"; done
        echo "the template a factory reset copies back" >"$seed/README"
        fsimg="$T/contract-data.img"
        truncate -s "$((DATA_MIB * 1024 * 1024))" "$fsimg"
        # Not this scenario's own mkfs command: the one build.sh writes, lifted
        # out of it and run here, so a flag the recipe asks for is a flag that
        # has been seen to work and one it quietly drops turns this red. build.sh
        # keeps the command on one line with the log redirect after it, so
        # cutting at '>' is enough, and it names its seed directory $SEED and its
        # target $fsimg, which is what lets the line run here unchanged.
        recipe=$(sed -n 's/^\(mkfs\.ext4[^>]*\)>.*$/\1/p' "$BUILD" | head -1)
        printf '%s\n' "$recipe" >"$T/contract-mkfs-cmd"
        echo "  mkfs, exactly as build.sh writes it:"
        sed 's/^/    /' "$T/contract-mkfs-cmd"
        ck_eq "the build makes the /data volume with one mkfs.ext4 command line" \
            "$(grep -c '^ *mkfs\.ext4 ' "$BUILD")" "1"
        ck_in "the command the build runs seeds itself from a directory" \
            "$T/contract-mkfs-cmd" '-d "$SEED"'
        ck_in "the command the build runs asks for 4096-byte blocks" \
            "$T/contract-mkfs-cmd" "-b 4096"
        ck_in "and the label the fstab line mounts by" \
            "$T/contract-mkfs-cmd" "-L streamer-data"
        # The guard is not ceremony: the command comes out of another file, so a
        # mangled one has to report as a failed check, not end the run.
        SEED="$seed"
        ec=0; eval "$recipe" >"$T/contract-mkfs.log" 2>&1 || ec=$?
        ck_eq "mkfs.ext4 -d seeds a filesystem out of a directory, with no mount and no loop device" \
            "$ec" "0"
        sed 's/^/    mkfs: /' "$T/contract-mkfs.log"
        ec=0; e2fsck -fy "$fsimg" >/dev/null 2>&1 || ec=$?
        ck "the seeded filesystem passes a real e2fsck (0 clean, 1 corrected)" "[ $ec -le 1 ]"
        ck_eq "and carries the label the build's fstab line mounts by" \
            "$(blkid -o value -s LABEL "$fsimg")" "streamer-data"
        ck_eq "at 4096-byte blocks, which is what makes a 1 GiB volume's block count predictable" \
            "$(dumpe2fs -h "$fsimg" 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /,"",$2); print $2}')" \
            "4096"
        ck_eq "and as many of them as the recipe asked for" \
            "$(dumpe2fs -h "$fsimg" 2>/dev/null | awk -F: '/^Block count/ {gsub(/ /,"",$2); print $2}')" \
            "$((DATA_MIB * 1024 * 1024 / 4096))"
        # build.sh asserts the same thing it does after splicing: the tree is
        # really in there. debugfs is how it looks, read-only.
        debugfs -R 'ls -l /' "$fsimg" >"$T/contract-ls.txt" 2>/dev/null
        for d in $DATA_DIRS README; do
            ck_in "the seeded filesystem really contains $d" "$T/contract-ls.txt" " $d"
        done
        # dd at the start sector, then the same read-back build.sh does, and the
        # comparison it makes: a byte-identical pull means the partition entry
        # and the splice agree.
        cp "$T/contract.img" "$T/spliced.img"
        dd if="$fsimg" of="$T/spliced.img" bs=512 seek=6012928 conv=notrunc status=none
        dd if="$T/spliced.img" of="$T/pulled.img" bs=512 skip=6012928 \
            count=$((DATA_MIB * 2048)) status=none
        cmp -s "$fsimg" "$T/pulled.img"
        ck_eq "the volume spliced into an image is byte for byte the volume that went in" \
            "$?" "0"
        # dd cannot guarantee that the table and the splice agree, so the build
        # reads both back. Assert it really does: the alternative is a card that
        # boots and never mounts anything, which is the failure this whole
        # round of work started from.
        ck_in "the build reads the partition table back after writing it" \
            "$BUILD" 'back=$(sfdisk -d "$IMG"'
        ck_in "the build reads the spliced volume back through its partition device" \
            "$BUILD" 'dumpe2fs -h "${LOOP}p3"'
        ck_in "the build reads the seeded tree back through debugfs" \
            "$BUILD" "debugfs -R 'ls -l /'"
        # ...and it looks inside the partitions read-only only. Every write goes
        # through a real mount, because a hand-written FAT header or a debugfs
        # write is exactly the cleverness nobody reading this script can audit.
        ck_not "the build never writes through debugfs" "$BUILD" "debugfs -w"
        ck_not "the build never writes FAT by hand" "$BUILD" "mtools"
        ck_not "the build never writes a filesystem with debugfs" "$BUILD" "debugfs -R 'write"
        # fstab: the read-only flip is a program in a file of its own, so it gets
        # run here rather than described. The input is the fstab a real card
        # shipped (tests/fixtures/fstab.orig), comments and all, and the expected
        # output is a file somebody wrote by hand: the only difference between
        # the two is the letters ro, in the right place, and nothing else.
        ro="$T/fstab-ro.out"
        ec=0; awk -f image/fstab-ro.awk "$FIX/fstab.orig" >"$ro" 2>&1 || ec=$?
        ck_eq "the fstab editor the build runs is a program that starts" "$ec" "0"
        if cmp -s "$ro" "$FIX/fstab.expected"; then fstab_ok=same
        else fstab_ok=$(diff -u "$FIX/fstab.expected" "$ro" | tail -n +3); fi
        ck_eq "it makes the root and the firmware partition read-only and touches nothing else" \
            "$fstab_ok" "same"
        if [ "$fstab_ok" != same ]; then printf '%s\n' "$fstab_ok" | sed 's/^/    /'; fi
        for mp in / /boot/firmware; do
            ck_eq "so $mp mounts read-only out of the box" \
                "$(awk -v m="$mp" '$2==m { print ($4 ~ /(^|,)ro(,|$)/) ? "ro" : "rw"; exit }' "$ro")" \
                "ro"
        done
        ck_eq "and the data partition, which is meant to be written, stays writable" \
            "$(awk '$2=="/data" { print ($4 ~ /(^|,)ro(,|$)/) ? "ro" : "rw"; exit }' "$ro")" "rw"
        # Idempotence is not a nicety: re-running the build over an image it made
        # before must not produce defaults,ro,ro.
        awk -f image/fstab-ro.awk "$ro" >"$T/fstab-ro2.out"
        if cmp -s "$ro" "$T/fstab-ro2.out"; then again=same; else again=different; fi
        ck_eq "running the editor over its own output changes nothing" "$again" "same"
        rm -f "$T/contract.img" "$T/spliced.img" "$T/pulled.img" "$fsimg"
        rm -rf "$seed" ;;
    14) note "14. streamer reset --yes: the data partition goes back to the template"
        reset; socket_on; seed_tree
        # A partition that has been lived on. The dotfile is the interesting
        # part: `rm -rf /data/*` would leave it behind, and a stale hidden file
        # under a freshly copied template is the half-reset state that is hardest
        # to diagnose a month later.
        printf 'mode=last\nkind=url\ntarget=https://example.org/stale/stream\n' \
            >"$T/data/streamer/state"
        printf 'volume=-4\n' >>"$T/data/streamer/state"
        install -d "$T/data/cliamp" "$T/data/music" "$T/data/bin"
        printf 'token = "not-a-real-token"\n' >"$T/data/cliamp/config.toml"
        printf 'hidden\n' >"$T/data/.hidden"
        printf 'a track\n' >"$T/data/music/song.flac"
        echo "-- streamer reset, with no --yes: refuse, name the cost, change nothing"
        if "$T/streamer" reset >"$T/logs/reset-no" 2>&1; then rc_no=0; else rc_no=$?; fi
        echo "  exit $rc_no"; sed 's/^/  /' "$T/logs/reset-no"
        ck_eq "without --yes it refuses, exit 2" "$rc_no" "2"
        ck_in "the refusal says what it costs" "$T/logs/reset-no" "Tidal sign-in"
        ck_in "and lists the dotfile a plain glob would miss" "$T/logs/reset-no" ".hidden"
        ck "refusing really changes nothing: the intent is still there" \
            "grep -q example.org \"$T/data/streamer/state\""
        ck "refusing really changes nothing: the dotfile is still there" \
            "[ -f \"$T/data/.hidden\" ]"
        echo "-- streamer reset --yes"
        if "$T/streamer" reset --yes >"$T/logs/reset" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/reset"
        echo "-- the units it was asked to touch, in order"
        sed 's/^/  /' "$T/systemctl"
        ck_eq "reset --yes exits 0" "$rc" "0"
        for d in $DATA_DIRS; do
            ck "the template's $d is back" "[ -d \"$T/data/$d\" ]"
        done
        # 'and empty' is not true of one of them: the boot log lives in a seeded
        # directory, and the reset writes the line that records itself. The claim
        # worth making is the stronger one: nothing else survived the wipe.
        ck_eq "after the reset the only files on the partition are the template README and the boot log" \
            "$(find "$T/data" -mindepth 1 -type f | sed "s|^$T/data/||" | LC_ALL=C sort | tr '\n' ' ')" \
            "README streamer/boot.log "
        ck_in "the template's README came across too" "$T/data/README" "template"
        ck "the saved intent is gone, so the next boot starts from the defaults" \
            "[ ! -e \"$T/data/streamer/state\" ]"
        ck "as are the local music and the Tidal sign-in" \
            "[ ! -e \"$T/data/music/song.flac\" ] && [ ! -e \"$T/data/cliamp/config.toml\" ]"
        ck "and so is the dotfile, which is why this does not use a glob" \
            "[ ! -e \"$T/data/.hidden\" ]"
        ck_eq "so 'streamer last' falls back to the configured default" \
            "$("$T/streamer" last)" "last url http://localhost/x.mp3"
        ck_in "the durable log records the reset" "$T/data/streamer/boot.log" "factory reset"
        # The order of the two systemctl calls is not decoration: the player holds
        # the IPC socket and its configuration directory open, and its exit handler
        # writes to both, so wiping the ground under it can drop a stale file back
        # after the reset has finished.
        ck_eq "the player is stopped first, then both units come back" \
            "$(cut -d' ' -f1 "$T/systemctl" | tr '\n' ' ')" "stop restart "
        # `ls` order comes from the locale, so comparing a listing to a fixed
        # string is luck. Sort both sides, and build the expected side from the
        # same directory list the build script seeds /data with.
        ck_eq "the template is untouched, so a second reset would do the same" \
            "$(ls -1A "$T/share/streamer/seed" | LC_ALL=C sort | tr '\n' ' ')" \
            "$(printf '%s\n' $DATA_DIRS README | LC_ALL=C sort | tr '\n' ' ')" ;;
    15) note "15. packaging: what lands on the card is something systemd can exec"
        # The card that came up mute was not broken by logic. A script had lost its
        # `#!` line in a commit, systemd's fork+exec answered ENOEXEC, and the unit
        # came up status=203/EXEC, retried, failed again: three failures a boot, and
        # no /data, because nothing that lays /data out had run. This suite cannot
        # see that by running the scripts, because bash falls back to parsing a file
        # it cannot exec, so a missing shebang is harmless here and fatal there. So
        # the checks here are about the bytes and the wiring, not the behaviour.
        n=0
        for f in "$CFG"/usr/local/bin/*; do
            name=$(basename "$f")
            n=$((n + 1))
            ck_eq "$name begins with a shebang, because systemd execs rather than parses" \
                "$(head -c 2 "$f")" "#!"
            if [ "$name" = streamer-http ]; then
                # The one payload program that is not shell: the LAN control
                # server is python3, and image/build.sh checks the base image
                # really ships that interpreter, per script. So the payload
                # side of the deal is the same idea: right interpreter named,
                # and the file at least parses.
                ck_eq "$name names /usr/bin/env python3, which build.sh cross-checks against the base image" \
                    "$(head -1 "$f")" "#!/usr/bin/env python3"
                ck "$name parses as python3" \
                    "python3 -c 'import sys; compile(sys.stdin.read(), sys.argv[1], \"exec\")' \"$f\" < \"$f\""
            else
                ck_eq "$name names /bin/sh, the shell guaranteed on the card" \
                    "$(head -1 "$f")" "#!/bin/sh"
                ck "$name parses as shell (sh -n only; a strict POSIX pass needs dash)" \
                    "sh -n \"$f\""
            fi
        done
        echo "  $n scripts in the payload"
        ck "the payload has scripts in it, or the three checks above checked nothing" \
            "[ $n -ge 5 ]"
        # Unit files are not shell either, so no sh -n would notice a mistyped
        # program name, and it surfaces as the same 203/EXEC. Every program a unit
        # names is checked against the payload: this design ships its own tools and
        # reaches for nothing else, which is the rule worth enforcing.
        for u in "$CFG"/etc/systemd/system/*.service; do
            unit=$(basename "$u")
            exes=$(sed -n 's/^Exec[A-Za-z]*=[@+-]*//p' "$u")
            ck "$unit names a program to run" "[ -n \"$exes\" ]"
            for exe in $exes; do
                ck "$unit runs $exe, which the payload ships" \
                    "[ -f \"$CFG/usr/local/bin/$(basename "$exe")\" ]"
            done
        done
        # The other direction: a script nothing reaches for is a leftover from a
        # deletion, and a unit pointing at a script that no longer exists is a
        # failure on every boot. Both are cheap to rule out here.
        for f in "$CFG"/usr/local/bin/*; do
            name=$(basename "$f")
            case $name in
                streamer) continue ;;   # the human command, run over SSH
            esac
            hits=$(grep -l "$name" "$CFG"/etc/systemd/system/* "$CFG"/usr/local/bin/* 2>/dev/null |
                grep -v "^$f$" | wc -l)
            ck "$name is reached from a unit or from another script" "[ $hits -ge 1 ]"
        done
        for dep in $(sed -n 's/^\(Requires\|After\|WantedBy\)=//p' \
                "$CFG"/etc/systemd/system/* | sort -u); do
            case $dep in
                streamer-*.service|streamer-*.timer|streamer.target)
                    ck "$dep is a unit the payload really ships" \
                        "[ -f \"$CFG/etc/systemd/system/$dep\" ]" ;;
                network.target|multi-user.target|timers.target|basic.target)
                    echo "  $dep: a stock RasPiOS target, taken as given" ;;
                *) bad "$dep is named by a payload unit, and is neither one of ours nor a stock target" ;;
            esac
        done
        # build.sh installs the payload by glob, so a script can only be broken on
        # the card by its own contents, never by a list of names that fell behind.
        ck_in "the build installs every script in the payload directory" \
            "$BUILD" 'for script in "$CONFIG"/usr/local/bin/*' ;;
    16) note "16. cold boot with the clock behind: an https target waits for NTP instead of dying on a certificate"
        # A power cut leaves the clock at the image build date, and a TLS
        # handshake made before the first NTP sync fails on certificate
        # validity. The daemon reports such a stream load as ok; only the
        # wait for a playing state notices, twenty seconds late. So the
        # script waits for the sync flag file first, bounded.
        sed -i 's/^STREAMER_SYNC_WAIT=.*$/STREAMER_SYNC_WAIT=1/' "$T/streamer.conf"
        # 16a. The clock never syncs in this scenario: the wait runs out,
        # says so in both logs, and the boot plays anyway rather than not.
        reset; socket_on
        printf 'mode=last\nkind=url\ntarget=https://radio.cliamp.stream/lofi/stream\n' >"$T/data/streamer/state"
        if STREAMER_TIME_SYNC_FLAG="$T/no-such-sync-flag" \
            "$T/streamer-play" >"$T/logs/s16a" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s16a"; player
        socket_off
        ck_eq "the boot still ends cleanly" "$rc" "0"
        ck_eq "playing" "$(jstr state)" "playing"
        ck_in "the warning says the clock is what was missing" "$T/logs/s16a" "clock not synchronized"
        ck_in "boot.log carries the warn too" "$T/data/streamer/boot.log" "WARN clock unsynced"
        # 16b. The clock is synced already, which is every warm boot: the
        # flag file is there, so there is no wait and no warning.
        reset; socket_on
        install -d "$T/timesync"
        : >"$T/timesync/synchronized"
        printf 'mode=last\nkind=url\ntarget=https://radio.cliamp.stream/lofi/stream\n' >"$T/data/streamer/state"
        if STREAMER_TIME_SYNC_FLAG="$T/timesync/synchronized" \
            "$T/streamer-play" >"$T/logs/s16b" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s16b"; player
        socket_off; rm -rf "$T/timesync"
        ck_eq "the boot ends cleanly" "$rc" "0"
        ck_eq "playing" "$(jstr state)" "playing"
        ck_not "no wait and no warning when the clock is synced" "$T/logs/s16b" "clock not synchronized"
        # The shipped budget goes back: like the ramp steps above, a leaked
        # one-second wait would confuse the scenarios that run after this one.
        sed -i 's/^STREAMER_SYNC_WAIT=.*$/STREAMER_SYNC_WAIT=30/' "$T/streamer.conf" ;;
    17) note "17. the LAN control server: token-guarded, and every playback path goes through the sanctioned writers"
        reset
        # build.sh and the payload have to agree on the interpreter, from both
        # ends: the build refuses a python3 unit if the base image has no
        # python3, and nothing here may enable a unit the image never installs.
        ck_in "the build cross-checks every unit's interpreter against the base image" \
            "$BUILD" 'runs python3, which this base image does not ship'
        ck_in "the build enables the control unit at boot" \
            "$BUILD" 'enable streamer-http.service   streamer.target'
        ck_in "streamer.conf carries the port and token knobs" \
            "$T/streamer.conf" "STREAMER_HTTP_TOKEN="
        # Packaging, without listening: the config the server would run with.
        no_listen=$(STREAMER_HTTP_TEST_NO_LISTEN=1 "$T/streamer-http" 2>&1); rc=$?
        ck_eq "it reads its knobs from streamer.conf without a listen" "$rc" "0"
        ck_has "it takes the port from the config" "$no_listen" "port=8077"
        ck_has "it takes the token path from the config" \
            "$no_listen" "token=$T/data/streamer/http.token"
        ck_not "the no-listen pass does not create the token file" \
            "$T/data/streamer/http.token" "x"
        # A stand-in player that speaks the same IPC V2 as the real daemon, so
        # the checks below are about this server's behaviour, not about whether
        # json.loads happened to work.
        ipc_start
        http_start
        ck_eq "no token: the API says no" "$(http_code GET /api/status)" "401"
        ck_eq "the page itself needs no token (the token arrives in the URL)" \
            "$(http_code GET /)" "200"
        ck_eq "once running, it has made the token" "$([ -f "$T/data/streamer/http.token" ] && echo y)" "y"
        ck_eq "the token file is readable only by its owner" \
            "$(stat -c %a "$T/data/streamer/http.token")" "600"
        tk=$(cat "$T/data/streamer/http.token")
        ck_has "with the token, the player's state comes back" \
            "$(http GET /api/status)" '"state":"stopped"'
        ck_has "the boot intent rides along, read from the appliance state file" \
            "$(http GET /api/status)" '"intent":{'
        ck_has "pause reaches the player over IPC" \
            "$(http POST /api/op/pause '{}')" '"ok":true'
        ck_eq "the player really paused" "$(jstr state)" "paused"
        ck_has "toggle came back playing, over the same socket" \
            "$(http POST /api/op/toggle '{}'; http GET /api/status)" '"state":"playing"'
        ck_has "a level set from the phone lands on the player" \
            "$(http POST /api/op/volume '{"value":-12}'; http GET /api/status)" '"volume":-12'
        ck_in "and it is the level the next boot will start at" \
            "$T/data/streamer/state" "volume=-12"
        # Browsing a provider the TUI reached for: Tidal over HTTP is the whole
        # reason this server exists next to the widget.
        ck_has "the provider list names Tidal" "$(http GET /api/providers)" '"key":"tidal"'
        ck_has "Tidal's playlists list over the API" \
            "$(http GET '/api/playlists?provider=tidal')" '"name":"Toni"'
        ck_has "Tidal search over the API" \
            "$(http GET '/api/search?provider=tidal&q=jamiroquai')" '"artist":"Jamiroquai"'
        # The fake, like the real daemon, keeps a provider job queued for a
        # couple of polls. A poller that spins without waiting or times out
        # in milliseconds passes every content check here and only fails on
        # the card, where a 50-track Tidal load takes tens of seconds. So
        # two queued answers must cost the caller at least a second.
        t0=$(date +%s%N)
        http GET '/api/search?provider=tidal&q=sting' >/dev/null
        t1=$(date +%s%N)
        ck "the job poller waits between checks instead of giving up at once" \
            "[ $(( (t1 - t0) / 1000000 )) -ge 900 ]"
        ck_has "an album search hit loads as an album, not as one file" \
            "$(http POST /api/play '{"track":{"title":"x","path":"tidal://album/1","provider_meta":{"albumID":"1","kind":"album"}}}')" '"ok":true'
        ck_eq "through provider.load_album, with the provider and the album id" \
            "$(grep -c '^provider.load_album {"provider":"tidal","album":"1"}' "$T/ipc.log")" "1"
        ck_has "a real track row plays through the player's own track.play" \
            "$(http POST /api/play '{"track":{"title":"y","path":"tidal://track/9","stream":true,"provider_meta":{"tidal.id":"9"}}}')" '"ok":true'
        ck_eq "the player was asked for that exact row, once" \
            "$(grep -c '^track.play ' "$T/ipc.log")" "1"
        ck_has "a listed playlist loads through provider.load" \
            "$(http POST /api/load/playlist '{"provider":"tidal","id":"pl-1"}')" '"ok":true'
        ck_eq "provider.load carried the provider and the list id" \
            "$(grep -c '^provider.load {"provider":"tidal","playlist":"pl-1"}' "$T/ipc.log")" "1"
        ck_in "that tap is what the next boot will load, as a provider target" \
            "$T/data/streamer/state" "kind=provider"
        ck_in "with its provider named" "$T/data/streamer/state" "provider=tidal"
        ck_in "and its list id" "$T/data/streamer/state" "target=pl-1"
        ck_not "and recording it did not restart the boot sequence under the music" \
            "$T/systemctl" "restart streamer-play.service"
        # Boot intent is the part with consequences, so the guards are checked
        # in both directions: the sanctioned path, and the rejections around it.
        ck_has "a station set from the phone writes the boot intent" \
            "$(http POST /api/intent '{"kind":"station","target":"http://station.example/s"}')" '"ok":true'
        ck_eq "the intent file says the new station plays next boot" \
            "$(sed -n 's/^target=//p' "$T/data/streamer/state")" "http://station.example/s"
        ck_in "and it restarts playback through the ramp path, not around it" \
            "$T/systemctl" "restart streamer-play.service"
        ck_has "the status call now shows the new station as next boot's target" \
            "$(http GET /api/status)" "station.example/s"
        ck_eq "a non-http station target is refused before anything is written" \
            "$(http_code POST /api/intent '{"kind":"station","target":"file:///etc/passwd"}' "$tk")" "400"
        ck_eq "the intent file did not move" \
            "$(sed -n 's/^target=//p' "$T/data/streamer/state")" "http://station.example/s"
        ck_eq "a non-http url.load is refused too" \
            "$(http_code POST /api/load/url '{"url":"javascript:alert(1)"}' "$tk")" "400"
        ck_eq "and with no token at all it is refused before even that" \
            "$(http_code POST /api/intent '{"kind":"mode","target":"stop"}')" "401"
        ck_has "the boot mode toggles through the streamer command as well" \
            "$(http POST /api/intent '{"kind":"mode","target":"stop"}')" '"ok":true'
        ck_eq "mode=stop is what the state file says now" \
            "$(sed -n 's/^mode=//p' "$T/data/streamer/state")" "stop"
        http_stop; ipc_off ;;
    18) note "18. a provider playlist whose network has not arrived yet"
        reset; socket_on
        # The card's own failure, 2026-11-18: DHCP's lease landed at 02:27:51
        # and provider.load was asked for at 02:27:43, so cliamp had no route to
        # refresh Tidal's session with and answered "sign-in required". A
        # provider target is a bare playlist id with no hostname in it, which is
        # why the name-resolution wait never applied to it.
        sed -i 's/^STREAMER_NET_WAIT=.*$/STREAMER_NET_WAIT=2/' "$T/streamer.conf"
        printf 'mode=last\nkind=provider\ntarget=pl-42\nprovider=tidal\nvolume=-9\n' >"$T/data/streamer/state"
        # The lease lands half a second into the boot.
        touch "$T/net-down"; ( sleep 0.5; rm -f "$T/net-down" ) >/dev/null 2>&1 &
        if "$T/streamer-play" >"$T/logs/s18a" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s18a"; player
        echo "  route asked for: $(wc -l <"$T/ip.log") times"
        ck_eq "a lease that arrives late does not fail the boot" "$rc" "0"
        ck "it asked more than once, so it waited rather than guessed" \
            "[ $(wc -l <"$T/ip.log") -gt 1 ]"
        ck_eq "the provider playlist is playing" "$(jrow 0)" "pl-42: row 0"
        ck_eq "at the level that was saved" "$(jnum volume)" "-9"
        ck_not "a boot that got there wrote no failure" "$T/data/streamer/boot.log" "FAIL"
        ck_in "the one line it did write is the play" "$T/data/streamer/boot.log" "OK provider pl-42"
        # And it said so while it waited: the journal here is volatile, so a
        # boot that spent four seconds without a route is only findable
        # afterwards if the waiting leaves a line of its own.
        ck_in "the journal says it was waiting for a route" "$T/logs/s18a" "network not up yet"
        ck_in "and boot.log says so too, once" "$T/data/streamer/boot.log" "WARN network not up"
        ck_eq "once, not once per probe" \
            "$(grep -c "WARN network not up" "$T/data/streamer/boot.log")" "1"
        # No network at all, the other half: it has to stop, inside the budget it
        # was given, and without ever asking the player for something the player
        # could not have fetched.
        rm -f "$T/state.json" "$T/player.log" "$T/ip.log" "$T/data/streamer/boot.log"
        "$T/bin/cliamp" --default-state >"$T/state.json"
        touch "$T/net-down"
        if "$T/streamer-play" >"$T/logs/s18b" 2>&1; then rc=0; else rc=$?; fi
        sed 's/^/  /' "$T/logs/s18b"
        socket_off
        ck_eq "with no network the boot fails" "$rc" "1"
        ck_eq "inside the seconds it was given, not one more" \
            "$(wc -l <"$T/ip.log")" "$((2 * 4 + 1))"
        ck_in "boot.log says what was missing" \
            "$T/data/streamer/boot.log" "FAIL no network route for provider pl-42"
        ck_in "after first saying it had waited" "$T/logs/s18b" "network not up yet"
        ck_not "and it never asked the player for the playlist" \
            "$T/player.log" "provider.load" ;;
    19) note "19. the durable log under several writers at once: a boot that keeps failing logs over its own earlier attempts"
        # A boot that fails is tried again by systemd every RestartSec, and the
        # attempts overlap: each one writes boot.log while a previous one is
        # still writing. The helper appends and then trims the file to a window,
        # so the question is what two such helpers do to each other. On the card
        # 2026-11-18, after a boot looped on a provider with no network, the
        # answer was 384 NUL bytes in the middle of the log where two lines used
        # to be: a trim had renamed a short file over the log under a writer that
        # was still appending at its old offset.
        reset; socket_on
        sed -i 's/^STREAMER_BOOTLOG_KEEP=.*$/STREAMER_BOOTLOG_KEEP=8/' "$T/streamer.conf"
        echo "-- 200 writers at one time into a window of 8"
        for i in $(seq 1 200); do "$T/streamer-bootlog" "event $i" & done
        wait
        echo "  kept: $(wc -l <"$T/data/streamer/boot.log") lines, \
$(wc -c <"$T/data/streamer/boot.log") bytes, \
$(tr -dc '\000' <"$T/data/streamer/boot.log" | wc -c) NUL bytes"
        sed 's/^/  /' "$T/data/streamer/boot.log"
        ck_eq "the window holds, however many writers collide" \
            "$(wc -l <"$T/data/streamer/boot.log")" "8"
        ck_eq "not one NUL byte in it, which is what an unlocked trim leaves behind" \
            "$(tr -dc '\000' <"$T/data/streamer/boot.log" | wc -c)" "0"
        ck_eq "and every kept line is a whole line, not a fragment of two" \
            "$(grep -c '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9:]*Z event [0-9]*$' \
                "$T/data/streamer/boot.log")" "8"
        ck_eq "the log is still readable as a log" \
            "$("$T/streamer" boots | grep -c "event ")" "8"
        ck_eq "a helper that only logs leaves nothing but the log behind" \
            "$(find "$T/data" -name 'boot.log*' | wc -l)" "1"
        # Ownership is the part that cannot be enacted in a sandbox with one
        # user. What can be tested is that the writer asks for it: the log is
        # written both by the service, as pi, and by a `streamer` command typed
        # over SSH, as root, and whichever came first owns the file.
        ck_in "it puts the log back in the boot user's hands, if it can" \
            "$T/chown.log" "pi:pi $T/data/streamer/boot.log"
        echo "-- and one writer, the ordinary case, still keeps the window"
        for i in 1 2 3; do "$T/streamer-bootlog" "solo $i"; done
        ck_eq "three more events leave the same window, oldest gone" \
            "$(wc -l <"$T/data/streamer/boot.log")" "8"
        ck_in "the newest event is in it" "$T/data/streamer/boot.log" "solo 3"
        ck_eq "the oldest of the collisions is not" \
            "$(grep -c " event 1$" "$T/data/streamer/boot.log")" "0"
        # The other half of the same device lesson: the log had been made
        # unreadable-by-the-boot-user by a root SSH session, and the service's
        # lines stopped coming. With one user in the sandbox the ownership cannot
        # be enacted, but a file the writer cannot write can be: mode 444 takes
        # the same path, and the helper has to come back with the log working,
        # the lines it could read kept, and no complaint on stderr.
        echo "-- then the log is closed to the writer, as a root session left it"
        chmod 444 "$T/data/streamer/boot.log"
        "$T/streamer-bootlog" "after the lockout" 2>"$T/logs/s19perm"
        echo "  stderr: $(sed 's/^/  /' "$T/logs/s19perm")"
        ck_eq "it makes no noise about not being able to write" \
            "$(wc -l <"$T/logs/s19perm")" "0"
        ck_in "its line still lands" "$T/data/streamer/boot.log" "after the lockout"
        ck_in "and the line it could read of the old one is kept" \
            "$T/data/streamer/boot.log" "solo 3"
        ck_eq "the log is writable again, and only the log is there" \
            "$([ -w "$T/data/streamer/boot.log" ] && echo w)$(find "$T/data" -name 'boot.log*' | wc -l)" "w1"
        # Where the rewrite is not possible - no directory to write in at all -
        # the only thing left to get right is silence. Two redirects make that a
        # matter of their order: a redirect the shell cannot open is reported at
        # the point in the list where it fails, so a `9>>` that comes before the
        # 2>/dev/null speaks to whoever is watching. On the card that was 210
        # messages in the journal from one boot.
        echo "-- and a log with nowhere to be created at all"
        install -d "$T/data/ro"
        chmod 555 "$T/data/ro"
        sed -i "s#^STREAMER_BOOTLOG=.*#STREAMER_BOOTLOG=$T/data/ro/gone/boot.log#" "$T/streamer.conf"
        "$T/streamer-bootlog" "into a closed directory" 2>"$T/logs/s19ro"
        ck_eq "it succeeds, because a log that cannot be written must not fail a boot" \
            "$?" "0"
        ck_eq "and it keeps the complaint to itself" \
            "$(wc -l <"$T/logs/s19ro")" "0"
        chmod 755 "$T/data/ro" ;;

    20) note "20. the tool that breaks the payloads on purpose: its own guards"
        # tests/mutation-check.py rewrites the payload files, so two of its
        # guards are worth checking here, in a tenth of a second, rather than
        # only inside a nine-minute sweep: the anchor pass it runs before
        # breaking anything, and the journal it keeps in case the sweep is
        # killed between writing and restoring. The second one is not
        # hypothetical: a journal left by a sweep that died in an earlier
        # session once restored a payload over a newer version of itself, which
        # quietly undid work and read, for a confusing while, as five typos in
        # the mutation list.
        python3 - "$T" >"$T/logs/meta" 2>&1 <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("mc", "tests/mutation-check.py")
mc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mc)

# The anchor pass, against the real definitions and the real payloads: an anchor
# that occurs twice mutates the wrong line, and an anchor that occurs nowhere
# tests nothing while still reporting a verdict.
print("preflight problems: %d" % mc.preflight())

tmp = pathlib.Path(sys.argv[1]) / "meta"
tmp.mkdir(parents=True, exist_ok=True)

# The same pass, aimed at three definitions that are known to be wrong, so the
# count is the thing being checked and not merely the absence of a complaint.
mc.ROOT = tmp
(tmp / "pay.sh").write_text("X\nX\nY\n")
(tmp / "tests").mkdir(exist_ok=True)
(tmp / "tests/appliance-scripts.sh").write_text('ck "the one label that exists" x y\n')
mc.MUTATIONS = [
    ("points at two places", "pay.sh", "X\n", "Z\n", "the one label that exists"),
    ("points at no place", "pay.sh", "Q\n", "Z\n", "the one label that exists"),
    ("has no check to notice it", "pay.sh", "Y\n", "Z\n", "a label nothing carries"),
]
mc.JOURNAL = tmp / "journal"
print("planted problems: %d" % mc.preflight())

# The journal, against the same scratch tree: nothing here may touch the payloads.
(tmp / "pay.sh").write_text("A\nC\n")          # the damage is still sitting there
mc.JOURNAL.write_text("pay.sh\ndrop a line\nA\nB\nC\n")
mc.MUTATIONS = [("drop a line", "pay.sh", "B\n", "", "the one label that exists")]
mc.recover()
print("matching journal undone: %s" % ((tmp / "pay.sh").read_text() == "A\nB\nC\n"))
print("journal left behind: %s" % mc.JOURNAL.exists())

(tmp / "pay.sh").write_text("A\nB\nC\nD\n")    # the file has moved on since
mc.JOURNAL.write_text("pay.sh\ndrop a line\nA\nB\nC\n")
mc.recover()
print("stale journal left the newer file: %s" % ((tmp / "pay.sh").read_text() == "A\nB\nC\nD\n"))
print("journal left behind again: %s" % mc.JOURNAL.exists())
PY
        sed 's/^/  /' "$T/logs/meta"
        ck_eq "every mutation names one line of a payload, and a check owns its label" \
            "$(grep 'preflight problems:' "$T/logs/meta")" "preflight problems: 0"
        ck_eq "the anchor pass reports a doubled anchor, a missing anchor, and an unowned label" \
            "$(grep 'planted problems:' "$T/logs/meta")" "planted problems: 3"
        ck_in "a journal that describes damage still in the file is undone" \
            "$T/logs/meta" "matching journal undone: True"
        ck_in "the journal it used is consumed, not kept" \
            "$T/logs/meta" "journal left behind: False"
        ck_in "a journal from an older run cannot overwrite the file as it is now" \
            "$T/logs/meta" "stale journal left the newer file: True"
        ck_in "it says which journal it threw away, rather than fixing it silently" \
            "$T/logs/meta" "discarded rather than applied"
        ck_in "and that journal is consumed too" \
            "$T/logs/meta" "journal left behind again: False" ;;
    esac
    log_tail
}

echo "sandbox: $T"
if [ $# -gt 0 ]; then
    for n in "$@"; do run "$n"; done
else
    for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do run "$n"; done
fi

printf '\n%d checks, %d failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
