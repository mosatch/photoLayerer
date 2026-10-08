#!/bin/bash
#
# Builds a Developer ID signed, optionally notarised, disk image of PhotoLayerer.
#
#   Scripts/release.sh                 build and sign only
#   Scripts/release.sh <profile-name>  also notarise and staple
#
# The profile is a notarytool keychain entry holding App Store Connect credentials, created once
# with `xcrun notarytool store-credentials`, so no credentials ever live in this repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${1:-}"
TEAM="${PHOTOLAYERER_TEAM_ID:-R5HR3DX3CV}"
IDENTITY="${PHOTOLAYERER_SIGN_IDENTITY:-Developer ID Application: B4 Group ($TEAM)}"
BUILD="$ROOT/build-release"

# xcode-select often points at the Command Line Tools, which have no xcodebuild.
for candidate in "${DEVELOPER_DIR:-}" "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer; do
    if [ -n "$candidate" ] && [ -x "$candidate/usr/bin/xcodebuild" ]; then
        export DEVELOPER_DIR="$candidate"
        break
    fi
done
if [ -z "${DEVELOPER_DIR:-}" ]; then
    echo "error: no Xcode found. Install Xcode, or set DEVELOPER_DIR." >&2
    exit 1
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>&1 || true)"
if [[ "$IDENTITIES" != *"$IDENTITY"* ]]; then
    echo "error: no signing identity matching \"$IDENTITY\"" >&2
    exit 1
fi

echo "==> Generating the project"
xcodegen generate --quiet

echo "==> Building Release"
rm -rf "$BUILD"
xcodebuild -project PhotoLayerer.xcodeproj -scheme PhotoLayerer -configuration Release \
    -derivedDataPath "$BUILD" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build > "$BUILD.log" 2>&1 || { tail -30 "$BUILD.log" >&2; exit 1; }

APP="$BUILD/Build/Products/Release/PhotoLayerer.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

echo "==> Verifying the signature"
codesign --verify --deep --strict "$APP"
SIGNING="$(codesign -dv "$APP" 2>&1 || true)"
if [[ "$SIGNING" != *"(runtime)"* ]]; then
    echo "error: hardened runtime is not enabled, notarisation would be rejected" >&2
    exit 1
fi
# Under the hardened runtime, Photos access is refused outright without this entitlement.
if [[ "$(codesign -d --entitlements - "$APP" 2>&1)" != *"photos-library"* ]]; then
    echo "error: the Photos entitlement is missing from the signed app" >&2
    exit 1
fi

# notarytool exits zero even on rejection, so the status is read from its output.
notarise() {
    local target="$1" submission id
    submission="$(xcrun notarytool submit "$target" --keychain-profile "$PROFILE" --wait 2>&1)"
    echo "$submission" | sed 's/^/  /'
    if [[ "$submission" != *"status: Accepted"* ]]; then
        id="$(echo "$submission" | awk '/id: /{print $2; exit}')"
        echo "error: notarisation was rejected for $(basename "$target"):" >&2
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        exit 1
    fi
}

# Staple the app itself too, so a copy dragged out of the image works offline.
if [ -n "$PROFILE" ]; then
    echo "==> Notarising the app (this takes a few minutes)"
    ZIP="$BUILD/PhotoLayerer.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarise "$ZIP"
    xcrun stapler staple "$APP"
fi

echo "==> Packaging"
DMG="$ROOT/PhotoLayerer-${PHOTOLAYERER_DMG_VERSION:-$VERSION}.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/LICENSE" "$STAGE/" 2>/dev/null || true
# Give the mounted volume the app icon rather than the blank default.
cp "$ROOT/Resources/PhotoLayerer.icns" "$STAGE/.VolumeIcon.icns"
if command -v SetFile > /dev/null; then
    SetFile -a C "$STAGE"
fi
rm -f "$DMG"
hdiutil create -volname "PhotoLayerer $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ -z "$PROFILE" ]; then
    echo
    echo "Built and signed, not notarised: $DMG"
    exit 0
fi

echo "==> Notarising the disk image"
notarise "$DMG"
xcrun stapler staple "$DMG"

echo "==> Checking it the way another Mac will"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo
echo "Ready: $DMG"
