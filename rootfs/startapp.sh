#!/bin/sh
# Started by the jlesage baseimage as the app user (USER_ID:GROUP_ID) once the
# X server and Openbox are up. With KEEP_APP_RUNNING=1 it is re-run whenever
# Steam exits, so every step here must be idempotent.
set -eu

log() { echo "[startapp] $*"; }

# --- Environment -------------------------------------------------------------
# The baseimage already sets these; the defaults only matter if run elsewhere.
# Steam's login data must live under /config (persistent), never in the image
# layer and never on a game library mount.
export HOME="${HOME:-/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/xdg/data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/xdg/config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/xdg/cache}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-app}"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

# --- GPU or software rendering ----------------------------------------------
# STEAM_GPU=auto (default): use the GPU if a DRI render node is present AND
# usable by this user (compose: `devices: [/dev/dri]` plus
# SUP_GROUP_IDS=<host render group id>). Otherwise fall back to software GL
# and disable GPU use in Steam's embedded browser (CEF).
# STEAM_GPU=on / off forces the choice.
gpu_usable=0
for node in /dev/dri/renderD*; do
    if [ -c "$node" ] && [ -r "$node" ] && [ -w "$node" ]; then
        gpu_usable=1; break
    fi
done
case "${STEAM_GPU:-auto}" in
    on|1|true)
        use_gpu=1
        [ "$gpu_usable" = 1 ] || log "WARNING: STEAM_GPU=on but no usable /dev/dri/renderD* (missing device or SUP_GROUP_IDS?)" ;;
    off|0|false) use_gpu=0 ;;
    *) use_gpu="$gpu_usable"
       if [ "$gpu_usable" = 0 ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
           log "NOTE: /dev/dri/renderD* exists but uid $(id -u) cannot open it; set SUP_GROUP_IDS to the host's render group id. Using software rendering."
       fi ;;
esac
if [ "$use_gpu" = 1 ]; then
    log "GPU rendering enabled (render node available)"
    gpu_args=""
else
    log "No usable GPU: software rendering (llvmpipe)"
    export LIBGL_ALWAYS_SOFTWARE=1
    gpu_args="-cef-disable-gpu -cef-disable-gpu-compositing"
fi

state_dir="${STEAM_GUI_STATE_DIR:-/config/.steam-gui}"
mkdir -p "$state_dir"

# --- D-Bus session bus (for the folder picker) -------------------------------
# Steam's "Add Drive > Let me choose another location" asks xdg-desktop-portal
# for a folder picker over the D-Bus session bus. The baseimage has no session
# bus, so start a private one. The portal services are D-Bus activated on demand.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-daemon >/dev/null 2>&1; then
    bus_sock="$XDG_RUNTIME_DIR/bus"
    bus_pidfile="$XDG_RUNTIME_DIR/dbus-session.pid"
    bus_pid="$(cat "$bus_pidfile" 2>/dev/null || true)"
    if [ -n "$bus_pid" ] && [ -S "$bus_sock" ] \
        && [ "$(cat "/proc/$bus_pid/comm" 2>/dev/null || true)" = "dbus-daemon" ]; then
        : # still running from a previous Steam start (KEEP_APP_RUNNING)
    else
        rm -f "$bus_sock" "$bus_pidfile"
        if dbus-daemon --session --fork --nosyslog \
                --address="unix:path=$bus_sock" --print-pid > "$bus_pidfile"; then
            :
        else
            log "WARNING: could not start a D-Bus session bus; the folder picker may not work"
            rm -f "$bus_pidfile"
        fi
    fi
    [ -S "$bus_sock" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus_sock"
fi

# --- One-time first-run notice ----------------------------------------------
# Under Openbox, clicks on Steam's pop-up/context menus fall through to the
# window underneath unless "Enable context menu focus compatibility mode" is on.
# Steam keeps that switch in its embedded browser's localStorage (key
# "EnableContextMenuBlurDelay3"), a LevelDB database that cannot be safely
# pre-seeded from a shell script, so we ask the user once instead.
notice_marker="$state_dir/focus-notice-acknowledged"
if [ "${STEAM_GUI_FOCUS_NOTICE:-1}" = "1" ] && [ ! -e "$notice_marker" ] \
    && command -v zenity >/dev/null 2>&1; then
    rc=0
    zenity --info --no-wrap --timeout=600 \
        --title="Steam container: one-time setup" \
        --text="Before you start, one setting is required in this container:

After logging in to Steam, open
    Steam > Settings > Interface
and turn ON
    \"Enable context menu focus compatibility mode\".

Without it, clicks in drop-down and right-click menus land
on the window underneath instead of the menu item.

This notice is shown only once. Click OK to start Steam." \
        >/dev/null 2>&1 || rc=$?
    # 0 = OK, 1 = closed; 5 = timeout (nobody looked) -> show again next time.
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
        date > "$notice_marker"
    fi
fi

# --- Steam -------------------------------------------------------------------
# Desktop mode only. Do not add -tenfoot or -gamepadui: Big Picture cannot
# serve Local Network Game Transfers. Without a GPU the CEF flags keep the
# software-rendered UI usable over VNC. STEAM_EXTRA_ARGS is optional and split
# on spaces (e.g. "-no-cef-sandbox" as a fallback, see README).
# shellcheck disable=SC2086
exec /usr/bin/steam -nofriendsui $gpu_args ${STEAM_EXTRA_ARGS:-} "$@"
