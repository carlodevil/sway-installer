#!/usr/bin/env bash
set -euo pipefail

# ── bootstrap helpers ─────────────────────────────────────────────────────────
log()  { echo -e "\033[1;36m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*"; }
err()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; }
require_root() { if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Run as root: sudo $0 [--backup|--overwrite|--skip]"; exit 1; fi; }

PROMPT_MODE=${PROMPT_MODE:-ask}
while [[ ${1:-} ]]; do
  case "$1" in
    -y|--overwrite) PROMPT_MODE=overwrite ;;
    --backup)       PROMPT_MODE=backup ;;
    --skip)         PROMPT_MODE=skip ;;
  esac; shift || true
done

prompt_choice() {
  local prompt=$1
  if [[ "$PROMPT_MODE" != "ask" || ! -t 0 ]]; then
    case "$PROMPT_MODE" in overwrite) echo o;; backup|'') echo b;; skip) echo s;; *) echo b;; esac; return
  fi
  local ans
  while true; do
    read -rp "$prompt [o]verwrite / [b]ackup / [s]kip: " ans || { echo b; return; }
    case "${ans,,}" in o|overwrite) echo o; return;; b|backup) echo b; return;; s|skip) echo s; return;; esac
  done
}

as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }
write_user_file() {
  local dst=$1 content=$2 dstdir tmp
  dstdir=$(dirname "$dst"); as_user "mkdir -p '$dstdir'"
  tmp=$(mktemp); printf "%s" "$content" >"$tmp"; chown "$TARGET_USER":"$TARGET_USER" "$tmp"; chmod 0644 "$tmp"
  mv -f "$tmp" "$dst"; chown "$TARGET_USER":"$TARGET_USER" "$dst"
}
install_user_file_with_prompt() {
  local name=$1 dst=$2 content=$3
  if as_user "test -e '$dst'"; then
    log "$name exists: $dst"; local c; c=$(prompt_choice "Replace $name?")
    case "$c" in
      o) log "Overwriting $dst"; write_user_file "$dst" "$content" ;;
      b) local bak="${dst}.bak.$(date +%Y%m%d-%H%M%S)"; as_user "mv '$dst' '$bak'" || true; log "Backed up to $bak"; write_user_file "$dst" "$content" ;;
      s) log "Skipped $name" ;;
    esac
  else
    write_user_file "$dst" "$content"
  fi
}

require_root
TARGET_USER=${SUDO_USER:-}
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then read -rp "Enter username to configure: " TARGET_USER; fi
if ! id "$TARGET_USER" &>/dev/null; then err "User $TARGET_USER not found"; exit 1; fi
HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
log "Configuring for user: $TARGET_USER (home: $HOME_DIR)"

# ── install packages ──────────────────────────────────────────────────────────
apt-get update
log "Installing base packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  sway swaybg swayidle swaylock waybar rofi xwayland \
  kitty mako-notifier libnotify-bin \
  wl-clipboard cliphist grim slurp swappy wf-recorder \
  brightnessctl playerctl upower power-profiles-daemon xdg-user-dirs \
  network-manager bluez bluetooth blueman \
  pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  thunar thunar-archive-plugin file-roller udisks2 udiskie gvfs \
  lxqt-policykit \
  fonts-jetbrains-mono fonts-firacode fonts-noto fonts-noto-color-emoji papirus-icon-theme \
  curl git jq unzip ca-certificates gpg dirmngr apt-transport-https \
  pavucontrol imv || true

log "Adding Google Chrome repository"
KEYRING_GOOGLE="/usr/share/keyrings/google-chrome.gpg"
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > "$KEYRING_GOOGLE"
echo "deb [arch=amd64 signed-by=$KEYRING_GOOGLE] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
apt-get update
log "Installing Google Chrome"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends google-chrome-stable || true

# VS Code repo (idempotent)
KEYRING="/usr/share/keyrings/packages.microsoft.gpg"
LIST="/etc/apt/sources.list.d/vscode.list"
rm -f /etc/apt/trusted.gpg.d/microsoft.gpg /usr/share/keyrings/microsoft.gpg
sed -i '/packages\.microsoft\.com\/repos\/code/d' /etc/apt/sources.list 2>/dev/null || true
rm -f "$LIST"
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$KEYRING"
echo "deb [arch=amd64,arm64,armhf signed-by=$KEYRING] https://packages.microsoft.com/repos/code stable main" > "$LIST"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends code || true

# Enable system daemons (optional but helpful)
systemctl enable --now NetworkManager || true
systemctl enable --now bluetooth || true

# ── unpack embedded payload (configs + systemd user units) ───────────────────
log "Unpacking embedded payload"
PAYLOAD_B64="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"
TMPD=$(mktemp -d)
printf "%s" "$PAYLOAD_B64" | base64 -d > "$TMPD/payload.tgz"
mkdir -p "$TMPD/payload"
tar -xzf "$TMPD/payload.tgz" -C "$TMPD/payload"

copy_tree() {
  local SRC=$1 DST=$2
  (cd "$SRC" && find . -type f -print0) | while IFS= read -r -d '' rel; do
    local to="$DST/${rel#./}"
    local content; content=$(cat "$SRC/$rel")
    install_user_file_with_prompt "$rel" "$to" "$content"
  done
}

as_user "mkdir -p '$HOME_DIR/.config'"
log "Installing configs"
copy_tree "$TMPD/payload/configs" "$HOME_DIR/.config"

log "Installing systemd user units"
copy_tree "$TMPD/payload/systemd_user" "$HOME_DIR/.config/systemd/user"

# Safe user systemd interaction (some environments lack an active user bus during install)
UID_TGT=$(id -u "$TARGET_USER")
RUNTIME_DIR="/run/user/$UID_TGT"
if [[ ! -d $RUNTIME_DIR ]]; then
  mkdir -p "$RUNTIME_DIR" && chown "$TARGET_USER":"$TARGET_USER" "$RUNTIME_DIR" || true
fi
run_user_sc() { sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$RUNTIME_DIR" systemctl --user "$@"; }
if run_user_sc daemon-reload 2>/dev/null; then
  run_user_sc enable sway-session.target || true
else
  warn "User systemd not ready (skipping sway-session.target enable)."
fi

# ── post-install (env + enable user services even without GUI session) ───────
install_user_file_with_prompt "environment.d (Wayland)" "$HOME_DIR/.config/environment.d/10-wayland.conf" "$(cat <<'ENV'
XDG_CURRENT_DESKTOP=sway
MOZ_ENABLE_WAYLAND=1
GTK_USE_PORTAL=1
ELECTRON_OZONE_PLATFORM_HINT=auto
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
ENV
)"

install_user_file_with_prompt "chrome flags" "$HOME_DIR/.config/chrome-flags.conf" "$(cat <<'CHR'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHR
)"

if ! as_user "systemctl --user is-active --quiet default.target"; then
  loginctl enable-linger "$TARGET_USER" || true
  systemctl start "user@$(id -u "$TARGET_USER")" || true
fi
UID_T=$(id -u "$TARGET_USER")
if run_user_sc daemon-reload 2>/dev/null; then
  run_user_sc enable waybar.service mako.service cliphist-store.service polkit-lxqt.service udiskie.service || true
else
  warn "User systemd not ready (skipping service enable); rerun postinstall or enable manually after login."
fi

as_user xdg-user-dirs-update

log "Done. Alt+Enter → Kitty, Alt+d → Rofi."
