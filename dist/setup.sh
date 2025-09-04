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
