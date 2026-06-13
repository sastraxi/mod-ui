# mod-host Output Data Flow

## Overview

mod-host continuously produces two kinds of feedback on its read socket (port 5556):

- **`output_set`** — real-time meter/scope values (audio level, parameter outputs)
- **`param_set`** — state changes: bypass toggles, parameter edits, MIDI-learn assignments

These share the same socket and the same flow-control mechanism.

## The `data_finish` / `output_data_ready` Handshake

mod-host batches one frame of output data, then signals the end:

```
mod-host                    mod-ui (host.py)              WebSocket clients
    |                            |                               |
    |-- output_set inst A ------>|                               |
    |-- output_set inst B ------>|-- output_set inst A --------->|
    |-- param_set X :bypass 1 ->|-- output_set inst B --------->|
    |-- data_finish ------------>|-- param_set X :bypass 1.0 --->|
    |                            |                               |
    |                            |-- data_ready N -------------->|
    |                            |                               |
    |                            |<-- data_ready N --------------|
    |                            |   (browser echoes back)       |
    |<-- output_data_ready ------|                               |
    |                            |                               |
    |  (next frame unlocked)     |                               |
    |-- output_set inst A ------>|                               |
    ...
```

**`output_data_ready` is the unlock signal.** Until mod-ui sends it back to mod-host,
mod-host will not produce the next frame. This means `param_set :bypass` echoes (and
all other feedback) stall if `output_data_ready` is never sent.

### mod-ui side (`host.py: process_read_message_body`)

```python
if msg == "data_finish":
    if self.web_connected:          # any WebSocket client is open
        self.web_data_ready_ok = False
        self.web_data_ready_counter += 1
        self.msg_callback("data_ready %i" % counter)
        return                      # wait for client echo
    else:
        yield gen.Task(self.send_output_data_ready, now)   # no client: use timer
```

### Client echo path (`session.py: ws_data_ready`)

```python
def ws_data_ready(self, counter):
    if self.host.web_data_ready_counter == counter:
        self.host.web_data_ready_ok = True
        self.host.send_output_data_ready(None, None)   # sends output_data_ready to mod-host
```

### `send_output_data_ready` (`host.py`)

```python
def send_output_data_ready(self, now, callback):
    ...
    self.send_notmodified("output_data_ready", callback)   # write socket → mod-host
```

## Local Client Optimization (`_is_local`)

pi-stomp connects from `127.0.0.1`; browsers connect from LAN IPs.
Local clients don't need meter spam, so `msg_callback` skips `output_set` and
`data_ready` for them (`session.py: websocket_opened` sets `ws._is_local = True`).

**Problem:** if all connected clients are local, `data_ready` is sent to nobody,
nobody echoes, and `output_data_ready` is never sent to mod-host → everything stalls.

**Fix (`session.py: msg_callback`):** when `data_ready` was suppressed for every
connected client, self-acknowledge immediately — mirroring what a real browser echo
would do:

```python
if msg.startswith("data_ready ") and not any_non_local_received:
    self.host.web_data_ready_ok = True
    self.host.send_output_data_ready(None, None)
```

When a browser is also open (LAN IP → not `_is_local`), it receives `data_ready`
normally, echoes back, and the real handshake runs. The self-acknowledge only fires
when pi-stomp is the sole client.

## Why the Browser Throttles

The browser JavaScript delays its echo by 25 ms before sending `data_ready` back.
This caps the `output_set` update rate at ~40 fps, preventing DOM update starvation
on pedalboards with many parameters.
