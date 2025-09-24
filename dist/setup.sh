#!/usr/bin/env bash
set -euo pipefail

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

# ── bootstrap helpers ─────────────────────────────────────────────────────────
log()  { echo -e "\033[1;36m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*"; }
err()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; }
require_root() { if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Run as root: sudo $0 [--backup|--overwrite|--skip]"; exit 1; fi; }

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
