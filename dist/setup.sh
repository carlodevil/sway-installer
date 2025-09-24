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
