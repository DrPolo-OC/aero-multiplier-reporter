#!/usr/bin/env bash
set -euo pipefail

REPO="DrPolo-OC/aero-multiplier-reporter"
BRANCH="master"
SCRIPT_NAME="aero-multiplier.sh"
DEST_DIR="/mnt/d/WriteHere/scripts"
DEST_PATH="$DEST_DIR/$SCRIPT_NAME"

echo "Updating $SCRIPT_NAME from GitHub ($REPO@$BRANCH)..."

# Ensure destination directory exists
mkdir -p "$DEST_DIR"

# Download fresh copy
curl -sL "https://raw.githubusercontent.com/$REPO/$BRANCH/$SCRIPT_NAME" -o "$DEST_PATH"

# Make executable
chmod +x "$DEST_PATH"

# Verify syntax
if bash -n "$DEST_PATH" 2>/dev/null; then
  echo "✓ $SCRIPT_NAME updated and syntax OK"
else
  echo "✗ WARNING: Syntax error in updated script!" >&2
  exit 1
fi
