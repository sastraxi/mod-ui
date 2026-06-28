# pi-stomp Web UI — Developer Reference

This document covers the codebase structure, key architectural decisions, and how to extend the app. For user-facing feature documentation see [`docs/webapp.md`](webapp.md).

---

## Files that make up the app

| File | Role |
|------|------|
| `html/index.html` | Entry point; Tornado template that injects server config as JS globals |
| `html/js/desktop.js` | Root `Desktop` object — instantiated once, holds references to all panels |
| `html/js/pedalboard.js` | `pedalboard` jQuery plugin — the canvas, connection manager, and plugin rendering |
| `html/js/effects.js` | `effectBox` jQuery plugin — the installed-plugin browser panel |
| `html/js/host.js` | WebSocket client — single `ws` connection, dispatches every incoming message |
| `html/js/snapshot.js` | `SnapshotsManager` — snapshot list panel and rename/save UI |
| `html/js/transport.js` | `TransportControls` — BPM/BPB/rolling panel |
| `html/js/hardware.js` | `HardwareManager` — parameter-to-actuator addressing logic |
| `html/js/pedalboards.js` | `pedalboardBox` jQuery plugin — pedalboard list panel |
| `html/js/banks.js` | Bank list panel |
| `html/js/patchstorage.js` | PatchStorage store panel and API client |
| `html/js/cc-manager.js` | Control Chain device management |
| `html/js/installation.js` | `InstallationQueue` — serialises plugin/pedalboard installs |
| `mod/webserver.py` | All HTTP endpoints (Tornado handlers) and WebSocket handler |
| `mod/session.py` | WebSocket session management; local vs. remote client logic |
| `mod/host.py` | mod-host command bridge; processes feedback socket and dispatches to WebSocket |

## Technologies

- **Python / Tornado** — async webserver; no framework beyond Tornado itself
- **jQuery 1.9.1 + jQuery UI** — DOM manipulation; most panels are implemented as jQuery plugins via a thin `JqueryClass` helper
- **Mustache** — template rendering for plugin/pedalboard list items
- **lunr.js** — client-side full-text search for plugin and pedalboard names
- **lilv (C++)** — LV2 plugin discovery via `utils/utils_lilv.cpp`, compiled into `libmod_utils.so`
- No module bundler; all JS is loaded as individual `<script>` tags with a `?v={{version}}` cache-buster

## Key objects and concepts

**`Desktop`** (`desktop.js:4`) is the root controller. It is instantiated once in `index.html` and receives jQuery references to every named UI element. All panels communicate back through `Desktop` methods. If you are adding a new panel or toolbar button, this is where you wire it in.

**`pedalboard` jQuery plugin** (`pedalboard.js`) manages the canvas. Internally it tracks:
- `plugins` — map of `instance → plugin data`
- `connectionManager` — tracks which output port is connected to which input port

Mutations are driven by WebSocket messages (`add`, `remove`, `connect`, `disconnect`, `param_set`, `plugin_pos`) rather than by user interaction dispatching directly. This means the same code path runs whether a change comes from the browser or from pi-stomp.

**`effectBox` jQuery plugin** (`effects.js`) is the installed-plugin browser. It uses `Desktop.pluginIndexer` (lunr) for search and fetches plugin metadata from `/effect/list` on startup.

**`SnapshotsManager`** (`snapshot.js:4`) owns the snapshot list. Snapshot switches send `POST /snapshot/load`; saves send `POST /snapshot/save` or `POST /snapshot/saveas`. The server broadcasts `pedal_snapshot <index> <name>` over WebSocket to all clients when the active snapshot changes.

**`HardwareManager`** (`hardware.js`) maps plugin parameters to physical actuators. Addressing data arrives over WebSocket as `hw_map`, `midi_map`, and `cv_map` messages when a pedalboard loads.

**`InstallationQueue`** (`installation.js`) ensures that plugin installs are serialised — never two concurrent downloads — and surfaces progress to the user.

---

## Architectural decisions

**WebSocket is the real-time state bus.** Every audio-state change — parameter values, bypass toggles, plugin additions, snapshot switches, transport changes — flows through the single WebSocket connection as a text message. REST calls handle configuration, queries, and one-shot actions (save, load, install). This keeps the browser state consistent without polling.

**The server pushes; the browser reflects.** Rather than the browser directly mutating its own state on user gesture, every mutation goes to the server first (via REST or a WebSocket send), and the server echoes the result back as a push message. This means pi-stomp, the browser, and any other client all see the same stream. See [`docs/output-data-flow.md`](output-data-flow.md) for how the meter handshake works within this model.

**Local clients bypass meter flow-control.** pi-stomp connects from `127.0.0.1` and is flagged as a local client in `session.py`. It does not receive `output_set` meter data or `data_ready` handshake messages — it self-acknowledges immediately. This prevents a hardware client from ever stalling audio feedback. See [`docs/output-data-flow.md`](output-data-flow.md) for the full handshake.

**Background browser tabs are excluded from the meter loop.** When a browser tab becomes hidden, it sends `client_hidden` over the WebSocket. The server then skips that tab for both `output_set` and `data_ready`, so a backgrounded tab cannot stall the meter clock. The tab sends `client_visible` when it returns to the foreground. Commit `c1ffe8f8` ("Working background tabs") introduced this mechanism.

**Plugin installation is live.** Installing a plugin via PatchStorage or the SDK endpoint calls both `bundle_add` on mod-host and `add_bundle_to_lilv_world` in the in-process lilv world. No restart is required. See [`docs/plugin-scanning.md`](plugin-scanning.md) for the full path and its current limitations.

**Pedalboard loading is batched.** When a pedalboard loads, `host.js` opens a `pendingPlugins` buffer. All `add` messages received during the `loading_start` → `loading_end` window are collected and then fetched in a single bulk request to `/effect/bulk/` instead of one `/effect/get` per plugin. Commit `40eb3876` ("Actually crazy fast pedalboard loading") introduced this; before it, large boards could take several seconds to paint.

**Nested pedalboard directories are a C++ concern.** The one-level-deep directory walk is in `utils/utils_lilv.cpp`. The Python and browser layers see flat bundle paths; they do not know or care about the parent directory. The walk is bounded at 2 levels, caps each scan at 1024 entries, and only appends sub-folders that directly contain at least one `.pedalboard` child.

**Snapshots persist to disk immediately.** Before commit `135afb51`, snapshot state was only written on explicit user action or pedalboard save. Now every snapshot save writes to disk immediately, so a power cycle right after saving a snapshot does not lose the change.

**BPM is part of the transport, not of individual plugins.** The BPM/BPB values are stored in snapshots (commit `3813b2d6`) and broadcast to all WebSocket clients when changed (commit `7c403535`). Any client — browser tab or pi-stomp — that sets BPM causes all others to reflect the new value.

---

## How to extend the app

### Adding a new WebSocket message (server → browser)

1. Emit the message from Python: call `self.msg_callback("your_cmd <args>")` in `host.py` or `session.py`.
2. Handle it in `host.js`: add an `if (cmd == "your_cmd")` branch in `ws.onmessage`. Parse `data` and call the relevant `Desktop` or `desktop.pedalboard` method.
3. If the message carries state that pi-stomp needs to react to, add a handler in the pi-stomp WebSocket client as described in the pi-stomp integration section below.
4. Note that `loading_start` and `loading_end` frame every pedalboard load. If your new message is only valid outside a load, check `pb_loading` in `host.js` before acting on it.

### Adding a new REST endpoint

Follow the pattern in `mod/webserver.py`: subclass `tornado.web.RequestHandler`, add a `get` or `post` method, then register the URL in `url_patterns` at the bottom of the file. If the endpoint mutates plugin or pedalboard state, call the corresponding method on `SESSION.host`.

### Adding a new UI panel or toolbar button

1. Add the HTML element to `html/index.html` (or the appropriate `html/include/*.html` template).
2. Pass a jQuery reference to it in the `Desktop(elements)` call in `index.html`.
3. Accept it in the `elements` parameter of `Desktop` (`desktop.js`) and initialise it there.
4. Implement the panel as a jQuery plugin (see `effects.js` for the `effectBox` pattern) or as a plain object (see `snapshot.js` for `SnapshotsManager`).

### The echo problem

When any client — browser or pi-stomp — sends a command that changes state, the server broadcasts the result to **all** connected clients, including the sender. pi-stomp already has echo-suppression for some message types. If you add a new action that pi-stomp initiates and the server echoes back, check whether pi-stomp's WebSocket handler needs to suppress its own echo for that message type.

---

## Integrating with pi-stomp (`../pi-stomp`)

pi-stomp connects to mod-ui via a WebSocket bridge implemented in `../pi-stomp/modalapi/websocket_bridge.py` (`AsyncWebSocketBridge`). It runs on a daemon thread with exponential backoff reconnection (up to 4 attempts before the service exits). State changes are drained every 10 ms on the main polling loop (`modalapistomp.py:220`).

**WebSocket** (`ws://localhost:80/websocket` — loopback, so pi-stomp is classified as a local client and never receives meter data or `data_ready` handshake messages):

Messages pi-stomp receives and handles (`../pi-stomp/modalapi/ws_protocol.py` defines all message types; dispatch lives in `modhandler.py:516`):

| Message | Meaning | pi-stomp action |
|---------|---------|----------------|
| `loading_start <isDefault>` | Pedalboard is being torn down and rebuilt | Suppresses outbound param_set; flushes stale outbound queue |
| `loading_end <snapshotIndex>` | Pedalboard fully loaded | Clears loading flag; stashes snapshot index for file-watch path |
| `pedal_snapshot <index> <name>` | Active snapshot changed | Updates LCD title; may activate blend mode |
| `param_set /graph/<instance> :bypass <0|1>` | Plugin bypassed/unbypassed | Updates plugin state; redraws LCD and LED |
| `param_set /graph/<instance> <symbol> <value>` | Parameter value changed | Caches value; mirrors onto bound controls |
| `add <instance> <uri> …` | Plugin added to pedalboard | Buffers bypass state during load; registers plugin |
| `remove <instance>` | Plugin removed | Removes from pedalboard plugin list |
| `connect / disconnect` | Port wiring changed | Used for state reconciliation |
| `midi_map <instance> <symbol> <ch> <cc>` | MIDI binding learned | Updates MIDI CC map |
| `transport <rolling> <bpb> <bpm> <mode>` | Transport state changed | Caches BPM for tap-tempo display |
| `truebypass <left> <right>` | Relay bypass state changed | Updates relay hardware |
| `clip_status <label> <0|1>` | Output clip detected/cleared | Can light an LED |

`output_set` (audio meter data) is **dropped at the WebSocket layer** before it enters the queue — it never reaches the main thread.

Messages pi-stomp **sends** over the WebSocket:
- `param_set /graph/<instance>/<symbol> <value>` — parameter change from encoder or LCD (`modhandler.py:1050`)
- `transport-bpm <value>` — tap tempo BPM

Parameter sets also go via a dedicated REST endpoint:
- `GET /effect/parameter/pi_stomp_set/<instance>/<symbol>?value=<v>`

**File-watch polling**: pi-stomp monitors `~/.pedalboards/last.json` (mtime-based, every 1000 ms). When the mtime changes, it reads the `pedalboard` field and reloads the pedalboard via LILV if it changed. This is the backup path for pedalboard switches that happen without a WebSocket connection being open.

**Echo suppression strategy**: footswitches route through MIDI CC → mod-host → `param_set` echo back to pi-stomp (reconciliation via echo). Non-footswitch UI bypasses go direct WebSocket → mod-ui; pi-stomp updates the display optimistically, then reconciles when the echo arrives with the authoritative value. The suppression logic is in `modhandler.py:1026`.

**Blend mode**: pi-stomp has a snapshot interpolation feature (`../pi-stomp/blend/`) that reads an analog input (expression pedal position) and linearly interpolates plugin parameter values between two snapshots. It intercepts hardware events when active and sends only changed parameters to avoid MIDI CC conflicts.

### Checklist for adding a new feature that pi-stomp reacts to

1. Add the message type to `../pi-stomp/modalapi/ws_protocol.py` (a `dataclass` + a branch in `parse_message`).
2. Add a handler in `modhandler.py:_handle_ws_message`.
3. If pi-stomp initiates the action and the server echoes it back, decide whether echo suppression is needed in `websocket_bridge.py`.
4. If the new state should survive a WebSocket reconnect, ensure it is reflected in `last.json` or re-sent in the post-connect `loading_end` dump.
5. See `../pi-stomp/GUIDE.md` (MOD Integration section) for architectural context on the polling loop and pedalboard data loading.

---

*Last updated: 2026-06-27. See also [`docs/output-data-flow.md`](output-data-flow.md) and [`docs/plugin-scanning.md`](plugin-scanning.md).*
