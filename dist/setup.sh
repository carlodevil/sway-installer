#!/usr/bin/env bash
set -euo pipefail

# ── bootstrap helpers ─────────────────────────────────────────────────────────
log()  { echo -e "\033[1;36m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*"; }
err()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; }
require_root() { if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Run as root: sudo $0 [--backup|--overwrite|--skip]"; exit 1; fi; }

PROMPT_MODE=${PROMPT_MODE:-ask}
while [[ ${1:-} ]]; do
  case "$1" in
    -y|--overwrite) PROMPT_MODE=overwrite ;;
    --backup)       PROMPT_MODE=backup ;;
    --skip)         PROMPT_MODE=skip ;;
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

# ── install packages ──────────────────────────────────────────────────────────
apt-get update
log "Installing base packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  sway swaybg swayidle swaylock waybar rofi xwayland \
  foot kitty mako-notifier libnotify-bin \
  wl-clipboard cliphist grim slurp swappy wf-recorder \
  brightnessctl playerctl upower xdg-user-dirs \
  network-manager bluez bluetooth blueman \
  pipewire pipewire-audio pipewire-pulse wireplumber libspa-0.2-bluetooth \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  thunar thunar-archive-plugin file-roller udisks2 udiskie gvfs \
  lxqt-policykit \
  fonts-jetbrains-mono fonts-firacode fonts-noto fonts-noto-color-emoji papirus-icon-theme \
  curl git jq unzip ca-certificates gpg dirmngr apt-transport-https \
  pavucontrol imv || true

log "Installing Chromium"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium || true

# VS Code repo (idempotent)
KEYRING="/usr/share/keyrings/packages.microsoft.gpg"
LIST="/etc/apt/sources.list.d/vscode.list"
rm -f /etc/apt/trusted.gpg.d/microsoft.gpg /usr/share/keyrings/microsoft.gpg
sed -i '/packages\.microsoft\.com\/repos\/code/d' /etc/apt/sources.list 2>/dev/null || true
rm -f "$LIST"
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$KEYRING"
echo "deb [arch=amd64,arm64,armhf signed-by=$KEYRING] https://packages.microsoft.com/repos/code stable main" > "$LIST"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends code || true

# Enable system daemons (optional but helpful)
systemctl enable --now NetworkManager || true
systemctl enable --now bluetooth || true

# ── unpack embedded payload (configs + systemd user units) ───────────────────
log "Unpacking embedded payload"
PAYLOAD_B64="H4sIAAAAAAAAA+w823IbyXX7KnxFF7gsUhIGxOBGElwqonix5NUtopT1llZFN2Z6gBYHM+PpGZBYLl2yvZVkXZV1Unb84FSl8hI7qeQheczv7AdYv+BzunuAGcwAhGSJu+twSiIw3eecPt3n9Ln0BZbvObwn1j54j08NnvVWCz/N9ZaZ/kyeD8xWrd1cb9Vr9foHNbNumusfkNb7ZCp5YhHRkJAPwtjzWDgb7qL67+ljafkf8ygavScteHP5N+rtxpX8L+PJyl/+rWLZu2wDBdxuNmfKv2W2p+TfaoBKkNq7ZGLW8/9c/o7vRUcOHXB3RH7Iojsh5Z544Hs+echCmxxAdUnCCP45I2a9Wit1qXXcC/3Ys8lSfb/RbNYAImRJ0X5rf/OgVrJ81w9rZKlxp1lv1dWrSZbuHLTN9o56rZOlncad/Y1d9doA3Du7dzbuqNcmWdowd8xdU722ALe5sb+zp17bULuxW9vTDa1n290gS83dVjtpaDPbrlnLNmya2ZbNerZps5Ft20TWDgAhgQfe9nf3Dw6a37Y03/xJ5v8JHXVp+H4cwFvY/2ateWX/L+OZkr+IRi6rWkK8yzbm23+zXm83p+2/9P9X9v/9PzfIWYnAs3aD/NiPHANtvUFPmPAH7MeECxKyn8Q8ZDaJfNJlBLxDRF0X3sHmEw7qI8iNNUlCoipX0iErhwfkceiTp+w0WqkQQT1hCBZyp0I8P/JlOyL93bBeHmfe2cB/ybMlp1FItyZtoUvqELMRnKYKTxjv9aMO6fqurYq7fmiz0AipzWMB8DWEvwakPMEj7nsdUqvWBWFUMIN7BvVsw4+jrdJ5qXTCPds/WVKTQ4/UxP0Z0vp3iCQV0JB5kWpRly858lFlk/aMIPQDFkYwStO0cqB2HFLFY7Ul8ixV+9y2mac58wNqcSQL/ZGw3TiKfG8i4WeCwWicGqJPgYaUJaM28R09RkT4JOozEsFIg+y9lQjqHMGiRMQT5A5iQ0WNGDD++SGA1naGPreJ7B2oi2pBEHwLYbCtPtHseXTAJg0gVAek7rFC6dVkx4B6P4oC0Vlb6/GoH3chZh2s7bjslI7E2ifKlp3wY752sPPXS9Al48QPj4FBixmqVWH06ZAZ1BDIeo8ZfX8IzTDHYZbsrgLryOKc5LH3fdDmaGv+sIw1QPE88mNiUY8gBCXS1hIYANUGzifqjcjAt2Mod/kxCKLP5fRaCmJXMBrb3J/BUaKLS+BpmxubssWlcacFyajCxbqfH/lWMssCatvc6wEmGZe9xZwo5G/mcIe9Ll2tVYj+V61fn0Gh6vhWLEDfZg4QuJn6+t4bCK6gkTjsQcdmt8G6TbvZnYVNrYgPGTlD5NK1OTJczEgtgcawd9lfy/Wt40ppqUujiIUj+GYFMfwdgEmWrzYXWB+xAdgxGsUhk9DWsYu2F757LMJuV9KKCy8n4EgCNx50WYhEwfX6A2PAbE6RWkiRNnYGPrjtsiOYZLzLIx+hhQUtWX3QPqTqn4Bmgh11uMuEYVPgzEPkIBF8SksnDqLILg9o2OPeWJulxKSJrWREdzYF3NTAMKvvOSQFCBMWTajLnGjgi0hP5wrxBzySpZoITuuqqhSGLL9FTrjdY1HH4aGIDKvPXRsKZ3EhkVIGsZCNEAWS50MWFzGiKsacuHQRRkLlcWsp7VnMPmkFmw2cFtSYgHwyBKpWX3LSq5BxEehZrze2A0UE5zN3+5iNnBBcE0xbl3tJjyAKUl8W4LiIayw71xJ7JoBlcAMsEKvX094Y2mMQb1ABXiLiA4RyYs9CO4AMuBxlCHOSxIL2pO+cjAQ4JW5RtwNx0+p4XK5fLI9Zo0Q9PpAhiIF+uqMGY7pKMWkkTHZ0p0w001lIHjEV0QADsRehGXK4B6XTgDbYCk2MuoDk0QIYHR0RiOrE1jWpEoWmIWsUEoU1xzO+EKkKxg2c8oB61hzzOm/8ZpPuUhfJznFTb0dXlQq6UIgwg7RLu8ztSD86h0ZqFqImvlFjaWTlVBazF+h3FrUs2hktBq791RsBV4EbSH880NJF5ChlNnaGf4bcxzSqg3ihlmeNfMobvxMii/IjVSbl+9+s8TptWc2W9t3gfMBTRX3M6mrJZE7TruoXEfgRdxZUsyICQ9daDDkVFM3xa7XNRr2bQxhb78UiS4yYFmQKIW+RakCFkKGnRDJ60bGBKbxOezrE5oMsgseYLQz0LZ40tLMQ+zDX5Hyb6VrTjGeDu9ldqNuNZqNdhKNiaDpX35jl1BxzSntSFCfBYlHU3LaszRmqp5EXNABOq2E1rAkWqFMQzEPYrHXNrjlBCOj8hKZl0sY6VfDgVXoxxgT5FAqmbRfULtul9WZto92cndhNRcfTk66dzDkIlro+DW1Ip0EoRa1vrjOT2sWGZKr12p/Z+i0iXVg+E2jNR6hi5Fow0rPTz0lS8lZIVZj6EU7hgiQwk0BLwx+CwlujXK8ytRhfDWZ0PDXyJ30ZcU0jVoE1xjzIEOcZL8tprdcKmq1KrwTZ6WxU06K1OaiQ0c6LONqbdhNxv+0107+kZ2r9X71WXwrfs95ZGxfs/7bWm7n1//W6ebX+fxnP2hoxbhi4OgC5nRQ7vpf0kvEaKbt0xMJyh5TBbZUrWKSWVwmNIBcNiKyX0OXAV2tVCN31IwibMghJNVkFvC8UwBe4iPGFzMeuKyJ9uX4PJBr1NLIqRlTchQghaRjqPQgaQ5mq1iSkfwAKZn2jlqYhyxWIXrnQXHbIemXcYVzhALMJhU2J/AMaCGgzOgHLqFdRBFltBqfXE5Tdvu8LJtdb1DI6pPD4ooF1i6mlHqD9vHStLGDSrU0WVcqV8apBWUWdazIELcviF5UsHQscgxTM8zHWNEioR3ICUZ5kD+nWdEaTLhonUNlCuciQYRR9ZrqgMC8tk6QP+V53UgsqCRGZdiPr5TNcdTiHBq6NG2Ch4AID0qMpKteyRG6gXBPS56VzPTqKYwlfjviAfe57DFvacUIIvdd+6PcpzHTRjcNeul8ch3tI3XKnXUsVR77vRjwwJhx/1OW9W2ed5U/J8p3zj9bw7TPvoyi69ZEYUNe9dQbxPfNsGkKlKvloDWrTbSliBnXVEAAtY3lgLNtyHNKD01m+21l+cK40JOngRHTpoS3bbMgt2VNqBfxoyG3mm/lWJV0YY9Sv82VyhmH+eQFzcusPlav8x6//AeZ5+Y+/+rX6+Cf18Sv18bX60CC/VB9/Lz++/pfyiynOlX5l+JYhWl5NcKr2fN+Gis1WJVNVPqGhp6ZwozZVlWRYaB5a46rz4mGwqNpRmzcOTuy6CwMn63HTCK//7vcF0HoJczHgRFlQpc/zHOBwaUg9amVlnHc8oqJQVQtG0nUhnbNZyoQVUUn6PVc1Xn/1JUr69Ve/UB8/Vx8/Ux+vpsRfbDomgk+LJtu/gmn4GIkRTQxo6G/nn3l7EHjiHuOZLb/kqZQx+o5ZpVTcrcyccmisBv71L/6QMYOTtcOC2mT5T1Z99XXefsoVPFn7s/8u68rzzGAlNjvND4pH2imHqmZP3KB+Q8l59VGAzpe618lTH4VtKQlDbqn8FRdkjJsT6Ql3uBx3JgS3z0EH/6tA8AwIhsCYkhDmH+H52pnF4YO8/tfflufazTPuSFtPhrgk1DuR2NNouiFcg9YTI8FafeiTe4+vz0BIp+qItpdO3b/53b/NmVC6ARjnbI+yRjflWKclAkmV77oGLomj1ZHSWK7IjWAIZShxXJ9GhfZn6LsxND3HoHTdmMFQynAnB//6l78hZwrwSPgxSHwuCUOu30ml+91/vhGJLOKF4Komy/HrL/9nJmSK/pf/O8feZB0ERJLUDvrau79+9e/lKVcAft4WhgMZrwT47T/mAICAUNpcUDsh/fN/ztX5YUS77qxqi6q5/bf/N10zMShgPF/9XtrJV39QH/+hzWVK7SQO7qW4XMY05YAOYxiNCDRO6+cF+XKS/6F1fF+XAN7i/F+t1b46/3cZT0b+OvsPqeDvso2Lzn/XzVbu/F/tKv+/lEeJPNlHPStBwMfBjtjQ3Qr8L2+VRN8/USZWhUVbJXCmAaT9BgJh4hQEAuDwzUiqlGWe5G+4bHcbooMBI+WfrlVVq0rpPMiZpcqVrxb2Lv/JzP+xKN5tGxfe/2isT83/5nqtdTX/L+PB87+ZfRp1o2MrVYiRcCe5yLGVuuvRSa49gJFgroylcTtqf8Pc2d0qqVNuneSexlZJHZrrJHcxoAl92FPf1QAqaumtQ9pb8tIJ2I8Zd1KIWZc2RR3VImeZjZfbk5et8YnSenCavCRbCrfV6xYESQNoouufAqHxrolZwwruBXEkD/8SeQ4qZGDynkMyCTlzhUB/wtELhHO5iIacISt4ekdo/G9bvBc+yfyXq3LvqY23iP/MWv0q/ruMJyN/9fLO27jg/keruW5O2/8Gyv/K/r//Z4l885tX36N/pSVyCKpKlKqSVctl1GP2dfLNq1+Tu6MgdPFotDpa32V9OuR+WPredRI4fuDbBLpCpAMq4VHtDyE2x+Kmckokubpzetw9gpgbN89jMS7x5XKfwMOT4CQ7ML+DI/h+BC8SJqIBuC9cpLDlu4cnkKh7pFarxlXnpRIQxubY3mPDJNSmAfr1IzHyLLwdkq2WR9HrrXbt1IQo4jb8uft5CbtzJ+Wfhe9ymzwE51shJzzqEz7AIysOdV303IQ7JAiZAOdaYqfMArZB4oIYhufjgY0wigMDCIg+MVyLrAD4c2I4pPzh3UcP9sfJhdpnAprVl0GvTMBLQ/7hEaRIsK7bI8aAOLjcbfD5yFuEuYJNo8puHMlYghgWKevQCaAdvoJ9/oSOUBvXxEhEbGDDmA7JKm5ZyuUhV6ztY9AUQt5FIYW6PrezdjcWRhzYNGKGPvuEJ2CBJAcCA7yNYBhJQ3v3Dh/f3/mUfLLz6f2dh3tHyfshFBw+2v2Y/GjvB0e7z5482X/49Ghv//Djp48eb2PH5o+3pG5FMF5GLFgIYsOOZHh4m5ZxqCCHBHkCNSuOhNL2iIUDvNPla+2XmwIgw9ijoZ4PzIsJwcyFGJilEkxBkdpdH/LMEAuSQ8TkmI1ERV2qGfKBwpen7vvqO0SRHnmpvscBOVbf1HF4F2kahkE+ZqMuBJwQHuLoGFB6n8ae1WehKGGFGA3kLL35hMFk0romO5KtZmrlTlXLfmXr7XQ99jJb/RNVfQyqm6047HMnuplSVI+CpkZE74eh0q7sn/JImtC/WiFGl6x8ysQKWUHggegBJo+k7h7qk0B+NOHtcchBxCneeiEfEKMHk2dVuHEYXC8Tg3yBLQfBCKekMcZVrCkKE9yfrj3mFp58hABk3KDx4SqqObm5fGAs311+sHx4vRp4vVJp0i88DEiME/JZavUUN77QBjZqNdUfeQ8BmbCIijRWCuHbCTz2v6yt2Q0i92HQwJVXCPAXg0bNhvLKWdpdhlmSIVzGglnMSLO4F4KE5AYAykdlM4J0R6Tvu6hnROqltPzoDNT9ER/3bPRdIqDxhMm7+bi6osypvt2RAiM3JQ2E3mMi4JHa+8G1mQp4COGrqyPyPIUHZmWaI0Tc7eM9OagOB9TFawjcG4LiM/yKLeV4k9RCZA4pIfuSMSCVg7JhGHBftFpKWj7ChSiHw+DKzqtWS7K3AGFL9rNrVziPiqaDBTwgSkl51aFkRnmi0pIqYngzD2/g4ZF3VZelpEyFqsevU7VSSKoWv07VgjlRdXEwVaMEpSqTsXkUytGUAM/j4AskmDol8yJL4v48vvbmsfVsFldPckwlg4Rjnlyv04m31DcsF1KVQKQQIdhqthcJ40OtJUNWwK8GkaMpQfJcaxAYUgkwzbuuTibAkI2HdY+Dsulwg4boG9AjFGHfv5DDvQsZfDaXvyc59jBYGJ9lQbVEI4KRLo+sPk6w8UkXdToyTdOcVBJPneY381D1PFQ9D9XIQzXyUM08VDMP1cpDtfJQ7TxUOw+1nodaz0Nt5KE28lCbeajNPFStYFRrWixyMiQTAXfbKIfU8AIxKdGbSuzFSHPEp7Dri2AXiFVhNxbBLhC3wm4ugl2gBgq7tQh2gXoo7PYi2AVqo7DXF8EuUCeFvbEIdoGaKezNRbAL1E9h1xbSlkQtH/oR66TvgOIJA7zlLq+Vy1v2eAH9hHqR/FkF8jIWkaYCHl4R+YSpYvRBpmHW8BIi2ne9MV2Vtuq+yjZFFDvOxFp9qm+3l0Xg8qisXHQc4gl24ndf4r1630l7WjTGGld2ukt85e5vDisyLICEgH+OnXdl+ADhhrodIxsQGhUijIDJtWZ3VM2PZFdB9/M1Q1UzLE1Z2xTbk5FPDoBCUOIwWecmgzBKznhmqIsJAOS0EHTkQU4SkIh2u5BrJ+aFHrMMF2q08MCVCpLzlJx0rSbz1O/13CJCSVci7iaB2Tjew/x9ljYqrRuDRpL+ZPBoME0ff0lCtxEyKhuSIURCAUsLBk41I0khO0fZhibGF2cD0lOXJCayypOkGkFBShU+HF/CSLtbCoG3vHVbnlzSKFfwugQoBseKLsTroMVJeI5aOo6Rs9NAMM8eR/R4MIrJEehBXilDdbnU4UKiE1YzfUsJzB1Nx1u6yxPuZglrwD05fsMMcNJRTJZlAoA/9JG6xKJbwamXnABMGMhBJf295yS9g/+DGE91uSwPDtm3PGNm+YMBjoM1slQ+D+F2T866QcHsVd1IEcM8XwrwSZJYjOUuAye5AFWWWQcr6wWyJZWbyJONoh/iZW6dPmjE1MnwJZ09SeBeqMdpBiiEoXOIqjPpGlQGtTOJpkDH3Zc8q44kDci25Q/YZEElcQ0qyevT8nlI4DhLciakGoY00VTrulMzguo0nfsL92Jv0U48W7QPTxbogl6pgXmlPVzeBGoQpVnJAa0MxL6waMCmIc6zsX9IMroplfgZ2seIZ2J+cGYcfByOJLJFbemP1UE5eTbyMR413MGjhhkmDENfX/vRwUZbVj+II70WBCY1cvFnZwwBAybP05HPbu/tH+w8u//06PDew49vJ/Z8Psn7uN7xN4qXIsqazWnaRmv5AsJPKBfszQnfvJDwA24VjsPkZGGa6KNnT3b3b0/7timR6AN2RN1eRpEE8hYM0L6AmccApzlJMOQ3Q97xvAgZYd4eO2TDHDKUcT8WF6A+RC8xhYqe4wK0Q7weNIWGl19nDavW9K60PB4TQg7t5HXu8D7wvTtjSGlKZMsZbPm7S61lY0Eqz4LZNG7+pZxVSvZ/B/TY/w7t/9eaV+c/L+XJyP9b2f+Hl/b07/82682r85+X8kxftN5OftIXfwMwKVKnvErp01Pb+pxXUogxzXa9pE9PbW+U1A1L+KLjIUPvt2y3cLpfPd+RJ5n/uM/6XbL/7Sv7fylPRv74p8q9d3z8d4Hzv/Vp+99qtK/s/2U8z/Hk64sSnlHYlmct8Nzt9oxTtx1p5c166bn0AeJF6pTwdp1N/RT8NmuxTadWgvfYpWFtu9GVPwWv383trtM22zR5r2/TRpdtWMl7Y5v9qb2z6XETBsLwnV/Bre3BXZIA4cJh+3Go1Krb7lattIoq45itVZKl4Gg3/74eG5BIkVKlLN1W73PKKMQjwbyODTNDJrIka+0wTWZ8JmatHaVZmEi+bu04TRIRrDt/y9a/W78HaSii2LhzZufdmZ1zZ3a+ndm5dmbn2ZnGcW6Obg82foXM83+kF3yTMvSVEnoe0fxPJUGY/yegd/2bptLmI7UKGM3H0fqv8DD/Nw5irP8n4frTVumV90rWolI2ZTRtuqVQ3wV6msMr74JX+n1uMwRZTRXgt9vn5qzdSO153vWlC5eV9/peikvKF0zPdnV1lqltE1HeR2nzCFNKLeKq2FWSfvjG9ZJfeZ/5Vsv1i/2Qh799gv5zevqnmwCjq/839D9fHNZ/RnO8/2ESBvT/zkQB5QeoXAmXWuc6cfzBNECBBcU/Rnr6L2+L70qz4v6HHnMaOKb/RXBY/7kM4iX0PwUD+r+wUeC//fJB++dUsumd52Z/mN5UvPxG+TeH4j99XqBIYybqlNhT4HHr7WpfyrRWm7LAKuHB6elfFMpc4VqzWptd/GhTwFH9h7/oP4pC6H8KBvT/sokCn8LBtsn1yaQu7U/vClZyEzH+HSXkyOrZCeIn4be1W914jGkje/fmIcbs6H4bjr4NxyfYRTwAPf3vqMG+Gk/4DUfX/9Hh/d94vsD6fxIG9N9EgW2suqGXdMjKCN8WelR8f4ri27/7dmTG6o35gtF4kDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAnMRPsnLZTgCgAAA="
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

log "Installing systemd user units"
copy_tree "$TMPD/payload/systemd_user" "$HOME_DIR/.config/systemd/user"

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

install_user_file_with_prompt "chromium flags" "$HOME_DIR/.config/chromium-flags.conf" "$(cat <<'CHR'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHR
)"

if ! as_user "systemctl --user is-active --quiet default.target"; then
  loginctl enable-linger "$TARGET_USER" || true
  systemctl start "user@$(id -u "$TARGET_USER")" || true
fi
UID_T=$(id -u "$TARGET_USER")
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$UID_T systemctl --user daemon-reload || true
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$UID_T systemctl --user \
  enable --now waybar.service mako.service cliphist-store.service polkit-lxqt.service udiskie.service || true

as_user xdg-user-dirs-update

log "Done. Alt+Enter → Foot, Alt+d → Rofi."
