"""The boot: bring playback up, then ramp the level.

`/usr/local/bin/atibi-play` is a thin entry onto `Boot.run`, and that unit
is the only thing that starts audio, which is what keeps the floor and the
ramp unbypassable from the page, from the command and from a reboot.

The order is the boot budget: 10 s to the first audible sample, so every wait
here is bounded by a knob and fails with its own line in boot.log rather than
by running into systemd's timeout.
"""

import sys
import time

from atibi import net, ramp
from atibi import num
from atibi.ipc import IpcError
from atibi.player import PlayerError

FAILED, OK = 1, 0


def wait_for(check, limit, sleep, tick=0.25):
    """Poll a cheap check until it passes, up to `limit` seconds.

    The caller says what it was waiting for and what failing means, because
    only the caller knows the difference between a route and a hostname.
    """
    waited = 0.0
    while not check():
        if waited >= limit:
            return False
        sleep(tick)
        waited += tick
    return True


def level_plan(saved, floor, default, ceiling):
    """Where the ramp ends, and what to say about it.

    The level the last session left, or the configured default, clamped: the
    floor has to be the last word, so a stale level can never make the first
    sample loud. A saved level at or below the floor is a parked control, not
    a preference, so it falls back to the default and says so. The way to ask
    for a quiet box is `atibi boot off`, said out loud.
    """
    if saved is None:
        return default, ("no saved level, ramping to the default %s dB"
                         % num(default)), None
    if saved <= floor:
        return default, ("saved level %s dB is at or below the %s dB floor, treating"
                         " it as parked: ramping to %s"
                         % (num(saved), num(floor), num(default)),
                         "saved volume %s at the floor, using %s"
                         % (num(saved), num(default)))
    return min(max(saved, floor), ceiling), None, None


def num(value):
    return "%g" % value


class Boot:
    """One boot's playback, in the order the budget is spent."""

    def __init__(self, app, out=sys.stdout, sleep=time.sleep):
        self.app = app
        self.out = out
        self.sleep = sleep

    def log(self, text):
        self.app.bootlog.note(text)

    def say(self, text):
        self.out.write("%s\n" % text)

    def run(self):
        conf = self.app.conf
        fields = self.app.read_record()
        kind, target = fields["kind"], fields["target"]
        provider = fields.get("provider", "")

        if fields["mode"] == "stop":
            self.say("appliance is in stop mode, staying quiet")
            self.log("stop mode, nothing started")
            return OK
        if not target:
            self.say("nothing to play")
            self.log("FAIL no target to play")
            return FAILED

        # The daemon starts in parallel: wait for its socket, not for its unit.
        if not wait_for(self.hello, conf.socket_wait, self.sleep):
            self.say("player socket never answered: %s" % conf.socket_path)
            self.log("FAIL no cliamp socket after %ss" % num(conf.socket_wait))
            return FAILED

        # A stream needs name resolution. Rather than pulling in network-online
        # target and its two-second stall, check the one thing the target needs.
        host = net.host_of(target)
        if net.needs_network(kind, target):
            ready = (lambda: net.resolved(host)) if host else net.routed
            if not ready():
                self.say("network not up yet, waiting up to %ss %s"
                         % (num(conf.net_wait),
                            ("to resolve %s" % host if host else "for a route")))
                self.log("WARN network not up, waiting %ss for %s %s"
                         % (num(conf.net_wait), kind, target))
                if not wait_for(ready, conf.net_wait, self.sleep):
                    if host:
                        self.say("cannot resolve %s" % host)
                        self.log("FAIL cannot resolve %s for %s %s"
                                 % (host, kind, target))
                    else:
                        self.say("no route to any address after %ss"
                                 % num(conf.net_wait))
                        self.log("FAIL no network route for %s %s" % (kind, target))
                    return FAILED

        # An https target waits for the clock: a cold-boot clock behind NTP makes
        # every TLS handshake fail as "certificate is not yet valid". Bounded,
        # because with no NTP reachable the box should still try to play.
        if target.startswith("https://"):
            if not wait_for(lambda: net.clock_synced(conf.clock_flag),
                            conf.sync_wait, self.sleep, 0.5):
                self.say("clock not synchronized after %ss: https certificates"
                         " will be checked against the wrong date"
                         % num(conf.sync_wait))
                self.log("WARN clock unsynced after %ss" % num(conf.sync_wait))

        # The floor, set again even though the daemon started at it: that covers
        # a daemon that restored an old session itself and came up at its own
        # level.
        try:
            self.app.player.set_level(conf.vol_floor)
        except PlayerError as exc:
            self.say(str(exc))
            self.log("FAIL volume floor %s" % num(conf.vol_floor))
            return FAILED

        try:
            self.app.player.start(kind, target, provider,
                                   (fields.get("title", ""),
                                    fields.get("artist", ""),
                                    fields.get("album", "")))
        except (PlayerError, ValueError) as exc:
            self.say(str(exc))
            self.log("FAIL %s" % exc)
            return FAILED

        if not wait_for(lambda: self.app.player.state() == "playing",
                        conf.play_wait, self.sleep, 0.5):
            self.say("no playback within %ss (state=%s)"
                     % (num(conf.play_wait), self.app.player.state()))
            self.log("FAIL no playing state within %ss" % num(conf.play_wait))
            return FAILED

        return self.ramp(fields, conf, kind, target)

    def hello(self):
        try:
            self.app.player.snapshot()
            return True
        except IpcError:
            return False

    def ramp(self, fields, conf, kind, target):
        """Nothing jumps: the amp's relay is closed by now and a step is the one
        thing it could not absorb.
        """
        saved = fields.get("volume")
        try:
            saved = float(saved)
        except (TypeError, ValueError):
            saved = None
        level, journal, log_line = level_plan(saved, conf.vol_floor,
                                              conf.vol_target, conf.vol_max)
        if journal:
            self.say(journal)
        if log_line:
            self.log(log_line)

        self.sleep(conf.ramp_start)
        start = self.app.player.level()
        if start is None:
            start = conf.vol_floor
        now, note = ramp.climb(self.app.player, start, level, conf.ramp_step,
                               conf.ramp_delay, conf.ramp_max_steps, self.sleep)
        if note:
            self.say(note)
            self.log(note)
        self.say("playing %s:%s at %s dB (target %s dB, floor %s dB)"
                 % (kind, target, num(now), num(level), num(conf.vol_floor)))
        self.log("OK %s %s at %s dB (target %s)"
                 % (kind, target, num(now), num(level)))
        return OK
