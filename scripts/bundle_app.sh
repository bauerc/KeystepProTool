#!/usr/bin/env bash
#
# Assemble the drag-and-drop app (M13.2) into a launchable .app.
#
# A macOS app bundle is a directory with an Info.plist, so SwiftPM builds the binary and this
# script does the wrapping -- no Xcode, no xcodebuild, no actool. Deliberately not part of
# validate.sh: it is a release build of a GUI, and the tests already compile the target.
#
# The signature here is ad-hoc, which is enough to launch on this machine. M14 replaces it with a
# Developer ID identity and notarisation, and needs no rebuild to do it.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root/swift"

# What the user sees. Finder labels an app by its bundle filename and the menu bar by
# CFBundleName, so both carry the spaced form or the two disagree.
app_name="Key Step Pro Plus"
# The Mach-O inside stays unspaced: nothing displays it, and a space in an executable name is a
# quoting trap in every script that ever touches it.
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

# The SwiftPM resource bundles, which is how the 3.5 MB factory template reaches the app:
# `Bundle.module` looks in `Bundle.main.resourceURL`, and for an app that is Contents/Resources.
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

# No entitlements file, and that is the point: the App Sandbox confines writes to the app's own
# container, which is exactly what writing into MIDI Control Center's Templates folder is not.
# Developer ID distribution permits an unsandboxed app; the Mac App Store would not.
echo "==> Signing (ad-hoc)"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

echo
echo "Built $bundle"
echo "Run it with:  open '$bundle'"
