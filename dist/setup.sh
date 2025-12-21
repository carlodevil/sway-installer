#!/usr/bin/env bash
set -euo pipefail

# ── bootstrap helpers (define early) ─────────────────────────────────────────
log()  { echo -e "\033[1;36m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*"; }
err()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; }
require_root() { if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Run as root: sudo $0 [--backup|--overwrite|--skip]"; exit 1; fi; }

# ── logging setup ────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="/var/log/sway-installer-${TS}.log"
mkdir -p /var/log || true
{
  echo "=== sway-installer run $TS ===";
  echo "Kernel: $(uname -r 2>/dev/null || true)";
  echo "Command: $0 $*";
} >>"$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging to $LOG_FILE"

PROMPT_MODE=${PROMPT_MODE:-ask}
OPT_MINIMAL=0
OPT_NO_CHROME=0
OPT_NO_VSCODE=0
OPT_NO_SYSTEMD_USER=0
OPT_NVIDIA_WORKAROUNDS=0
 # Display manager now fixed: mandatory greetd + tuigreet

usage() {
  cat <<USAGE
Usage: sudo $0 [options]
  -y, --overwrite          Overwrite existing user files (no prompt)
      --backup              Backup existing user files (default unattended)
      --skip                Skip existing user files
      --minimal             Skip optional extras (file manager, media, code, chrome)
      --no-chrome           Do not install Google Chrome
      --no-vscode           Do not install VS Code
      --no-systemd-user     Do not deploy/enable user systemd units
    --nvidia-workarounds  Add conservative NVIDIA Wayland env flags
      --help                Show this help
USAGE
}

while [[ ${1:-} ]]; do
  case "$1" in
    -y|--overwrite) PROMPT_MODE=overwrite ;;
    --backup)       PROMPT_MODE=backup ;;
    --skip)         PROMPT_MODE=skip ;;
    --minimal)      OPT_MINIMAL=1 ;;
    --no-chrome)    OPT_NO_CHROME=1 ;;
    --no-vscode)    OPT_NO_VSCODE=1 ;;
    --no-systemd-user) OPT_NO_SYSTEMD_USER=1 ;;
  --nvidia-workarounds) OPT_NVIDIA_WORKAROUNDS=1 ;;
    --help|-h)      usage; exit 0 ;;
    *) warn "Unknown option: $1"; usage; exit 1 ;;
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

# ── install packages (network check, retry, selectable groups) ───────────────
net_check() {
  local host=deb.debian.org
  getent hosts "$host" >/dev/null 2>&1 && return 0
  ping -c1 -W1 1.1.1.1 >/dev/null 2>&1 && return 0
  return 1
}

log "Checking network connectivity"
if ! net_check; then
  warn "No network connectivity detected – continuing, but package installs may fail."
fi

APT_RETRIES=3
for i in $(seq 1 $APT_RETRIES); do
  if apt-get update; then break; fi
  warn "apt-get update failed (attempt $i/$APT_RETRIES); retrying in 5s"; sleep 5
  [[ $i -eq $APT_RETRIES ]] && err "apt-get update failed after $APT_RETRIES attempts" && exit 1
done

CORE_PKGS=(
  sway swaybg swayidle swaylock waybar rofi xwayland
  kitty mako-notifier libnotify-bin
  wl-clipboard cliphist grim slurp swappy wf-recorder
  brightnessctl playerctl upower power-profiles-daemon xdg-user-dirs
  network-manager bluez bluetooth blueman
  pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth
  xdg-desktop-portal xdg-desktop-portal-wlr
  lxqt-policykit
  fonts-jetbrains-mono fonts-firacode fonts-noto fonts-noto-color-emoji papirus-icon-theme
  curl git jq unzip ca-certificates gpg dirmngr apt-transport-https
)
EXTRA_PKGS=(
  thunar thunar-archive-plugin file-roller udisks2 udiskie gvfs
  pavucontrol imv
)
INSTALL_PKGS=("${CORE_PKGS[@]}")
if [[ $OPT_MINIMAL -eq 0 ]]; then INSTALL_PKGS+=("${EXTRA_PKGS[@]}"); fi
log "Installing packages (${#INSTALL_PKGS[@]} selected)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${INSTALL_PKGS[@]}" || true

# ── mandatory display manager: greetd + tuigreet ────────────────────────────
log "Installing greetd (mandatory display manager)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends greetd || warn "greetd install failed"

if ! command -v cargo >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cargo || true
fi
if ! command -v tuigreet >/dev/null 2>&1; then
  log "Building tuigreet via cargo"
  sudo -u "$TARGET_USER" bash -lc 'cargo install --locked greetd-tuigreet' || warn "tuigreet build failed"
  [[ -f "$HOME_DIR/.cargo/bin/tuigreet" ]] && install -Dm0755 "$HOME_DIR/.cargo/bin/tuigreet" /usr/local/bin/tuigreet || true
fi

GREET_CMD="/usr/local/bin/tuigreet --time --remember --cmd 'systemctl --user start sway.service'"
if ! command -v tuigreet >/dev/null 2>&1; then
  GREET_CMD="/usr/bin/sway"
fi
cat >/etc/greetd/config.toml <<CFG
[terminal]
vt = 1

[default_session]
command = "$GREET_CMD"
user = "greeter"
CFG
systemctl enable --now greetd || warn "Failed to enable greetd"

if [[ $OPT_MINIMAL -eq 0 && $OPT_NO_CHROME -eq 0 ]]; then
  if [[ ! -f /etc/apt/sources.list.d/google-chrome.list ]]; then
    log "Adding Google Chrome repository"
    KEYRING_GOOGLE="/usr/share/keyrings/google-chrome.gpg"
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > "$KEYRING_GOOGLE"
    mkdir -p /etc/apt/sources.list.d
    echo "deb [arch=amd64 signed-by=$KEYRING_GOOGLE] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update || true
  else
    log "Chrome repo already present"
  fi
  log "Installing Google Chrome"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends google-chrome-stable || true
else
  log "Skipping Chrome (minimal or disabled)"
fi

if [[ $OPT_MINIMAL -eq 0 && $OPT_NO_VSCODE -eq 0 ]]; then
  KEYRING="/usr/share/keyrings/packages.microsoft.gpg"
  LIST="/etc/apt/sources.list.d/vscode.list"
  rm -f /etc/apt/trusted.gpg.d/microsoft.gpg /usr/share/keyrings/microsoft.gpg
  sed -i '/packages\.microsoft\.com\/repos\/code/d' /etc/apt/sources.list 2>/dev/null || true
  rm -f "$LIST"
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$KEYRING"
  echo "deb [arch=amd64,arm64,armhf signed-by=$KEYRING] https://packages.microsoft.com/repos/code stable main" > "$LIST"
  apt-get update || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends code || true
else
  log "Skipping VS Code (minimal or disabled)"
fi

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

# Install udev rule for backlight control
if [[ -f "$TMPD/payload/configs/udev/90-backlight.rules" ]]; then
  log "Installing udev rule for backlight control"
  cp "$TMPD/payload/configs/udev/90-backlight.rules" /etc/udev/rules.d/90-backlight.rules
  udevadm control --reload-rules || true
  udevadm trigger --subsystem-match=backlight || true
fi

if [[ $OPT_NO_SYSTEMD_USER -eq 0 ]]; then
  log "Installing systemd user units"
  copy_tree "$TMPD/payload/systemd_user" "$HOME_DIR/.config/systemd/user"

  UID_TGT=$(id -u "$TARGET_USER")
  RUNTIME_DIR="/run/user/$UID_TGT"
  if [[ ! -d $RUNTIME_DIR ]]; then
    mkdir -p "$RUNTIME_DIR" && chown "$TARGET_USER":"$TARGET_USER" "$RUNTIME_DIR" || true
  fi
  run_user_sc() { sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="$RUNTIME_DIR" systemctl --user "$@"; }
  if run_user_sc daemon-reload 2>/dev/null; then
    # If a display manager is managing the login (greetd), keep sway.service enabled (started via DM command)
    run_user_sc enable sway-session.target sway.service || true
  else
    warn "User systemd not ready (skipping sway-session.target enable)."
  fi
else
  warn "Skipping systemd user units (per --no-systemd-user)"
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

if lspci 2>/dev/null | grep -qi nvidia; then
  log "NVIDIA GPU detected"
  if [[ $OPT_NVIDIA_WORKAROUNDS -eq 1 ]]; then
    {
      echo 'WLR_NO_HARDWARE_CURSORS=1'
      echo 'WLR_DRM_NO_ATOMIC=1'
    } >> "$HOME_DIR/.config/environment.d/10-wayland.conf" || true
    log "Applied NVIDIA workaround env vars"
  else
    log "(Use --nvidia-workarounds to add conservative WLR flags)"
  fi
fi

install_user_file_with_prompt "chrome flags" "$HOME_DIR/.config/chrome-flags.conf" "$(cat <<'CHR'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHR
)"

if [[ $OPT_NO_SYSTEMD_USER -eq 0 ]]; then
  USER_SD_SOCKET="$RUNTIME_DIR/systemd/private"
  if [[ ! -S $USER_SD_SOCKET ]] || ! run_user_sc is-active --quiet default.target 2>/dev/null; then
    loginctl enable-linger "$TARGET_USER" || true
    systemctl start "user@$(id -u \"$TARGET_USER\")" || true
  fi
  if run_user_sc daemon-reload 2>/dev/null; then
    run_user_sc enable sway.service waybar.service mako.service cliphist-store.service polkit-lxqt.service udiskie.service || true
  else
    warn "User systemd not ready (skipping service enable); will start after first Sway login."
  fi
fi

as_user xdg-user-dirs-update

log "Done. Alt+Enter → Kitty, Alt+d → Rofi."
log "Summary:"; cat <<SUM
  User: $TARGET_USER
  Minimal mode: $OPT_MINIMAL
  Chrome installed: $(( OPT_MINIMAL==0 && OPT_NO_CHROME==0 ))
  VS Code installed: $(( OPT_MINIMAL==0 && OPT_NO_VSCODE==0 ))
  Systemd user units: $(( OPT_NO_SYSTEMD_USER==0 ))
  NVIDIA workarounds: $OPT_NVIDIA_WORKAROUNDS
  Display manager: greetd (tuigreet)
  Log file: $LOG_FILE
SUM
log "If bar/services missing on first login: systemctl --user start sway-session.target"
