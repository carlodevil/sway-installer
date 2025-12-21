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
PAYLOAD_B64="H4sIAAAAAAAAA+w8XZPcxnF85f6KqT1d3R112MV+3y11TO54pCmLpBhSLEVFsc4DYLA7PCwAY4DdW53ORduqJHJV5KTs+MGpSuUldlLJQ/KYv6MfYP6FdM8AWHztckmTp8gmSuJhZvprpnu6ewYza3quzUeieeUtPjo8g14P/7YGvVb2b/JcafVa7bbe1bsd/Yrearf0zhXSe5tCJU8kQhoQciWIXJcFy+Fe1v49fcxY/xN66r0tI3h1/Xf0Tvud/i/jyelfFd44D1Rwv9tdqv9Oq1vQfxferxD9jUtS8fyZ63+DPHa5zZlFwjGbMLL9KZ0bMCDUNJkbEp86LAzZTs2g5uko8CLX0kzP8YKDDZjS3b39WsjOwqTqtnxqhhdYLKiuFPwLdtCu+dSyuDs62KtNaDDiLrxYzKaRE2ohnzAvCg96YBk123PDgx+y8Cig3BX3PNcj91lgkdtQT1ptwD7Tplxww2EHl+Iu/tSeZP7PpNrfTgR4Df/fGejv/P9lPAX9i3DusIYpxJvksdr/g95b/YL+e20Af+f/L+G5Rs5rBJ7mNfIjL7Q1dLganTHhTdiPCBckYD+OeIDxwSMGI+CFQ+o4ULa9gHAwH0GuNSUJiWrTCXfmQ7L16DZ5EHjkEwgPW7tEUFdoggXc3iWuF3qSj8i+a+az01yZTbxnPF9zFgb0+oIXxpIhaXX8s0zljPHROBwSw3MsVR1HnoBaPBIAryP8VSDlCh5yzx0SvdEWhFHBNO5qFEIcxJ/rtYtabcZdy5ttqMkRj1QxEg6JJOXTAAKm4hjXb9jyUXULfpofeD4LQhilIq0SqBUFVMnY6ImySI0xtyzmxpJ5PjU5koX+SFgjCkPPXWj4sWAwGmeaGFOgIXXJqEU8Ox4jIjxMAwjGdNC9uxVCmy1YmKh4gTxEbGjQiQbjXx4C4HY49bhFZO/AXBQHQbAUwGCbYxKL51LIO1IGCDUErbusUnu67BhQH4ehL4bN5oiH48homN6keeiwMzoXTZXCNGf8lDdvH/7VBnRJm3nBKQhoMk1xFdqYTplGNYGij5g29qbAhtk2M2V3FdhQVpc0j70fgzWHiTRzLyImdQkOCSXSixLomsLGmULdOZl4VgT1Dj+FIR5zOXE2/MgRjEYW95bwSqwsTrgkx420O4LklPxyqy6PaS+ZP3FSBpgkrXsNa6+Ub+lABiODbuu7JP6v0d5ZQqFhe2YkwJKWDlC/O2gPjq+vttTVYjaiYIR571IezOhaXWMZNjVDPmXkHJFrV1focD33swEWw95kf03HM093axsGhaQ+mMOb6Ufw7wScrSxaXGB7yCbgoWgYBUxCm6cOelV4d1mI3d7NGi4UZhAifCeaGCxAohBUvYk2YRanSC2gSBs7A3+45bATmD7c4KGH0MIETuYYrA+pejOwTPCQNneY0CwKkrmI7CeKz1jpwvVXeVy1skitWWpMOs/dnOrOC8DdGBhm9Yc2yQDChEXn6DA7nHgijKfzLvEmPJS1MRGc1g3VKDRZf4PMuDVi4dDmgYDV0pg7FlQuk0IiZVxdpRgBKqQsh6yuEkQ1pJI4dB1BAhVL9Yz1rOefYgNbDpxVVEpAPjkCDXMsJRntkrQK7Gw0Sv1AFcHVwv3lKZvbAQQdmLYOd5MeQX6jXtaQuEpqrLuINfZYgMgQBpgvtneycRb4MVxdC4gSsNBFKDtyTfQDKIDDUYcwJ0kk6EhGxcVIQLjhJnWGkBFtp+Oy83J9LBsl6vKJTC40jMBDNRjFJiWklgg5jDvVQjedh+QhU7kKCBC5Ibohm7tQWwS0wFfExKgDSC6tgInzHgL5mrh+VZpEpWvIO4XEYFvpjK9EaoBzg6A8oa65wr2uGr/lpA3qINkVYer16KpaQddKEZaQdqjBnKGMoytoZGYhWuIrMcsiq6Cynr/AuLOuZ4mD0Xrgcbx6JeAGSAMLGxesdB09Sp2lwfCP0HtKozGJ1uK8bOQz0fiNEFlXHmkymdj/aszbtGd2e3HshuADkSoc43pNTyZzlnYjLgjfC7m9pplVEZg65nrImaRoRVzT9ztto4SQeu/1MkvMmNYUCiFvkIZPhZCpp0TSRuGphovzeEEzJBaf5BFcxiyhYWxxpaNdhjiGuSbn29LQmhU8n9wt70Lb6nQ7/SoclUPTlfbGTFu3WwXryVBcJItVWXPfNPeXmF6MvKYDsHsds2MusMCcfH8Vwr5utIzWAsGnqxc0vRbtDKiCh6gyijAnKC+hYNoaYHb5Lg26+l6/u3xhV8iOi5Oun8w5SJYMjwYWLJRBKVXc9wesRa1qR1Lgrv+R3G8QGcLKK4HeaoQGZq4VI718+blYlLwWUgOmfohTuGIRmFtAS8cfgMGb81Kvcq2YX02WdDwz8rOxzLiKiA0QjTEXVoirnJdp9wZ6BduGjEqwOl2O2jKpvgIVVrSrMo7+vtVF3O96N/TP7yns/6ti45nwXPON8XjJ99/eYNAq7v8P9N67/f/LeJpNol3TcA8BVoBS7ViuxVvGTVJ36JwF9SGpQ3Cr72JV8oU4hBWrT2S7hK77ntrRQmjDCyG5yiEkzWQb8L5UAF/iVseXctW2o4iM5f49kOi0s8iqGlHxK0QAS4tp/A2CRlCnmmMSMooAhVZ7T8/SkPUKJN7fwD4NyWA3VxmLntbjKODmCHhcqOxKij+gvgBBwhk41XgDRpDtrn+2k6DcHHueYHKrRu2tw+ofCzFwzDGzSwS0n9Su1gXMxOZiP6a+m2441FXC2pTZa11WP93N08Fv9lJbT1KsIkgQD+8Cor5YeGS5xYuhbFW69spXyv2JnKAYbrMVlUvaOkn6UO71MLMXkxCRK3YUvX6OGxYXwOBqyoAFggvMZU8KVK7miVxDvSakL2oX8egoiSV8HQ8gfOG5DDkd2gFk7c0femMK018YUTDK9ovjcE+pUx/29Ux16HlOyH1tIfEHBh/dOB9ufkY2jy4+aGLpc/eDMLzxgZhQx7lxDksD5lo0gEZV80ETWrO8FDGNOmoIgJa2OdE2LTkO2cEZbt4Zbt67UBaSdHChuuzQ1i025absKTV9fjLlFvNaZa6SLowx2tfFJjnHFcJFhXDyeyAaV/0P3/w9TP76H375K/XnH9WfX6o/36g/Mcgv1J+/k3+++ef604Lkyr5ycsvsrmwmOFVHnmdBw35vN9dUn9HAVVO4oxeaksUZ+oxe2nRRPQwmVZ/ZVo2DHTnO2sDJVl4R4cXf/q4COt79XA84MRY06YuyBDhcMWQ8anXlsQ9dohJY1Qqe03FgJWixjAuropL0e6VpvPj6K9T0i69/rv78TP35qfrzvKD+atexUHxWNfn+VUzDB0iMxMSARvx28bl7DDkrfng8t+RLmUodE/eI7daqu5WbU/IgE/J78fPf59zgYtuxojXZOZRNX39T9p9y80+2/vS/6nHjRW6wEp+dlQfVI/2UTRXbmeO3ryk9b3/sY0Smzg75xENlm0rDsCxV8YoLkuKWVDrjNpfjzoTg1gXY4H9WKJ4BwQAEUxrCpUtw0Tw3OfwhL/7lN/WVfvOc29LXkynuJo1mEruIFjPC7et4YiRY2/c98uGDnSUI2VU+oh1nV/3f/vZfV0yomAGMc75HeaebCaxFjcB6zHMcDXfT0etIbWzuym/IkN9QYjseDSv9z9RzImC9wqEYTsRgKGUOVIJ/8Ytfk3MFeCK8CDS+koQmt/6k0f32P16JRB7xpeCqJS/xi6/+eylkhv5X/7PC3+QDBKSX1PLHcXR/8fzf6oVQAHHeEpoNi2UJ8Jt/KAEAAaGsuaJ1Qfpn/1Rq84KQGs6yZpOquf03/1tsWTgUcJ7Pfyf95PPfqz//HrvLjNlJHPwM43CZ09R9Oo1gNEKwuNg+F0vtZP1ng7L/P53/7r07/30pT07/+E+Du/wN83jZ+e/eYFA8/93rdN6t/y/jeTKh3H1agxA/OUD1F05cEzxyPZSHtlvt2hO5YyeeZk6DH+hUt1tdQAtYXKO+adWgHDk00A86Rrfdayfl1oFh91t9mpTbB7RjsD0zKXcOmGEae0ZS7h7stWjLbCXl3oHR3QMfnJT7B3t7pm7pSXlwwHps39Zrhlzp6gdds9cHdqqYclfFlLkqprxVMWWtiilnVewf6GbfNjpxcZD024wC4QUH6iMN2ZdPTTBHffMu1H/X6k/n/ykPw/lbCgCv4f/b3cE7/38ZT17/8t8G1r1JHi/z//120f/32v3BO/9/GQ+6+xN1aJssuWcjQ8IJxgDSajf0jPMnG/qhfjvn/Uly30eGCp1sdI6k95fFFtk4ug3u91AV22TjsHN0a++mKnbIxq2jm0d7R6rYJRt7rcPWzZYq9gC3u3fr8FgV+8lncFUcAG7v1v5tXRX3yEb3Jrj9mNF+nm9LzzNutfKcW+0861Ynz7sFouk3+7ePOnG5t+i1dP6pbKnbP6kYoUVjbkQl5qXpP5n/cgP2LfF4nfy/33/n/y/jyen/O7n/Ca+9ov67bdT/O///9p8N8u2vn3+P/qttkEdgqkSZKtk2HUZdZu2Qb5//ityZ+4GDB+jVBQyDjemUe0Hte9dJkPieZxHoCuGuH4U1PND/3gSqoLpbk3Ukubp1dmqcOHSORywikdZ4cmdX4BHbGXeHML/9E3g/gYKECalPmIv7UZYsu3hOjTonamMybbqo1VCao8zpF+E53CL3vcDaJTMejgmf4LkkmzoOBjLCbeIHTDDIHNgZM4ErKEwQTXM9PJUThJGvAQExJppjki0Af0I0m9Tfu/PxvVvNB9zEA3OiuWCJpxMcp/HMH9XJ0+u4Qe0SpEzQaRkjok2IjR8oNL4ekeuEOYIVSchunciATjST1Dfatzrdrg7QNt/CMfiUztG4mmIuQjaxYIimZBu/QMuNPUc0b2E8DzyXUN8XOys7bxmR0CLfoiHT4gNveOwZSHIgMMErKJqWMDr+8NGDu4efkU8PP7t7eP/4JCk/gopHH9/8iPz18Q9Obj5++PDW/U9Ojm89+uiTjx8cYMdWj7+kboYwblokWABqxI7kZHgdzspgDn0fNAz0zCgUynxxj4EQucRQFfKLDqgzcmkQWzhzI0LwowzRAHtGLHC7SO6ON2FQDxXJ4XFyyuZiV12mmvKJwpe3Lcbq3fJmLnmm3iOfnKo3dQ3CQZo35WZGcuNdow4fgSdZXHmX8AYFS5FPkuum1TidoBrjVvtQVce35iV0kgGm1SdjnuaNqv+jZLt2kRKisOoKElbfOuoed4+k8cmbK8RiphefjFd7McPk6h4Ysbq251rcpHj4Ut7uOFHNNdPhQDS9Q5U+C5Ezb4lgpcYCmRPuxjeeFgOSeUvJlBsTQpFbkGgx4Jm3HKHFW0okHbCESFqTeUuJFBsTMr5DTTb2HBzN15Ylk8pn4OIZwWiAX/iG8adUHmKQooFoJpcjt6XRP4OcBAMcHmfYKWBOON6RcEjLP0s0vw2LNUkLSe0olxx6o5HDkt9UiI2A+PyMAWpaLT8ycXeUtOOtyxrKdsKsETtJpBITcBrYhU8k1fQqp+c2PduuGWByYj6R8en9R2Nuh+8bC+c6ESOyVZBD3u4kq6S4TspiYP1WFTd3Nbe416/OUPZbun5N08hHbI68AQ99qQa1d2nkmmOAzAv1kEHsiWWSTi/fHLsT1SxdYL7dyrajQ8w3/1g1n0LAqxqLTFhzKcS1kMTnHjDEbd0646HMn/5ii2gG2fqMiS2ylQwcg1bZ3UfxYVEvXMj2IODpHJMsRgGfEG0EIXdbOFHg79SJRr5Ezr4/x4CupbhKNEVhgfuTRZgWKUPtvW0MiuT9zdva5p3Ne5uPdhq+O6rVFv3C8+JEm5HPM1/J4h8NIR1dV/2RV9VQCJOoZcZWJXw/gcf+16FGJVbyezvefa5vEZAvguCzHMqt52kbDBf7mnAY85cJI2PkcQAaSoyRqLuJghhzgk4Iq2QIk2kfZoLqiqGH3+bj66ZA4yGTGzP44y1q5scXADNg5H1JA6GPmfB5qL7x4wfsXUgPhaduF8rDdDAVtKJEiHhzjJekoTlA5xN6EGamYPgMX5FTSTZJLUDhkBKKLwUDUiUoC4YBz780aunEBHHxR2kC1XnFtSZ7CxDyp2riBUByTQznUdV0MEEGRKmplHoqhVF5bG1DVTG8vI2XtPFWlGrLU1JZhWrH10KrVJJqxddCK2Qeqi3yCy1KUaoxGZuPAzmaEuBJ5H+JBDNHJJ/mSdxdJdfxKrEeL5PqYUmoZJBwzJNYrQwjjjRQL6QpgUoJtSw126uU8V5sJVNWIW8MIkdTgpSljkFgSCVAUfa4OZkAU5YO6zHknF68WKEBppGYPFZh332phMcvFfDxSvkelsTD7C49s4hmKVM/cNM8NDGSLy7/qgP0WZqtRSNx1YWvVhmqXYZql6E6ZahOGapbhuqWoXplqF4Zql+G6pehBmWoQRlqrwy1V4baL0Ptl6H0ilHVY7XIyZBMBEzSKHehfbWalOpbSu3VSCvUp7Db62BXqFVhd9bBrlC3wu6ug11hBgq7tw52hXko7P462BVmo7AH62BXmJPC3lsHu8LMFPb+OtgV5qew9bWsJTHL+14Iq4PMPX48SYY/cSJ/eUT+xAr+RsmMuqH8TR21yFBUIMIrIp8yVY0xqKW1dLynjv49Tpwb0lfdVVtNIoxse+GtPot/AKUufIeHdRWiowAvORHPeIY/quLZ2UiLzjjGlZ02iKfC/fvTXZkWjL2Af4Gdd2T6AOmGukApGYgYFTIMn8klqDNvlEfSUNDjcstUtUxrBW+bEXsx8slBf0hKbCbbnGQQ5slZ/hx1sQCA9SAkHWWQWQISUsNgViLHPXrKclKo0cKDtSpJLlOys60xmXilViaUdCXkTpKYpfkeXgJZZo3K6lLQeH2ZDh71i/TxZ4RiHgGjkpFMIRIKWFsxcIqNJIXinOQZLZwvzgakp+7RLXRVJkljBAUpTfhRek8vG24pJN7yhxnqi3t89V28UQeGwbHBgHwdrDhJz9FK0xw5Pw0Ec600o8cDsEyOwIiFKlWXG6UOLHSCRq5vGYU582K+FXd5Id0yZU24K8dvmgNOOopbDHIBgNtFmXuOMReceslJ70SAElTS3w/tpHfw/yTC07sOK4OLXXWW2PQmExwHc26qrT9It0dy1k0qZq/qRoYY7o5IBT5MFhbbaj8Q87l0cZ75uQ0qjWhH7p9ZmPxZ6N9wa7OQ/d0MAyfOT9WqBToxDvDHQeSlIfmjYVUYKtmMMUaYWZLVGDLBfCUeKmFczmOD3FF3o17SOUibS4zjW1XLeieT8QLn1SiPJZNX4iIT6lVcNshtmNlkW96LYcFOtqMqp69YcUjS2WVH5ZC3KyXKLSSqxn0l2opxXom3YrARD83+MXrUkOdWCRD+OERFXNCgg1BjQ9QRanlq/gEeQj/8v/auvTdxI4j/ff4Uq0inJrlzE0gIJ5AlSEKq08GF8GhPSiPkEOdqHWDXNgno1O/endldvzC4vYJzbecnRYrtnfWynpl9zGPBCT0hYbouY6I/Xb07w8edeSB3j7gSDiaQy0z3eevR05r92rhsXTWH7cGo//7jh4YaATZX2YYdkp9FW7Jqls1M161XXudU3DNt3/r7Fb/JrbhjjzP7IfI5j1d6PexdtBrp0TD1SaTrNRMpMeCTuBg0yevOaUyXl5MtURT4n46JA/KIocy3U3vW0woxv2c7cz+H9COMKylSGGtyyPoQTZoig4wK67pVcrrwvpxZvo9dG11u7N6OMzsPS6IGwjcnqDGZX+W1/hdrGbrr63jz8o6ea6D8P8Dm9j35/5yS/38hSHx/Gf3vmf5WQwBy/D9L1VIl7f9ZqpL/fyFIbqN/1WDnvcb2wO7+lv/t1TWYdItoKhEBWdcebB/HESgEMdKu6/NycKWrRyIIKwrVhuQeh8l0KDVlUa+zEEeH7MH0vjC0rR4eJbKnmJOgpqzt9bA4WJVjNlegiVwta8qwnnyF69lT01sKezlQCE9M6yHKrcRYgkLawfensBLhCxeZUEDG1B9gJcISXlMm/kQVWAmGX1thav0n07PNmWiAMETXlMF/ldbkE1/ZVpGJoMbO6vBTgWovlmuZlU6ws+Vi7mtGvpVGdKseJtzlU0x1EZZT3VLPTKHM/tAmth882Ra8RrgN8U6RTMKfcuqpyKX6KkxYc+ouGCb3yciLE2+X9io6V4A/iT4p/DZVcZg9MDvPTiPJPHFK9cvWEIY/PNkMxUycJtZr6iqkFowQ3Ve99k7kKIKAm3tnwfss7BXVn+jXhZmmhfOGZ3H5unU9Z+oGbxlvuLe8S/U7JJTELwL3v0H+pY/RCDyAvqPxv3xcovG/CCS+P9iqdR+iuZ3Zj7xbPlvBNt6RF/9xshL/UT2uUPxHIbgdzuzgTru0uAK30WXUkP61U8zX43hMMgTbF/lnmGCMA+3SGc9Bm+LUwZia6GS63K8caOewWBo4xmfPdH+DTfsUU2m/8IHPX/+4+cgV+/rH2u17cQrBHVZkPZwvDWWikEVeulv/NUjIvzxUgP8LWWG29o5c+a+k83+dHZ+S/BeCDPmXk1tIsQMGHdPTuqYXXD8aGcMDGFPApdhnz+CVnVECLSfCSVQpEJwIi3M6QmXChbov2O5Oay2sMdZqHM197+jenknO1HoWOjAb4KVk2pO5Z2mZ2mBHA9l/EAn5d53JFzvQJ4vfg20qgXz5T5//xsd/yv9XCDLkv4tcwNqfbgLWRAfpnPF4o3pohul80VSTVShH9oEddc6a9ngJ3GlikwZL1zJ8e+pOSAX8EyTkHw6B3Prony//5Wp6/VeplEok/0UgQ/47nAvARch+hEASmPmLpGu7lnPgPpLlgrGy/n8B+a+erOR/qND4XwzWrf9lsCO7iPYB9jFKUIrhpuV/znRh8+I/U3Ns0DwxnRKfE2ToF4yIDO93HT/+LB0MieuMzLZkrEHkrb41NspaK4qfNNYGZsYL/TT4MBr2W6PudW/QbBulxMObweim2xx1283B1XWvYzyL71JfjO+3sg+SkP85HMNiW9tWAbnz/1Ja/s/KZRr/C0GG/EsuwMTaUzjKCWIMRayHZy4Pdj0NUK/XdYy/0+GlNC3YFRLyP57YXCf7ge5zfb89NZAn/6cr579XKf9fQciQ/wvJBQzYAQ9TYXAJZ3ntP0901+Qcw57REu7tTBvgoCwzRIQv1fWAD/HCbq/r2ASmeJYhz/5AW4QEAoFAIBAIBAKBQCAQCAQCgUAgEAiE/zP+BKK/9xIAoAAA"
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
