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
PAYLOAD_B64="H4sIAAAAAAAAA+w825Ibx3V8Jb6iC6ut3SUxWAwue8GKDPdqyeItXDIyS1KtGzM9QHMHM6PpGSyh1bpoW5VEroqclB0/OFWpvMROKnlIHvM7+gDzF3JOdw8wN2BBmqSkZKfIBab7nNOn+5w+l77A8j2H98X6tbf4NODZ7HTw09zsmOnP5Llmdhob7c12q7XZutYwm2arcY103iZTyROLiIaEXAtjz2PhbLjL6n+gj6Xlf8qjaPyWtODV5d9qbrav5P8unqz85d86lr3JNlDAG+32TPl3zI2c/Dst07xGGm+SiVnP/3P5O74XnTh0yN0x+TGL9kLKPXHP93xyn4U2OYLqioQR/AtGzGa9UelR67Qf+rFnk6XmYavdbgBEyJKiw87h9lGjYvmuHzbIUmuv3ew01atJlvaONsyNXfXaJEu7rb3DrX312gLcvf29rT312iZLW+auuW+q1w7gtrcOdw/U6wbUbu03DnRDm9l2t8hSe7+zkTS0nW3XbGQbNs1sy2Yz27TZyrZtImtHgJDAA2+H+4dHR+3vWpqv/iTz/4yOezR8Ow7gNex/2+xc2f938eTkL6Kxy+qWEG+yjfn232w2N9p5+y/9/5X9f/vPDXJeIfCs3yA/9SPHQFtv0DMm/CH7KeGChOzzmIfMJpFPeoyAd4io68I72HzCQX0EubEuSUhU5Uq6ZOX4iDwMffKYPY9WakRQTxiChdypEc+PfNmOSH83rGenmXc29J/xbMnzKKQ707bQJXWJ2QqepwrPGO8Poi7p+a6tint+aLPQCKnNYwHwDYS/DqQ8wSPue13SqDcFYVQwg3sG9WzDj6OdykWlcsY92z9bUpNDj9TU/RnS+neJJBXQkHmRalGXLznyUWXT9owg9AMWRjBKeVoFUDsOqeKx3hFFluoDbtvM05z5AbU4koX+SNheHEW+N5XwE8FgNJ4bYkCBhpQlozbxHT1GRPgkGjASwUiD7L2VCOocwaJExFPkLmJDRYMYMP7FIYDWdkc+t4nsHaiLakEQfAthsK0B0ex5dMimDSBUF6TusVLpNWTHgPogigLRXV/v82gQ9yBmHa7vuuw5HYv1j5UtO+OnfP1o9y+XoEvGmR+eAoMWM1SrwhjQETOoIZD1PjMG/giaYY7DLNldBdaVxQXJY+8HoM3RzvxhmWiA4nnsx8SiHkEISqStJTAAqg2cT9Qbk6Fvx1Du8lMQxIDL6bUUxK5gNLa5P4OjRBeXwNO2t7Zli0uTTguSUYXLdb848p1klgXUtrnXB0wyKXuNOVHK38zhDvs9utqoEf2v3lybQaHu+FYsQN9mDhC4mebmwSsIrqSROOxDx2a3wXptu92bhU2tiI8YOUfkyvU5MlzMSC2BxrA32V/L9a3TWmWpR6OIhWP4ZgUx/B2CSZavNhdYH7Eh2DEaxSGT0Napi7YXvnsswm7X0ooLL2fgSAI3HvZYiETB9fpDY8hsTpFaSJE2dgY+uO2yE5hkvMcjH6GFBS1ZA9A+pOqfgWaCHXW4y4RhU+DMQ+QgEXxKS6cOoswuD2nY595Em6XEpImtZUR3ngNua2CY1R86JAUIExZNqMucaOiLSE/nGvGHPJKlmghO67qqFIYsv03OuN1nUdfhoYgMa8BdGwpncSGRUgaxlI0QBVLkQxaXMaIqJpy4dBFGQuVxGyntWcw+aQWbDZwW1ISAfDIE6tZActKvkUkR6Fm/P7EDZQTnM3fnlI2dEFwTTFuXe0mPIApSXxbguIxrLLvQEnsigGVwAywQq2tpbwztMYg3qAAvEfEhQjmxZ6EdQAZcjjKEOUliQfvSd05HApwSt6jbhbhpdTIua5fLY9YoUY8PZQhioJ/uqsHIVykmjYTJru6UiWY6C8kjpiIaYCD2IjRDDvegNA9og63QxKgLSB4tgdHREYGoTuxclypRahqyRiFRWHMy40uR6mDcwCkPqWfNMa/zxm826R51kewcN/V6dFWpoAuFCDNIu7TH3K70o3NopGYhauIrNZZGVk5lMXuBfmdRy6Kd0WLg2l+9EnAduIH0xwMtXUSOUmYTZ/hnyH1Coz6MF2p51sinvPEbIbIoP1JlUr7/1Rpv0o7V7mjfDc4HPFU0wKyukUzmNO26fhGBH3FnQTUrIzByrcWQU0HRHL/W2G41ewWEifVeLLLEiGlBphDyNqkHVAgZekokox+dGpjC67SnS2w+zCJ4jNnCQN/iSUM7C3EAc03Ot5muNc14Nrib3YWm3Wq3NspwVAxN5+obs5yGY+a0J0VxGiyWRc0blrU9Q/U08oIGwOm0rJY1xQJ1CoJ5CNuNntkzpwgBnZ/QdEza2qQKHrxKP8aYoJhCwbTtgdplu7TZbmxttGcndrnoOD/pNpI5B8FSz6ehDek0CKWs9e1NZlK73JDkWm/8ma3fJtKFFTOBznyEOkauJSM9O/2cJiWvhVSHqR/hFC5JAjMJtDT8ISi8NS70KlOL8dVwRsdTI382kBFXHrEOrDHmQYY4z3hZTmezUdJsXXolyE5no5oWbcxBhYx2XsSxsW23Efe7XjP9v/Tk1v/Va/2Z8D3rjbVxyf5vZ7NdWP/fbDWv1v/fxbO+TowbBq4OQG4nxY7vFb1kvE6qLh2zsNolVXBb1RoWqeVVQiPIRQMi6yV0NfDVWhVC9/wIwqYMQlJNVgHvSwXwJS5ifCnzsTVFZCDX74FEq5lGVsWIirsQISQNI70HQWMoU9WahPQPQMFsbjXSNGS5AtErF5rLLtmsTTqMKxxgNqGwLZF/RAMBbUZnYBn1Koogq+3g+VqCsj/wfcHkeotaRocUHl80sG4xtdQDtD+pXK8KmHTr00WVam2yalBVUee6DEGrsvizWpaOBY5BCuaTCVYeJNQjOYWoTrOHdGs6o0kXTRKobKFcZMgwij4zXVCal1ZJ0odir7upBZWEiEy7kfXqOa46XEAD1ycNsFBwgQHpSY7K9SyRGyjXhPRF5UKPjuJYwlcjPmRf+B7DlnadEELv9R/7AwozXfTisJ/uF8fhHlG32t1opIoj33cjHhhTjt/v8f7t8+7yU7K8d/H+Or596r0fRbffF0PqurfPIb5nnk1DqFQl769DbbotRcygrhoCoGUsD41lW45DenC6yx90l+9dKA1JOjgVXXpoqzYbcUv2lFoBPxlxm/lmsVVJF8YY9etimZxjmH9Rwpzc+kPlqv7pm7+DeV79069/oz7+QX38Wn18oz40yK/Ux9/Kj2/+qfpZjnOlXxm+ZYhWVBOcqn3ft6Fiu1PLVFXPaOipKdxq5KqSDAvNQ2dSdVE+DBZVO2rzxsGJXXdh4GQ9Lo/w8m/+UAKtlzAXA06UBVX6osgBDpeG1KNWVcZ51yMqClW1YCRdF9I5m6VMWBmVpN9zVePl11+hpF9+/Uv18Qv18XP18SIn/nLTMRV8WjTZ/pVMw4dIjGhiQEN/u/jUO4DAE/cYz235pUilitF3zGqV8m5l5pRDYzXwL3/5x4wZnK4dltQmy3+y6utvivZTruDJ2p//Z1VXXmQGK7HZaX5QPNJOOVQ1e+YGzRtKzqsPAnS+1F0jj30UtqUkDLml8ldckAluQaRn3OFy3JkQ3L4AHfyPEsEzIBgCY0pCmH+EF+vnFocP8vKff1edazfPuSNtPRnhklD/TGLn0XRDuAatJ0aCtXrfJx8+XJuBkE7VEe0gnbp/+/t/mTOhdAMwztkeZY1uyrHmJQJJle+6Bi6Jo9WR0liuyY1gCGUocVyfRqX2Z+S7MTQ9x6D03JjBUMpwpwD/8le/JecK8ET4MUh8LglDrt9Jpfv9v78SiSzipeCqJsvxy6/+ayZkiv5X/z3H3mQdBESS1A4G2ru/fPGv1ZwrAD9vC8OBjFcC/O7vCwBAQChtLqmdkv7FPxbq/DCiPXdWtUXV3P7r/8nXTA0KGM8Xf5B28sUf1ce/aXOZUjuJg3spLpcxTTWgoxhGIwKN0/p5Sb6c5H9oHd/WJYDXOP/X2Ni8Ov/3Lp6M/HX2H1LB32Qbl53/bpqdwvk/8yr/fyePEnmyj3pegYCPgx2xobs1+F/dqYiBf6ZMrAqLdirgTANI+w0EwsQpCATA4ZuRVCnLPM3fcNnuDkQHQ0aqP1uvq1aV0nmQM0uVq14t7L37JzP/J6J4s21cev+jtZmb/+1Nc+Nq/r+LB8//ZvZp1I2OnVQhRsLd5CLHTuquRze59gBGgrkylsbtqMMtc3d/p6JOuXWTexo7FXVorpvcxYAm9GFPfVcDqKilty7Z2JGXTsB+zLiTQsymtCnqqBY5z2y83Jm+7ExOlDaD58lLsqVwR73uQJA0hCZ6/nMgNNk1MRtYwb0gjuThXyLPQYUMTN4nkExCzlwj0J9w/BnCuVxEI86QFTy9IzT+dy3eS59k/stVubfUxmvEf6bZuor/3sWTkb96eeNtXHL/A6ry8V+7hfd/ruz/23+WyLe/ffED+ldZIsegqkSpKlm1XEY9Zq+Rb1/8hnwwDkIXj0aro/U9NqAj7oeVH1wngeN7vk2gK0Q6oAoe1X4PYnMsbiunRJKrO89PeycQc+PmeSwmJb5c7hN4eBKcZBfmd3AC30/gRcJENAD3hYsUtnz38AQSdU/UatWk6qKCzOylvKvwXW6T++A6a+SMRwPCh3jgxKGui36XcIcEIRPgGivsObOgUZCXIIbh+XjcIoziwAACYkAM1yIrAP4JMRxSfe+DB/cOJ6mB2iUCmvVnQb9KwMdC9uARpEiwrtcnxpA4uFht8PnIO4S5guVRZTdOZCRADItUdeAD0A5fwT5/TMeoS+tiLCI2tGFERmQVNxzl4o4r1g8x5Akha6KQAK3N7azdi4URBzaNmKFPLuH5VSDJgcAQ7xIYRtLQwYfHD+/uPiUf7z69u3v/4CR5P4aC4wf7H5GfHPzoZP/Jo0eH9x+fHBwef/T4wcNb2LH54y2pWxGMlxELFoLYsCMZHl6nZRwqyABBnkDNiiOhdDVi4RBvZPlad+WSPsgw9miotZl5MSGYdxADc0yCCSRS+8CHLDHEguQIMDllY1FTV2JGfKjw5Zn5gfoOMaBHnqnvcUBO1Td1mN1FmoZhkI/YuAfhIgR3ODoGlN6lsWcNWCgqWCHGQznHbj5iMBW0rsmOZKuZWndT1bJf2Xo7XY+9zFZ/rqpPQXWzFccD7kQ3U4rqUdDUiOjdLFTalcPnPJIG8C9WiNEjK0+ZWCErCDwUfcDkkdTdY32Ox4+mvD0MOYg4xVs/5ENi9GHyrAo3DoO1KjHIl9hyEIxxShoTXMWaojDF/dn6Q27huUUIHyYNGu+topqTm8tHxvIHy/eWj9fqgdevVKb9wqN8xDgjn6bWPnHbCi1Yq9FQ/ZG3CJAJi6g4YaUUfiOBx/5XoURZRrmLgpfXqisE+ItBo2ZDedUs7R7DHMcQLmPBLGZglJeWUKVIolNy3HG+4aF9UBruUfcyvQKUj9CEJZeWVDpTphafK4WZtAHmPiSu1t+8/qVUDxAOQtAjucmAWqSaEKQ3JgPfRc6JnD3Su6DDUXdUfNwX0veVgMYjJu//4wqOMvr6BkkKjNyUNBD6gImAR2p/Cdd/auCFhK+up8gzGx4YvzxHiLg/wLt4UB0OqYtXHbg3gunJ8Cu2VOBNUguROaSE7EvGgFQByoZhwL3XeiVp+QQXuxwOKiA7r1qtyN4ChC3Zz66P4Wwvk44FPCAKIsspikpDVl0fTA1e+kNN9R0lNO1XiMCtNN9be3Uj8BQoootFjUEemWxR2986OfBlmyEDBzgGRA8P6mggtBzkMe71yX1eBnyUMVUH67InrUttilgwNEsyTBnJkVfBQVLEFFV1h0DVZbuprLeqx6+5WqmRqha/5mrBwqu6OMjVKK1UlYkiPAil6kiAT+LgSySYOnb0WZbE3Xl8Hcxj68ksrh4VmEoGCYWXnfpqcmG5kPMG9JdQ21YGuExT3tNTYsRK+NUgcjQlSJFrDQJDKgHyvOvqZLaP2GRYDzjMLB0B0hDdNTrpMuy7l3J4cCmDT+by96jAHsZvk8NBqJZo1zF14JE1wOkwOTqkjpumaZrTSuKp6xFmEapZhGoWoVpFqFYRql2EahehOkWoThFqowi1UYTaLEJtFqG2ilBbRajtItR2EapRMqoNLRY5GZKJgNuXlEOufYmYlOhNJfZypDniU9jNRbBLxKqwW4tgl4hbYbcXwS5RA4XdWQS7RD0U9sYi2CVqo7A3F8EuUSeFvbUIdomaKeztRbBL1E9hNxbSlkQt7/sR66Yv1eKRDfzZAHlPX/5sATpa9LDydyrIs1hEmgqEM4rIx0wVow8yDbOBtzrRvuud/rq0VXdV+i6i2HGm1uqp/rmAqghcHlVVPBKHeCWA+L1n+EMFSVChvAsaY40rO90jvoptbo5qMgaCGIF/gZ13ZawEsZW6biQbEBoVIouAycV7d1wvjmRPQQ+KNSNVM6rkrG2K7enIJydqIQJzmKxzk0EYJ4dmM9TFFIBapxB0FEHOEpCI9np6XSOXuiUAfr8PSYjkN2H3Hj1lGWbVoOJBN5XeFOk56VpN5rEiXSSU9DjibhKsTmJgPH89S2mVck5AFevTMaZBnj7+goduA4JA2ZCMNBIKWFoyvqoZSQrZOck2NLXROGmQnrqcMhVpkSTVCApSavrx5PJL2itDsDyQt52r08sx1RpeUwH94VjRgzAYlD1JWVCZJ3lDdrYIDGqTLAcPpDE5An0WqfRFLlK5kKKG9UzfUgJzx/mwTHd5yt0sYUHaJ8dvlAFOOorLHDIpwh9YSV0e0q3gDE1OXiYMFKCS/n7oJL2D/8MYT9O5rAgOEbw822f5wyGOgzW21EoMROV9OTmHJZNcdSNFDFdopAAfJcnWRO4yvpK/QVGVmRir6oXJJZWvyUxDDEK8RK9TKo2YOpG/pDNKCdwP9TjNAIVodQ5RdRdAg8rYdybRFOik+5Jn1ZGkAdm2/OGgLKgkrkEleX1LoQgJHGdJzoRUw5Ammmpdd2pG7J2mc3fhXhws2okni/bh0QJd0GshMK+0IyyaQA2iNCs5GJeBOBQWDVge4iKbIoQko5tSiZ+gfYx4JjUAn8fBFeJIIlvUlm5bHVCUZ1If4hHPXTzimWHCMPS1wZ8cbW3I6ntxpBN4MKmRiz/3YwgYMHmOkXx65+DwaPfJ3ccnxx/e/+hOYs/nk7yLK1V/pXgpo6zZzNM2OsuXEH5EuWCvTvjmpYTvcat0HKYnOtNEHzx5tH94J+/bciLRBxuJujWOIgnk7SOgfQkzDwFOc5JgyG+GvFt7GTLCvD52yEYFZCjjfiwuQb2PXiKHip7jErRjvJaVQ8NLx7OGVWt6T1oejwkhh3b6Ond47/ne3gRSmhLZcgZb/t5VZ9lYkMqTYDaNmyWdkM4ZYzdKpsvQyjjiMnWm1dwSdqVS4Z7lxmAf7ogxHgl3bB7eSe+G1+31G9/1Ju1bfJL9/yE99b9H5z8anavzv+/kycj/Ozn/gSdA8r//jCfNrs5/vIsnf9H+VvKTzvgbkEmROuVXSZ+eu6XP+SWFGFvdalb06blbWxV1wxa+6LjM0Dt2tzo43a+e78mTzH/cqf8+2f/NK/v/v+2dS4/TMBSF9/4V2QGLME2apAHJi+GxQAIxvARSVSEndQaLtJQk1Uz/Pb52HJFQ1FHphAGdbzHq1bS5UnPPrd0e26PQu//056Fan9j+fQP/dzjs/3E0Q/8fgzk5nxeM3AjcuHXId81/47p+bLp8ELK5+QyoFz+5xHkoB0cBcBnLR8WE6XhbimrCp5k5CqCNA54VSZAIF4dcTDOZ5i6ecpnlWZq5OOJpIII8cHHMsyiVYunihKdpPll2+WYuv51HTHiUx4lOZ8Muuw275DbsctuwS23DLrMNdeJCP9s9WefNZVH8I2cBtKazz2QJu0P9PwwT9P8x6N3/dlNx/ZC2ijhZjoPr/6JgcP+TyQzj/1GYf1irZsGeyTqvlLEM83a3HNp3g35VEhW7EFXzujAeU985hPS7dikbxtj8nS2XBXt+LXPjTuNn27o6y9S6rSj2VhonKifbl1DltpL0whf2LIEF+yjWjVw+2e3L8LffoP+cnv7pS4CTq/8G+g+nw/W/8RTnf4zCHv2/0lVAdgZVqNzaHu1OLH/QBqiwoPi7SE//m2/lV9X45fX35pRt4JD+9Wx/oP9ZoIeE0P8I7NH/hakC7+WnN413Tkt22Xmh54f8shKbL2QXGor/+L5AlebrqlP5jgpPmGzvdxvJa7XalBgl3Do9/eel0ne4bvy60bP4k7WAg/qPftF/nGD95yjs0f/Ttgo8KgezTbJHIe3Sf/+q9DdCV4x3RcYgWT04QvwkfLf6r7ue7zda9vbkKd83V/dcOXqmHO9hFnEL9PS/pQMW1OmE33Jw/B8Pv/9Nwgjj/1HYo/+2CszGuis6pEVWWvhmXUoldsco3n3cuyv7fr3S//DpepAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAR/MDuT/S+wCgAAA="
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
