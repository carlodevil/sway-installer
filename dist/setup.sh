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
