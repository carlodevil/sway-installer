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
