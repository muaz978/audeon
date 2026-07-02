# 05 — File Transfer (Phase 2, M7)

Rides entirely on the transport from 03 — same pairing, same encryption, no new
trust decisions. The UX bar: drag a file onto the tray/menu icon (or hit
"Send to ⟨device⟩" in Finder/Explorer context menus later), progress appears on
both machines, file lands in Downloads/Bridgeboard.

## Protocol

```
Sender                                   Receiver
  │ FilesOffer{transfer_id,                │
  │   files:[{file_id, rel_path, size,     │
  │           blake3, mode, mtime}],       │
  │   total_size}                          │
  │ ───────────────────────────────────▶   │  UI: accept / decline
  │                    FilesAnswer{accept, │  (auto-accept from paired device
  │ ◀─────────────────  have:[{file_id,    │   is a per-device setting,
  │                       chunk_bitmap}]}  │   default ON for clipboard-size,
  │                                        │   ask for > 100 MB)
  │ per file: open uni QUIC stream:        │
  │   StreamHeader{transfer_id, file_id}   │
  │   then raw chunks (1 MiB):             │
  │   [u32 chunk_index | chunk bytes]      │
  │ ───────────────────────────────────▶   │  write sparse, verify per-chunk
  │                                        │  BLAKE3 (chunk hashes derived via
  │        FileChunkAck{file_id, bitmap}   │  blake3 tree mode), ack on control
  │ ◀────────────────  (every 32 chunks)   │  stream
  │ FilesDone / receiver verifies          │
  │   whole-file blake3 → Complete{ok}     │
```

Design points:

- **Resume:** receiver persists `{transfer_id, file_id, chunk_bitmap}` in SQLite;
  a re-offer of the same content hash resumes via the `have` bitmaps. Survives
  app restart and network flap.
- **Backpressure:** QUIC stream flow control does the work; sender writes chunks
  as fast as the stream accepts. One stream per file, max 4 concurrent file
  streams (config) so a big file doesn't starve the clipboard stream (QUIC
  stream priority: control > clipboard > files).
- **Integrity:** per-chunk BLAKE3 (reject/rerequest bad chunks) + whole-file hash
  before rename from `*.part` to final name.
- **Paths:** receiver controls destination, always. `rel_path` is sanitized
  (reject `..`, absolute paths, reserved names, symlinks materialize as files);
  collisions get ` (2)` suffixes. Directories = files with `rel_path` prefixes.
- **Metadata:** preserve mtime and the executable bit (mode) where the receiving
  OS supports it; nothing else in v1 (no xattrs/ACLs/resource forks — document).
- **Speed target:** saturate the LAN — ≥ 80 MB/s on gigabit, ≥ 40 MB/s on good
  Wi-Fi 5. This embarrasses the "500 KB/s LocalSend" complaints and is mostly
  free with QUIC if we don't fumble buffer sizes (`quinn` defaults are close;
  tune `stream_receive_window` / `send_window` ≈ 8 MiB, test on real Wi-Fi).

## Shell integration

- **macOS:** menu-bar icon is a drag destination (`onDrop` of file URLs on the
  `MenuBarExtra` label is unreliable — use a transparent drop-window that appears
  when a drag nears the icon, or the history window as drop target; prototype in
  M7 spike). Also a Services/Share-extension entry ("Send to PC") later.
- **Windows:** tray icons can't be drop targets — provide a small always-on-top
  **drop overlay** summoned by hotkey or when a drag starts while the history
  window is open; plus "Send to Mac" in the Explorer context menu (registry
  `shell` verb, classic context menu; Win11 modern menu needs a sparse MSIX —
  defer).
- Received files: toast with "Open" / "Show in folder"; history window lists
  transfers with re-open actions.

## Clipboard `FILE_REFS` interplay

Copying files (⌘C in Finder / Ctrl+C in Explorer) produces a `FILE_REFS` clip
item. v1 behavior: the *references* sync as a history entry showing file names;
pasting on the other machine triggers an automatic transfer request back to the
origin device (which prompts there unless auto-accept). This turns "copy file on
Mac, paste on PC" into the magic moment — implement as M7 stretch once plain
transfers are solid.
