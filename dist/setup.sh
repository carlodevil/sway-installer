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
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$UID_T systemctl --user daemon-reload || true
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$UID_T systemctl --user \
  enable --now waybar.service mako.service cliphist-store.service polkit-lxqt.service udiskie.service || true

as_user xdg-user-dirs-update

log "Done. Alt+Enter → Kitty, Alt+d → Rofi."
