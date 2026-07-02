# 09 — Testing, CI, Distribution, Licensing

## Test pyramid

### Core unit + property tests (the bulk)
- HLC: property tests (`proptest`) — monotonicity, commutative merge, clock-skew
  bounds.
- Frame codec: round-trip properties + `cargo-fuzz` targets (decoder, pairing
  messages, BlobRef paths). Fuzzing is non-optional: these bytes come from the
  network.
- History: retention/GC invariants, FTS correctness, encryption round-trips,
  crash-during-write (kill -9 a writer subprocess, reopen, assert WAL recovery).

### Headless integration (the workhorse)
`core/tests/duo.rs` harness: spin up two (or N) `Node`s in one process with real
QUIC over localhost, fake keystores, temp dirs, and scripted `NodeDelegate`s.
Scenarios as table-driven tests:
- pair → clip text → assert applied + in both histories
- offline peer → outbox → reconnect → newest-wins applied, rest in history
- simultaneous copy both sides → HLC winner deterministic, no loop, both kept
- image > 512 KiB → blob pull → injection after landing
- malformed/hostile frames from a raw-socket "evil peer" → clean rejection
- version negotiation old↔new (frames from previous release kept as fixtures)
- (M7) transfer kill/resume at arbitrary chunk; corrupted chunk re-request
- (M8) punch failure → relay fallback, with a relay binary spawned in-test

### Shell tests (thin, matching thin shells)
- macOS XCTest: pasteboard read priority, TIFF→PNG, concealed-type drop,
  self-write fingerprint suppression (uses a real pasteboard on CI mac runner).
- Windows xUnit: clipboard open-retry, CF_HTML header synthesis, DIB→PNG,
  exclusion-format drop. UI smoke via WinAppDriver later, not v1.

### The two-VM end-to-end rig (pre-release gate, semi-manual)
Tart (macOS VM) + Windows VM on a Mac mini CI host, or two physical boxes:
scripted "copy here, assert pasteable there" via small agent binaries; network
impairment via `pfctl`/`clumsy` (loss, latency, mDNS blocked → ladder step 2,
UDP blocked → 443 relay). Run per release candidate; automate incrementally.

## CI (GitHub Actions)

```
ci.yml (every PR)
├─ core: {ubuntu, macos-14, windows-2022} × cargo test --workspace
│         + clippy -D warnings + fmt + deny (licenses/advisories)
├─ fuzz-smoke: 60 s per target on PRs touching proto/ (nightly: 1 h)
├─ macos-app: xcodebuild test (unsigned)
├─ windows-app: dotnet build + test
└─ perf-gate: loopback latency + RSS budget (08 §rules) on macos-14

release.yml (tag push)
├─ build universal staticlib / win cdylibs → shells
├─ macOS: sign (Developer ID) → notarize (notarytool) → staple → DMG
├─ Windows: sign (Azure Trusted Signing or EV token in cloud HSM) → NSIS
├─ generate Sparkle/NetSparkle appcast, upload artifacts
└─ draft GitHub release with changelog
```

Secrets: signing identities in GH encrypted secrets / Azure; notarization via
app-specific password or App Store Connect API key.

## Distribution & updates

| | macOS | Windows |
|---|---|---|
| Package | DMG (drag-to-Applications) | NSIS `.exe` installer |
| Signing | Developer ID Application + notarization + stapling | Authenticode (EV or Azure Trusted Signing — order cert by M4, SmartScreen reputation takes time) |
| Updates | Sparkle 2 (EdDSA-signed appcast) | NetSparkle, same appcast model |
| Autostart | `SMAppService` login item (user-visible toggle) | HKCU Run key written by installer, toggle in settings |
| Permissions onboarding | Pasteboard-access prompt explainer; Accessibility (optional, for direct-paste); Local Network prompt (macOS 15) | Installer-created inbound UDP firewall rule (avoids the KDE Connect fiddliness) |

Both apps: menu "Check for Updates", release notes in-app, staged rollout flag
in the appcast (percentage field) once user count justifies it.

## Licensing / payments (M9)

- Merchant of record: **Paddle or LemonSqueezy** (handles global VAT — a solo
  dev must not do EU VAT manually).
- License = Ed25519-signed token `{license_id, tier, max_pairs, issued_at}`
  signed by our offline key; apps verify locally (no phone-home required for
  the one-time tier), relay verifies the same token for entitlement (06).
- Free tier enforced client-side gracefully (1 pair, LAN-only ladder steps 1–2,
  history cap); no dark patterns — free tier must stay genuinely useful, it's
  the top of the funnel.
- Refund-proof: relay entitlement carries token revocation list (small, fetched
  daily by relay, never by clients on the one-time tier).

## Telemetry & support posture

- Default: **zero telemetry**. Opt-in toggle enables crash reports (Sentry,
  content-scrubbed) + anonymous counters that matter for engineering only:
  punch success rate, transport ladder distribution, clip latency histogram.
- Diagnostics screen with "copy debug bundle" (logs, never clipboard content) —
  the difference between "actively maintained" and Pushbullet-style silence is
  support turnaround, and debug bundles are what make that cheap.

## Naming & trademark note (pre-M6)

"Bridgeboard" is a codename. Before beta: trademark search, domain, and App
Store-safe naming even though we ship outside it (future iOS companion will
need the App Store).
