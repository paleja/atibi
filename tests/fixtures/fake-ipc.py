#!/usr/bin/env python3
"""Fake cliamp IPC V2 server for the appliance test harness.

Models what the real daemon actually does, verified against cliamp 2.4.1 on
the card, because the shape of the replies is exactly the kind of thing an
HTTP layer gets wrong:

  * method calls (state.get) answer inline, with a "snapshot" object;
  * operation.submit answers with a "job" object that is already "succeeded"
    for everything cheap, carrying its own "result";
  * provider.search/playlists results only ever arrive inside a job.

State (play/pause/volume/playlist) persists across requests, so the harness
can read back what the server under test really asked the player to do.
Every operation.submit is appended to <dir>/ipc.log as
"<operation> <params-json>", so ordering and exact params are checkable.

usage: fake-ipc.py <socket path> [state file]   (blocks; SIGTERM to stop)
"""
import json
import os
import signal
import socket
import sys
import threading

SOCK = sys.argv[1]
D = os.path.dirname(os.path.abspath(SOCK))
STATE = sys.argv[2] if len(sys.argv) > 2 else os.path.join(D, "state.json")
PIDFILE = sys.argv[3] if len(sys.argv) > 3 else ""
LOG = sys.argv[4] if len(sys.argv) > 4 else os.path.join(D, "ipc.log")

STATIONS = ["https://one.example/stream", "https://two.example/stream"]


def load():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {"state": "playing", "volume": -25, "index": 1,
                "playlist": "tidal:Toni", "position": 12.0,
                "queue": [{"title": "Row One", "artist": "Someone"},
                          {"title": "Row Two", "artist": "Someone Else"}]}


def save(d):
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, separators=(",", ":"))
    os.replace(tmp, STATE)


def snapshot(d):
    return {"revision": 1, "state": d["state"], "track": d["queue"][d["index"]],
            "position": d.get("position", 0), "seekable": False,
            "volume": d["volume"], "playlist": d.get("playlist", ""),
            "index": d["index"], "total": len(d["queue"])}


def providers():
    return {"ok": True, "providers": [
        {"key": "radio", "name": "Radio", "searchable": True, "catalog": True},
        {"key": "local", "name": "Local", "searchable": True},
        {"key": "tidal", "name": "Tidal", "searchable": True,
         "browse_albums": True}]}


def playlists():
    return {"ok": True, "total": 2, "playlists": [
        {"id": "favorites/tracks", "name": "Favorite Tracks",
         "provider": "tidal", "section": "Library"},
        {"id": "pl-1", "name": "Toni", "provider": "tidal",
         "section": "Your playlists", "track_count": 50}]}


def search():
    return {"ok": True, "total": 1, "tracks": [
        {"title": "Travelling Without Moving", "artist": "Jamiroquai",
         "album": "Travelling Without Moving",
         "path": "tidal://album/117160041"}]}


def apply_op(op, params, d):
    """Mutate the fake's state the way the real player would. Returns the
    result object for the job."""
    if op == "play":
        d["state"] = "playing"
    elif op == "pause":
        d["state"] = "paused"
    elif op == "toggle":
        d["state"] = "paused" if d["state"] == "playing" else "playing"
    elif op == "stop":
        d["state"] = "stopped"
    elif op == "next":
        d["index"] = min(d["index"] + 1, len(d["queue"]) - 1)
    elif op == "prev":
        d["index"] = max(d["index"] - 1, 0)
    elif op == "volume":
        v = float(params.get("value", d["volume"]))
        d["volume"] = int(v) if v.is_integer() else v
    elif op == "provider.load":
        d["playlist"] = "%s:%s" % (params.get("provider"), params.get("playlist"))
        d["index"] = 0
    elif op in ("url.load", "track.play"):
        d["index"] = 0
        d["state"] = "playing"
    elif op == "queue.list":
        return {"ok": True, "tracks": d["queue"]}
    return {"ok": True}


def handle(conn):
    f = conn.makefile("rwb")
    for raw in f:
        try:
            req = json.loads(raw)
        except ValueError:
            continue
        d = load()
        method = req.get("method")
        id_hint = req.get("id", "")
        if method == "state.get":
            reply = {"version": 2, "id": id_hint, "ok": True,
                     "snapshot": snapshot(d)}
        elif method == "operation.submit":
            params = req.get("params", {}) or {}
            op = params.get("operation", "")
            with open(LOG, "a", encoding="utf-8") as lg:
                lg.write("%s %s\n" % (op, json.dumps(params.get("params", {}),
                                                     separators=(",", ":"))))
            result = apply_op(op, params.get("params", {}) or {}, d)
            save(d)
            if op == "provider.list":
                result = providers()
            elif op == "provider.playlists":
                result = playlists()
            elif op == "provider.search":
                result = search()
            job = {"id": "job1", "operation": op, "state": "succeeded",
                   "result": result}
            reply = {"version": 2, "id": id_hint, "ok": True, "job": job,
                     "snapshot": snapshot(d)}
        else:
            reply = {"version": 2, "id": id_hint, "ok": False,
                     "error": "fake: no such method %r" % method}
        f.write((json.dumps(reply, separators=(",", ":")) + "\n").encode())
        f.flush()


def main():
    # A listener left behind by a killed harness run owns the socket, and two
    # fakes answering one port makes every later check meaningless. The
    # harness's pidfile is how we find and evict the old one before binding.
    if PIDFILE and os.path.exists(PIDFILE):
        try:
            os.kill(int(open(PIDFILE).read().strip()), signal.SIGKILL)
        except (ValueError, ProcessLookupError):
            pass
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(SOCK)
    s.listen(8)
    if PIDFILE:
        with open(PIDFILE, "w", encoding="utf-8") as f:
            f.write(str(os.getpid()) + "\n")
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
