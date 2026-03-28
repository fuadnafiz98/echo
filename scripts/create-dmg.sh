#!/bin/bash

set -euo pipefail

APP_PATH="${1:?First argument must be the exported .app path}"
DMG_PATH="${2:?Second argument must be the output .dmg path}"

APP_NAME="$(basename "$APP_PATH")"
WORK_DIR="$(mktemp -d)"
STAGING_DIR="$WORK_DIR/dmg"

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "Echo" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
