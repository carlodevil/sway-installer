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
