#!/bin/bash
set -euo pipefail

# Release builds require a "Developer ID Application" signing certificate.
# Debug builds use local development signing via -allowProvisioningUpdates.

SCHEME="iMCP"
CONFIG="Debug"
DERIVED_DATA="$(pwd)/build/derived"
INSTALL_DIR="$HOME/Applications"
APP_NAME="iMCP.app"

echo "Building $SCHEME ($CONFIG)..."
xcodebuild \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -quiet \
    build

echo "Stopping running instance..."
pkill -x iMCP 2>/dev/null && sleep 1 || true

echo "Installing to $INSTALL_DIR/$APP_NAME..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$DERIVED_DATA/Build/Products/$CONFIG/$APP_NAME" "$INSTALL_DIR/$APP_NAME"

echo "Launching..."
open "$INSTALL_DIR/$APP_NAME"

echo "Done."
