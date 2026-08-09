#!/usr/bin/env bash
# Build an unsigned Dexo IPA locally — same steps as .github/workflows/build-ipa.yml.
set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/dexo.xcarchive"
IPA="$BUILD_DIR/dexo-unsigned.ipa"

mise x -- tuist install
mise x -- tuist generate --no-open

rm -rf "$ARCHIVE" "$BUILD_DIR/Payload" "$IPA"
xcodebuild archive \
  -workspace dexo.xcworkspace \
  -scheme dexo \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM=""

mkdir -p "$BUILD_DIR/Payload"
cp -R "$ARCHIVE/Products/Applications/dexo.app" "$BUILD_DIR/Payload/"
(cd "$BUILD_DIR" && zip -qry "$(basename "$IPA")" Payload)
rm -rf "$BUILD_DIR/Payload"

echo "IPA: $(pwd)/$IPA"
ls -lh "$IPA"
