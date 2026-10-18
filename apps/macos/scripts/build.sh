#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
PROJECT="$REPO_ROOT/apps/macos/Bluemock/Bluemock.xcodeproj"
DERIVED="$REPO_ROOT/apps/macos/build/DerivedData"
PRODUCT="$DERIVED/Build/Products/${CONFIGURATION:-Release}/Bluemock.app"
DESTINATION="$REPO_ROOT/apps/macos/build/Bluemock.app"

if [ "${BLUEMOCK_SIGN_WITH_TEAM:-0}" = "1" ]; then
    xcodebuild -project "$PROJECT" -scheme Bluemock -configuration "${CONFIGURATION:-Release}" \
        -derivedDataPath "$DERIVED" build
else
    xcodebuild -project "$PROJECT" -scheme Bluemock -configuration "${CONFIGURATION:-Release}" \
        -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
fi

rm -rf "$DESTINATION"
mkdir -p "$(dirname -- "$DESTINATION")"
ditto "$PRODUCT" "$DESTINATION"
printf '%s\n' "$DESTINATION"
