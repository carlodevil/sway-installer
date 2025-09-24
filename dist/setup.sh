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
  foot kitty mako-notifier libnotify-bin \
  wl-clipboard cliphist grim slurp swappy wf-recorder \
  brightnessctl playerctl upower xdg-user-dirs \
  network-manager bluez bluetooth blueman \
  pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  thunar thunar-archive-plugin file-roller udisks2 udiskie gvfs \
  lxqt-policykit \
  fonts-jetbrains-mono fonts-firacode fonts-noto fonts-noto-color-emoji papirus-icon-theme \
  curl git jq unzip ca-certificates gpg dirmngr apt-transport-https \
  pavucontrol imv || true

log "Installing Google Chrome"
KEYRING_CHROME="/usr/share/keyrings/google-linux.gpg"
LIST_CHROME="/etc/apt/sources.list.d/google-chrome.list"
if ! command -v google-chrome &>/dev/null; then
  if ! grep -q "dl.google.com/linux/chrome/deb" "$LIST_CHROME" 2>/dev/null; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > "$KEYRING_CHROME"
    echo "deb [arch=amd64 signed-by=$KEYRING_CHROME] http://dl.google.com/linux/chrome/deb/ stable main" > "$LIST_CHROME"
    apt-get update
  fi
fi
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

log "Done. Alt+Enter → Foot, Alt+d → Rofi."
