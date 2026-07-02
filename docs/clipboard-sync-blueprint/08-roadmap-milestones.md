# 08 — Roadmap & Milestones (the coding plan)

Each milestone is shippable/demoable and maps to future GitHub epics. Estimates
assume one experienced developer, full-time-ish; treat as relative sizing.
Order is chosen so **risk dies first**: FFI plumbing and the sync loop before UI
polish, hole punching before any relay-tier marketing.

## M0 — Repo scaffold & walking skeleton (≈ 1 wk)

- [ ] New repo, workspace layout from 02-D9; MIT/commercial license decision.
- [ ] `bridgeboard-core`: empty `Node` with `start/shutdown`, UniFFI proc-macros,
      `xtask` generating Swift + C# bindings; universal macOS staticlib +
      win-x64 cdylib built in CI.
- [ ] macOS app: `MenuBarExtra` showing core-reported version; calls `start()`.
- [ ] Windows app: tray icon + flyout showing core version.
- [ ] CI (GitHub Actions): `cargo test/clippy/fmt` on ubuntu+macos+windows;
      Xcode build on macos-14; .NET build on windows-2022.
- **Exit:** both shells run a Rust core round-trip on real hardware. (This
  de-risks the single scariest integration bet — UniFFI C# — in week 1.
  If `uniffi-bindgen-cs` disappoints, pivot to hand C ABI now, cheaply.)

## M1 — Core engine, headless (≈ 2 wks)

- [ ] protobuf schema v1 + prost build; frame codec (length-prefix, caps) + fuzz
      target (`cargo-fuzz`) from day one.
- [ ] HLC implementation + property tests.
- [ ] `sync_engine` state machine with **in-memory fake transport**: two `Node`s
      in one test exchange clips; dedupe layers 2–3; outbox queue semantics.
- [ ] History store: schema, CRUD, FTS5 search, retention GC, at-rest encryption
      via fake keystore.
- **Exit:** `cargo test` proves copy→sync→history→search entirely headless.

## M2 — Real transport + discovery + pairing (≈ 3 wks; hardest core milestone)

- [ ] QUIC endpoint (quinn + rustls custom verifier, pinned self-signed certs,
      rcgen issuance from identity key).
- [ ] mDNS advertise/browse (`mdns-sd`), network-change re-announce hooks.
- [ ] Pairing: SPAKE2 + Noise XX + SAS derivation; trust store; rate limits;
      unpair. Integration tests over localhost UDP.
- [ ] Reconnect/backoff, presence, simultaneous-dial tiebreak.
- [ ] Shell pairing UI both platforms (code display / code entry / emoji SAS).
- **Exit:** two real machines pair with the 6-digit flow and stay connected
  across sleep/wake and Wi-Fi flap.

## M3 — Clipboard MVP: text (≈ 2 wks)

- [ ] macOS ClipboardMonitor (poll, concealed-type honor, frontmost exclusion)
      + Writer with self-write fingerprint.
- [ ] Windows ClipboardMonitor (WM_CLIPBOARDUPDATE, retry-open, exclusion
      formats + owner exe) + Writer.
- [ ] Wire through core; measure end-to-end latency; perf budget < 150 ms LAN.
- [ ] Pause-sync toggle.
- **Exit: the product exists** — copy on Mac, paste on PC, and back. Dogfood
  daily from here; keep a friction log.

## M4 — Images, rich text, history UI (≈ 3 wks)

- [ ] Representations list in proto (RTF/HTML/plain bundles); CF_HTML header
      synthesis; TIFF/DIB→PNG conversion.
- [ ] Blob path for large images (BlobRequest machinery — this is 60 % of file
      transfer built early).
- [ ] History windows: global hotkey, search-first list, arrow-key + ⏎ paste
      injection (Accessibility permission flow on macOS), pinning.
- [ ] **Checkpoint (from 02-D4):** WinUI 3 tray/panel pain assessment — commit
      or pivot Windows UI now.
- **Exit:** screenshots sync; history search feels like Ditto/Maccy.

## M5 — Exclusions, settings, onboarding, resilience (≈ 2 wks)

- [ ] Exclusion settings UI + shipped defaults; "mirror settings" opt-in sync.
- [ ] Onboarding: first-run explains pasteboard prompt (macOS), installs
      firewall rule (Windows installer), pairing walkthrough.
- [ ] Outbox/offline behavior surfaced in UI; diagnostics screen (transport
      state, last error, log export).
- [ ] Crash handling: core panic supervision; opt-in crash reporting (Sentry,
      scrubbed).
- **Exit:** a stranger can install both apps and succeed with zero support.

## M6 — Private beta packaging (≈ 2 wks)

- [ ] macOS: Developer ID signing, notarization, Sparkle auto-update, DMG.
- [ ] Windows: Authenticode signing (EV cert lead time — **order in M4**), NSIS
      installer + firewall rule, update via Sparkle-equivalent (NetSparkle or
      built-in check+download).
- [ ] Versioned protocol compatibility test in CI (old core vs new core).
- [ ] Beta channel: 20–50 users from the validation posts. Instrument punch-list.
- **Exit: Phase 1 complete** — free-tier product in real hands.

## M7 — File transfer (≈ 3 wks) → per 05

Offers/answers, chunked streams, resume bitmaps, drop UX both platforms,
received-files management, `FILE_REFS` paste-triggers-transfer (stretch).

## M8 — Relay & hole punching (≈ 4 wks; hardest overall) → per 06

Rendezvous server, observed-addr reflection, punch orchestration, relay data
plane + 443 fallback, transport ladder integration, license-token auth, deploy,
punch-success telemetry (opt-in), transport badge UI.
**Exit: the paid tier's reason to exist works** on hostile-network test matrix
(phone hotspot ↔ home NAT, corp guest Wi-Fi, VPN-on).

## M9 — Monetization & launch (≈ 3 wks)

- [ ] Payments: Paddle or LemonSqueezy (merchant-of-record → they handle VAT);
      license tokens (Ed25519-signed, offline-verifiable — feeds relay auth).
- [ ] Free/paid gating per product plan (free: 1 pair, LAN, basic history).
- [ ] Website, docs, privacy page that states the E2EE design plainly.
- [ ] Launch: r/macapps, Product Hunt, the Pushbullet-refugee angle.

## M10+ — Phase 3 backlog (order by user demand)

Android companion + notification mirroring (07) · snippets/templates ·
multi-device pairs (protocol already N-peer capable; UI work) · settings mirror
· Explorer/Finder context-menu senders · team tier.

## Standing engineering rules (all milestones)

1. Every protocol change lands with a fuzz-corpus entry and a
   compat test against the previous release's frames.
2. Anything touching crypto or parsing gets a second pass in review with the
   threat model (03) open.
3. Perf gates in CI: text clip end-to-end < 150 ms (loopback harness), core RSS
   < 60 MB idle, shell cold start < 1 s.
4. Dogfood from M3; a week without using it yourself = smell.
5. Windows is not the second-class citizen — every feature demo GIF gets
   recorded on both platforms before a milestone closes. (This is the exact
   failure mode of every competitor.)
