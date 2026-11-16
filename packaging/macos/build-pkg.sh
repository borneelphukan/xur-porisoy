#!/usr/bin/env bash
#
# Build a macOS installer package (.pkg) for xur-porisoy.
#
# A .dmg only mounts the app and relies on a manual drag into Applications,
# which is why it feels "portable". A .pkg runs a real Install macOS workflow:
# it copies the bundle into /Applications for the whole system, needs admin
# authorisation, and can register the app afterwards.
#
# The .app bundle is assembled from BINARY the same way the other macOS targets
# do it, unless you pass a prebuilt bundle via APP.
#
# Environment:
#   VERSION           package version (required)
#   BINARY            path to the universal binary (default: target/release/xur-porisoy)
#   APP               path to a prebuilt .app bundle to package instead of BINARY
#   APP_NAME          bundle / display name (default: XurPorisoy)
#   BUNDLE_ID         reverse-DNS identifier (default: io.github.borneelphukan.XurPorisoy)
#   EXECUTABLE        name of the executable inside Contents/MacOS (default: xur-porisoy)
#   INSTALL_LOCATION  where the app lands (default: /Applications)
#   SIGN_IDENTITY     optional "Developer ID Installer: ..." identity to sign the .pkg
#   OUT_DIR           output directory (default: dist)
#
# Usage:
#   VERSION=0.1.0 packaging/macos/build-pkg.sh
#   VERSION=0.1.0 APP="/path/to/MP3 Tagger.app" APP_NAME="MP3 Tagger" \
#     BUNDLE_ID=io.github.borneelphukan.mp3Tagger EXECUTABLE=mp3-tagger \
#     packaging/macos/build-pkg.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

VERSION="${VERSION:?VERSION is required}"
BINARY="${BINARY:-$ROOT/target/release/xur-porisoy}"
APP="${APP:-}"
APP_NAME="${APP_NAME:-XurPorisoy}"
BUNDLE_ID="${BUNDLE_ID:-io.github.borneelphukan.XurPorisoy}"
EXECUTABLE="${EXECUTABLE:-xur-porisoy}"
INSTALL_LOCATION="${INSTALL_LOCATION:-/Applications}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v pkgbuild >/dev/null 2>&1 || die "pkgbuild is required (run this on macOS)"
command -v productbuild >/dev/null 2>&1 || die "productbuild is required (run this on macOS)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# --- Assemble (or accept) the .app bundle ------------------------------------
if [ -n "$APP" ]; then
    [ -d "$APP" ] || die "prebuilt app not found at $APP"
    APP_DIR="$STAGE/$APP_NAME.app"
    ditto "$APP" "$APP_DIR"
else
    [ -f "$BINARY" ] || die "universal binary not found at $BINARY (or set APP=/path/to/App.app)"
    BINARY="$(cd -- "$(dirname -- "$BINARY")" && pwd)/$(basename -- "$BINARY")"
    command -v sips >/dev/null 2>&1 || die "sips is required (run this on macOS)"
    command -v iconutil >/dev/null 2>&1 || die "iconutil is required (run this on macOS)"

    APP_DIR="$STAGE/$APP_NAME.app"
    install -d -m 0755 "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
    install -m 0755 "$BINARY" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

    SQUARE="$STAGE/icon-square.png"
    ICONSET="$STAGE/icon.iconset"
    sips -c 301 301 "$ROOT/assets/icon.png" --out "$SQUARE" >/dev/null
    install -d -m 0755 "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$SQUARE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$SQUARE" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/icon.icns"

    cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</string>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
</dict>
</plist>
EOF
fi

chmod -Rf a+rx "$APP_DIR/Contents/MacOS" || true

# --- Payload root: contents land at INSTALL_LOCATION -------------------------
PAYLOAD="$STAGE/payload"
install -d -m 0755 "$PAYLOAD"
ditto "$APP_DIR" "$PAYLOAD/$(basename -- "$APP_DIR")"

# --- postinstall: refresh Launch Services so the app is discoverable ---------
SCRIPTS="$STAGE/scripts"
install -d -m 0755 "$SCRIPTS"
cat > "$SCRIPTS/postinstall" <<EOF
#!/bin/sh
set -e
APP="$INSTALL_LOCATION/$(basename -- "$APP_DIR")"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -d "\$APP" ] && [ -x "\$LSREGISTER" ]; then
    "\$LSREGISTER" -f "\$APP" || true
fi
exit 0
EOF
chmod 0755 "$SCRIPTS/postinstall"

# --- Build and wrap the package ----------------------------------------------
mkdir -p "$OUT_DIR"
COMPONENT_NAME="$APP_NAME-component.pkg"
COMPONENT="$STAGE/$COMPONENT_NAME"
OUTPUT="$OUT_DIR/$APP_NAME-${VERSION}-macos-universal.pkg"

pkgbuild \
    --root "$PAYLOAD" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "$INSTALL_LOCATION" \
    --scripts "$SCRIPTS" \
    "$COMPONENT" >/dev/null

# productbuild wraps a pkgbuild component via a distribution document so the
# install scripts survive and a real "Install macOS" GUI drives it.
DIST="$STAGE/distribution.dist"
cat > "$DIST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>$APP_NAME $VERSION</title>
    <options customize="never" require-scripts="false" rootVolume="false"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="11.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="$BUNDLE_ID"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$BUNDLE_ID" visible="false">
        <pkg-ref id="$BUNDLE_ID"/>
    </choice>
    <pkg-ref id="$BUNDLE_ID" version="$VERSION" onConclusion="none">$COMPONENT_NAME</pkg-ref>
</installer-gui-script>
EOF

if [ -n "$SIGN_IDENTITY" ]; then
    productbuild \
        --distribution "$DIST" \
        --package-path "$STAGE" \
        --identifier "$BUNDLE_ID" \
        --version "$VERSION" \
        --sign "$SIGN_IDENTITY" \
        "$OUTPUT" >/dev/null
else
    productbuild \
        --distribution "$DIST" \
        --package-path "$STAGE" \
        --identifier "$BUNDLE_ID" \
        --version "$VERSION" \
        "$OUTPUT" >/dev/null
fi

printf 'built %s\n' "$OUTPUT"
