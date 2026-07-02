# Bridgeboard — Technical Blueprint

> Working codename: **Bridgeboard** (final name TBD). This is a **separate product** from Audeon;
> the blueprint lives here temporarily until its own repository is created.

A menu-bar (macOS) / system-tray (Windows) app that keeps **clipboard, files, and
notifications** in sync between a Mac and a Windows PC — near-instant on the local
network, with an encrypted relay fallback when the two machines are on different
networks. Polish level of a paid Mac utility, not a volunteer-project aesthetic.

## Document map

| Doc | Contents |
|---|---|
| [01-architecture.md](01-architecture.md) | System overview, process model, component boundaries, data flow |
| [02-tech-stack.md](02-tech-stack.md) | Language/framework decisions per layer, with rejected alternatives |
| [03-protocol-and-security.md](03-protocol-and-security.md) | Discovery, pairing, encryption handshake, wire protocol, threat model |
| [04-clipboard-engine.md](04-clipboard-engine.md) | Platform clipboard capture/injection, loop prevention, exclusions, history store |
| [05-file-transfer.md](05-file-transfer.md) | Chunking, hashing, resume, drag-and-drop UX plumbing |
| [06-relay-cross-network.md](06-relay-cross-network.md) | NAT traversal, rendezvous server, blind relay design (the Phase-2 differentiator) |
| [07-notifications.md](07-notifications.md) | Notification mirroring: what is actually possible per platform |
| [08-roadmap-milestones.md](08-roadmap-milestones.md) | Milestone-by-milestone coding plan with task-level breakdown |
| [09-testing-ci-distribution.md](09-testing-ci-distribution.md) | Test strategy, CI matrix, signing/notarization, packaging, licensing |

## The three product invariants

Every technical decision below is checked against these; they encode the market gap
this product exists to fill:

1. **Zero-config on LAN.** Two devices on the same network find each other and pair
   with a 6-digit code comparison, nothing else. No IP addresses, no ports, no
   firewall documentation as a prerequisite (we do the firewall prompt for the user).
2. **Works across networks.** When mDNS fails (guest Wi-Fi, VPN, different subnets),
   the connection silently upgrades to hole-punched direct or relayed transport.
   This is the failure point of LocalSend / KDE Connect and the paid-tier feature.
3. **End-to-end encrypted, always.** The relay and rendezvous servers never see
   plaintext and never store content. Key material never leaves the devices.
   "Your clipboard never touches our servers unencrypted" must be literally true.

## Architecture in one paragraph

A shared **Rust core** (`bridgeboard-core`) owns everything platform-independent:
discovery, pairing, the Noise-over-QUIC transport, the sync state machine, the
SQLite history store, file transfer, and relay fallback. Each OS gets a thin
**native shell** — SwiftUI menu-bar app on macOS, WinUI 3 tray app on Windows —
that does only three things: platform clipboard I/O, platform UI, and lifecycle
(login item / autostart, permissions prompts). Shells talk to the core through
UniFFI-generated bindings. Server side is a single small Rust binary
(`bridgeboard-relay`) providing rendezvous + blind byte relay, deployable on
commodity hosts, horizontally scalable because it holds no state beyond live
connection maps.

## Phasing (matches product plan)

- **Phase 1 (MVP):** clipboard sync (text + images), LAN-only, pairing, per-app
  exclusions, E2EE, persistent searchable history. Milestones M0–M6.
- **Phase 2:** file drag-and-drop, cross-network relay + hole punching. M7–M8.
- **Phase 3:** notification mirroring (Android first), snippets, multi-pair,
  licensing/payments. M9+.
