# 02 — Tech Stack Decisions

Each decision lists the choice, the rationale, and the rejected alternatives, so
future-us doesn't re-litigate them without new information.

## D1. Shared core: **Rust**

The sync engine, crypto, transport, and storage are written once in Rust and
embedded in both apps.

- Memory-safe crypto/network code; first-class QUIC (`quinn`), Noise (`snow`),
  mDNS (`mdns-sd`), SQLite (`rusqlite`) crates.
- Compiles to a static lib for macOS (arm64 + x86_64 universal) and a cdylib for
  Windows (x86_64 + arm64).
- Headless integration tests: two `Node` instances in one test process exercising
  the full pair→sync→history pipeline with no UI and no OS clipboard.
- Same core later powers Android/iOS companions (UniFFI targets Kotlin/Swift).

**Rejected:** C++ core (more footguns in exactly the code — parsing, crypto — where
they're most expensive); Go core (cgo friction both directions, larger binary, GC
pauses irrelevant but FFI story worse); writing the engine twice natively (guarantees
protocol drift between platforms — this is how KDE Connect's Windows client rotted).

## D2. FFI: **UniFFI** (Mozilla)

- Generates Swift bindings natively; C# bindings via the maintained
  `uniffi-bindgen-cs` third-party generator.
- Callback interfaces give us core→shell delegation without hand-written C headers.
- Proc-macro mode (`#[uniffi::export]`) keeps definitions next to the code.

**Rejected:** hand-rolled `extern "C"` + cbindgen (all the marshalling bugs are
ours); flatbuffers-over-pipe out-of-process daemon (process management pain on
Windows, complicates permission model on macOS; can revisit if in-process crashes
prove problematic).

## D3. macOS shell: **Swift + SwiftUI, `MenuBarExtra`**

- Target macOS 13+ (gives `MenuBarExtra`, `SMAppService`; ~95 %+ of active Macs by
  ship date).
- Distribution: **Developer ID + notarization outside the App Store.** The App
  Store sandbox forbids the pasteboard-polling-plus-background patterns and would
  gut per-app exclusion (no `NSWorkspace.frontmostApplication` in sandbox without
  workarounds). Direct sales also match the $25–35 one-time pricing plan.
- App structure: `MenuBarExtra` for the always-there menu; a regular `Window` scene
  for history (summonable via global hotkey, `⇧⌘V` default); `Settings` scene.
- Global hotkey: `Carbon RegisterEventHotKey` wrapper (still the reliable API) or
  `KeyboardShortcuts` package.

**Rejected:** Catalyst/AppKit-only (SwiftUI menu-bar apps are mature now);
App Store (above).

## D4. Windows shell: **C# / .NET 8 + WinUI 3 (Windows App SDK), unpackaged**

- Target Windows 10 21H2+ and Windows 11.
- Tray icon via `Shell_NotifyIcon` interop (WinUI has no first-party tray API;
  use the `H.NotifyIcon.WinUI` package or a small interop file we own).
- History window and settings in WinUI 3 for a modern-Windows look (the "not a
  2003-era utility" polish requirement).
- Clipboard: use **Win32 APIs via P/Invoke** (`AddClipboardFormatListener`,
  `GetClipboardData`), *not* the WinRT `Clipboard` class — the WinRT class is
  designed for foreground apps and misbehaves in background/tray contexts.
- Distribution: signed installer. **NSIS or WiX MSI** (unpackaged) rather than
  MSIX for v1 — MSIX complicates autostart+tray+firewall-rule installation.
  Installer adds the inbound firewall rule for our UDP port so discovery works
  without the user ever seeing the firewall dialog.

**Rejected:** WPF (fine, but dated visuals out of the box — polish is the product);
Tauri/Electron shell (Electron: 150 MB+ memory for a tray utility contradicts
positioning; Tauri: viable fallback if WinUI tray interop turns painful — decision
checkpoint at end of M4); UWP (deprecated trajectory, sandbox blocks clipboard
monitoring).

## D5. Transport: **QUIC (`quinn`) with Noise `XX`/`KK` payload encryption**

- QUIC gives us: one UDP socket (helps hole punching later), multiplexed streams
  (clipboard control vs. bulk file streams without head-of-line blocking),
  connection migration (Wi-Fi → Ethernet without re-pairing), built-in congestion
  control for file transfer.
- Authentication/encryption model: QUIC requires TLS 1.3 — we run it with
  per-device **self-signed certs bound to the device identity key**, and verify
  peers by **certificate public-key pinning against the paired-device trust store**
  (custom `rustls` verifier; no CAs, no hostnames). The Noise layer (see 03) runs
  the *pairing* handshake; after pairing, day-to-day sessions are pure
  pinned-cert QUIC. Sequence: pair once via PAKE → exchange identity pubkeys →
  pin forever (TOFU with explicit ceremony).
- Wire format inside streams: length-prefixed **protobuf** frames (`prost`).
  Protobuf over serde/CBOR because schema evolution across app versions on two
  different update cadences (Mac users update, Windows lags) is a certainty, and
  proto's field-number discipline handles it.

**Rejected:** raw TCP + Noise (loses stream mux + migration + shared-socket hole
punching); WebRTC data channels end-to-end (huge dependency; we only need ICE-style
techniques, not the whole stack — see 06); libp2p (brings a kitchen sink and its
own opinions; we need ~5 % of it).

## D6. Storage: **SQLite via `rusqlite`, FTS5, blobs on disk**

- `history.db`: items table + FTS5 index over `text_preview`; images and large
  payloads stored content-addressed (`blobs/<blake3-prefix>/<hash>`) with rows
  referencing them; refcounted GC on retention expiry.
- Encryption at rest: encrypt blob files and sensitive columns with a per-device
  symmetric key held in Keychain/DPAPI (via the `KeystoreAdapter`). This is
  simpler and more portable than SQLCipher and keeps the plaintext-never-on-disk
  promise for history content. DB metadata (timestamps, kinds) stays plain for
  query performance; document this honestly.
- Config: TOML file in `~/Library/Application Support/Bridgeboard` /
  `%APPDATA%\Bridgeboard`.

## D7. Server: **Rust, `bridgeboard-relay`, single static binary**

- Same `quinn`/`tokio` stack as the client transport so frame code is shared.
- Stateless except live-connection maps → trivially horizontally scalable behind
  round-robin DNS or per-region hostnames; devices agree on a relay via their
  rendezvous exchange.
- Deploy: Docker on Fly.io/Hetzner to start; one small VM handles thousands of
  idle pairs (relay only carries traffic for the minority of sessions that can't
  hole-punch).

## D8. Crypto primitives (see 03 for protocol)

| Purpose | Primitive | Crate |
|---|---|---|
| Device identity | Ed25519 | `ed25519-dalek` |
| Pairing PAKE | SPAKE2 | `spake2` (RustCrypto) |
| Session handshake (pairing) | Noise `XX` (X25519/ChaChaPoly/BLAKE2s) | `snow` |
| Steady-state transport | TLS 1.3 w/ pinned Ed25519 certs | `rustls` + `rcgen` |
| Content hashing / dedupe / chunk verify | BLAKE3 | `blake3` |
| At-rest encryption | XChaCha20-Poly1305 | `chacha20poly1305` |
| IDs | ULID | `ulid` |

## D9. Repo shape (the future separate repository)

```
bridgeboard/
├─ core/                  # Rust workspace
│  ├─ bridgeboard-core/   # the library (uniffi)
│  ├─ bridgeboard-proto/  # .proto files + prost build
│  ├─ bridgeboard-relay/  # server binary
│  └─ xtask/              # build glue: uniffi generation, universal libs
├─ apps/
│  ├─ macos/              # Xcode project (SwiftPM for deps)
│  └─ windows/            # .NET solution
├─ deploy/relay/          # Dockerfile, fly.toml
├─ docs/                  # this blueprint moves here
└─ .github/workflows/     # ci.yml, release.yml
```
