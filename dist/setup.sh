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
