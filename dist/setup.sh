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
