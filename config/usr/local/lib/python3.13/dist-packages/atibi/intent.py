"""What a reboot should load, worked out from the player's own snapshot.

The mapping lives here, on the card, because a page that guesses it boots to
silence. The snapshot's `playlist` label was checked on cliamp 2.4.1 (2026-11-21)
and comes in four shapes and only these:

  <provider>:<list id>            a streaming-service list
  <provider>:album:<album id>     an album - a spelling provider.load itself
                                    refuses, so the word `album` comes back out
                                    before the intent is written
  a bare name                   a list saved on the card, which `load` resolves
  radio:l:0                     cliamp's built-in channel: `load` cannot open it,
                                hence `radio` in ATIBI_PROVIDERS

A single track.play leaves the key out altogether, which is why the playing
row is the fallback and never the first choice: a row in the middle of a list
is not loadable, the list's name is.
"""

import re

from atibi import num

PROVIDER_NAME = r"[a-z][a-z0-9-]*"
ALBUM_ROW = re.compile(r"\A(%s)://album/(\S+)\Z" % PROVIDER_NAME)
TRACK_ROW = re.compile(r"\A(%s)://track/(\S+)\Z" % PROVIDER_NAME)
LIST_ALBUM = re.compile(r"\A(%s):album:(\S+)\Z" % PROVIDER_NAME)
LIST_PROVIDER = re.compile(r"\A(%s):(\S+)\Z" % PROVIDER_NAME)


class NoTarget(Exception):
    """Nothing the next boot could reach. A file on the card is refused here
    on purpose: the boot has no way to find a path a person typed."""


def snap_row(snapshot, key):
    """A row the player answers as a bare string is treated as no row: the
    harness does that for the built-in radio rows, and an unparseable row is
    worth less than an exception on a status read."""
    row = snapshot.get(key)
    return row if isinstance(row, dict) else {}


def boot_fields(snapshot, providers):
    """The record's fields for the choice: what plays now becomes what plays
    next boot."""
    label = str(snapshot.get("playlist") or "")
    hit = LIST_ALBUM.match(label)
    if hit and hit.group(1) in providers:
        return {"mode": "last", "kind": "album",
                "target": hit.group(2), "provider": hit.group(1)}
    hit = LIST_PROVIDER.match(label)
    if hit and hit.group(1) in providers:
        return {"mode": "last", "kind": "provider",
                "target": hit.group(2), "provider": hit.group(1)}
    if label and ":" not in label:
        return {"mode": "last", "kind": "playlist", "target": label, "provider": ""}

    for key in ("logical_track", "track"):
        row = snap_row(snapshot, key)
        path = str(row.get("path", ""))
        hit = ALBUM_ROW.match(path)
        if hit and hit.group(1) in providers:
            meta = row.get("provider_meta") or {}
            return {"mode": "last", "kind": "album",
                    "target": str(meta.get("albumID") or hit.group(2)),
                    "provider": hit.group(1)}
        hit = TRACK_ROW.match(path)
        if hit and hit.group(1) in providers:
            meta = row.get("provider_meta") or {}
            # The display strings come from the row the player is holding: an
            # empty one is passed as empty on purpose, so a row without an
            # artist cannot inherit the previous track's.
            return {"mode": "last", "kind": "track",
                    "target": str(meta.get("%s.id" % hit.group(1))
                                   or hit.group(2)),
                    "provider": hit.group(1),
                    "title": str(row.get("title", "")),
                    "artist": str(row.get("artist", "")),
                    "album": str(row.get("album", ""))}
        if path.startswith("http://") or path.startswith("https://"):
            return {"mode": "last", "kind": "url", "target": path, "provider": ""}
    raise NoTarget("nothing playing that the next boot could reach")


def captured_level(app):
    """The player's level as the appliance may remember it.

    Read back from the player, never remembered from what was asked for: what
    cliamp settled at is what the next boot aims at. A level at or below the
    boot floor is a parked control, not a preference - the floor is the last
    word by design - so it is not remembered, and the saved level carries on.
    Returns None when there is nothing to remember.
    """
    level = app.player.level()
    if level is None or level <= app.conf.vol_floor:
        return None
    return num(level)


def record_level(app):
    """The level alone, with the source untouched: what the page's volume
    control and `atibi level` do after they move the dial.
    """
    level = captured_level(app)
    if level is None:
        return None
    return app.save(volume=level)


def parse_target(what, target, providers):
    """Split a person's words into the record's fields.

    A bare id for a provider target means nothing until the service that minted
    it is named, so the prefix is required, not assumed. A bare name means a
    list saved on the card, which cliamp's `load` resolves; a provider:id list
    is fetched by id, and `radio:l:0` only opens that way, hence `radio` in
    ATIBI_PROVIDERS.
    """
    if what == "station":
        if not target.startswith(("http://", "https://")):
            raise ValueError("station target must be http(s): %s" % target)
        return {"kind": "url", "target": target, "provider": ""}
    provider = ""
    for name in providers:
        if target.startswith("%s:" % name):
            provider, target = name, target[len(name) + 1:]
            break
    if what == "playlist" and not provider:
        return {"kind": "playlist", "target": target, "provider": ""}
    if not provider:
        raise ValueError("%s target must be written <provider>:<id>, "
                         "like tidal:1306459" % what)
    # A playlist the service holds is fetched by id, not resolved on the card:
    # the kind follows where the list lives, which the prefix says.
    kind = "provider" if what == "playlist" else what
    return {"kind": kind, "target": target, "provider": provider}


def record_now(app):
    """The choice itself: next boot = what is playing now.

    Reached by `atibi boot now` and by the page's "use the now playing"
    button. The source and the level are captured together, which is what lets
    a level set outside the appliance - the Omarchy panel talking to the
    socket - be remembered at all: `boot now` is the moment the appliance
    learns it.
    """
    fields = boot_fields(app.player.snapshot(), app.conf.providers)
    level = captured_level(app)
    if level:
        fields["volume"] = level
    return app.save(**fields)


def record_target(app, fields):
    """Next boot = a target typed out, in the record's own field names. Nothing
    that is playing is touched: a tapped playlist has already started its music,
    and a second start would mean a trip back to the floor mid-track.
    """
    return app.save(**fields)


def record_mode(app, resume):
    """Resume on boot, or stay quiet after it. The source carries on either way:
    `stop` on the transport is not a statement about the next boot, and this is
    the verb that says so out loud.
    """
    current = app.read_record()
    return app.save(mode="last" if resume else "stop",
                    kind=current["kind"], target=current["target"])
