# 01 — System Architecture

## Process model

One user-space process per device. No kernel extensions, no drivers, no admin
services. The process is a tray/menu-bar app that hosts the Rust core in-process.

```
┌────────────────────────── macOS ──────────────────────────┐
│  SwiftUI menu-bar shell                                    │
│  ├─ ClipboardMonitor (NSPasteboard poll)                   │
│  ├─ ClipboardWriter  (NSPasteboard write)                  │
│  ├─ UI: menu, history window, settings, pairing sheet      │
│  └─ Lifecycle: login item, network-permission prompt       │
│            ▲  UniFFI (callbacks + calls)  ▼                │
│  bridgeboard-core (Rust, staticlib)                        │
│  ├─ Discovery (mDNS)      ├─ SyncEngine (state machine)    │
│  ├─ Pairing (SPAKE2+SAS)  ├─ HistoryStore (SQLite/FTS5)    │
│  ├─ Transport (QUIC/Noise)├─ FileTransfer                  │
│  └─ RelayClient (Phase 2) └─ Config/Keystore adapter       │
└────────────────────────────────────────────────────────────┘
                    ▲ QUIC over UDP (LAN)  ▲
                    │ or via relay (WAN)   │
┌────────────────────────── Windows ────────────────────────┐
│  WinUI 3 tray shell (C#)                                   │
│  ├─ ClipboardMonitor (WM_CLIPBOARDUPDATE)                  │
│  ├─ ClipboardWriter                                        │
│  ├─ UI: tray flyout, history window, settings, pairing     │
│  └─ Lifecycle: autostart, firewall rule via installer      │
│            ▲  UniFFI C# bindings  ▼                        │
│  bridgeboard-core (same Rust crate, cdylib)                │
└────────────────────────────────────────────────────────────┘

Server side (Phase 2, one Rust binary):
┌─ bridgeboard-relay ───────────────────────────────────────┐
│ ├─ Rendezvous: device-ID ↦ live connection map, intro     │
│ │   messages for hole punching (like Tailscale's DERP     │
│ │   control plane, much smaller)                          │
│ └─ Blind relay: forwards opaque ciphertext frames between │
│     two authenticated device connections; no persistence  │
└────────────────────────────────────────────────────────────┘
```

## Component boundaries — what lives where and why

### Rust core owns (platform-independent, testable headlessly)

| Component | Responsibility |
|---|---|
| `discovery` | mDNS advertise + browse; emits `PeerFound`/`PeerLost` events |
| `pairing` | PAKE handshake, SAS code generation, identity-key exchange, trust store |
| `transport` | QUIC endpoint, Noise session per peer, stream multiplexing, reconnect/backoff, transport selection (LAN direct → punched direct → relay) |
| `sync_engine` | The heart: consumes local clipboard events from the shell, decides what to broadcast, consumes remote items, dedupes/orders them (HLC), and calls back into the shell to inject |
| `history` | SQLite (FTS5) persistent clipboard history, search, pinning, retention policy |
| `file_transfer` | Chunked, resumable, BLAKE3-verified transfers over dedicated QUIC streams |
| `relay_client` | Rendezvous registration, hole-punch coordination, relay fallback |
| `config` | Settings persistence (TOML), exclusion lists, device table |

### Native shells own (thin, platform-specific)

| Concern | macOS | Windows |
|---|---|---|
| Clipboard read trigger | `NSPasteboard.changeCount` poll (200 ms timer; no notification API exists) | `AddClipboardFormatListener` → `WM_CLIPBOARDUPDATE` (event-driven) |
| Clipboard write | `NSPasteboard.setData` | `SetClipboardData` |
| Frontmost app (for exclusions) | `NSWorkspace.frontmostApplication.bundleIdentifier` | `GetClipboardOwner` → PID → exe path |
| Secret-content flag | `org.nspasteboard.ConcealedType` / `TransientType` pasteboard types | `ExcludeClipboardContentFromMonitorProcessing` clipboard format |
| Key storage | Keychain (`kSecClassGenericPassword`) | DPAPI (`ProtectedData`, CurrentUser) |
| Autostart | `SMAppService.mainApp` login item | `Run` registry key or StartupTask (MSIX) |
| Notifications UI | `UNUserNotificationCenter` | `AppNotificationManager` (WinAppSDK) |
| UI | SwiftUI: `MenuBarExtra`, Settings scene | WinUI 3: tray icon (Win32 `Shell_NotifyIcon` interop) + windows |

**Rule:** if a line of code can be written without an OS API, it goes in the core.
The shells should each stay under ~3–4k lines through Phase 1.

## Core ↔ shell interface (UniFFI)

The core exposes a single object graph; the shell registers a callback interface.
Sketch of the `.udl`/proc-macro surface (final form uses `uniffi::export`):

```rust
// Shell → core (calls)
interface Node {
    constructor(data_dir: String, keystore: KeystoreAdapter, delegate: NodeDelegate);
    void start();                       // begins discovery + listening
    void shutdown();
    // clipboard
    void local_clipboard_changed(ClipItem item, SourceApp app);
    sequence<ClipItem> history_search(String query, u32 limit);
    void history_pin(String item_id, boolean pinned);
    // pairing
    PairingSession begin_pairing(PeerInfo peer);      // outgoing
    void pairing_confirm_sas(String session_id, boolean user_confirmed);
    void unpair(String device_id);
    // files (Phase 2)
    String send_files(String device_id, sequence<String> paths);  // returns transfer_id
    void cancel_transfer(String transfer_id);
    // settings
    void set_exclusions(sequence<String> app_ids);
    void set_sync_images(boolean enabled);
}

// Core → shell (callbacks, delivered on a core thread; shell hops to main)
callback interface NodeDelegate {
    void apply_remote_clip(ClipItem item);            // write to OS clipboard
    void peer_state_changed(PeerSnapshot peer);       // online/offline/transport
    void incoming_pairing_request(PeerInfo peer, String sas_code);
    void pairing_completed(DeviceInfo device);
    void transfer_progress(TransferProgress p);
    void incoming_files_offer(FilesOffer offer);      // user accept/decline
    void notify(UserFacingEvent event);               // toasts, errors
}

// Shell-provided keystore so keys live in Keychain/DPAPI, not on disk
callback interface KeystoreAdapter {
    void put(String name, bytes value);
    bytes? get(String name);
    void delete(String name);
}
```

`ClipItem`:

```rust
struct ClipItem {
    id: String,            // ULID
    kind: ClipKind,        // Text | Rtf | Html | Image | FileRefs
    inline_data: Option<Vec<u8>>,  // present when <= 512 KiB
    blob_ref: Option<BlobRef>,     // content-addressed ref when larger
    text_preview: String,          // for history list + FTS index
    origin_device: String,
    hlc: HybridLogicalClock,
    created_at_ms: u64,
}
```

## Data flow: one clipboard copy, end to end

1. User hits ⌘C on the Mac. Shell's poll sees `changeCount` bump, reads the richest
   supported representation (see 04), checks the concealed/transient types and the
   frontmost-app exclusion list **in the shell** (fail-closed: excluded items never
   cross the FFI boundary), then calls `local_clipboard_changed`.
2. Core `sync_engine`: assigns ULID + HLC timestamp, dedupe check (BLAKE3 of
   normalized content vs. last N hashes — kills echo loops), writes to history DB,
   then serializes a `ClipboardItem` protobuf frame.
3. `transport` encrypts the frame in the established Noise session and sends it on
   the clipboard QUIC stream to every online paired peer (MVP: exactly one).
4. Windows core receives, decrypts, dedupes (drops if it originated the same
   content — loop prevention layer 2), stores to its history, and fires
   `apply_remote_clip`.
5. Windows shell marks the write with its own "self-write" fingerprint (so its
   `WM_CLIPBOARDUPDATE` handler ignores the change it caused — loop prevention
   layer 1), then `SetClipboardData`.

Target budget: **< 150 ms LAN end-to-end** for text (measured copy→pasteable).

## Ordering and conflicts

Clipboards are last-writer-wins by nature; users expect "the newest copy anywhere
wins." We use a **Hybrid Logical Clock** (HLC) per device:

- Every `ClipItem` carries `(wall_ms, logical, device_id)`.
- On receive, a peer applies the item to the OS clipboard **only if** its HLC is
  greater than the HLC of the item currently occupying the clipboard.
- History keeps *everything* regardless of the clipboard race, so nothing is lost
  even when two machines copy simultaneously.

No CRDT needed — history is append-only per item, and the "current clipboard" is a
single LWW register. Keep it that simple.

## Failure behavior

- Peer offline → items queue in a bounded outbox (last 50 items or 20 MiB,
  configurable); flushed newest-first on reconnect, applying only the newest to the
  live clipboard and the rest to history.
- Transport drop → exponential backoff reconnect (0.5 s → 30 s cap) while
  re-running discovery; transport selection re-evaluates LAN vs relay each attempt.
- Core panic → shells run the core on a supervised thread; on panic, restart core
  with same config, surface a diagnostic toast, log to rotating file.
