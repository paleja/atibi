"""The appliance's shared library, stdlib only: one implementation of the knobs,
the boot record, the player's IPC socket and boot.log, used by every atibi-*
entry point. Nothing here reads a path, an executable or a clock it was not
given, which is what makes the pieces testable on their own.
"""

import os
import grp
import pwd


def num(value):
    """A number the way the card writes it: no trailing zeros, so a level
    a person read off the player and a level read back from it print the
    same, and the record never holds two spellings of one number.
    """
    return "%g" % value


def own(path, user, group):
    """Hand a file back to the appliance account.

    Two identities write the durable files: the units as ATIBI_USER, and a
    command typed over SSH as root. Whoever made the file closes it to the other
    one, so an ownership accident cannot leave a record nobody can rewrite.
    """
    if not (user and group):
        return False
    try:
        os.chown(path, pwd.getpwnam(user).pw_uid,
                 grp.getgrnam(group).gr_gid)
    except (OSError, KeyError):
        return False
    return True
