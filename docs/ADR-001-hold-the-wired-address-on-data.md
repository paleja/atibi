# ADR-001: hold the wired address on /data, and let the boot skip the DHCP wait

Date: 2026-11-22

## Context

On the LAN the box is expected to live on, the router's DHCP server answers
late: measured 2026-11-22, NetworkManager is up at boot+6 s, the wired interface
has its carrier and is auto-activated at +10 s, and the lease is acknowledged
and routed only at +19 s. The first 10 s are the Pi's own; the rest is that
server replying, on a LAN where nobody cares which address this box has as long
as it is in the subnet and clear of the router's pool.

The boot cannot spend a load call before a route and a resolver exist, so it
pays that ~9 s at every reboot.

## Decision

`atibi network static` reads the four numbers the kernel already holds — address
and prefix, gateway, the nameserver in resolv.conf — and writes them as a
NetworkManager profile at `ATIBI_STATIC` (`/data/atibi/static-v4.conf`).
atibi-static.service, wanted by NetworkManager and ordered before it, copies
the file to `/run/NetworkManager/system-connections/atibi.nmconnection`, where
`method=manual` means the boot never asks the router. Absent file: DHCP, exactly
as before. `atibi network dhcp` removes it; `atibi reset` clears it with the
rest of `/data`.

The copy of the live lease is what makes the choice cheap: the numbers cannot
be mistyped, and the only judgement left is whether to keep the address the
lease gave or pick one clear of the pool.

## Consequences

- The appliance now believes the LAN. If the subnet changes, the box comes up
  on an address that is not there: no route, no sound, and boot.log says so in
  its own line. Recovery is `atibi network dhcp` over SSH, or one edit of a
  file on the writable partition.
- boot.log gains the line that says which path played — `route from dhcp:
  192.168.88.146/24 via 192.168.88.1, resolving at 192.168.88.1` or
  `route from static: ...` — which is the only durable place the difference
  between the two paths is visible.
- Measured on the device (journald monotonic, and `/proc/uptime` marks the
  boot writes next to its own lines, since boot.log's stamps straddle the
  NTP step): three boots held, three on DHCP. The gate — a route and a
  resolver — opens at +10.6 s held, +17.9 to +26.5 s on DHCP; the floor
  lands at +11.2 s versus +19.8 s; the record is in play at the floor at
  +17.5 s versus +21.5 s, and at the saved level by +21.1 s versus +26.7 s.
  So the saving is ~4 s, not the 8 s the route gap suggests: what is left
  is the daemon's warm-up and the provider list fetch, and neither is
  network-bound.
- The remaining cost is now visible as a race: on a held boot the load
  asked for 3.7 s after the daemon's socket answers is refused as bare
  `failed` with nothing on `cliamp.log`, and the same ask 2 s later plays.
  The boot asks again (`ATIBI_LOAD_TRIES` × `ATIBI_LOAD_RETRY_AT`) rather
  than losing the boot to systemd's `RestartSec=15`, which measured 15 s
  and a second wait for the route.
