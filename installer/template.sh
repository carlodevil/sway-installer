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
  sudo -u "$TARGET_USER" bash -lc 'cargo install --locked tuigreet' || warn "tuigreet build failed"
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
PAYLOAD_B64="__PAYLOAD_B64__"
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
