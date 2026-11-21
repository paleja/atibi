"""boot.log: the one durable record a boot leaves behind, journald is volatile.

Append and trim are one operation under a lock on the file itself: a boot that
keeps failing writes again every RestartSec, and an unlocked trim renames a fresh
file over a log another writer is still appending to. A line that cannot be
written is dropped, in silence - the card once spent 210 journal lines on the
shell complaining it could not open this file.
"""

import fcntl
import os
import time

from atibi import own

STAMP = "%Y-%m-%dT%H:%M:%SZ"


class BootLog:
    def __init__(self, path, keep, user="", group="", clock=time.time):
        self.path = path
        self.keep = keep
        self.user = user
        self.group = group
        self.clock = clock

    def note(self, text):
        """One line, stamped in UTC: the shape `atibi boots` reads back.
        False when the log could not be written. A log is never worth failing
        an operation over, but a caller may want to know it was skipped."""
        line = "%s %s\n" % (time.strftime(STAMP, time.gmtime(self.clock())),
                            " ".join(text.split()))
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        except OSError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            os.write(fd, line.encode())
            self._trim()
            return True
        except OSError:
            return False
        finally:
            os.close(fd)

    def _trim(self):
        try:
            with open(self.path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except OSError:
            return
        if len(lines) <= self.keep:
            return
        tmp = "%s.tmp.%d" % (self.path, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as handle:
                handle.write("\n".join(lines[-self.keep:]) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, 0o644)
            os.replace(tmp, self.path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return
        own(self.path, self.user, self.group)
