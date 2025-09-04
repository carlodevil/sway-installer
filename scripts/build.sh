#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/.build"
TAR_PATH="$WORK_DIR/payload.tgz"
PLACEHOLDER="__PAYLOAD_B64__"


rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"


# Create payload tarball (configs + systemd_user)
# The tar contains top-level dirs: configs/ and systemd_user/
(
cd "$ROOT_DIR"
tar -czf "$TAR_PATH" configs systemd_user
)


# Base64 encode payload (one line)
B64=$(base64 -w0 "$TAR_PATH")


# Compose installer: common + packages + template with payload
INSTALLER="$DIST_DIR/setup.sh"
{
cat "$ROOT_DIR/installer/template.sh" |
sed "s|$PLACEHOLDER|$B64|g"
} > "$INSTALLER"


chmod +x "$INSTALLER"


# Optional: print size
echo "Built: $INSTALLER ($(du -h "$INSTALLER" | cut -f1))"