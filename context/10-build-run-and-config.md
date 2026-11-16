# 10 — Build, Run, and Configuration

## 1. Toolchain

| Item | Value |
|---|---|
| Edition | 2021 |
| CI/release toolchain | Rust **1.98.1** (pinned via `dtolnay/rust-toolchain@1.98.1`) |
| README claim | "Rust 1.75+" — not verified against this lockfile |
| Build system | Cargo, single package, no workspace members |
| Lockfile | `Cargo.lock` is committed; CI uses `--locked` |

The `[workspace]` table is empty; it exists to make the crate its own workspace root.

## 2. Dependencies and feature choices

```toml
eframe = { version = "0.29", default-features = false,
           features = ["persistence", "default_fonts", "glow", "wayland", "x11"] }
winit = "0.30"
egui = "0.29"
egui_extras = "0.29"
lofty = "0.25"
reqwest = { version = "0.12", default-features = false,
            features = ["json", "rustls-tls-webpki-roots"] }
serde = { version = "1.0", features = ["derive", "rc"] }
serde_json = "1.0"
tokio = { version = "1.40", features = ["rt-multi-thread", "macros"] }
directories = "5.0"
image = { version = "0.25", default-features = false,
          features = ["png", "jpeg", "gif", "bmp"] }
rfd = { version = "0.17", default-features = false, features = ["xdg-portal"] }
thiserror = "1.0"
```

Rationale encoded in comments:

- **No wgpu.** eframe's default renderer is glow here; the wgpu tree was enabled but never selected.
- **`winit` is a direct dependency** to restore `winit/default` (Wayland dynamic loading, client-side decorations) after eframe defaults were disabled.
- **`accesskit` off** because on Linux it pulls zbus/atspi and a `quick-xml` release with advisories.
- **`image` decoders limited** to the four formats the app accepts, to avoid AVIF/EXR/TIFF/WebP bloat.
- **`rustls`** so no OpenSSL system dependency is needed.
- **`serde/rc`** lets `AlbumArt` serialise `Arc<[u8]>` without copying.

## 3. Build profiles

```toml
[profile.dev]
debug = 1          # line tables only, smaller target/

[profile.test]
debug = 1

[profile.release]
opt-level = 3
lto = "thin"
codegen-units = 1
strip = true
panic = "abort"

[profile.release.build-override]
opt-level = 0
codegen-units = 256
```

- `panic = "abort"` means no unwinding in release; a panic terminates the process.
- Thin LTO links much faster than fat LTO with most of the runtime benefit.
- Build scripts and proc macros are built at `opt-level = 0`.

## 4. Prerequisites

### Linux (Debian/Ubuntu)

Build-time packages (from CI):

```bash
sudo apt-get install -y --no-install-recommends \
  pkg-config \
  libx11-dev libxcb1-dev libxcb-composite0-dev libxcb-cursor-dev \
  libxcb-image0-dev libxcb-icccm4-dev libxcb-keysyms1-dev \
  libxcb-randr0-dev libxcb-render0-dev libxcb-render-util0-dev \
  libxcb-shape0-dev libxcb-xfixes0-dev libxcb-xinerama0-dev \
  libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev
```

Packaging additionally uses `dpkg-dev desktop-file-utils appstream rpm squashfs-tools zstd file flatpak flatpak-builder`.

At **runtime** the X11/Wayland/GL/DBus libraries are `dlopen`ed, not linked, so `ldd` will not show them. The Debian package declares them explicitly. A manually built binary needs them installed on the target machine.

### Windows

- MSVC toolchain (`x86_64-pc-windows-msvc`, `i686-pc-windows-msvc`, or `aarch64-pc-windows-msvc`).
- `build.rs` embeds `assets/icon.ico` and version resources via `winresource`.
- Inno Setup is only needed to build the installer.

### macOS

- Xcode command-line tools; `sips`, `iconutil`, `pkgbuild`, `productbuild` for the installer package.
- Cross-build both `aarch64-apple-darwin` and `x86_64-apple-darwin`, then `lipo`.

## 5. Commands

```bash
cargo build                 # debug
cargo build --release       # release (thin LTO, stripped, abort)
cargo run                   # run debug
cargo test                  # 2 unit tests
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- \
  -D warnings -A clippy::never_loop -A clippy::large_enum_variant
cargo build --release --locked
```

### Docker (noVNC)

```bash
docker compose up --build -d                          # then open the browser URL
XUR_MUSIC_DIR=~/Music docker compose up --build -d    # mount a real music folder
docker compose logs -f
docker compose down                                   # add -v to wipe settings
```

See section 11 for the full picture.

The two clippy allows are pre-existing findings in `services/metadata.rs` and `ui/state.rs`; CI treats all other warnings as errors.

### Faster local iteration

- `cargo check` / `cargo clippy` avoid linking.
- `debug = 1` keeps `target/` smaller than the default.
- Optional: `RUSTFLAGS="-C link-arg=-fuse-ld=lld"` (or `mold`) if installed. Not enabled by default.
- Do not enable wgpu or extra `image` features just to "make it work"; the app is built around glow and four image formats.

## 6. Runtime configuration

### Config location

`SettingsService::new` uses:

```rust
ProjectDirs::from("", "", "xur-porisoy")
```

`ProjectDirs::config_dir()` gives:

| OS | Path |
|---|---|
| Linux | `~/.config/xur-porisoy/settings.json` |
| macOS | `~/Library/Application Support/xur-porisoy/settings.json` |
| Windows | `%APPDATA%\xur-porisoy\settings.json` |

The directory is created if missing. If `ProjectDirs` cannot resolve a directory, the app panics during startup.

### `settings.json`

```json
{
  "llm": {
    "api_key": "",
    "model_name": "",
    "base_url": null,
    "enabled": false
  },
  "last_opened_folder": null,
  "window_size": null,
  "theme": "System"
}
```

- Written pretty-printed via `serde_json::to_string_pretty` and `fs::write` (not atomic).
- A missing file returns `AppSettings::default()`.
- A malformed file is an error and panics at startup (no fallback, no backup).
- The API key is plaintext.
- `theme` is the only field with `#[serde(default)]`; older files missing other fields fail to deserialize.
- Window size/position is handled by eframe's `persistence` feature, not by `window_size`.

### No environment variables

The app reads no runtime environment variables. `CARGO_PKG_VERSION` is compiled into the User-Agent and About window.

## 7. Tests

Only two unit tests exist, both in `models/song.rs`:

```bash
cargo test --workspace --locked
```

They cover serde defaults for LLM responses and the `AlbumArt` byte bridge. There are no UI, metadata round-trip, HTTP, or packaging tests. CI does not run a release build (packaging jobs do).

## 8. Common build failures

| Symptom | Cause / fix |
|---|---|
| `error: failed to run custom build command for 'x11'` or missing `xcb` headers | Install the Linux build packages above. |
| Linker cannot find `-lX11` / `-lwayland-client` | Missing `libx11-dev` / `libwayland-dev`. |
| App starts then exits with a windowing error over SSH | No display; use X forwarding or run locally. |
| Wayland window has no decorations | Ensure the direct `winit = "0.30"` dependency stays; it restores `winit/default`. |
| `cargo build --locked` fails after editing dependencies | Commit the updated `Cargo.lock`. |
| Clippy fails on an unrelated lint | The toolchain is newer than 1.98.1; either pin it or add a justified allow. |
| `error: failed to select a version for ... rustls` | `Cargo.lock` was updated without resolving; run `cargo update -p <crate>`. |

## 9. Packaging entry points

All scripts expect an already-built binary and never compile Rust:

| Target | Command |
|---|---|
| `.deb` | `packaging/debian/build-deb.sh` |
| apt repo | `python3 packaging/apt/build-repo.py --debs dist --out pages ...` |
| tarball | `VERSION=x ARCH=y packaging/linux/build-tarball.sh` |
| AppImage | `VERSION=x ARCH=y packaging/linux/build-appimage.sh` |
| RPM | `VERSION=x RPM_ARCH=y packaging/rpm/build-rpm.sh` |
| Flatpak | `VERSION=x ARCH=y packaging/flatpak/build-flatpak.sh` |
| Arch | `VERSION=x ARCH=y packaging/arch/build-arch-pkg.sh` |
| macOS installer | `VERSION=x packaging/macos/build-pkg.sh` |
| Windows installer | `ISCC.exe /DMyAppVersion=... /DMyVersionInfo=... /DMyArch=... /DMySourceExe=... /DMyOutputBaseFilename=... installer/xur-porisoy.iss` |

See [12-packaging-and-release.md](12-packaging-and-release.md) for the full matrix and naming.

## 10. Reproducing CI locally

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- \
  -D warnings -A clippy::never_loop -A clippy::large_enum_variant
cargo test --workspace --locked
desktop-file-validate packaging/debian/xur-porisoy.desktop
appstreamcli validate --no-net packaging/debian/xur-porisoy.metainfo.xml
bash -n packaging/debian/build-deb.sh
sh -n packaging/debian/postinst packaging/debian/prerm packaging/debian/postrm packaging/apt/install.sh
python3 -m py_compile packaging/apt/build-repo.py
```

There is no `.cargo/config.toml`; linker settings and target flags are not configured in-repo.

## 11. Docker (noVNC)

The container is self-contained: it does **not** need a host X11/Wayland
display. `docker/entrypoint.sh` runs the app on an in-container X server and
streams it to a browser:

```text
xur-porisoy (glow/X11)
  -> Xvfb :99 (software GL, LIBGL_ALWAYS_SOFTWARE=1 / llvmpipe)
  -> x11vnc localhost:5900 (never published out of the container)
  -> websockify 0.0.0.0:6080 serving /usr/share/novnc
```

Intended use:

```bash
XUR_MUSIC_DIR=~/Music docker compose up --build -d
open http://localhost:6080/vnc.html?autoconnect=1&resize=scale
```

### Image layout

- Builder stage `rust:1.98.1-slim-bookworm` runs the **exact CI build package
  list** and `cargo build --release --locked`. This is the only packaging
  target that compiles Rust; the `packaging/**` scripts still expect a
  prebuilt binary.
- Runtime stage is `debian:bookworm-slim` with two package groups: the
  dlopened GUI stack (mirrors the `Depends` line of
  `packaging/debian/build-deb.sh` — remember `ldd` cannot verify these) and
  the display stack (`xvfb x11vnc novnc websockify dbus-x11
  xdg-desktop-portal xdg-desktop-portal-gtk fonts-dejavu-core libglx-mesa0`).
- Runs as user `xur` with `HOME=/home/xur` exported by the entrypoint. The
  app panics at startup if `ProjectDirs` cannot resolve
  `~/.config/xur-porisoy`, so HOME is not optional.

### Runtime knobs

| Variable | Default | Effect |
|---|---|---|
| `RESOLUTION` | `1200x800x24` | Xvfb screen; the app builds a 1200×800 viewport |
| `VNC_PASSWORD` | unset (no auth) | x11vnc password; noVNC prompts for it |
| `NOVNC_PORT` / `VNC_PORT` | `6080` / `5900` | listen ports inside the container |
| `XUR_MUSIC_DIR` | `./music` | compose-only; host folder mounted at `/home/xur/Music` |

### Data

| Path | Contents | How compose persists it |
|---|---|---|
| `/home/xur/.config/xur-porisoy` | `settings.json` (plaintext API key) | named volume `xur-porisoy-config` |
| `/home/xur/.local/share/xur-porisoy` | eframe persisted window geometry | named volume `xur-porisoy-data` |
| `/home/xur/Music` | the library | bind mount, **read-write** (saves rewrite tags in place) |

### File dialogs

`rfd` is built with the `xdg-portal` feature only, so the picker needs
`org.freedesktop.portal.Desktop` on a session bus. The entrypoint starts a
private `dbus-daemon` plus `xdg-desktop-portal`/`xdg-desktop-portal-gtk`
inside the container; the GTK chooser window appears on `:99` and is visible
through noVNC. Without that stack, Add Songs/Add Folder silently fail while
the rest of the app works.

### CI

The `docker` job in `ci.yml` builds the image (`docker/build-push-action`
with gha layer cache) and smoke-tests it: boots the container, waits for
`http://127.0.0.1:6080/vnc.html`, then asserts the `xur-porisoy` process is
alive in `docker top` (catches missing dlopened libraries and startup
panics). The image is **not** pushed to a registry.
