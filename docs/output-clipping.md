# Output Clipping Indicators

## Overview

mod-ui reports whether the audio **output** (Output 1 / Output 2, the system
playback path) is clipping, and forwards boolean clip transitions to WebSocket
clients (the browser UI and pi-stomp). pi-stomp drives two LCD indicators from
these messages.

The design goal was a clip signal that costs almost nothing on the Raspberry Pi.
The naive approach — streaming every output meter value to mod-ui and diffing in
Python — was rejected: that stream runs at hundreds of messages/second and the
Python read-socket parsing alone cost ~15% CPU on the Pi (the same reason
`output_set` is suppressed for local clients; see
[output-data-flow.md](output-data-flow.md)).

Instead, **all the high-rate work stays in mod-host's real-time thread**, which
emits a message only when the clip state *changes*. mod-ui sees a handful of
messages per second at most.

> Input clipping is **not** handled here — pi-stomp has dedicated hardware input
> clipping LEDs. The same mechanism could tap `system:capture_1/2` if that ever
> changes.

## Data Flow

```
mod-host (C, RT thread)        mod-ui (host.py, Python)        WebSocket clients
        |                              |                        (browser + pi-stomp)
        |  per audio block:            |                               |
        |  scan mod-monitor:out_1      |                               |
        |  for |sample| >= threshold   |                               |
        |  apply hold hysteresis       |                               |
        |  -- only on transition: --   |                               |
        |-- audio_clip mod-monitor:out_1 1 -->                         |
        |   (feedback socket 5556)     |-- clip_status out_1 1 ------->|
        |                              |                               |
        |  ... signal drops ...        |                               |
        |-- audio_clip mod-monitor:out_1 0 -->                         |
        |                              |-- clip_status out_1 0 ------->|
        |                              |                               |
        |                       every 5s: re-broadcast last-known      |
        |                       state to heal out-of-sync clients      |
        |                              |-- clip_status out_1 0 ------->|
```

Two transports are involved, and mod-ui is the translator between them:

- **mod-host <-> mod-ui**: raw line-based TCP. Commands go out on the write
  socket (5555); feedback (`output_set`, `param_set`, and now `audio_clip`)
  comes back on the read socket (5556).
- **mod-ui <-> clients**: WebSocket, via `msg_callback`. Unlike `output_set`,
  `clip_status` is **not** suppressed for local pi-stomp clients — it is sparse
  and tiny, so pi-stomp gets clip status without re-enabling meter spam.

## mod-host Side

mod-host taps a JACK port by name and detects clipping entirely in the RT
process callback. This reuses the existing audio-monitor machinery
(`effects_monitor_audio_levels`), but clip monitors **skip the peak-value
stream** and report only boolean edges.

### Command

```
monitor_audio_clip <jack-port> <enable> <threshold> <hold_ms>
```

- `jack-port`   — source port to watch, e.g. `mod-monitor:out_1`
- `enable`      — `1` to start, `0` to stop
- `threshold`   — linear peak that counts as clipping (knob 1)
- `hold_ms`     — ms below threshold before the indicator clears (knob 2)

Implemented by `effects_monitor_audio_clip()` (`effects.c`), registered as
`MONITOR_AUDIO_CLIP` (`mod-host.h`) with callback `monitor_audio_clip_cb`
(`mod-host.c`).

### RT detection

In the audio-monitor loop (`effects.c`, process callback), a clip-enabled
monitor:

1. Scans the block for the first sample with `|sample| >= threshold`
   (early-exit on first hit — strictly less work than a peak meter).
2. Turns the indicator **on** immediately on the first over-threshold block.
3. Turns it **off** only after `hold_ms` of *consecutive* below-threshold audio
   (hysteresis — prevents flicker on sustained clipping, and guarantees a single
   transient stays visible for at least `hold_ms`).
4. Posts a `POSTPONED_AUDIO_CLIP` event **only on a state change**.

### Feedback

The postpone handler emits name-keyed feedback:

```
audio_clip <jack-port> <0|1>
```

Name-keying (rather than a bare monitor index) makes mod-ui's mapping
order-independent and robust against the monitor array's LIFO teardown.

## mod-ui Side (`mod/host.py`)

### Tunable knobs

| Knob | Constant | Default | Effect |
|------|----------|---------|--------|
| 1 | `CLIP_THRESHOLD` | `0.999` (~0 dBFS) | Peak level counted as clipping |
| 2 | `CLIP_HOLD_MS` | `250` | Time below threshold before the LED clears |
| 4 | `CLIP_RESEND_SEC` | `5.0` | Periodic re-broadcast interval |
| 5 | `CLIP_MONITORS` | out 1/2 | Which JACK ports to watch + client labels |

(Knobs 1 and 2 are passed down in the command, so they can be tuned without
rebuilding mod-host. Knob 3 — a separate minimum-on time — was deliberately
dropped: the hold time already guarantees minimum visibility.)

### Setup

Clip monitors tap `mod-monitor:out_1/2`, which are **stable system ports** that
persist across pedalboard changes, so they are enabled **once** in `init_host`
and re-registered in the crash-recovery path of `report_current_state`.

```python
for port, _ in CLIP_MONITORS:
    self.send_notmodified("monitor_audio_clip %s 1 %f %d" % (port, CLIP_THRESHOLD, CLIP_HOLD_MS))
self.cliptimer.start()
```

> **Startup ordering is safe.** `mod-monitor` is an internal JACK client that
> mod-host opens during its own `effects_init()`, *before* it starts listening
> on port 5555. mod-ui is gated (by `wait-for-mod-host.sh` on the pi-stomp image)
> until 5555 is listening, so `mod-monitor:out_1/2` always exist by the time the
> one-shot `jack_connect()` runs.

### Forwarding

A new dispatch branch in `process_read_message_body` parses the name-keyed
feedback and forwards a transition to clients:

```python
elif cmd == "audio_clip":
    port, val = data.rsplit(" ", 1)
    clipping = bool(int(val))
    if self.clip_state.get(port) != clipping:
        self.clip_state[port] = clipping
        self.msg_callback("clip_status %s %d" % (self.clip_labels.get(port, port), int(clipping)))
```

### Healing out-of-sync clients

mod-host only emits *transitions*, so a client that connects late or drops a
message could hold a stale value. Two cheap, Python-only safety nets cover this
(neither touches the read-socket hot path):

- **On connect:** `report_current_state` seeds the current `clip_state` to the
  new client.
- **Every `CLIP_RESEND_SEC`:** `clip_heal_callback` re-broadcasts last-known
  state from memory.

## Client Protocol

Clients receive a single message type:

```
clip_status <label> <0|1>
```

e.g. `clip_status out_1 1` (Output 1 started clipping),
`clip_status out_2 0` (Output 2 stopped clipping). Labels are
space-free so the message stays cleanly space-delimited; they come from
`CLIP_MONITORS`. The desktop browser ignores unknown messages, so it is
unaffected; pi-stomp maps each label to an LCD indicator.
