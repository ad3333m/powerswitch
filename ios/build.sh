#!/usr/bin/env bash
# Builds PowerSwitch for iPhone/iPad. Needs macOS with Xcode.
#   ios/build.sh            -> dist/PowerSwitch.ipa (unsigned; KravaSigner/ESign/AltStore/Sideloadly sign it on install)
#   ios/build.sh simulator  -> ios/build/Build/Products/Release-iphonesimulator/PowerSwitch.app
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-device}"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet

if [ "$MODE" = simulator ]; then
    SDK=iphonesimulator; DEST='generic/platform=iOS Simulator'
else
    SDK=iphoneos; DEST='generic/platform=iOS'
fi
xcodebuild -project PowerSwitch.xcodeproj -scheme PowerSwitch -configuration Release -sdk "$SDK" -destination "$DEST" \
    -derivedDataPath build ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet build
APP="build/Build/Products/Release-$SDK/PowerSwitch.app"
[ -d "$APP" ] || { echo "PowerSwitch.app not found"; exit 1; }
[ "$MODE" = simulator ] && { codesign -dv "$APP" 2>&1 | head -2 || true; exit 0; }

# --- checks that matter to on-device sideloaders (lessons from PowerSwitchNX)
EXTRA=$(find "$APP" -name Info.plist ! -path "$APP/Info.plist")
[ -z "$EXTRA" ] || { echo "nested Info.plist: $EXTRA"; exit 1; }
for d in Resources resources Contents contents "Support Files"; do
    [ ! -e "$APP/$d" ] || { echo "root folder '$d' would make CFBundle treat the app as an old-style bundle"; exit 1; }
done
cat > "${RUNNER_TEMP:-/tmp}/bundlecheck.swift" <<'SWIFT'
import Foundation
let b = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let name = b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "nil"
let version = b?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "nil"
let id = b?.bundleIdentifier ?? "nil"
print("Bundle(url:) reads: \(name) \(version) \(id)")
exit(name == "nil" || version == "nil" || id == "nil" ? 1 : 0)
SWIFT
swift "${RUNNER_TEMP:-/tmp}/bundlecheck.swift" "$APP"

# --- package: unsigned, files only, no zip extra fields
mkdir -p ../dist
rm -rf ../dist/Payload ../dist/PowerSwitch.ipa
mkdir -p ../dist/Payload
cp -R "$APP" ../dist/Payload/
rm -rf ../dist/Payload/PowerSwitch.app/_CodeSignature ../dist/Payload/PowerSwitch.app/embedded.mobileprovision
(cd ../dist && python3 - <<'PY'
import os, time, zipfile
stamp = time.localtime()[:6]
with zipfile.ZipFile("PowerSwitch.ipa", "w", zipfile.ZIP_DEFLATED, compresslevel=6) as out:
    files = []
    for root, _, names in os.walk("Payload"):
        files += [os.path.join(root, n) for n in names]
    for path in sorted(files):
        info = zipfile.ZipInfo(path.replace(os.sep, "/"), date_time=stamp)
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (0o100755 if os.access(path, os.X_OK) else 0o100644) << 16
        with open(path, "rb") as f:
            out.writestr(info, f.read())
PY
rm -rf Payload)
ls -la ../dist
