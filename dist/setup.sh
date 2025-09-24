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
