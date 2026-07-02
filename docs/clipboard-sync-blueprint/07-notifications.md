# 07 — Notification Mirroring (Phase 3)

Positioned as bonus, not headline — and the platform realities agree. This doc
records exactly what is possible so scope decisions later are made with eyes open.

## Reality matrix

| Source → shown on | Feasible? | Mechanism |
|---|---|---|
| Android → Mac/PC | **Yes, fully** | Companion app with `NotificationListenerService`: full content, dismiss-sync, reply actions (`RemoteInput`) |
| iPhone → Mac/PC | **Barely** | No public notification-read API. Only path: BLE **ANCS** (Apple Notification Center Service) — device acts as a BLE accessory. KDE Connect/Windows tried; fragile, limited, needs proximity. **Defer indefinitely; do not promise.** |
| Mac → PC (desktop-to-desktop) | **No public API** | Reading other apps' notifications requires private APIs / SIP-off hacks. Out of scope. |
| PC → Mac | **Partial, unsupported** | `UserNotificationListener` (WinRT) exists but is flaky for third-party listeners. Prototype-only; not a commitment. |

**Conclusion:** Phase 3 = **Android companion app**, mirroring to both desktops.
This also quietly covers the Pushbullet-refugee use case (SMS notifications on
desktop). iPhone users get clipboard/file features only — say so plainly on the
pricing page rather than disappoint.

## Android companion design

- Kotlin app, same `bridgeboard-core` via UniFFI Kotlin bindings (the D1/D2 bet
  paying off): pairing, transport, relay all identical; phone is just a third
  device kind with capability flags `{notifications, clipboard_send}`.
- `NotificationListenerService` → filter (per-app include list, default
  messaging apps on) → `NotificationEvent` frames on a new stream type:

```proto
message NotificationEvent {
  string key = 1;              // Android notification key (dedupe/dismiss)
  string app_package = 2;
  string app_label = 3;
  string title = 4;
  string body = 5;
  bytes icon_png = 6;          // small, cached by hash
  repeated NotifAction actions = 7;   // reply/mark-read via RemoteInput
  uint64 posted_at_ms = 8;
  bool dismissed = 9;          // dismiss-sync both directions
}
```

- Desktop display: native toasts (`UNUserNotificationCenter` /
  `AppNotificationManager`) with action buttons wired back to
  `NotificationAction{key, action_index, reply_text}`.
- Battery: notifications ride the existing connection; on Android use
  foreground service (required for listener reliability anyway) + relay
  connection with long keepalive (4 min) when off-LAN.
- Privacy: same E2EE; notification content also honors a per-app "title only"
  redaction mode (lock-screen-style) for shared/office desktops.

## Android clipboard caveat

Android 10+ blocks background clipboard reads. Mirroring phone→desktop clipboard
works only via share-sheet ("Send to desktop") or foreground app. Desktop→phone
works (we can set the clipboard). Scope the marketing accordingly.
