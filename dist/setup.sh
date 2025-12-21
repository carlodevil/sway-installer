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
