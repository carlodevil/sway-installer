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
