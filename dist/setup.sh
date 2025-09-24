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
