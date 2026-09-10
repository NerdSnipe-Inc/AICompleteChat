#!/usr/bin/env bash
# Builds, signs, notarizes, and publishes a downloadable macOS release — so "grab the signed
# build" (see README) is one command instead of a dozen manual xcodebuild/codesign/notarytool
# steps. Runs entirely on this machine: your Developer ID key and notarization credentials never
# leave your login keychain.
#
# One-time setup: have a "Developer ID Application: <Name> (QW2MDLZZJH)" identity in your login
# keychain. Notarization uses the App Store Connect API key already at
# ~/.appstoreconnect/private_keys/AuthKey_XBLUUZUD2M.p8 (the same one Xcode's own Accounts/
# Organizer flow uses) — nothing to set up separately, no notarytool store-credentials needed.
#
# Usage: scripts/release.sh 1.2.0   (tags v1.2.0, builds HEAD, publishes the release)
set -euo pipefail

APP_NAME="AICompleteChat"
TEAM_ID="QW2MDLZZJH"
NOTARY_KEY_ID="XBLUUZUD2M"
NOTARY_ISSUER_ID="d8c7c3d3-f620-40e6-99a4-500721b826c5"
NOTARY_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${NOTARY_KEY_ID}.p8"

usage() {
  echo "Usage: $0 <version>   e.g. $0 1.2.0" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Version must look like 1.2.0" >&2; exit 1; }
TAG="v$VERSION"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Preflight checks"
command -v xcodegen >/dev/null || { echo "xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not installed (brew install gh)" >&2; exit 1; }
security find-identity -p codesigning -v | grep -q "Developer ID Application" || {
  echo "No 'Developer ID Application' identity in your login keychain" >&2
  exit 1
}
[[ -f "$NOTARY_KEY_PATH" ]] || {
  echo "Notarization key not found at $NOTARY_KEY_PATH" >&2
  exit 1
}
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree has uncommitted changes — commit or stash before releasing" >&2
  exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists" >&2
  exit 1
fi
LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_MASTER="$(git rev-parse origin/master 2>/dev/null || echo "")"
if [[ -n "$REMOTE_MASTER" && "$LOCAL_HEAD" != "$REMOTE_MASTER" ]]; then
  echo "Local HEAD ($LOCAL_HEAD) != origin/master ($REMOTE_MASTER) — push first, or the release" >&2
  echo "won't match what a fresh 'git clone' of master gives someone." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Resolving Swift packages"
xcodebuild -resolvePackageDependencies -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME"

echo "==> Archiving (Release, Developer ID signing)"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$WORK_DIR/$APP_NAME.xcarchive" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION"

echo "==> Exporting signed .app"
cat > "$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$WORK_DIR/$APP_NAME.xcarchive" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
  -exportPath "$WORK_DIR/export"

APP_PATH="$WORK_DIR/export/$APP_NAME.app"

echo "==> Verifying code signature"
codesign -v -vvv --strict --deep "$APP_PATH"

echo "==> Submitting for notarization (can take a few minutes)"
# This zip is submission-only and discarded — not the release artifact (that's built fresh
# from the stapled .app below).
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$WORK_DIR/notarize-submission.zip"
xcrun notarytool submit "$WORK_DIR/notarize-submission.zip" \
  --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
  --wait --timeout 30m

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Packaging release zip"
ZIP_NAME="$APP_NAME-$TAG-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_NAME"

echo "==> Tagging and pushing $TAG"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Publishing GitHub release"
gh release create "$TAG" "$ZIP_NAME" \
  --title "$TAG" \
  --generate-notes \
  --notes "Signed, notarized macOS build. Download, unzip, and run directly — no DesignFoundationPro license needed to run this binary, only to build from source."

rm -f "$ZIP_NAME"
echo "==> Done: https://github.com/NerdSnipe-Inc/AICompleteChat/releases/tag/$TAG"
