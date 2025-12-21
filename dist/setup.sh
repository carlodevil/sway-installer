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
