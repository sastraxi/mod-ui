# Plugin scanning and hot-load

## Normal install path (PatchStorage / web UI)

`install_bundles_in_tmp_dir` in `webserver.py` does a live two-sided load:

1. Sends `bundle_add "<path>"` to mod-host over the command socket → mod-host rescans its lilv world and accepts `add <uri>` commands for the new plugin immediately.
2. Calls `add_bundle_to_lilv_world(bundlepath)` → C++ call into the in-process lilv world so mod-ui can query the plugin too.

No restart needed. The plugin is drag-droppable onto the board straight away.

## Manual bundle drop (hand-copying `.lv2` into `~/.lv2`)

There is no signal or endpoint that triggers a rescan today.

- `SIGUSR1` → save-state (or HMI screenshot / CC firmware update)
- `SIGUSR2` → disconnect / boot-check / upgrade-check

**Workaround:** `systemctl restart mod-ui`. This runs `lv2_cleanup()` + `lv2_init()` which does a full lilv rescan. mod-host is left running; only mod-ui restarts.

## What a proper fix would look like

Add a small HTTP endpoint (e.g. `POST /plugin/rescan`) that:

1. Calls `add_bundle_to_lilv_world(bundlepath)` for the new bundle.
2. Sends `bundle_add "<path>"` to mod-host via `SESSION.host.send_notmodified(...)`.
3. Invalidates the `_plugins_list_cache` so the next `/effect/list` request reflects the change.

Or wire one of the existing signals (or a new `SIGUSR1` sub-case) to the same three steps.
