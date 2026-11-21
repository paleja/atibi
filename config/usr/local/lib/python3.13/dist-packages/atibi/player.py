"""The player, as the appliance needs it: what is loaded, what level it is at,
and how to bring one target up.

The operation names are cliamp 2.4.1's own, read off `cliamp remote capabilities`
on the card (2026-11-21), and each kind needs its own because they reach the
service in different ways: a list saved on the card is a file `load` resolves, a
streaming-service list is fetched by id, an album is expanded into rows first,
and a single track row is sent whole because there is no fetch-a-track-by-id.

Failure messages come out in the words boot.log and `atibi boots` show, so
they name the operation that refused, the target, and what the daemon said:
"sign-in required" means the DHCP lease had not landed yet, and a TLS failure
means the cold-boot clock is behind NTP.
"""

import json
import subprocess

from atibi.ipc import IpcError


class PlayerError(Exception):
    """What the player refused, in its words."""


def track_row(provider, track_id, triple=()):
    """The row for one provider track: path plus the id in provider_meta, which
    is all 2.4.1 accepts for a track it has not been given.

    The display strings ride along because a row rebuilt from an id alone would
    show the wrong words under "now playing". Empty strings are left out
    rather than written empty: the daemon keeps its own title for a row it
    resolves itself, and an empty one is not a claim about a track.
    """
    title, artist, album = (list(triple) + ["", "", ""])[:3]
    row = {"path": "%s://track/%s" % (provider, track_id),
           "stream": True,
           "provider_meta": {"%s.id" % provider: track_id}}
    for key, value in (("title", title), ("artist", artist), ("album", album)):
        if value:
            row[key] = value
    return row


class Player:
    """Everything the appliance asks of the daemon, over one transport.

    `ipc` speaks version 2 to the socket; `cliamp` is only the CLI, and only
    for the level, which no v2 operation answers.
    """

    def __init__(self, ipc, cliamp="/usr/local/bin/cliamp"):
        self.ipc = ipc
        self.cliamp = cliamp

    def snapshot(self):
        return self.ipc.snapshot()

    def state(self):
        return self.snapshot().get("state", "unknown")

    def transport(self, operation, params=None):
        """pause, play, toggle, next, prev, stop: the transport, nothing else."""
        try:
            self.ipc.op(operation, params)
        except IpcError as exc:
            raise PlayerError("%s: %s" % (operation, exc)) from exc

    def level(self):
        """The player's dB, or None when it said nothing usable.

        Not over IPC: no v2 operation answers the level - checked on the card
        2026-11-21, `remote state` carries 20 keys with no volume among them,
        and the volume operations reply with a snapshot that omits it - so it
        comes from `cliamp status --json`, which pretty-prints and may repeat
        a key; json.loads keeps the last one, which is the live value.
        """
        try:
            answer = subprocess.run([self.cliamp, "status", "--json"],
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL,
                                    universal_newlines=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return None
        try:
            status = json.loads(answer.stdout)
        except ValueError:
            return None
        value = status.get("volume")
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return float(value)

    def set_level(self, db):
        """One absolute dB. cliamp clamps to the volume_min in
        /data/cliamp/config.toml and to +6, so the caller reads back what it
        settled at rather than assuming its number."""
        try:
            self.ipc.op("volume", {"value": db})
        except IpcError as exc:
            raise PlayerError("volume %s: %s" % (db, exc)) from exc

    def adjust_level(self, db):
        """One relative step, for the ramp: the climb is measured in steps
        because a jump is what the amp's relay could not absorb."""
        try:
            self.ipc.op("volume.adjust", {"value": db})
        except IpcError as exc:
            raise PlayerError("volume.adjust %s: %s" % (db, exc)) from exc

    def load(self, kind, target, provider="", triple=(), revision=None):
        """Load `target`, and report the row it landed on where the player says
        one. A target the daemon cannot reach is a PlayerError naming the
        operation and the target: on the card that distinction is the whole
        value of the line, because it says whether to sign in, wait for a
        route, or fix the record.
        """
        params = {}
        if revision is not None:
            params["if_revision"] = revision
        try:
            if kind in ("url", "stream", "file"):
                params.update({"path": target, "play": True})
                self.ipc.op("url.load", params)
                return 0
            if kind == "playlist":
                params.update({"playlist": target})
                self.ipc.op("load", params)
                return 0
            if kind == "provider":
                if not provider:
                    raise PlayerError("provider.load %s: kind=provider with no"
                                      " provider named in the record" % target)
                params.update({"provider": provider, "playlist": target})
                self.ipc.op("provider.load", params)
                return 0
            if kind == "album":
                if not provider:
                    raise PlayerError("provider.load_album %s: kind=album with no"
                                      " provider named in the record" % target)
                params.update({"provider": provider, "album": target})
                self.ipc.op("provider.load_album", params)
                return 0
            if kind == "track":
                if not provider:
                    raise PlayerError("track.play %s: kind=track with no"
                                      " provider named in the record" % target)
                result = self.ipc.op(
                    "track.play",
                    dict(params, track=track_row(provider, target, triple)))
                index = result.get("index")
                return int(index) if isinstance(index, int) else None
        except IpcError as exc:
            raise PlayerError("%s %s %s: %s" % (self.operation_for(kind),
                                                provider, target, exc)) from exc
        raise PlayerError("no way to load kind=%s" % kind)

    def operation_for(self, kind):
        return {"url": "url.load", "stream": "url.load", "file": "url.load",
                "playlist": "load", "provider": "provider.load",
                "album": "provider.load_album",
                "track": "track.play"}.get(kind, kind)

    def start(self, kind, target, provider="", triple=(), revision=None):
        """The one thing this appliance does with a target: bring it up.

        Row 0, never a remembered row - the record keeps *what*, not *where* it
        got to - and the start is asked for only if loading did not already
        begin playing, so nothing restarts a track that had already begun. The
        exception: kind=track is a row appended to whatever list the daemon
        holds, so the row track.play reported is the one to start.
        """
        row = self.load(kind, target, provider, triple, revision)
        if self.state() == "playing":
            return row
        index = row if row is not None else 0
        params = {"index": index}
        if revision is not None:
            params["if_revision"] = revision
        try:
            self.ipc.op("queue.play", params)
        except IpcError as exc:
            raise PlayerError("queue.play index=%s for %s %s: %s"
                              % (index, kind, target, exc)) from exc
        return row
