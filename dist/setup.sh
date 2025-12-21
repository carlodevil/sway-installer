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
