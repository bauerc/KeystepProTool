#!/usr/bin/env bash
#
# Wrap the built ksp-app binary in a launchable .app.
#
#   ./scripts/bundle_app.sh             build it under swift/.build/app/
#   ./scripts/bundle_app.sh --install   build it and put it in /Applications
set -euo pipefail

install=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        *)
            echo "usage: ${BASH_SOURCE[0]##*/} [--install]" >&2
            exit 2
            ;;
    esac
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root/swift"

# Finder labels an app by its bundle filename and the menu bar by CFBundleName, so both carry the
# spaced form or the two disagree. The Mach-O inside stays unspaced -- nothing displays it, and a
# space there is a quoting trap.
app_name="Key Step Pro Plus"
exe_name="KeyStepProPlus"

bundle="$root/swift/.build/app/$app_name.app"
contents="$bundle/Contents"

echo "==> Building ksp-app (release)"
swift build -c release --product ksp-app

build_dir=$(swift build -c release --show-bin-path)

echo "==> Assembling $app_name.app"
rm -rf "$bundle"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$build_dir/ksp-app" "$contents/MacOS/$exe_name"

# `Bundle.module` looks in `Bundle.main.resourceURL`, which for an app is Contents/Resources.
# Globbed rather than named, so renaming the package cannot quietly ship an app that builds, runs
# and then cannot find its template.
shopt -s nullglob
bundles=("$build_dir"/*.bundle)
if [[ ${#bundles[@]} -eq 0 ]]; then
    echo "error: no SwiftPM resource bundle in $build_dir -- the app could not find its template" >&2
    exit 1
fi
cp -R "${bundles[@]}" "$contents/Resources/"

cat > "$contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$app_name</string>
    <key>CFBundleDisplayName</key><string>$app_name</string>
    <key>CFBundleExecutable</key><string>$exe_name</string>
    <key>CFBundleIdentifier</key><string>com.github.bauerc.keysteppro-plus</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Standard MIDI File</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.midi-audio</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>KeyStep Pro Project</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>KeyStepPro</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# No entitlements file, deliberately: the App Sandbox would confine writes to the app's own
# container, and writing into MIDI Control Center's Templates folder is exactly what that forbids.
echo "==> Signing (ad-hoc)"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

echo
echo "Built $bundle"

if [[ $install == false ]]; then
    echo "Run it with:  open '$bundle'"
    exit 0
fi

# /Applications is group-writable by admin on a stock macOS, so this needs no sudo.
installed="/Applications/$app_name.app"
echo "==> Installing to $installed"

# Replacing a bundle under a running process leaves it half old and half new.
if pgrep -qf "$app_name.app/Contents/MacOS/$exe_name"; then
    echo "    (quitting the running copy first)"
    pkill -f "$app_name.app/Contents/MacOS/$exe_name" || true
    sleep 1
fi

rm -rf "$installed"
if ! cp -R "$bundle" "$installed"; then
    echo "error: could not write to /Applications -- retry with: sudo $0 --install" >&2
    exit 1
fi

echo
echo "Installed $installed"
echo "Run it with:  open -a '$app_name'"
