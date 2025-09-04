#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/.build"
TAR_PATH="$WORK_DIR/payload.tgz"
PLACEHOLDER="__PAYLOAD_B64__"

rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"

# bundle configs + systemd_user
(
  cd "$ROOT_DIR"
  tar -czf "$TAR_PATH" configs systemd_user
)

B64=$(base64 -w0 "$TAR_PATH")

# inject payload into template
INSTALLER="$DIST_DIR/setup.sh"
sed "s|$PLACEHOLDER|$B64|g" "$ROOT_DIR/installer/template.sh" > "$INSTALLER"
chmod +x "$INSTALLER"

echo "Built: $INSTALLER"
