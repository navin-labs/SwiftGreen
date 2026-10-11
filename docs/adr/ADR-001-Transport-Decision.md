# ADR-001: TLS over TCP

| | |
|---|---|
| Status | Accepted |
| Date | 2026-05-30 (rewritten 2026-10-10 to match what was built) |

## Context

The early product spec assumed QUIC (Cronet on Android, `NWProtocolQUIC` on the Mac) from the start. QUIC's draws are connection migration across IP changes and several streams without head-of-line blocking. Its costs for a one-person project: Cronet's API is built for HTTP, not a long-lived custom stream; Network.framework's QUIC is thinly documented for that use; devices without Google Play services would need a second QUIC implementation.

## Decision

Transport is **TLS over one TCP connection**: `java.net.Socket` + JSSE on Android, `NWConnection` + `NWProtocolTLS` on the Mac. Messages are newline-delimited JSON (`docs/protocol/PROTOCOL.md`). QUIC is a possible Phase 3; nothing is built for it.

## Consequences

- Both stacks are standard platform APIs with no third-party transport library.
- An IP change drops the connection; the phone reconnects (PROTOCOL.md §2). The Mac → phone sender has a resume path (`resume_offset`); it is not device-tested.
- One connection carries everything, so a large file transfer can delay a notification line behind it. There is no priority scheme; chunks are 256 KiB, which bounds the wait per chunk.
- A move to QUIC would be a transport change; the JSON messages would not need to change.

## Alternatives considered

- **QUIC now:** rejected for the integration risk above.
- **WebSocket:** no advantage over plain TLS for two apps that control both ends.
- **A second TCP connection for files:** a second reconnect path and a second authentication to keep correct; rejected.
