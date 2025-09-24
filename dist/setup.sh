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

log "Installing Chromium"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium || true

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

install_user_file_with_prompt "chromium flags" "$HOME_DIR/.config/chromium-flags.conf" "$(cat <<'CHR'
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
