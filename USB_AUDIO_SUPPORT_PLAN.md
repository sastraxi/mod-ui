# Plan: Add USB Audio Interface Support to MOD-UI

## Executive Summary

**Target Repository**: `../mod-ui/` **[mod-ui ONLY]**
**NO mod-host changes required** - problem is purely in the UI layer

**Scope**: Modify MOD-UI's port discovery to include USB audio interface ports (`USB_In:*`) alongside built-in hardware ports (`system:capture_*`) in the web interface's hardware routing display.

## Goal
Enable MOD-UI to recognize and display USB audio interfaces (specifically `USB_In` ports created by `alsa_in`) in the pedalboard routing interface, allowing users to route USB audio inputs to plugins without requiring manual JACK connections.

## Current State

### What Works
- USB audio interface (SF-558) is detected by ALSA as `card 1`
- `alsa_in` bridge is running as systemd service (`usb-audio-bridge.service`)
- JACK port `USB_In:USB_Audio_Capture_1` is created and visible in JACK
- Manual JACK connections work: `jack_connect USB_In:USB_Audio_Capture_1 effect_4:INPUT_L`

### What Doesn't Work
- USB_In ports don't appear in MOD-UI's hardware routing interface
- MOD-UI only shows `system:capture_*` ports as hardware inputs

## Architecture Overview

### Component Separation

**mod-host** (C, separate repository: `../mod-host/`)
- LV2 plugin host that runs the actual audio processing
- JACK client that connects plugins together
- Controlled via socket protocol by mod-ui
- **Does NOT handle UI or user interaction**

**mod-ui** (Python + JavaScript, repository: `../mod-ui/`)
- Web interface for controlling mod-host
- Sends commands to mod-host via socket
- Queries JACK for available ports
- Renders UI in browser

### Important: mod-host vs mod-ui Port Discovery

These are **independent** port discovery systems:

1. **mod-host discovers ports** (C code, `../mod-host/src/effects.c`):
   - Used when auto-connecting plugin inputs/outputs
   - Hardcoded to query for `"system"` prefix only
   - Stores results in `g_capture_ports` and `g_playback_ports`
   - **Only matters for automatic connections, not UI display**

2. **mod-ui discovers ports** (Python/C, `../mod-ui/modtools/utils.py`):
   - Used to populate the web UI's hardware routing interface
   - Calls native C extension `utils.get_jack_hardware_ports()`
   - Filters for `JackPortIsPhysical` flag
   - **This is what controls what the user sees in the browser**

### Critical Insight
**We only need to modify mod-ui, NOT mod-host**, because:
- Manual connections work fine (we tested `jack_connect USB_In:USB_Audio_Capture_1 effect_4:INPUT_L`)
- mod-host doesn't prevent non-system connections
- The problem is purely that mod-ui doesn't **show** USB ports in the UI
- Once mod-ui shows them, users can wire them normally

### Data Flow Diagram

```
JACK Layer
  ├─ system:capture_1 (IQaudIO L)  ◄─── Built-in audio card
  ├─ system:capture_2 (IQaudIO R)
  └─ USB_In:USB_Audio_Capture_1    ◄─── alsa_in bridge (USB interface)
         │
         │ Manual connection works! ✓
         ├─────► effect_4:INPUT_L
         │
         │ But hidden from UI ✗
         │
         ▼
    mod-ui Port Discovery **[THIS IS THE PROBLEM]**
    (modtools/utils.py → C extension)
         │
         │ Filters for JackPortIsPhysical only
         │ Excludes USB_In ports
         │
         ▼
    Returns: [system:capture_1, system:capture_2]
         │
         ▼
    mod-ui Frontend (JavaScript)
         │
         ▼
    Browser shows only 2 hardware inputs
```

**Solution**: Modify `modtools/utils.py` to also return `USB_In:*` ports

## Root Cause Analysis

### Port Discovery Flow (mod-ui only)

1. **Frontend** (`../mod-ui/html/js/pedalboard.js:552-559`) **[mod-ui]**:
   - JavaScript creates hardware port widgets
   - Based on `data.hardware.audio_ins` count received from backend
   - Generates symbols like `/graph/capture_1`, `/graph/capture_2`
   - Only creates ports for indices specified in hardware descriptor

2. **Backend** (`../mod-ui/mod/host.py:397`) **[mod-ui]**:
   - Python code sets `jack_hw_capture_prefix = "system:capture_"`
   - Used for mapping internal capture references to actual JACK ports
   - Controls which ports are considered "hardware inputs"

3. **Native Utils** (`../mod-ui/modtools/utils.py` → C extension) **[mod-ui]**:
   - C extension function `utils.get_jack_hardware_ports()`
   - Queries JACK for ports with `JackPortIsPhysical` flag
   - Filters for hardware-only ports
   - **This is where USB ports get filtered out**
   - Excludes bridged clients like `alsa_in`

4. **mod-host Port Query** (`../mod-host/src/effects.c`) **[mod-host - NOT RELEVANT]**:
   - Separate system in mod-host (don't need to modify)
   - Queries JACK: `jack_get_ports(client, "system", ...)`
   - Only used for automatic plugin connections
   - Not involved in UI display

### Why USB Ports Are Invisible
- `alsa_in` creates JACK client named "USB_In", not "system"
- Ports don't have `JackPortIsPhysical` flag (they're bridged, not physical)
- **mod-ui's** `get_jack_hardware_ports()` filters them out
- Result: USB ports never reach the browser UI

## Solution Options

**All solutions modify mod-ui ONLY** (no mod-host changes needed)

### Option A: Modify Native Utils (Recommended)
**Repository**: `../mod-ui/` **[mod-ui]**
**Pros**: Cleanest, works at the port discovery layer
**Cons**: Requires C compilation

**Changes Required**:

1. **File**: `../mod-ui/modtools/utils.cpp` (or `.c` - find the actual utils source) **[mod-ui]**
   - Locate `get_jack_hardware_ports()` function
   - Modify JACK port query to include specific non-physical ports
   - Add pattern matching for `USB_In:*` or configurable patterns

```cpp
// Current (pseudocode):
ports = jack_get_ports(client, NULL, JACK_DEFAULT_AUDIO_TYPE,
                       JackPortIsPhysical | (isOutput ? JackPortIsOutput : JackPortIsInput));

// Proposed:
// 1. Query physical ports as before
ports_physical = jack_get_ports(client, NULL, JACK_DEFAULT_AUDIO_TYPE,
                                JackPortIsPhysical | (isOutput ? JackPortIsOutput : JackPortIsInput));

// 2. Query additional USB ports
ports_usb = jack_get_ports(client, "USB_In:", JACK_DEFAULT_AUDIO_TYPE,
                           (isOutput ? JackPortIsOutput : JackPortIsInput));

// 3. Merge arrays
ports_combined = merge_port_arrays(ports_physical, ports_usb);
return ports_combined;
```

2. **File**: `../mod-ui/mod/settings.py` **[mod-ui]**
   - Add configuration for additional port patterns:

```python
# Settings for additional audio interfaces
ADDITIONAL_JACK_CAPTURE_PATTERNS = os.environ.get(
    'MOD_ADDITIONAL_CAPTURE_PATTERNS',
    'USB_In:'
).split(',')

ADDITIONAL_JACK_PLAYBACK_PATTERNS = os.environ.get(
    'MOD_ADDITIONAL_PLAYBACK_PATTERNS',
    ''
).split(',')
```

3. **File**: `/lib/systemd/system/mod-ui.service` **[piStomp system]**
   - Add environment variable:

```ini
Environment=MOD_ADDITIONAL_CAPTURE_PATTERNS=USB_In:
```

4. **Compilation**:
   - Rebuild native utils extension
   - Deploy updated `.so` file to piStomp

### Option B: Python-Layer Filtering
**Repository**: `../mod-ui/` **[mod-ui]**
**Pros**: No C compilation needed
**Cons**: Requires wrapper around native function

**Changes Required**:

1. **File**: `../mod-ui/modtools/utils.py` **[mod-ui]**

```python
# Keep existing C binding
def _get_jack_hardware_ports_native(isAudio, isOutput):
    return charPtrPtrToStringList(utils.get_jack_hardware_ports(isAudio, isOutput))

# New wrapper that adds USB ports
def get_jack_hardware_ports(isAudio, isOutput):
    from mod.settings import ADDITIONAL_JACK_CAPTURE_PATTERNS

    # Get physical ports from native code
    ports = _get_jack_hardware_ports_native(isAudio, isOutput)

    # Add USB audio interface ports if audio input
    if isAudio and not isOutput:
        try:
            import jack
            client = jack.Client('mod-ui-query', no_start_server=True)
            for pattern in ADDITIONAL_JACK_CAPTURE_PATTERNS:
                if pattern:
                    usb_ports = client.get_ports(pattern, is_audio=True, is_output=True)
                    ports.extend([p.name for p in usb_ports])
            client.close()
        except:
            pass  # Graceful fallback if JACK query fails

    return ports
```

2. **File**: `../mod-ui/requirements.txt` or `setup.py` **[mod-ui]**
   - Add dependency: `JACK-Client>=0.5.4` (Python JACK library)

### Option C: Hardware Descriptor File
**Repository**: `../mod-ui/` + piStomp system **[mod-ui + system]**
**Pros**: No code changes, configuration-only
**Cons**: May not fully work without code changes to handle non-system ports

**Changes Required**:

1. **File**: `/etc/mod-hardware-descriptor.json` **[piStomp system]** (create on piStomp)

```json
{
  "platform": "piStomp",
  "audio_ins": 3,
  "audio_outs": 2,
  "additional_audio_inputs": [
    {
      "jack_port": "USB_In:USB_Audio_Capture_1",
      "symbol": "usb_capture_1",
      "name": "USB Audio In"
    }
  ]
}
```

2. **File**: `../mod-ui/mod/host.py` **[mod-ui]**
   - Modify port mapping to recognize `additional_audio_inputs`
   - Update `get_jack_source_port_name()` to handle USB ports

**Note**: This option likely still requires code changes to actually use the descriptor.

### Option D: Create System Port Aliases (JACK-level hack)
**Pros**: No MOD code changes
**Cons**: Fragile, may break with JACK updates

**Not recommended** - JACK doesn't easily support client name aliasing.

## Recommended Implementation Plan

### Phase 1: Option B (Python Wrapper) - Quick Win
This gets USB ports working without C compilation.

**Repository**: `../mod-ui/` **[mod-ui only]**

**Files to Modify**:
1. `../mod-ui/modtools/utils.py` **[mod-ui]** - Add wrapper function
2. `../mod-ui/mod/settings.py` **[mod-ui]** - Add configuration variables
3. `/lib/systemd/system/mod-ui.service` **[piStomp system]** - Add environment variable

**Deployment**:
```bash
# Local development
cd /Users/cam/dev/mod-ui
# Make changes...

# Deploy to piStomp
scp modtools/utils.py pistomp@pistomp.local:/usr/local/lib/python3.11/dist-packages/modtools/
scp mod/settings.py pistomp@pistomp.local:/usr/local/lib/python3.11/dist-packages/mod/

# Update service file
ssh pistomp@pistomp.local "sudo nano /lib/systemd/system/mod-ui.service"
ssh pistomp@pistomp.local "sudo systemctl daemon-reload && sudo systemctl restart mod-ui"
```

**Testing**:
1. Open MOD-UI in browser
2. Load a pedalboard
3. Check hardware routing - should see USB Audio In option
4. Wire USB input to plugin
5. Test with audio source connected to USB interface

### Phase 2: Option A (Native Code) - Proper Fix
Once Python approach is validated, implement properly in C.

**Files to Modify**:
1. Find utils C/C++ source (likely in `modtools/` or separate repo)
2. Modify `get_jack_hardware_ports()` to include configurable patterns
3. Rebuild and deploy native extension

## Testing Checklist

- [ ] USB_In port appears in MOD-UI hardware routing interface
- [ ] Can wire USB_In to plugin inputs via UI
- [ ] Audio flows from USB interface through plugins
- [ ] Connections persist across pedalboard changes
- [ ] USB interface disconnect/reconnect handled gracefully
- [ ] No regression: system:capture_1/2 still work
- [ ] MIDI ports still work (ensure changes don't break MIDI discovery)
- [ ] Performance: no increased latency on main IQaudIO inputs
- [ ] Service survives reboot

## Rollback Plan

If changes break MOD-UI:

```bash
# Restore original files from backup
ssh pistomp@pistomp.local "
  sudo cp /usr/local/lib/python3.11/dist-packages/modtools/utils.py.backup \
          /usr/local/lib/python3.11/dist-packages/modtools/utils.py
  sudo systemctl restart mod-ui
"
```

## Future Enhancements

1. **Dynamic USB Device Detection**
   - Monitor for USB audio device hotplug
   - Update available ports without restart

2. **Multi-USB Interface Support**
   - Support multiple USB interfaces simultaneously
   - Configurable per-device settings

3. **UI Improvements**
   - Differentiate USB ports visually from built-in ports
   - Show connection status/health

4. **Configuration GUI**
   - Allow enabling/disabling USB interfaces via MOD-UI settings
   - Configure port names and labels

## Open Questions

1. Where is the native `utils` module source code?
   - May be in separate `mod-utilities` or `mod-python-modules` repo
   - Could be built in-tree in `modtools/`

2. Does MOD-UI support Python JACK library?
   - May need to use `ctypes` with libjack instead
   - Or use subprocess calls to `jack_lsp`

3. Will frontend auto-refresh port list?
   - May need WebSocket message to trigger reload
   - Check `mod/webserver.py` WebSocket handlers

## Related Files Reference

### mod-ui Repository (`../mod-ui/`) **[mod-ui]**

**Python Backend**:
- `mod/settings.py` - Configuration constants
- `mod/__init__.py` - Hardware descriptor loading
- `mod/host.py` - JACK port mapping, prefix handling
- `mod/webserver.py` - HTTP API, hardware descriptor endpoints
- `modtools/utils.py` - JACK port query wrapper (Python)
- `modtools/utils.cpp` (or .c) - Native JACK port query C extension (need to locate)

**JavaScript Frontend**:
- `html/js/pedalboard.js` - Hardware port widget creation
  - Lines 552-559: `createHardwarePorts()` function
  - Lines 590-602: MIDI port creation (reference for similar approach)

### mod-host Repository (`../mod-host/`) **[mod-host - NOT NEEDED]**

**C Code** (NO CHANGES REQUIRED):
- `src/effects.c` - Port discovery and connection logic
  - Uses: `jack_get_ports(client, "system", ...)`
  - Stores: `g_capture_ports`, `g_playback_ports`
  - **This code does NOT need modification** - only affects auto-connection

### piStomp System Files **[piStomp system]**

**System Configuration**:
- `/lib/systemd/system/mod-ui.service` - MOD-UI service
- `/lib/systemd/system/usb-audio-bridge.service` - USB bridge (already created)
- `/etc/mod-hardware-descriptor.json` - Hardware config (optional, doesn't exist yet)

## Dependencies

- JACK-Client Python library (for Option B)
- C compiler and JACK development headers (for Option A)
- Access to native utils module source code (for Option A)

## Estimated Effort

- **Option B (Python)**: 2-3 hours (implementation + testing)
- **Option A (Native)**: 4-6 hours (if source available, includes build setup)
- **Testing & Validation**: 2 hours
- **Documentation**: 1 hour

**Total**: 5-12 hours depending on approach
