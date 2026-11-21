"""The boot record on /data: what plays next boot and how loud.

One writer, this class. The format stays key=value with last-line-wins while
streamer-play is still /bin/sh, so a value carrying a newline is cleaned rather
than trusted: it would forge a line and with it a second answer to the same key.
"""

import fcntl
import os

from streamer import own

KEYS = ("mode", "kind", "target", "provider", "volume",
        "title", "artist", "album")


class Record:
    """A record is read as strings and written as strings; the only types that
    matter here are the ones the player's own words gave them."""

    def __init__(self, path, user="", group=""):
        self.path = path
        self.user = user
        self.group = group

    def read(self):
        """Last line wins per key. No file yet is not an error: the defaults
        belong to the caller, which knows the knobs."""
        fields = {}
        try:
            with open(self.path, encoding="utf-8") as handle:
                for line in handle:
                    key, _, value = line.partition("=")
                    if key in KEYS:
                        fields[key] = value.rstrip("\r\n")
        except OSError:
            pass
        return fields

    def commit(self, **changes):
        """Rewrite the record with these fields, and say whether anything was
        written. A field that is not named carries on what the file holds, so a
        level change cannot forget the target and a target change cannot forget
        the level. A field named with an empty value is a clear: a track chosen
        without strings must not inherit the track before it. Any kind that is
        not a single track drops the display triple: those strings describe one
        row and must not ride along to a playlist.

        Read, compare and write happen under a lock on the record, and a rewrite
        whose content would not change is not a write at all. Two writers can
        therefore be asked to record the same fact - the command sets the level
        and the daemon reports it changing a breath later - without the record
        gaining a second answer or the log a second line.

        The write is atomic and reaches the platter: this box is powered from
        the wall, so a rename that survives a cut but not its directory entry
        would be indistinguishable from a person never having made the change.
        """
        directory = os.path.dirname(self.path)
        try:
            os.makedirs(directory, exist_ok=True)
        except OSError:
            pass
        lock = os.open("%s.lock" % self.path, os.O_WRONLY | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX)
            fields = self.read()
            for key, value in changes.items():
                value = str(value).replace("\n", " ").replace("\r", "")
                if value:
                    fields[key] = value
                else:
                    fields.pop(key, None)
            if fields.get("kind") != "track":
                for key in ("title", "artist", "album"):
                    fields.pop(key, None)

            body = "".join("%s=%s\n" % (key, fields[key])
                           for key in KEYS if fields.get(key))
            try:
                with open(self.path, encoding="utf-8") as handle:
                    current = handle.read()
            except OSError:
                current = None
            if body == current:
                return False

            tmp = "%s.tmp" % self.path
            with open(tmp, "w", encoding="utf-8") as handle:
                handle.write(body)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.path)
            try:
                dirfd = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(dirfd)
                finally:
                    os.close(dirfd)
            except OSError:
                pass
            own(self.path, self.user, self.group)
            return True
        finally:
            os.close(lock)
