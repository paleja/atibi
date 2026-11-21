"""Where the ramp ends, and the climb to it.

Nothing jumps: the amp's relay is closed by the time audio starts and a step
is the one thing it could not absorb. Three guards keep the climb inside the
boot budget, because a ramp that outlives the boot leaves the listener at a
level the boot never intended:

  a level that will not move - the output device will not go where it is asked,
  a step budget - the ramp cannot use up the whole boot,
  a level set elsewhere - someone moved the dial during the climb, their level
  wins and the climb stops.
"""

from streamer.ipc import IpcError

STEP_SLACK = 0.02
NOT_MOVED = 0.01


def climb(player, start, target, step, delay, max_steps, sleep):
    """Walk from `start` to `target` in steps, and report where the player
    ended up and what stopped the climb.

    The level is read back from the player after every step rather than added
    up in here: cliamp clamps to its own limits, and what it settled at is
    what the next boot aims at.
    """
    now = start
    steps = 0
    note = ""
    while now < target - NOT_MOVED:
        step_now = min(step, target - now)
        try:
            player.adjust_level(step_now)
        except IpcError:
            break
        expected = now + step_now
        after = player.level()
        if after is not None:
            if abs(after - expected) > step_now + STEP_SLACK:
                note = "volume set elsewhere to %s dB, ramp stops" % _num(after)
                now = after
                break
            if abs(after - now) < NOT_MOVED:
                note = "volume stuck at %s dB, ramp stops" % _num(after)
                now = after
                break
            now = after
        else:
            now = expected
        steps += 1
        if steps >= max_steps:
            note = "ramp budget of %d steps exhausted at %s dB" % (steps, _num(now))
            break
        sleep(delay)
    return now, note


def _num(value):
    return "%g" % value
