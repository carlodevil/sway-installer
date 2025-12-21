#!/usr/bin/env bash
set -euo pipefail


install_pkg_group() { local label=$1; shift; log "Installing: $label"; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }


apt-get update


CORE=(
sway swaybg swayidle swaylock waybar rofi xwayland
kitty mako-notifier libnotify-bin
wl-clipboard cliphist grim slurp swappy wf-recorder
brightnessctl playerctl upower power-profiles-daemon xdg-user-dirs
network-manager bluez bluetooth blueman
pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth pulseaudio-utils
xdg-desktop-portal xdg-desktop-portal-wlr
thunar thunar-archive-plugin file-roller udisks2 udiskie gvfs
lxqt-policykit
fonts-jetbrains-mono fonts-firacode fonts-noto fonts-noto-color-emoji papirus-icon-theme
curl git jq unzip ca-certificates gpg dirmngr apt-transport-https
pavucontrol imv
)
install_pkg_group "Core Wayland desktop + tools" "${CORE[@]}"


# Google Chrome (stable) repo + install (replaces Chromium)
KEYRING_GOOGLE="/usr/share/keyrings/google-chrome.gpg"
echo "Installing: Google Chrome (stable)" >&2
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > "$KEYRING_GOOGLE"
mkdir -p /etc/apt/sources.list.d
echo "deb [arch=amd64 signed-by=$KEYRING_GOOGLE] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
apt-get update
install_pkg_group "Google Chrome" google-chrome-stable || true


# VS Code repo (idempotent)
KEYRING="/usr/share/keyrings/packages.microsoft.gpg"
LIST="/etc/apt/sources.list.d/vscode.list"
rm -f /etc/apt/trusted.gpg.d/microsoft.gpg /usr/share/keyrings/microsoft.gpg
sed -i '/packages\.microsoft\.com\/repos\/code/d' /etc/apt/sources.list 2>/dev/null || true
rm -f "$LIST"
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$KEYRING"
echo "deb [arch=amd64,arm64,armhf signed-by=$KEYRING] https://packages.microsoft.com/repos/code stable main" > "$LIST"
apt-get update
install_pkg_group "Visual Studio Code" code || true


systemctl enable --now NetworkManager || true
systemctl enable --now bluetooth || true