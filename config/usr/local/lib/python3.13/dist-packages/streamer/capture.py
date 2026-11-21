"""The level a person sets outside the appliance, and the one place that hears it.

The Omarchy panel (orsa.remote-cliamp) drives this player's socket directly: its
volume slider sends the `volume` operation over the forwarded socket, so no CLI
verb runs on the card and the appliance never sees a command. cliamp does not
persist its dB, so a level that is not heard is a level that is lost: the next
boot would come back at whatever the record still held. Checked on the card
2026-11-21, two facts decide this module:

  the IPC snapshot answers 20 keys and no `volume` among them, and the volume
  operations' replies carry no level either, so a level cannot be read there;
  `cliamp remote events runtime.state` streams the runtime state, and its
  `data` carries `"volume": -4` beside the revision: the event stream is the
  only channel that answers the level, and it answers it when it changes.

So the appliance subscribes once and writes on change. No timer: a change made
by a person is a change the appliance is allowed to remember, which is the same
rule the boot record obeys.
"""

import json
import subprocess

from streamer import num


def level_events(cliamp, topics=("runtime.state",)):
    """The player's level, as the daemon reports it changing.

    `cliamp remote events` is the shipped client of the daemon's event stream,
    used here for the one thing the CLI is good at in this design: one long-
    lived connection, read line by line, instead of a spawn per event. The
    generator returns when the stream ends - the daemon restarting, or the
    socket going away - and the caller decides what that means.
    """
    try:
        stream = subprocess.Popen([cliamp, "remote", "events"] + list(topics),
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL,
                                  universal_newlines=True, bufsize=1)
    except OSError:
        return
    try:
        for line in stream.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            data = event.get("data")
            if isinstance(data, dict) and "volume" in data:
                yield data["volume"]
    finally:
        try:
            stream.terminate()
        except OSError:
            pass


def follow(app, events):
    """Remember each level the daemon reports, while it is a level worth keeping.

    A level at or below the boot floor is a parked control - the floor is the
    last word by design - so it is not remembered. Everything else goes to the
    record, whose own commit decides whether the fact is new: the command may
    have written the same level a breath earlier, and then nothing is written
    and nothing is logged.
    """
    for value in events:
        try:
            level = float(value)
        except (TypeError, ValueError):
            continue
        if level <= app.conf.vol_floor:
            continue
        app.save(volume=num(level))
