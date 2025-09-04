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
