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
