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
