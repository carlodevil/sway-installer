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
