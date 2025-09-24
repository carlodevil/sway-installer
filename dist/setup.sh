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

# Ensure custom sway-session target is enabled (will become active when sway starts if a sway.service binds it)
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$(id -u "$TARGET_USER") systemctl --user daemon-reload || true
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$(id -u "$TARGET_USER") systemctl --user enable sway-session.target || true

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
# Enable units; they will activate when session target is reached
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$UID_T systemctl --user enable \
  waybar.service mako.service cliphist-store.service polkit-lxqt.service udiskie.service || true

as_user xdg-user-dirs-update

log "Done. Alt+Enter → Kitty, Alt+d → Rofi."
