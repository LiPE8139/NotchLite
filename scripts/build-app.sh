#!/bin/bash
# Builds build/NotchLite.app (release, ad-hoc signed).
#   VERSION=0.1.0 scripts/build-app.sh   set the version shown in Finder (default 0.1.0)
#   scripts/build-app.sh --run          launch the app afterwards
#
# The MediaRemoteAdapter framework is vendored in vendor/mediaremote-adapter, so no
# network access or cmake is needed to build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
ADAPTER=vendor/mediaremote-adapter

if [ ! -f "$ADAPTER/bin/mediaremote-adapter.pl" ] || [ ! -d "$ADAPTER/build/MediaRemoteAdapter.framework" ]; then
    echo "error: vendored MediaRemoteAdapter is missing under $ADAPTER" >&2
    echo "       expected bin/mediaremote-adapter.pl and build/MediaRemoteAdapter.framework" >&2
    exit 1
fi

if [ ! -f Resources/AppIcon.icns ]; then
    scripts/make-icns.sh
fi

# The MediaRemote bridge is compiled here so it always matches the current source.
clang -dynamiclib -fobjc-arc -Wno-objc-method-access -framework Foundation \
    vendor/MediaRemoteBridge/bridge.m -o build/libMediaRemoteBridge.dylib

swift build $SWIFT_BUILD_FLAGS -c release

APP="build/NotchLite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ThirdPartyLicenses" "$APP/Contents/Frameworks"
cp .build/release/NotchLite "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/en.lproj "$APP/Contents/Resources/"
cp "$ADAPTER/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp "$ADAPTER/LICENSE.txt" "$APP/Contents/Resources/ThirdPartyLicenses/mediaremote-adapter.txt"
cp -R "$ADAPTER/build/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
cp build/libMediaRemoteBridge.dylib "$APP/Contents/Frameworks/"
cp vendor/MediaRemoteBridge/bridge.pl "$APP/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# A stable identity matters: macOS keys the Accessibility grant to the signature, so re-signing
# with a different one (ad-hoc changes every build) silently revokes it. Prefer a real developer
# identity, fall back to ad-hoc when none is available.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | head -1)}"
if [ -n "$IDENTITY" ]; then
    echo "Signing as: $IDENTITY"
    SIGN=(--sign "$IDENTITY")
else
    echo "Signing ad-hoc (Accessibility will need re-granting after every build)"
    SIGN=(--sign -)
fi

codesign --force "${SIGN[@]}" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force "${SIGN[@]}" "$APP/Contents/Frameworks/libMediaRemoteBridge.dylib"
codesign --force "${SIGN[@]}" "$APP"

echo "Built $APP ($VERSION)"

if [ "${1:-}" = "--run" ]; then
    pkill -x NotchLite 2>/dev/null || true
    open "$APP"
fi
