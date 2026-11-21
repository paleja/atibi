"""One run's view of the appliance: the knobs, the record, the durable log and
the player, built once so no function reaches for a path of its own.

The record's writer: `save` is the only call in the library that commits, and
it writes boot.log in the same breath, because boot.log is the record that
survives a power cut and the file it describes does not.
"""

import os

from atibi.conf import CONF_PATH, Config
from atibi.ipc import Ipc
from atibi.log import BootLog
from atibi.player import Player
from atibi.state import Record


class Appliance:
    def __init__(self, conf_path=None):
        self.conf = Config(conf_path or os.environ.get("ATIBI_CONF",
                                                      CONF_PATH))
        self.record = Record(self.conf.state_path, self.conf.user, self.conf.group)
        self.bootlog = BootLog(self.conf.bootlog, self.conf.bootlog_keep,
                               self.conf.user, self.conf.group)
        self.ipc = Ipc(self.conf.socket_path)
        self.player = Player(self.ipc, self.conf.cliamp)

    def read_record(self):
        """The record with the shipped defaults filled in: a card nobody has
        set up yet still has an answer, and it is the one in the knobs. A
        level is deliberately not defaulted here - only a real session ever
        recorded one.
        """
        fields = self.record.read()
        fields.setdefault("mode", "last")
        fields.setdefault("kind", self.conf.start_kind)
        fields.setdefault("target", self.conf.start_target)
        return fields

    def save(self, **changes):
        """One change to the record, and one line to the durable log when there
        was a change to make.

        The log line is the record's whole content, not a diff: a boot that
        comes back wrong is read from what the file said. Two writers can be
        asked to record the same fact a breath apart - a person moves the dial
        through the command, the daemon reports the level changing right after -
        and the record answers once, so boot.log says it once.
        """
        if not self.record.commit(**changes):
            return self.read_record()
        saved = self.read_record()
        detail = "mode=%s kind=%s target=%s" % (saved["mode"],
                                                saved["kind"], saved["target"])
        for key in ("provider", "volume", "title"):
            if saved.get(key):
                detail += " %s=%s" % (key, saved[key])
        self.bootlog.note("intent set: %s" % detail)
        return saved
