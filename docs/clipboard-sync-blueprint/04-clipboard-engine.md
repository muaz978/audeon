# 04 — Clipboard Engine

The hardest-to-get-right subsystem, because both OS clipboard APIs are old, quirky,
and different. This doc pins down capture, normalization, injection, loop
prevention, exclusions, and history.

## Capture

### macOS — polling (no other way)

There is **no** pasteboard-change notification API on macOS. Every clipboard
manager polls `NSPasteboard.general.changeCount`. Ours:

- Timer at **200 ms** on a utility queue (measure battery impact; Maccy uses
  similar cadence and is fine). Back off to 1 s when no paired peer is online.
- On count change:
  1. Read `pasteboard.types`. If it contains `org.nspasteboard.ConcealedType`
     or `org.nspasteboard.TransientType` → **drop immediately** (this is how
     1Password etc. mark secrets; honoring it is table stakes).
  2. If frontmost app’s bundle ID is in the exclusion list → drop. (Caveat:
     frontmost-app is a heuristic — background apps can write the pasteboard.
     Also check `pasteboard.name`/owner where available. Documented limitation.)
  3. Read representations in priority order: `public.png` / `public.tiff`
     (convert TIFF→PNG in-shell), `public.rtf`, `public.html`, `public.utf8-plain-text`,
     `public.file-url` (→ `FILE_REFS`).
  4. Build `ClipItem`, call `local_clipboard_changed`.
- macOS 15.4+ shows a one-time "app accessed the clipboard" style prompt for
  background pasteboard reads — onboarding must explain this before first poll
  so the user expects and accepts it. (Watch this API area each macOS release;
  it's the platform risk for the whole category. Every clipboard manager shares it.)

### Windows — event-driven

- Message-only window (`HWND_MESSAGE`) + `AddClipboardFormatListener` →
  `WM_CLIPBOARDUPDATE`. No polling needed.
- On event:
  1. If `GetClipboardData` sees format `ExcludeClipboardContentFromMonitorProcessing`
     (or `CanIncludeInClipboardHistory` == 0) → drop. (Password managers set these.)
  2. `GetClipboardOwner()` → `GetWindowThreadProcessId` → exe path; if in
     exclusion list → drop. (Owner can be null; treat null as non-excluded but
     flag in item metadata.)
  3. Open clipboard with a **retry loop** (5 attempts, 10→100 ms backoff) —
     `OpenClipboard` fails routinely because another app holds it. Never block
     the message loop; do reads on a worker after cloning handles per the API rules.
  4. Read priority: `PNG`/`CF_DIBV5` (convert DIB→PNG), `CF_HTML`, RTF,
     `CF_UNICODETEXT`, `CF_HDROP` (→ `FILE_REFS`).
- Windows fires `WM_CLIPBOARDUPDATE` multiple times for some apps (Office
  delayed rendering); debounce 100 ms and dedupe by content hash.

## Normalization (in core)

- Text: keep exact bytes (UTF-8). `text_preview` = first 500 chars, control
  chars stripped.
- Rich text: send RTF + HTML + plain together in one item when available
  (`ClipItem` gets a `representations` list in the proto rather than a single
  kind — revise proto in M3). Receiver writes all representations it supports so
  paste targets pick the richest.
- Images: canonical wire format is **PNG**. Shell converts (TIFF/DIB→PNG) before
  the FFI call; core never links image codecs beyond validation.
- Cross-platform gotchas to encode in tests: CRLF↔LF is **not** normalized (paste
  targets expect what the source produced — Windows apps handle LF poorly, note as
  an opt-in setting "convert line endings"); Windows `CF_HTML` has a required
  header block that must be synthesized when injecting HTML.

## Injection

- **Self-write fingerprint (loop prevention layer 1):** before writing, the shell
  records BLAKE3(content); the capture path drops the next event whose hash
  matches. On macOS, additionally write a private marker type
  (`io.bridgeboard.origin`) alongside; on Windows, register a custom clipboard
  format with the origin device ID.
- **HLC gate (layer 2):** core only instructs injection if the remote item's HLC
  beats the HLC of the last item applied locally.
- **Origin dedupe (layer 3):** core drops any received item whose `origin_device`
  is itself, or whose content hash matches one of the last 16 sent hashes.
- Three layers because layer 1 races (another app can grab the clipboard between
  write and event) and layers use different identity notions (event vs content).

## Exclusion list (per-app, trust feature #1)

- Ships with defaults ON: 1Password, Bitwarden, KeePassXC, Dashlane, LastPass,
  Keeper, Windows Credential Manager UI, macOS Keychain Access, Enpass, Proton Pass.
  (Bundle IDs on macOS, exe names on Windows; table in `core/defaults.rs`, but
  matching happens in the shells so excluded content never crosses FFI.)
- Settings UI: running-app picker + manual add. Stored in config, synced *between
  the pair* only if the user opts in ("mirror settings").
- Also: honor the OS secret flags unconditionally (not user-disableable) and a
  global "pause sync" toggle in the tray/menu (with 15 min / 1 h / until-I-resume).

## History store (trust feature #2 / most-requested feature)

Schema (`rusqlite`, WAL mode):

```sql
CREATE TABLE items (
  id TEXT PRIMARY KEY,              -- ULID
  kind INTEGER NOT NULL,
  inline_data BLOB,                 -- encrypted (XChaCha20-Poly1305), <=512 KiB
  blob_hash BLOB,                   -- else content-addressed file in blobs/
  text_preview TEXT NOT NULL,       -- plaintext, powers FTS (documented tradeoff:
                                    --   encrypted-at-rest applies to full content;
                                    --   previews are indexable. Setting to disable.)
  origin_device TEXT NOT NULL,
  hlc_wall INTEGER, hlc_logical INTEGER,
  pinned INTEGER DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE VIRTUAL TABLE items_fts USING fts5(text_preview, content='items', content_rowid='rowid');
```

- Retention: default 30 days / 1,000 items / 500 MB blobs, whichever first;
  pinned items exempt. Nightly GC task; blob refcount check before delete.
- Search: FTS5 `MATCH` with prefix queries, ranked by recency-boosted bm25.
- History window UX targets (from Ditto/Maccy/Paste research): global hotkey →
  focused search field → arrow keys → ⏎ pastes into the previously focused app
  (macOS: `CGEvent` ⌘V synthesis with Accessibility permission, or
  copy-and-restore fallback if permission declined; Windows: `SendInput` Ctrl+V
  after re-focusing the prior foreground window — store `GetForegroundWindow`
  before showing).

## Large images / payload split

- ≤ 512 KiB → `inline_data` on the clipboard stream (fast path).
- > 512 KiB → item is sent immediately with `blob_ref` + preview; receiver shows
  it in history instantly and pulls the blob via `BlobRequest` over a bulk stream
  (same machinery as file transfer); clipboard injection happens when the blob
  lands. Cap syncable images at 20 MiB default (setting).
