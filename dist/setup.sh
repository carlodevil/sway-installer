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
