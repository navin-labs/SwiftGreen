# ADR-003 — Keepalive driven by the Mac; phone reconnects with short backoff, then hands off

| Field | Value |
|---|---|
| ID | ADR-003 |
| Status | **ACCEPTED** (records the design as built) |
| Date | 2026-10-10 |
| Supersedes | An earlier "Android heartbeat every 60 s, Mac timeout 75 s" model (removed from the public docs) |
| Wire details | [`docs/protocol/PROTOCOL.md`](../protocol/PROTOCOL.md) §2 |

## Context

A phone in your pocket goes through Doze, Wi-Fi power save, network switches and OEM task killers. A Mac sleeps, wakes and relaunches. Users notice two failures: a phone that shows "connected" while nothing syncs, and a phone that takes minutes to come back after the Mac wakes. Battery cost on the phone has to stay near zero.

What was measured during development, on the maintainer's devices (Motorola Edge 40, Apple Silicon Mac):

- With the Mac quitting silently, the phone took **~80 s** to notice (comment on `mDNSQuicServer.sayGoodbye`).
- After the Mac relaunched, the TLS handshake took **6.4 s** because the Mac's identity lived in the legacy login keychain. Importing it memory-only cut that to **21 ms** (commits `6a75965`, `0b0c192`).
- Reconnect latency after a Mac relaunch, from scripted relaunch loops: **median 3.8 s, p90 7.2 s**. This is the maintainer's measurement on that one setup, not an automated benchmark.

## Decision

1. **The Mac sends the keepalive** (`ping` every 30 s) and the phone only answers. The phone keeps no timer, so an idle socket lets it sleep like any other idle connection. A phone-driven heartbeat would need a wake lock or an exact alarm every interval.
2. **Dead after 100 s of silence on either side**: three missed pings plus slack, so one delayed Wi-Fi power-save wake doesn't drop the link.
3. **The Mac says goodbye** (`disconnect`) on quit and sleep, and waits up to 0.5 s for it to leave. The phone then reconnects at once instead of after a timeout.
4. **Phone backoff restarts on every drop**: 2 s doubling to 10 s for the first couple of minutes, then 30 s, about 10 minutes in all. After that a 15-minute JobScheduler job (on an unmetered network) and the Mac's Bluetooth LE beacon take over.
5. **Find the Mac without mDNS when we have to**: last good address first, then the QR's addresses, then a probe of the phone's /24. Some ISP routers drop mDNS between Wi-Fi clients (seen on a Nokia GPON router).

## Alternatives considered

| Option | Why not |
|---|---|
| Phone-driven heartbeat (the earlier build) | Costs a wake-up per interval on the phone, the side with the battery. |
| TCP keepalive only | Kernel defaults are hours; tuning per-socket intervals is inconsistent across Android OEMs and can't carry the latency reading. |
| FCM / push to wake the phone | Needs a Google account and a server. SwiftGreen is local-only. |
| Unlimited fast retry | Drains battery when the Mac is simply off or away. |

## Consequences

- Detecting a dead link takes up to 100 s when neither side gets an error (e.g. Wi-Fi drops silently). A clean quit or sleep is immediate.
- Only one phone can be connected. While the tunnel is up, a new connection must answer its own challenge within 5 s before it replaces the tunnel; failing or timing out leaves the tunnel alone (SG-08). At most 4 such candidates are held at once.
- The /24 probe touches up to 254 addresses on the local subnet, and only while no tunnel is up.
