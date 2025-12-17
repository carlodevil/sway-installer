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
