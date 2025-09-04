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
