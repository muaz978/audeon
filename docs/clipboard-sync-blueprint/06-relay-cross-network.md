# 06 — Cross-Network: Rendezvous, Hole Punching, Blind Relay (Phase 2, M8)

The paid-tier differentiator and the hardest engineering in the product. Every
free competitor stops at "same network only." Design borrows the proven shape of
Tailscale (DERP), Syncthing (relays), and magic-wormhole (rendezvous) — scaled
down to exactly one job: connect two already-paired devices.

## Transport selection ladder

The core's `transport` module tries, in order, and **upgrades live** (existing
QUIC connection migrates or is replaced; sync never notices beyond latency):

1. **LAN direct** — peer found via mDNS, dial its advertised addr. (Free tier.)
2. **Known-address direct** — dial the peer's last-known LAN + WAN addresses
   (cached from previous sessions) even without fresh mDNS. Catches the
   "same network but mDNS blocked" case that plagues LocalSend.
3. **Hole-punched direct** — coordinate via rendezvous (below), simultaneous
   UDP open. Works for the large majority of home/office NATs.
4. **Relay** — encrypted frames forwarded blind through `bridgeboard-relay`.
   Always works (TCP 443 fallback framing for hostile networks).

Ladder state is visible in UI as a small badge: "Local · Direct · Relayed" —
turning the hard engineering into visible product value.

## Rendezvous protocol

Devices with relay entitlement keep a lightweight QUIC (fallback: WebSocket/443)
connection to the nearest relay host.

```
Device → Relay:  Register{device_id, proof}          # see auth below
Relay  → Device: Registered{your_observed_addr}       # STUN-equivalent

A wants B:
A → Relay: Intro{to: B}
Relay → B: IntroRequest{from: A, a_addrs:[observed_wan, lan_hints...]}
Relay → A: IntroAnswer{b_addrs:[...]}
A & B: simultaneous QUIC dials to each candidate pair (ICE-lite: stagger
       50 ms, first validated path wins; both keep the same TLS identity so
       any path authenticates identically)
on failure after 3 s → both send RelayOpen{peer} and traffic flows via relay
```

- **Auth without accounts:** `proof` = Ed25519 signature over a server challenge
  with the device identity key + a **license token** (opaque, from the payment
  flow, see 09). Relay checks token validity (signed JWT-style, offline
  verifiable) — it never learns emails. Free-tier devices simply don't register.
- **Pair privacy:** relay only introduces devices that present each other's
  DeviceIDs; it cannot enumerate pairings (introductions require knowing the
  target ID, which only paired peers know).
- The relay's `observed_addr` reflection replaces any STUN dependency; no
  third-party infra.

## Blind relay data plane

- After `RelayOpen`, the relay splices the two connections: every
  `RelayFrame{to, bytes}` is forwarded as `RelayFrame{from, bytes}` — contents
  are the peers' end-to-end QUIC/TLS ciphertext (QUIC-in-QUIC when relayed via
  QUIC; raw framing over the 443 fallback). Relay cannot read or inject —
  the inner session is pinned end-to-end.
- Per-connection token-bucket rate limits (default 20 Mbps burst / 5 Mbps
  sustained on relay — direct paths are unlimited; this also nudges the
  economics: relay is the fallback, not the norm).
- No persistence. Frames in, frames out, counters for abuse detection only.

## Server implementation notes

- `bridgeboard-relay`: tokio + quinn + axum (health/metrics). Target: single
  binary, < 50 MB RSS at 10k idle registrations.
- Regions: start with one (EU or US based on early users), add per-region
  hostnames later; devices ping and pick lowest RTT, agree during intro
  (initiator's choice wins).
- Ops: Docker image, fly.io/Hetzner, Prometheus metrics (connections, punch
  success rate — **the** KPI, relayed bytes), structured logs with no payload
  metadata at default level.
- Abuse: license token required → revocable; per-token concurrent-pair caps.

## Hole-punch realism checklist (build M8 against this)

- Full-cone / restricted NAT both sides: punch succeeds, easy.
- Symmetric NAT one side: punch usually succeeds (other side's mapping stable).
- Symmetric both sides (rare: CGNAT + enterprise): relay. Expected relay share
  ~10–20 % of cross-network sessions; measure, don't assume.
- UDP blocked entirely (hotel/corp): 443 TCP relay fallback; clipboard fine,
  file throughput reduced — surface "constrained network" in UI.
- IPv6: try v6 candidates first when both sides have GUAs — often direct with
  no punching at all.

## Cost model sanity check

Clipboard traffic is trivial (KBs). Relay cost is file transfers that fail to
punch: at 15 % relay share and average 200 MB/user/month relayed, 10k paying
users ≈ 300 GB/mo egress ≈ tens of dollars on Hetzner. The paid tier prices in
orders of magnitude of headroom; rate limits bound the tail.
