#!/bin/bash
#
# Builds tetmux and wraps it in a .app bundle inside a .dmg.
#
# A SwiftPM executable is a bare Mach-O binary, which macOS treats as a command-line tool: no Dock
# icon, no menu bar ownership, and no bundle identifier for the Keychain ACL or window restoration to
# key on. `swift run` gets away with it because `AppMain` sets the activation policy by hand, but
# nothing ships that way. This assembles the bundle the app has always assumed it would eventually
# have, and hands it to hdiutil.
#
# The result is single-architecture, and the filename says which. A universal binary needs SwiftPM's
# `--arch arm64 --arch x86_64`, which routes the build through xcbuild, which compiles SwiftTerm's
# Metal shaders — and that needs a Metal toolchain component that is a separate multi-gigabyte
# download (`xcodebuild -downloadComponent MetalToolchain`) absent from a stock CI image. The native
# build path copies the .metal source into the resource bundle instead and never invokes the compiler.
#
# Usage: Scripts/package-dmg.sh [--version X.Y.Z] [--output DIR] [--skip-build]

set -euo pipefail

APP_NAME="tetmux"
BUNDLE_ID="org.tetmux.tetmux"
# macOS wants a strictly numeric CFBundleVersion, and a git description is not one.
FALLBACK_VERSION="0.1.0"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/dist"
VERSION=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    VERSION="$2"; shift 2 ;;
        --output)     OUTPUT_DIR="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    # A tag if we are on one, otherwise the fallback. Deliberately not `git describe`: its output
    # carries a commit hash, and CFBundleShortVersionString is shown to the user.
    VERSION="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    VERSION="${VERSION:-$FALLBACK_VERSION}"
fi
# CFBundleVersion must be one to three dot-separated integers. Anything else and the bundle is
# rejected at install time rather than at build time, which is a bad place to find out.
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "==> version '$VERSION' is not numeric; using $FALLBACK_VERSION for CFBundleVersion"
    BUNDLE_VERSION="$FALLBACK_VERSION"
else
    BUNDLE_VERSION="$VERSION"
fi

BUILD_DIR="$REPO_ROOT/.build/release"
STAGING="$(mktemp -d)"
APP="$STAGING/$APP_NAME.app"
trap 'rm -rf "$STAGING"' EXIT

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "==> building $APP_NAME $VERSION (release)"
    swift build -c release --package-path "$REPO_ROOT"
fi

if [[ ! -x "$BUILD_DIR/$APP_NAME" ]]; then
    echo "no binary at $BUILD_DIR/$APP_NAME" >&2
    exit 1
fi

echo "==> assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM emits one resource bundle per target that has resources — SwiftTerm's holds its Metal
# shaders. `Bundle.module` looks in `Bundle.main.resourceURL` first, so Contents/Resources is where
# these have to land. Miss this and the app builds, launches, and fails the moment a pane draws.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
    echo "    resource bundle: $(basename "$bundle")"
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUNDLE_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not a substitute for a Developer ID — Gatekeeper still quarantines a download —
# but an unsigned bundle is refused outright on Apple silicon, and the Keychain ACL keys on the
# signature, so without one every launch re-asks for stored passwords.
echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep --strict "$APP"

echo "==> building disk image"
mkdir -p "$OUTPUT_DIR"
# The architecture is in the name because the binary only has one. Someone on an Intel Mac should be
# able to tell from the filename, not from the crash.
ARCH="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME" | tr ' ' '-')"
DMG="$OUTPUT_DIR/$APP_NAME-$VERSION-$ARCH.dmg"
rm -f "$DMG"
# The conventional drag-to-install layout: the app and a shortcut to where it goes.
ln -s /Applications "$STAGING/Applications"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo "==> $DMG"
