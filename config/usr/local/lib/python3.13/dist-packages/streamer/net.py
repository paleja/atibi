"""The waits a boot pays before it spends a load call.

Journald is volatile here and the boot budget is 10 s, so a wait is bounded,
says once what it is waiting for, and fails with a line in boot.log rather
than by timing out in systemd. The checks are cheap commands the image
already ships.
"""

import os
import re
import subprocess

HOST_OF = re.compile(r"\A[a-z][a-z0-9-]*://([^/:]+)")
CLOCK_FLAG = "/run/systemd/timesync/synchronized"


def host_of(target):
    """The hostname a target names, or the empty string for a bare id."""
    hit = HOST_OF.match(target)
    return hit.group(1) if hit else ""


def needs_network(kind, target):
    """Does this target have to reach a service somewhere?

    A hostname says yes on its own. provider playlists, albums and single
    tracks are bare ids with no hostname, yet all three are fetched across
    the network, so they answer yes too.
    """
    return bool(host_of(target)) or kind in ("provider", "album", "track")


def resolved(host):
    """Can this hostname be answered yet?"""
    try:
        answer = subprocess.run(("getent", "hosts", host),
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return False
    return answer.returncode == 0


def routed():
    """Is there a route to any address?

    Which host the service needs is cliamp's business; either way it needs a
    route and an address, which is what this answers.
    """
    try:
        answer = subprocess.run(("ip", "route", "get", "1.1.1.1"),
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
    except OSError:
        return False
    return answer.returncode == 0


def clock_synced(flag=CLOCK_FLAG):
    """Has NTP landed yet?

    A Pi has no RTC battery: after a power cut the clock starts at the image
    build date, and every TLS handshake before the first sync fails as
    "certificate is not yet valid". With no NTP reachable the box should still
    try to play, so this is waited for and not insisted on.
    """
    return os.path.exists(flag)
