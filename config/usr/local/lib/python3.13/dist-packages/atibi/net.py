"""The waits a boot pays before it spends a load call.

Journald is volatile here and the boot budget is 10 s, so a wait is bounded,
says once what it is waiting for, and fails with a line in boot.log rather
than by timing out in systemd. The checks are cheap commands the image
already ships.
"""

import os
import re
import subprocess

from atibi import save

HOST_OF = re.compile(r"\A[a-z][a-z0-9-]*://([^/:]+)")
CLOCK_FLAG = "/run/systemd/timesync/synchronized"
INET = re.compile(r"\binet ([0-9.]+)/([0-9]+)")
NAMESERVER = re.compile(r"\Anameserver ([0-9.]+)")
# The kernel's own words for how an address was obtained.
DEFAULT = re.compile(r"\Adefault via ([0-9.]+) dev ([a-z0-9]+)")
PROTO = re.compile(r"\bproto ([a-z]+)")


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


def _words(command):
    """A cheap command's answer as text; "" when it is missing or refused."""
    try:
        answer = subprocess.run(command, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return ""
    return answer.stdout if answer.returncode == 0 else ""


def resolver():
    """The address names are resolved through, as resolv.conf says."""
    try:
        with open("/etc/resolv.conf", encoding="utf-8") as handle:
            for line in handle:
                hit = NAMESERVER.match(line)
                if hit:
                    return hit.group(1)
    except OSError:
        return ""
    return ""


def lease():
    """eth0's numbers, and which of the two paths gave them.

    Read from the kernel rather than from NetworkManager's own view, because
    this is what the boot's wait and the boot.log line have to agree with.
    The default route carries the answer in its `proto` word: `dhcp` means a
    DHCP server was consulted for that address, `static` means a profile was.
    """
    out = {"iface": "eth0", "address": "", "prefix": "", "gateway": "",
           "dns": "", "source": ""}
    default = _words(("ip", "-4", "route", "show", "default"))
    hit = DEFAULT.search(default)
    if hit:
        out["gateway"], out["iface"] = hit.group(1), hit.group(2)
    hit = PROTO.search(default)
    if hit:
        out["source"] = hit.group(1)
    for line in _words(("ip", "-4", "addr", "show",
                        out["iface"])).splitlines():
        hit = INET.search(line)
        if hit:
            out["address"], out["prefix"] = hit.group(1), hit.group(2)
            break
    out["dns"] = resolver()
    return out


def profile(numbers):
    """Those numbers as the file that pins them.

    A system-connection file, not a conf.d section: this NetworkManager 1.52
    answers "unknown key" for ipv4.method and friends inside a
    [connection-...] section and reads them here (checked 2026-11-22). `manual`
    is the word that stops the DHCP request - NM has no method called `static`
    - so the boot never waits for a DHCP server to answer, and `dns=` is
    carried so names resolve from the profile rather than from a server's
    reply.
    """
    return ("[connection]\n"
            "id=atibi\n"
            "type=ethernet\n"
            "interface-name=%s\n"
            "\n"
            "[ipv4]\n"
            "method=manual\n"
            "address=%s/%s\n"
            "gateway=%s\n"
            "dns=%s\n"
            % (numbers["iface"], numbers["address"], numbers["prefix"],
               numbers["gateway"], numbers["dns"]))


def write(path, numbers, user="", group=""):
    """Save those numbers where atibi-static reads them at the next boot.

    save() writes it whole and closes it to the appliance account, which is
    what makes a hand edit with `atibi rw` possible.
    """
    return save(path, profile(numbers), user, group)


def clear(path):
    """Forget them: a DHCP server answers for the interface again."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return True
