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
