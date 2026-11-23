"""The wall clock, carried across reboots through /data.

/var's own clock stamp sits on the read-only root and froze at the build
date, so every boot starts months behind until NTP lands (ADR-000).
"""

import os
import subprocess
import time

from atibi import own


def read(path):
    """The saved epoch, or None - no, torn or unreadable file are one answer."""
    try:
        with open(path, encoding="utf-8") as handle:
            value = int(handle.read().strip())
    except (OSError, ValueError):
        return None
    return value


def trusted(path, now=None):
    """The stamp exists and the clock has reached it - restored, or NTP-past.
    """
    if now is None:
        now = time.time
    saved = read(path)
    return saved is not None and now() >= saved


def keep(path, user="", group="", now=None):
    """Save the current epoch atomically; False when /data says no.
    """
    if now is None:
        now = time.time
    directory = os.path.dirname(path)
    try:
        os.makedirs(directory, exist_ok=True)
        tmp = "%s.tmp" % path
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write("%d\n" % int(now()))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
        try:
            dirfd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
        except OSError:
            pass
        own(path, user, group)
    except OSError:
        return False
    return True


def set_epoch(epoch):
    """Root-only, which is why atibi-clock is a separate unit."""
    try:
        answer = subprocess.run(("date", "-s", "@%d" % epoch),
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return False
    return answer.returncode == 0


def hand_back(path, setter=None, now=None):
    """Set the clock forward to the stamp, never backwards. Answers the epoch
    it set, or None for nothing to do - including a setter that failed.
    """
    if setter is None:
        setter = set_epoch
    if now is None:
        now = time.time
    saved = read(path)
    if saved is None or now() >= saved:
        return None
    return saved if setter(saved) else None
