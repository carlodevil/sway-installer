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

# sanity check: ensure tarball was created and is non-empty
if [[ ! -s "$TAR_PATH" ]]; then
  echo "error: tarball missing or empty: $TAR_PATH" >&2
  echo "build dir listing:" >&2
  ls -la "$(dirname "$TAR_PATH")" >&2 || true
  exit 1
fi

# encode payload (make newline handling portable across base64 implementations)
B64=$(base64 "$TAR_PATH" | tr -d '\n')

# inject payload into template
INSTALLER="$DIST_DIR/setup.sh"
sed "s|$PLACEHOLDER|$B64|g" "$ROOT_DIR/installer/template.sh" > "$INSTALLER"
chmod +x "$INSTALLER"

echo "Built: $INSTALLER"
