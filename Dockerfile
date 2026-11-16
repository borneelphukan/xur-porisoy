# syntax=docker/dockerfile:1
#
# xur-porisoy — MP3 metadata editor (eframe/egui desktop app) in Docker,
# streamed to a web browser through noVNC.
#
# The intended way in is the browser port served by the container itself:
#
#   docker compose up --build -d
#   open http://localhost:6080/vnc.html?autoconnect=1&resize=scale
#
# The container does not need a host display. It runs Xvfb (software GL via
# llvmpipe) -> x11vnc (localhost only, never published) -> noVNC/websockify
# on 6080, plus a private D-Bus session and an in-container XDG portal so
# the app's file picker works inside the streamed window.
#
# Tunables (see docker/entrypoint.sh):
#   RESOLUTION    default 1200x800x24 — the app builds a 1200x800 viewport
#   VNC_PASSWORD  unset = no password; compose already binds 6080 to localhost
#
# Data locations inside the image:
#   /home/xur/.config/xur-porisoy       settings.json (plaintext API key!)
#   /home/xur/.local/share/xur-porisoy  eframe persisted window geometry
#   /home/xur/Music                     mount music here, READ-WRITE: saves
#                                       rewrite tags in place

# ---------------------------------------------------------------------------
# Stage 1 — build
# ---------------------------------------------------------------------------
# Toolchain pinned to 1.98.1, the same version CI and the release workflows
# use. Bump all three together (context/11, context/14).
FROM rust:1.98.1-slim-bookworm AS builder

# Build-time headers for the X11/XCB/Wayland/xkbcommon windowing stack —
# the exact list from .github/workflows/ci.yml (context/10, section 4).
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config \
        libx11-dev libxcb1-dev libxcb-composite0-dev libxcb-cursor-dev \
        libxcb-image0-dev libxcb-icccm4-dev libxcb-keysyms1-dev \
        libxcb-randr0-dev libxcb-render0-dev libxcb-render-util0-dev \
        libxcb-shape0-dev libxcb-xfixes0-dev libxcb-xinerama0-dev \
        libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Resolve and download the committed lockfile first, so source edits
# don't invalidate the dependency layer.
COPY Cargo.toml Cargo.lock ./
RUN cargo fetch --locked

COPY build.rs ./
COPY assets ./assets
COPY src ./src

# Release profile: thin LTO, stripped, panic=abort (see Cargo.toml).
# --locked matches CI; rustls means no OpenSSL is needed here.
RUN cargo build --release --locked

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# Two groups of packages:
#   1. the dlopened GUI stack the binary loads at startup — ldd will never
#      flag a miss, it just fails at runtime. Mirrors the Depends line in
#      packaging/debian/build-deb.sh (libc6/libgcc-s1 ship with the base).
#   2. the noVNC display stack: Xvfb + software GL, x11vnc, the noVNC web
#      client + websockify proxy, and dbus/portal for rfd file dialogs.
#      fonts are needed by the GTK file chooser, not by egui (it embeds its
#      own default fonts).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libdbus-1-3 \
        libegl1 libgl1 libglx-mesa0 \
        libwayland-client0 libwayland-egl1 \
        libx11-6 libx11-xcb1 libxcb1 libxcursor1 libxi6 \
        libxkbcommon0 libxkbcommon-x11-0 libxrender1 \
        xvfb x11vnc novnc websockify \
        dbus-x11 xdg-desktop-portal xdg-desktop-portal-gtk \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# The app resolves its config dir via ProjectDirs (~/.config/xur-porisoy) and
# panics at startup if that fails, so it needs a real home directory. Run it
# as a non-root user; named volumes for config/data are pre-created so Docker
# initializes them with the right ownership.
RUN useradd --create-home --shell /usr/sbin/nologin xur \
    && mkdir -p /home/xur/.config/xur-porisoy \
                /home/xur/.local/share/xur-porisoy \
                /home/xur/Music \
    && chown -R xur:xur /home/xur/.config /home/xur/.local /home/xur/Music
USER xur
WORKDIR /home/xur

# Default display size matches the app's startup viewport.
ENV RESOLUTION=1200x800x24

COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --from=builder /app/target/release/xur-porisoy /usr/local/bin/xur-porisoy

# Settings/window-state survive `docker compose down` with named volumes.
VOLUME ["/home/xur/.config/xur-porisoy", "/home/xur/.local/share/xur-porisoy"]

EXPOSE 6080

# Browser port answering = the stack is up. 5900 is x11vnc's localhost-only
# port inside the container and is deliberately not published.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python3 -c "import socket; socket.create_connection(('127.0.0.1', 6080), timeout=3)"

ENTRYPOINT ["/bin/sh", "/usr/local/bin/docker-entrypoint.sh"]
