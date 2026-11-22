# ADR-000: carry the wall clock across reboots through /data

Date: 2026-11-22

## Context

A Pi has no RTC, and the distro's clock stamp `/var/lib/systemd/timesync/clock`
sits on the read-only root.
Measured on the device: every boot starts with the clock months behind, NTP lands
at boot+34 s, and an https boot target therefore waits ~18 s before call.

## Decision

The boot keeps its own clock stamp in `/data/atibi/clock` (`ATIBI_CLOCK`).
atibi-clock.service sets the clock forward, before the player units.
atibi-play then treats "the stamp exists and the clock has reached it" as equivalent
to the NTP flag at its gate. Clock is still behind, but close enough
for https cert validation. The stamp itself is saved after
the sound, and only once the NTP flag says the clock is exact.

## Consequences

- A second durable writer on /data, alongside the record and boot.log: one
  11-byte rename per boot that heard NTP, fsynced, pi-owned; a power cut
  leaves the previous stamp, not a torn one. `atibi reset` wipes it, so a
  reset card pays the gate once.
- Measured: clock "right" at boot+6 s instead of boot+34 s
- No stamp, or NTP never reachable: the gate waits as before and no stamp
  is written.