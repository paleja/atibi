"""The appliance knobs: one file, one parser.

/etc/streamer.conf stays shell-sourced text while streamer-play and streamer-daemon
are still /bin/sh, so this reads the same key=value lines the shell would expand.
Every knob a payload script needs is a field here: a missing or mistyped knob is
an error naming it, never a silent default that turns into a quiet speaker.
"""

import os
import re

CONF_PATH = "/etc/streamer.conf"

_KNOB = re.compile(r'\A([A-Z_][A-Z0-9_]*)=("[^"]*"|[^\s#]*)')


class KnobError(Exception):
    pass


def read(path=CONF_PATH):
    """The knobs as text. A missing file is empty knobs, which the typed reader
    below turns into a named error rather than a guess."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        lines = []
    knobs = {}
    for line in lines:
        hit = _KNOB.match(line.strip())
        if hit:
            knobs[hit.group(1)] = hit.group(2).strip('"')
    data = knobs.get("STREAMER_DATA", "/data")
    for name, value in knobs.items():
        knobs[name] = value.replace("$STREAMER_DATA", data)
    return knobs


class Config:
    """Typed view of the knobs, with the paths derived from STREAMER_DATA.

    The socket and the cliamp binary come from the environment the units set
    (HOME=/home/pi) or from the same-named override the harness sets; everything
    else is a knob.
    """

    def __init__(self, path=CONF_PATH):
        self.path = path
        knobs = read(path)

        def need(name, cast=str):
            if name not in knobs:
                raise KnobError("%s has no %s" % (path, name))
            try:
                return cast(knobs[name])
            except ValueError:
                raise KnobError("%s: %s=%r is not a %s"
                                % (path, name, knobs[name],
                                   cast.__name__)) from None

        def derived(name, default):
            return knobs.get(name) or default

        self.data = need("STREAMER_DATA")
        self.seed = need("STREAMER_SEED")
        self.user = need("STREAMER_USER")
        self.group = need("STREAMER_GROUP")
        self.state_path = derived("STREAMER_STATE", self.data + "/streamer/state")
        self.bootlog = derived("STREAMER_BOOTLOG", self.data + "/streamer/boot.log")
        self.bootlog_keep = need("STREAMER_BOOTLOG_KEEP", int)

        self.start_kind = need("STREAMER_START_KIND")
        self.start_target = need("STREAMER_START_TARGET")
        self.providers = need("STREAMER_PROVIDERS").split()
        self.station_list = need("STREAMER_STATION_LIST")
        self.radio_size = need("STREAMER_RADIO_SIZE", int)
        self.radio_providers = need("STREAMER_RADIO_PROVIDERS").split()
        self.tidal_cred = derived("STREAMER_TIDAL_CRED",
                                  self.data + "/cliamp/tidal_credentials.json")

        self.vol_floor = need("STREAMER_VOL_FLOOR", float)
        self.vol_target = need("STREAMER_VOL_TARGET", float)
        self.vol_max = need("STREAMER_VOL_MAX", float)

        # The boot budget is 10 s to the first sample, so every wait in the
        # boot entry is bounded by a knob rather than by a systemd timeout.
        self.socket_wait = need("STREAMER_SOCKET_WAIT", float)
        self.play_wait = need("STREAMER_PLAY_WAIT", float)
        self.net_wait = need("STREAMER_NET_WAIT", float)
        self.sync_wait = need("STREAMER_SYNC_WAIT", float)
        self.clock_flag = derived("STREAMER_TIME_SYNC_FLAG",
                                  "/run/systemd/timesync/synchronized")
        self.ramp_start = need("STREAMER_RAMP_START", float)
        self.ramp_step = need("STREAMER_RAMP_STEP", float)
        self.ramp_delay = need("STREAMER_RAMP_DELAY", float)
        self.ramp_max_steps = need("STREAMER_RAMP_MAX_STEPS", int)

        self.http_port = need("STREAMER_HTTP_PORT", int)
        self.http_token = derived("STREAMER_HTTP_TOKEN",
                                  self.data + "/streamer/http.token")

        self.socket_path = os.environ.get(
            "STREAMER_CLIAMP_SOCKET") or os.path.join(
                os.environ.get("HOME", ""), ".config", "cliamp", "cliamp.sock")
        self.cliamp = os.environ.get("STREAMER_CLIAMP_EXECUTABLE",
                                     "/usr/local/bin/cliamp")

    def as_string(self):
        """For `streamer`' own diagnostics: where the knobs came from."""
        return self.path
