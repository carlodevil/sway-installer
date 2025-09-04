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
PAYLOAD_B64="H4sIAAAAAAAAA+w8a3MbyXH3VfgVU+ApEiUuiDdJ8E4RX/LJp5MUUbSs0l3owe4AGHGxu97ZJcjjMSXbV07OVTnn4bgqTlUqX2InFX9IPubv3A+w/kK6e2aBXewChGRJl0u4JRHYmX7NTE93T88MbN/ryb5afe8tPlV41lot/KyttWr0Xmu36dM879Va1Va7Ua8321Bfq1cBnLXeplDJE6uIh4y9F8aeJ8LZcI5vH82r/44+thn/IxlFp29JC159/OFL7XL838WTHX/6W8GyN8kDB7jdbM4c/1atPTX+rXqj/R6rvkkhZj3/z8e/53vRYY8PpXvKvi+i7ZBLT33iez67L0KH3YHqEsEo+blgtXqlWupy+6gf+rHnsKX6XqPZrAJEKJKivdbexp1qyfZdP6yypcZ2s96q69caW9q+0661t/RrnS1tNbb31nf0awNwt3e217f1a5Mtrde2ajs1/doC3Ob63taufm1D7fpOddcwWsvyXWdLzZ1WO2G0keVbq2YZ12pZzrV6lnWtkeVdQ9HuAEICD7Lt7ezdudP8tkfz1Z9k/o/4aZeHb8cBvIb9bzTrl/b/XTxT46+iU1dUbKXeJI/59r9Wr7ebOfuP/v/S/r/95wY7KzF4Vm+wH/lRz0Jbb/GRUP5Q/IhJxULx41iGwmGRz7qCgXeIuOvCO9h8JkF9FLuxSiQIVbuSDru2f4c9DH32WJxE11aY4p6ylAhlb4V5fuQTH5X+btnPjzLvYug/l9mSkyjkmxNe6JI6rNYITlKFIyH7g6jDur7r6OKuHzoitELuyFgBfBXhrwApT8lI+l6HVSt1xQRXwpKexT3H8uNos3ReKo2k5/ijJT05TE9N3J9F1r/DiFTAQ+FFmqMpX+rRo8sm/Kwg9AMRRtBL07RyoE4cci1jpaXyIlUG0nGEZyTzA25LJAvtIdhuHEW+NxnhAyWgN04sNeBAg8ZScIf5PdNHTPksGggWQU/D2HvXIqjrKRElQzxB7iA2VFSZBf2f7wLgtnXsS4dR60BdNAfF8C2EzrYHzIjn8aGYMECoDoy6JwpHr0oNA+qDKApUZ3W1L6NB3IWYdbi65YoTfqpWn2hbNpJHcvXO1p8tQZOskR8egYC2sDRXZQ34sbC4pVD0vrAG/jGwEb2esKm5GqxDxbmRx9YPQJujzfndMtYALfOpHzObewwhOCNby6ADNA+cT9w7ZUPfiaHclUcwEANJ02spiF0leOxIf4ZEiS4ugadtrm8Qx6VxoxXLqMLFup/v+VYyywLuONLrAyYbl73GnCiUb2Z3h/0uv15dYeZfpb48g0Kl59uxAn2b2UHt5lp9bfcVBq6ASRz2oWGzeYhu02l2Z2FzO5LHgp0hcunKnDFczEgtgcaIN9le2wVft1Ja6vIoEuEpfLODGP4OwSTTqyMV1kdiCHaMR3EoCNo+ctH2wndPRNjslbTiwssIHEngxsOuCJEouF5/aA2FIzlSCznSxsbAh3RccQiTTHZl5CO0soGTPQDtQ6r+CDQT7GhPukJZDgfJPEQOkoFPaenEQRTZ5SEP+9IbazONGJnYlczQnU0BNw0wzOq7PZYChAmLJtQVvWjoq8hM5xXmD2VEpYYITuuKrlQWld9iI+n0RdTpyVBFlj2QrgOFs6QgpJRBLBQjxAHJy0HFRYLoirEkLl9EkFB73GpKexazT0bBZgOnB2pMgJ4MgYo9IEn6K2xcBHrW74/tQBHB+cLdPhKnvRBcE0xbV3pJiyAK0l8WkLhIaiw7NyN2oEBkcAMiUNeX094Y+AmIN7gCLxHJIUL1Ys9GO4ACuBLHEOYkixXvk++c9AQ4JWlztwNx0/VxvyxfPB6zeol7ckghiIV+uqM7Y7pKC2klQnZMo2poprOQMhI6ogEBYi9CM9STHpROAzpgKwwx7gKSxwtgTHTEIKpTm1dIJQpNQ9YoJApbG8/4QqQKGDdwykPu2XPM67z+m026y10kO8dNvR5dXar4QiHCDNIu7wq3Q350Do3ULERNfCVmaWTtVBazF+h3FrUsxhktBm781SsBV0AaWP54oKWLjCON2dgZ/hHjPqZRGcYLcZ7V8ylv/EaILCoPqUzK978a8zpv2c2W8d3gfMBTRQNc1VWTyZymXTEvKvAj2VtQzYoIHLv2YsipoGiOX6tuNOrdHMLYei8WWWLEtKBQCHmLVQKuFIWehGT1oyMLl/Bm2dNhjhxmETwhHGWhb/HI0M5CHMBco/k207WmBc8Gd7ObUHcazUa7CEfH0Hyuvgm7V+3VprQnRXESLBZFzW3b3pihegZ5QQPQazXshj3BAnUKgnkIG9VurVubIAR8/oKmVeONNa7hwav0Y4wJ8ksomLZdULtsk9aa1fV2c/bCbio6np507WTOQbDU9XnowHIaBqWI+8aaqHGn2JBMca/+kdxvMXJh+ZVAaz5CBSPXgp6evfycLEpeC6kCUz/CKVywCMwsoMnwh6Dw9mmuVZlajK+GMxqe6vnRgCKuacQKiCaEByvEecbL7rXWqgVsK+SVYHU6G7Vm8+ocVFjRzos42htOE3G/7Zzp/6VnKv+vXyvPle/Zb4zHBfu/rbVmLv/fbq1d5v/fxbO6yqwbFmYHYG1Hw47vJZMyXmVll5+KsNxhZXBb5RUs0ulVxiNYiwaM6gm6HPg6V4XQXT+CsCmDkFSz64D3hQb4ApMYX9B6bFkTGVD+Hkg06mlkXYyouAsRwqLh2OxB8BjKdLUhQf4BKNTq69U0DSrXICZzYaTssLWVcYMxwwFmEwqbhPw9HijgGY3AMposimLXm8HJcoKyM/B9JSjfotPosITHFwNsOKZSPUD7WelKWcGkW50kVcor46xBWUedqxSClqn4s5UsHRscAw3MszHWNEhoenICUZ6sHtLczIomXTReQGULKcmQERR9ZrqgcF1aZkkb8q3upBIqCRFadqPo5TPMOpwDgytjBiJUUmFAejhF5UqWyA0c14T0eenc9I6WmODLkRyKz31PIKetXgih9+r3/QEHS6C6cdhPt0tidx9zt9xpV1PFke+7kQysicQfdGX/1lnn6lN2dfv8g1V8+9T7IIpufaCG3HVvnUF8LzyHh1CpSz5Yhdo0L03M4q7uAqBlXR1aVx3qh3TndK5+1Ln6ybnWkKSBk6FLd23ZEcfSppZyO5CHx9IRfi3PlehCH6N+nV9lZxjmnxcIR1t/qFzlP3z91zDPy3/45d/rj7/VH7/UH1/rDwPyC/3xV/Tx9T+VP5uSXOtXRm4K0fJqglO17/sOVGy0VjJV5REPPT2FG9WpqmSFheahNa46L+4Gm+sdtXn90Itdd2HgJB83jfDyL39bAG1SmIsBJ8qCKn2elwC7y0CaXitr47zlMR2F6lowkq4LyzlHpExYEZWk3XNV4+VXX+JIv/zqZ/rjp/rjJ/rjxdTwF5uOycCnhybbvoJp+BCJMUMMaJhv5596uxB44h7jmUNf8lTKGH3HYqVU3KzMnOrxWHf8y5/9LmMGJ7nDgtok/UdVX32dt5+UwaPan/y+bCrPM52V2Oy0PDg8ZKd6XLMduUH9hh7n6w8CdL7cXWaPfRxsW48wrC21v5KKjXFzQzqSPUn9LpSSzjno4H8UDLwAgiEIpkcI1x/h+eqZLeGDvfznX5fn2s0z2SNbz44xJdQfEfY0mmGEOWgzMRKs6/d9dvfh8gyE9FId0XbTS/dvfvMvcyaUYQD9nG1R1uimHOv0iMCiynddC1PiaHVoNK6u0EYwhDKc9VyfR4X259h3Y2A9x6B03VhAV1K4k4N/+YtfsTMNeKj8GEZ8LgmL8nekdL/591cikUW8EFzXZCV++eV/zoRM0f/yv+bYm6yDgEiSO8HAePeXL/61POUKwM87yurBipcAfv03OQAgoLQ2F9ROSP/0H3J1fhjxrjur2uZ6bv/8v6drJgYFjOeL35KdfPE7/fFvxlym1I5wcC/FlRTTlAN+HENvRKBxRj8vWC8n6z+0jm/rEsBrnP+r1pqX5//exZMZf7P6D7mSb5LHRee/67XW9Pq/1rhc/7+TRw95so96VoKAT4IdcaA7VuB/ebOkBv5Im1gdFm2WwJkGsOy3EAgXTkGgAA7frKRKW+bJ+g3TdrchOhgKVv6L1YrmqpXOgzUzqVz5MrH37p/M/B8PxZvlceH9D5js2fnfbDcbl/P/XTx4/jezT6NvdGymCjES7iQXOTZTdz06ybUHMBLCpVgat6P21mtbO5slfcqtk9zT2CzpQ3Od5C4GsDCHPc1dDaCiU28d1t6kSydgP2bcSWG1OtkUfVSLnWU2Xm5PXjbHJ0rrwUnykmwp3NavmxAkDYFF1z8BQuNdk1oVK6QXxBEd/mV0DioUYPKewWIS1swrDNoTnn6GcK5U0bEUKAqe3lEG/9se3gufZP5TVu4t8Xid+K9ZvYz/3sWTGX/98sZ5XHD/Y22tMX3/rwmfl/b/XTxL7JtfvfgO/SstsX1QVaZVleFCG/eBwB7j6fqQfXQahC4s7PGMfRyUvnPNA4k/8R2GLSDXox0QS67pnBx1DyG+xo3yWI1LfErtKTwoCQ6xA3M5OITvh/BCMBEPwFVhQsKhdw9PG3H3UGemxlW4K8924lD5IaPrntd5AJ7uBI9bCupZAD1e3gQ+yqdLDNLDEhn63hBcYcWBOIBHDP9U2YlNlA511G8SG6zeRCbbKW+tfFc67D644hU2ktGAAbu+YD3uuujHmeyxIBQK6JfEibChYTD+ilmW5+PxjRCG2QICasAs12bXAPwZs3qs/P5HDz7ZGy819K4T0Kw8D/plBj4b5ALpgSLDum6fWUPWw+S3JecjbzLhKjGNSs04pMiCWTYrm0AKoHvyGrZ5z1N4JkydqkgMHcy7UnfSHibli1y1uodRFPTm3JY63VhZceDAoFjmGBQehk0NBKAkbHbv7j+8t/WUPdl6em/r/u5h8r4PBfsPdj5mP9z93uHOwaNHe/cfH+7u7X/8+MHDD7FV8zubqNsRdJZFDZFDbEJGhtfhjP1E+62r4/tCeR2EKFKA9p6d0yzRcHQ9ebnUR1yJhpw19AvMFHhZKxn9OzQXnQJ5IlxWQ36WZbGPxWkXIkmI+4DhkNP5LLIpyHAZQQAQ17kl1Pr3gSToiu9H+pW2K0CfYo+HugQ6IGa4pGIWLp8Zro1LJWShTodQ7Ts3f6wViGhla2x2BGqYLRtO1M3joG8RM3tcqHrX9k5kRGbxT68xq8uuPRXqGruGwEPVB0wZXcuSM9qrJc9WHet8NJKO/H7fFdnq0GBiC6FPaEACJWLHX9XgsP4HYRzf++bFP0bIW5GZQOk2GR5rFyrqZGnSIQI0aZoCIxJZkOe6MBEJvYA5quRHMGQkBp2S64dy2MVrC5tsJEAEmM+4w4HFN5Ubh8FNtI7B6XKW/pFuFoIxqw/z/zoBL5eZxb5gGgWtikUGmk6trjKdvIYvQ2mjxtJ+O8T+INBDGYgnEqb7KIBZMmH2wzvr7S3cJXjEpRI/0ASINQGiUbUMWQv0k93e3buzdXDv8eHWwe7dB4f7d+9/fJu1rt7ME7yH+0ZzCcIzg5yVJ/cJzJskwzxFbjiuKiQ3pTUTitIeE12Y4oODRzt7hTRhPbg97vCDICE6GQSyToLc1HSHZXB3/ZE3F7egd+7jBUmNFNABGETwoDAP+hBPb06DUo6MznUWIEBdjvZchFAc5xGgUPoQIxgLtxVHPhlwM1kQ3PLxZsM3P/87HVKlDH5i8rYhNP4TvIIre9LmOsi4Tt4fN+kSH5P4AE+HYMkV4XB5rg/RJ87mggz5kV8ylhcvvpgGDPH4pDbNHfaDfbaDV8bYvj7iPZegDZDzHZsmYrk89uyBCJPue6LzDKE+/EM9qFMPWDLpQvDlh7o86UEjHoGMj6uAc5pAsmdgXA6l82EZpSszG6yX+rD854j2fvkzhiedMNyNuES/Bt0woePp0/sNMojmiHuWU4ucJG7W67OdhYxNqye8Da0F2bdXUgxMNIkS3e17PphA4AIjCR4cQ0q8Tg4eIOnEsooDjO6UOMaYIQErL2fkNGJVboA85gj4IZ4HT7ertESh8zE6Lq5DSyhCm0LFQuumvtWi6/VB07QXeJ/u4WkY/FoA4aC10BD4tQAiDkw9LD/ytfqCnQag70bEB+S/NNCzOPgCiacOx32WJ3XvIll3LxL1YJ6kj3KCpjsTTw4kN23NKFHsjuWKD2E6dsGfc8dh+wNZJBwVmw4nFStugwGjXiew4pYYMOh6AipqjwExNx8RKt39uzKKfLP+4GEIzTkSp2oWlXsLSb27kNAHF8r8aFpk1PQn46NvEzXfB/HBMKanaJ5mLT9/a3moeh6qnodqFJmiHFQzD9XMQ7XyUK08VLvA+uSh1vJQa3mo9TzUeh5qIw+1kYeqFvRqNT1hkslSbElnDX1tEfNbMHwau74IdsGwauzGYp5nBnZzEewCNdDYrUWwC9RDY7cXclqzsNcWwS5QJ429vgh2gZpp7I1FsAvUT2NXF9KWRC3v+5HopK+M44Ek/FEM+hUK+lEO/L2KEfci+hUW9jyGpZymoiqGyBOhi9F31axaFe8sow8wy+0K2ap7enWnorjXm1irp+bHMMq0sisTmh2HeOGF+d3n+DMcfi/ttdE4G1xqdJf5oVmzrlAWZeCH8nNsvEtBz7EI9WU6YqAMKgQbgaCtKfe0ku/JroYe5GuOdc1xacrapsSe9HxyXtyRvZ6gOjfphNPkSHiGupoAcPsIgpg8yGi8TObdrigIX0ThOjqxQvxIZITVnZqKoHL0epn4SpN5rEnnCSUtjqRLIRhGnUkiAW8XzFJarZzTOYdxH/Ngmj7+Po3hEQpOjCgaSShgaUH/ajZECsU5zDKa2GicNEhPX72aDGmeJDcIGpI0fX98tSvtlWFhMKC7/OXJ1a/yCl7CAv2RWNHlfVT2ge86dNnfT5YX44n2dPzTMV4ScdFMw/gaSvqwUsVEK+2DghpEIqzkAjYzYO7pdOhmmjyRbtZgDaVH/XecAU4aipkupIML4VR9wgVnaHKuOBEgB5W0924vaR38H8Z4VtQVeXC1ok+u2v5wiP1gn9o6FwcRfp8m57BgkutmpIhhko4G8JFQ8nMcgvG4U3xFv7BSDrESVmhnRkYKXum8tBqE+BMR1MljxNR9kyXzixsE3A9NP80AhSh2DlF908WAUlw8k2gKdNx8klk3JGFAvOlnsbKgRNyAEnlzBycPCRJnSc6E1N2QJprivngsfm/hVuwu2oiDRdvwaIEmPBJRHNJvdST7HjkTaEC0ZiXHPjMQe8rmgZiGOJ/Ox2Z0k5T4AO1jJDNLA/B5Elwh9iSKxR1y2yYziMmch3iAmfJJGSEsy1yKzWYGdbaJJwk8BR2ms3ifjjN4mWzgfJK53OUUZSPmNG2rdfUCwrks62KEb15IOElmThOdnFdOE81mMWcMiTm2y/RvIuCQjLN5FwhDGcPZCcMLkC/IT16AjbnHWanH+aiUQy1Koc5H28dLh1NoeKV+VrcaTU8l57FrM6ne2RwXShQnWeLFqBwEs2ncLGgEOWeM3ThT4y0PbRxxtyLD9SEYrmiyk1Fa4EBlcv4DU63/m87/VC/Pf7+TJzP+38r5H/196vxPbe3y/Pc7eaZ/aOHD5Ce98TdAk6L/ae9sepsGgjB831/hG1y29XcM0h7KxwEJRKFFIEURWjvrYuE4wXbU5t+zsx9WbYJSWtcENM8hzaSuR4rnnazTd3e1y5Pcdk8y4/O0L8Log/nEuCdZQvQMa/nEjFxgjTAhb05ZBHJHjgSrf3AzHFP/97H/T0Lv+sPDSVGNbP+/g//fH/b/cBZi/5+COTjfFwRcSEw5msB3z37jun+uurznk7n6DGgWt2YJMF8MtoJgIhLPcpfIeFvy2mVBqraCMLHH0jz2Ym5jn/EgFUlm44CJNEuT1MYhSzzuZZ6NI5aGieBLG8csSTJ32eWb2fx6pO2yMItimU6HXXYddsl12OXWYZdah11mHcrEuTzaHizzZiLP/5G9IIyH4ys4OI6o/3tRgP1/CnrX3ywqL5/CUiGj5Tg4/zP0Btc/lgdi/5+C+aeqaBfklWiyulA2cmZWS4J1V+D/Lrwm57xu3+fKFkwbWAFiXZ3Id+1KtISQ+YUulwV5fSOyC/BSsdNtU5+mRWUqinwUymPF1hXNeVFuawF/+EYbxRbkM69asXyx25fhb79B/zk9/cOXAKOr/w7694Ph/G/4gfqfgD36fyeroOf5dPRKPA9oA9rIiYo/Pnr636zL70VLy5sf7Zht4JD+A3c4/3vm+hHqfwr26P9cVYHz9suH1jmDKdvkLJf3h+yq5ptvYKgZiv/+fQEqjcqqK7IdFB5X2S53G8GaYrUpcZTw6PT0n5WFvMJNS5tW3sWP1gIO6j/8Rf+R56P+p2CP/l+aKnCgHNQy2Q6EsEvD0+uSbrisGOcarDMwxePPxQ/Ct7M1u/NR2krZ653HKFVnd2w5Oqocn+BdxCPQ0/8WNtgoxhO+4eD4Pxp+/xt7Mxz/T8Ie/ZsqUAsrr2CTHlFL4avZHTXf3Ufx9uPenpnSZiV/QeF8KGEEQRAEQRAEQRAEQRAEQRAEQRAEQRAEQZAH8RNNM15+AKAAAA=="
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
