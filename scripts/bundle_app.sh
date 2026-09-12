#!/usr/bin/env bash
#
# Wrap the built ksp-app binary, and the kspplus CLI beside it, in a launchable .app.
#
#   ./scripts/bundle_app.sh             build it under swift/.build/app/
#   ./scripts/bundle_app.sh --install   build it and put it in /Applications
#   ./scripts/bundle_app.sh --link-cli  that, and link kspplus into $BINDIR (default /usr/local/bin)
set -euo pipefail

install=false
link_cli=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        # Linking names the installed copy, so it installs too rather than pointing at .build/.
        --link-cli)
            install=true
            link_cli=true
            ;;
        *)
            echo "usage: ${BASH_SOURCE[0]##*/} [--install | --link-cli]" >&2
            exit 2
            ;;
    esac
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root/swift"

# Finder labels an app by its bundle filename and the menu bar by CFBundleName, so both carry
# the spaced form. The Mach-O inside stays unspaced.
app_name="Key Step Pro Plus"
exe_name="KeyStepProPlus"

bundle="$root/swift/.build/app/$app_name.app"
contents="$bundle/Contents"

echo "==> Building ksp-app and kspplus (release)"
swift build -c release --product ksp-app
swift build -c release --product kspplus

build_dir=$(swift build -c release --show-bin-path)

echo "==> Assembling $app_name.app"
rm -rf "$bundle"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$build_dir/ksp-app" "$contents/MacOS/$exe_name"

# The CLI rides inside the bundle, so `kspplus` finds the template through Contents/Resources.
cp "$build_dir/kspplus" "$contents/MacOS/kspplus"

# Contents/Resources is where `TemplateLocation` looks; `Bundle.module` looks beside the bundle
# root and finds nothing here.
shopt -s nullglob
bundles=("$build_dir"/*.bundle)
if [[ ${#bundles[@]} -eq 0 ]]; then
    echo "error: no SwiftPM resource bundle in $build_dir -- the app could not find its template" >&2
    exit 1
fi
cp -R "${bundles[@]}" "$contents/Resources/"

echo "==> Drawing the icon"
swiftc -O "$root/tools/make_app_icon.swift" -o "$root/swift/.build/make_app_icon"
"$root/swift/.build/make_app_icon" "$contents/Resources/AppIcon.icns"

cat > "$contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$app_name</string>
    <key>CFBundleDisplayName</key><string>$app_name</string>
    <key>CFBundleExecutable</key><string>$exe_name</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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

# No entitlements file, deliberately: the App Sandbox forbids writing into MCC's Templates folder.
echo "==> Signing (ad-hoc)"
# The nested CLI is code, not a resource, so it is signed on its own before the bundle seals it.
codesign --force --sign - "$contents/MacOS/kspplus"
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

if [[ $link_cli == false ]]; then
    exit 0
fi

# A link rather than a copy, so the next install moves the command along with the app.
bin_dir="${BINDIR:-/usr/local/bin}"
echo
echo "==> Linking $bin_dir/kspplus"
if ! mkdir -p "$bin_dir" 2>/dev/null \
    || ! ln -sf "$installed/Contents/MacOS/kspplus" "$bin_dir/kspplus"; then
    echo "error: could not write $bin_dir -- retry with: sudo $0 --link-cli, or name a" >&2
    echo "       directory of your own: BINDIR=~/bin $0 --link-cli" >&2
    exit 1
fi

echo "Run it with:  kspplus --help"
