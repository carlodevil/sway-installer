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
  kitty mako-notifier libnotify-bin \
  wl-clipboard cliphist grim slurp swappy wf-recorder \
  brightnessctl playerctl upower power-profiles-daemon xdg-user-dirs \
  network-manager bluez bluetooth blueman \
  pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  thunar thunar-archive-plugin file-roller udisks2 udiskie gvfs \
  lxqt-policykit \
  fonts-jetbrains-mono fonts-firacode fonts-noto fonts-noto-color-emoji papirus-icon-theme \
  curl git jq unzip ca-certificates gpg dirmngr apt-transport-https \
  pavucontrol imv || true

log "Adding Google Chrome repository"
KEYRING_GOOGLE="/usr/share/keyrings/google-chrome.gpg"
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > "$KEYRING_GOOGLE"
echo "deb [arch=amd64 signed-by=$KEYRING_GOOGLE] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
apt-get update
log "Installing Google Chrome"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends google-chrome-stable || true

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

# Safe user systemd interaction (some environments lack an active user bus during install)
UID_TGT=$(id -u "$TARGET_USER")
RUNTIME_DIR="/run/user/$UID_TGT"
if [[ ! -d $RUNTIME_DIR ]]; then
  mkdir -p "$RUNTIME_DIR" && chown "$TARGET_USER":"$TARGET_USER" "$RUNTIME_DIR" || true
fi
run_user_sc() { sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$RUNTIME_DIR" systemctl --user "$@"; }
if run_user_sc daemon-reload 2>/dev/null; then
  run_user_sc enable sway-session.target || true
else
  warn "User systemd not ready (skipping sway-session.target enable)."
fi

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

install_user_file_with_prompt "chrome flags" "$HOME_DIR/.config/chrome-flags.conf" "$(cat <<'CHR'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHR
)"

USER_SD_SOCKET="$RUNTIME_DIR/systemd/private"
if [[ ! -S "$USER_SD_SOCKET" ]] || ! run_user_sc is-active --quiet default.target 2>/dev/null; then
  loginctl enable-linger "$TARGET_USER" || true
  systemctl start "user@$(id -u \"$TARGET_USER\")" || true
fi
if run_user_sc daemon-reload 2>/dev/null; then
  run_user_sc enable waybar.service mako.service cliphist-store.service polkit-lxqt.service udiskie.service || true
else
  warn "User systemd not ready (skipping service enable); rerun postinstall or enable manually after login."
fi

as_user xdg-user-dirs-update

log "Done. Alt+Enter → Kitty, Alt+d → Rofi."
