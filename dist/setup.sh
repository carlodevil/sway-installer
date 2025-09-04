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
