#!/bin/sh
# Starts the in-container display stack for xur-porisoy, then the app:
#
#   Xvfb (:99, software GL)  ->  x11vnc (localhost:5900, never published)
#                            ->  websockify/noVNC (0.0.0.0:6080, browser port)
#
# A private session bus + the GTK XDG portal run inside the container so the
# app's rfd file picker opens as a window on the streamed display instead of
# requiring a host portal.
#
# Environment:
#   RESOLUTION     Xvfb screen, default 1200x800x24 (the app's startup viewport)
#   VNC_PASSWORD   if set, x11vnc requires it (noVNC prompts for it)
#   NOVNC_PORT     websockify listen port, default 6080
#   VNC_PORT       x11vnc port inside the container, default 5900
set -eu

: "${RESOLUTION:=1200x800x24}"
: "${NOVNC_PORT:=6080}"
: "${VNC_PORT:=5900}"

# The app resolves ~/.config/xur-porisoy via ProjectDirs and panics at
# startup without it; keep HOME explicit regardless of how the image is run.
export HOME=/home/xur
export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1

export XDG_RUNTIME_DIR=/tmp/runtime-xur
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

cleanup() {
    # shellcheck disable=SC2086 # word splitting is intended for job ids
    kill $(jobs -p) 2>/dev/null || true
}
trap cleanup EXIT INT TERM

Xvfb "$DISPLAY" -screen 0 "$RESOLUTION" -nolisten tcp &

# Wait for the X socket before anything connects to the display.
i=0
while [ ! -e "/tmp/.X11-unix/X99" ]; do
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then
        echo "ERROR: Xvfb did not come up" >&2
        exit 1
    fi
    sleep 0.1
done

dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" &

# File dialogs: rfd speaks the org.freedesktop.portal.Desktop FileChooser API
# on the session bus. The gtk portal backend draws its picker on $DISPLAY, so
# it is visible through noVNC.
xdg-desktop-portal-gtk &
xdg-desktop-portal &

if [ -n "${VNC_PASSWORD:-}" ]; then
    AUTH="-passwd $VNC_PASSWORD"
else
    AUTH="-nopw"
fi

# -localhost keeps raw VNC inside the container; the browser never talks to it.
# shellcheck disable=SC2086
x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -localhost -forever -shared \
    -quiet $AUTH &

# Serve the noVNC web client and proxy the websocket to the VNC port.
websockify --web=/usr/share/novnc "0.0.0.0:$NOVNC_PORT" "localhost:$VNC_PORT" &

echo "noVNC ready: http://localhost:$NOVNC_PORT/vnc.html?autoconnect=1&resize=scale" >&2

# The app is the container's reason to live: when it exits, the trap tears
# the display stack down and the container stops.
xur-porisoy &
wait $!
