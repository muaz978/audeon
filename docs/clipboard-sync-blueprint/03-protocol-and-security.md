# 03 — Protocol & Security

## Identities

- Each install generates a long-term **Ed25519 identity keypair** on first run,
  stored via the shell `KeystoreAdapter` (Keychain / DPAPI). The public key's
  BLAKE3 hash (truncated to 16 bytes, base32) is the **DeviceID** — stable,
  unforgeable, and what users pair against.
- A device also generates a self-signed X.509 cert (`rcgen`) whose SubjectPublicKey
  is (derived from) the identity key; this is what QUIC/TLS presents. Peers verify
  by pinning: *is this exact public key in my trust store?* Hostnames and CAs are
  ignored entirely.

## Discovery (LAN)

DNS-SD service over mDNS: **`_bridgeboard._udp.local.`**

TXT record fields (all values short; total < 400 bytes):

```
v=1                  protocol version
id=<DeviceID>
fp=<8-byte pubkey fingerprint>   # quick trust-store lookup before dialing
name=<user-visible device name>
os=mac|win
port=<udp port>      # QUIC listener; OS-assigned, announced here
pair=1               # present only while the device is in "accepting pairing" mode
```

Rules:
- Advertise + browse continuously while running (`mdns-sd` crate).
- Unpaired devices are shown in UI **only** during an active pairing flow, and
  only if they advertise `pair=1`. Paired devices dial immediately on discovery.
- Content is never trusted from TXT records; they are hints. Authentication is
  the pinned key at connection time, period.
- Discovery re-announce on network-change events (shell forwards
  `NWPathMonitor` / `NetworkListManager` changes to the core).

## Pairing (the trust ceremony)

Goal: two devices that have never met establish mutual trust with an
active-MITM-proof exchange, UX = "compare a 6-digit code."

Flow (initiator = the device where the user clicked "Pair"):

```
1. Responder enters pairing mode (UI button) → advertises pair=1 for 2 min.
2. Initiator browses, user picks the responder from the list.
3. Initiator opens a provisional QUIC connection (certs unverified — pairing only).
4. SPAKE2 over a dedicated stream:
     password = 6-digit numeric code displayed on the RESPONDER,
     typed by the user on the INITIATOR.
     (Code entry, not just comparison → resists a MITM who can't see the screen,
      and gives SPAKE2 a real low-entropy secret to amplify.)
5. SPAKE2 output keys an authenticated channel; inside it, run Noise XX to
   exchange and prove possession of the long-term Ed25519 identity keys.
6. Both sides display a 4-emoji SAS derived from the session transcript hash;
   user taps "they match" on both. (Belt and suspenders over SPAKE2; also the
   moment the user consciously establishes trust.)
7. Each side writes the peer into its trust store:
     {device_id, ed25519_pub, name, os, paired_at, capabilities}
8. Provisional connection closes; a normal pinned-cert QUIC session dials.
```

- Rate limiting: 3 failed SPAKE2 attempts → responder exits pairing mode.
- Unpair: deletes trust-store row + sends best-effort `Unpair` message; peer
  removes reciprocally (and its UI says so).
- Re-key: not needed for identity keys (unpair/re-pair is the rotation story
  for v1); QUIC/TLS handles session key freshness.

## Steady-state transport

- Single QUIC connection per peer pair; either side may dial (lower DeviceID
  wins simultaneous-dial races: keep the connection dialed by the smaller ID).
- **Streams:**
  - Stream 0 (bidi, long-lived): control — hello/version negotiation, presence,
    capability flags, acks.
  - Stream 1 (bidi, long-lived): clipboard items.
  - One new unidirectional stream **per file** in a transfer (see 05).
- Keepalive: QUIC keep-alive 15 s; peer considered offline after 45 s silence →
  UI state change + outbox queuing.
- Version negotiation: `Hello{proto_version, min_supported, app_version, os}`.
  Reject with `IncompatibleVersion` + UI prompt to update. Protobuf gives us
  room to add fields without bumping versions; bump only on semantic breaks.

## Wire format

Length-prefixed protobuf frames per stream: `u32 LE length | frame bytes`,
max frame 1 MiB (larger content goes through blob transfer).

```proto
// bridgeboard-proto/bridgeboard.proto (v1 sketch)
message Frame {
  oneof body {
    Hello hello = 1;
    ClipboardItem clip = 2;
    ClipAck clip_ack = 3;
    FilesOffer files_offer = 4;
    FilesAnswer files_answer = 5;
    FileChunkAck chunk_ack = 6;       // control-stream acks for resume
    BlobRequest blob_request = 7;     // pull an image/blob referenced by a clip
    Presence presence = 8;
    Unpair unpair = 9;
  }
}

message ClipboardItem {
  string id = 1;                      // ULID
  Hlc hlc = 2;
  ClipKind kind = 3;                  // TEXT / RTF / HTML / IMAGE_PNG / FILE_REFS
  bytes inline_data = 4;              // <= 512 KiB, else blob_ref set
  BlobRef blob_ref = 5;               // {blake3, size} — fetch via BlobRequest
  string text_preview = 6;            // truncated, for history/search on receiver
  string origin_device = 7;
}

message Hlc { uint64 wall_ms = 1; uint32 logical = 2; string device = 3; }
message BlobRef { bytes blake3 = 1; uint64 size = 2; }
```

Rules: receiver never trusts `kind` blindly — image bytes are re-validated
(decode PNG header + bounded dimensions) before being placed on the OS clipboard;
text is length-capped; `FILE_REFS` never auto-materializes files without user
action.

## Threat model (v1 scope)

**In scope / defended:**

| Threat | Defense |
|---|---|
| Passive LAN sniffing | Everything inside QUIC/TLS 1.3; nothing plaintext ever |
| Active MITM at pairing | SPAKE2 with off-band code + SAS confirmation |
| MITM after pairing | Pinned identity keys; unknown key = hard fail, no fallback |
| Malicious/compromised relay | Relay sees only ciphertext + (DeviceID, timing, sizes) metadata; cannot decrypt or inject (frames authenticated end-to-end) |
| Evil device on LAN spoofing mDNS | TXT is a hint only; connection fails pinning |
| Password manager leakage | Concealed/transient clipboard types honored (never captured); per-app exclusion list, fail-closed in the shell |
| History theft from disk | Content encrypted at rest with Keychain/DPAPI-held key |
| Malformed frames / parser attacks | Length caps, protobuf, image re-validation, fuzzed decoders (see 09) |

**Explicitly out of scope for v1 (documented honestly):**
- A compromised endpoint (malware with user privileges can read the clipboard OS-wide
  anyway — no app can defend this).
- Traffic-analysis resistance (relay operator can see *that* two devices talk and
  how much).
- Multi-user machines sharing an OS account.

## Privacy posture (product-level commitments the code must keep)

1. No account required for LAN-only use. Relay tier uses an opaque license token,
   not an email-keyed identity, wherever payment provider allows.
2. Servers store: nothing content-related, ever. Rendezvous holds
   `{device_id → connection}` in memory only. Logs exclude payload sizes at
   default level.
3. Telemetry: opt-in only, crash reports scrubbed, and the setting is per-device.
