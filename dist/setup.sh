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
