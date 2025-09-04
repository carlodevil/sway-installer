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
