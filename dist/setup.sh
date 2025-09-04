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
PAYLOAD_B64="H4sIAAAAAAAAA+w8a3MbyXH3VfgVU+ApFCUuiDdJ8E4RX/LJp5MUUbSs0l3owe4AGHGxu97ZJcjjMSXbV07OVTnn4bgqTlUqX2InlXxIPubv3A+w/kK6e2aBXewChGRJl4u1JRHYmX7NTE93T88MbN/ryb5ae+8NPlV41lst/Kytt2r0Xmu36dM879Va1Va7Ua83qlBfq1eb7fdY600KlTyxinjI2Hth7HkinA3n+PbxvPrv6GOb8T+WUXT2hrTg5ce/Ua/V343/23iy409/K1j2OnngALebzZnj36q1p8a/Va+vv8eqr1OIWc8f+fj3fC866vGhdM/Y90W0E3LpqU98z2f3ROiw21BdIhglPxesVq9US11uH/dDP/YctlTfbzSbVYAIRVK039rfvF0t2b7rh1W21Nhp1lt1/VpjSzu327X2tn6ts6Xtxs7+xq5+bQDuzu7Oxo5+bbKljdp2bbemX1uA29zY397Tr22o3dit7hlG61m+G2ypudtqJ4w2s3xr1SzjWi3LuVbPsq41srxrKNptQEjgQbb93f3bt5vf9mi+/JPM/xE/6/LwzTiAV7D/8Lyz/2/jmRp/FZ25omIr9Tp5zLf/tXq93czZf/T/7+z/m3+us/MSg2ftOvuRH/UstPUWHwnlD8WPmFQsFD+OZSgcFvmsKxh4h4i7LryDzWcS1Eex62tEglC1K+mw5YPb7EHos0fiNFpeZYp7ylIilL1V5vmRT3xU+rtlPzvOvIuh/0xmS06jkG9NeKFL6rBaIzhNFY6E7A+iDuv6rqOLu37oiNAKuSNjBfBVhL8CpDwlI+l7HVat1BUTXAlLehb3HMuPo63SRak0kp7jj5b05DA9NXF/Fln/DiNSAQ+FF2mOpnypR48um/CzgtAPRBhBL03TyoE6cci1jJWWyotUGUjHEZ6RzA+4LZEstIdgu3EU+d5khA+VgN44tdSAAw0aS8Ed5vdMHzHls2ggWAQ9DWPvLUdQ11MiSoZ4gtxBbKioMgv6P98FwG37xJcOo9aBumgOiuFbCJ1tD5gRz+NDMWGAUB0YdU8Ujl6VGgbUB1EUqM7aWl9Gg7gLMetwbdsVp/xMrT3Wtmwkj+Xa7e0/W4ImWSM/PAYBbWFprsoa8BNhcUuh6H1hDfwTYCN6PWFTczVYh4pzI4+tH4A2R1vzu2WsAVrmMz9mNvcYQnBGtpZBB2geOJ+4d8aGvhNDuSuPYSAGkqbXUhC7SvDYkf4MiRJdXAJP29zYJI5L40YrllGFy3U/3/OtZJYF3HGk1wdMNi57hTlRKN/M7g77XX6tusrMv0p9ZQaFSs+3YwX6NrOD2s31+vreSwxcAZM47EPDZvMQ3abT7M7C5nYkTwQ7R+TSlTljuJiRWgKNEa+zvbYLvm61tNTlUSTCM/hmBzH8HYJJpldHKqyPxBDsGI/iUBC0feyi7YXvnoiw2atpxYWXETiSwI2HXREiUXC9/tAaCkdypBZypI2NgQ/puOIIJpnsyshHaGUDJ3sA2odU/RFoJtjRnnSFshwOknmIHCQDn9LSiYMosstDHvalN9ZmGjEysauZoTufAm4aYJjVd3osBQgTFk2oK3rR0FeRmc6rzB/KiEoNEZzWFV2pLCq/yUbS6Yuo05Ohiix7IF0HCmdJQUgpg1goRogDkpeDiosE0RVjSVy+iCCh9rjVlPYsZp+Mgs0GTg/UmAA9GQIVe0CS9FfZuAj0rN8f24EigvOFu3UsznohuCaYtq70khZBFKS/LCBxkdRYdmFG7FCByOAGRKCuraS9MfATEG9wBV4ikkOE6sWejXYABXAljiHMSRYr3iffOekJcErS5m4H4qZr435ZuXw8ZvUS9+SQQhAL/XRHd8Z0lRbSSoTsmEbV0ExnIWUkdEQDAsRehGaoJz0onQZ0wFYYYtwFJI8XwJjoiEFUp7aukEoUmoasUUgUtjae8YVIFTBu4JSH3LPnmNd5/TebdJe7SHaOm3o1urpU8YVChBmkXd4Vbof86BwaqVmImvhSzNLI2qksZi/Q7yxqWYwzWgzc+KuXAq6ANLD88UBLFxlHGrOxM/wDxn1MozKMF+I8q+dT3vi1EFlUHlKZlO9/OeZ13rKbLeO7wfmAp4oGuKqrJpM5TbtiXlTgR7K3oJoVEThx7cWQU0HRHL9W3WzUuzmEsfVeLLLEiGlBoRDyJqsEXCkKPQnJ6kfHFi7hzbKnwxw5zCJ4QjjKQt/ikaGdhTiAuUbzbaZrTQueDe5mN6HuNJqNdhGOjqH5XH0Tdq/aq01pT4riJFgsiprbtr05Q/UM8oIGoNdq2A17ggXqFATzEDar3Vq3NkEI+PwFTavGG+tcw4NX6ccYE+SXUDBtu6B22SatN6sb7ebshd1UdDw96drJnINgqevz0IHlNAxKEffNdVHjTrEhmeJe/QO532TkwvIrgdZ8hApGrgU9PXv5OVmUvBJSBaZ+hFO4YBGYWUCT4Q9B4e2zXKsytRhfDWc0PNXzowFFXNOIFRBNCA9WiPOMl91rrVcL2FbIK8HqdDZqzebVOaiwop0XcbQ3nSbifts50/9Pz1T+X79Wninfs18bj0v2f1vrzVz+v92qvsv/v41nbY1Z1y3MDsDajoYd30smZbzGyi4/E2G5w8rgtsqrWKTTq4xHsBYNGNUTdDnwda4Kobt+BGFTBiGpZtcA7wsN8AUmMb6g9diKJjKg/D2QaNTTyLoYUXEXIoRFw4nZg+AxlOlqQ4L8A1Co1TeqaRpUrkFM5sJI2WHrq+MGY4YDzCYUNgn5ezxQwDMagWU0WRTFrjWD05UEZXfg+0pQvkWn0WEJjy8G2HBMpXqA9tPSlbKCSbc2SaqUV8dZg7KOOtcoBC1T8WerWTo2OAYamKdjrGmQ0PTkBKI8WT2kuZkVTbpovIDKFlKSISMo+sx0QeG6tMySNuRb3UklVBIitOxG0cvnmHW4AAZXxgxEqKTCgPRoisqVLJHrOK4J6YvShekdLTHBlyM5FJ/7nkBO270QQu+17/sDDpZAdeOwn26XxO4+4W65066miiPfdyMZWBOJP+jK/s3zztUn7OrOxQdr+Pap90EU3fxADbnr3jyH+F54Dg+hUpd8sAa1aV6amMVd3QVAy7o6tK461A/pzulc/ahz9ZMLrSFJAydDl+7asiNOpE0t5XYgj06kI/xanivRhT5G/bq4ys4xzL8oEI62/lC5yr//+q9hnpd//8u/1x9/qz9+qT++1h8G5Bf646/o4+t/Kn82JbnWr4zcFKLl1QSnat/3HajYbK1mqsojHnp6CjeqU1XJCgvNQ2tcdVHcDTbXO2rz+qEXu+7CwEk+bhrhxV/+tgDapDAXA06UBVX6Ii8BdpeBNL1W1sZ522M6CtW1YCRdF5ZzjkiZsCIqSbvnqsaLr77EkX7x1c/0x0/1x0/0x/Op4S82HZOBTw9Ntn0F0/ABEmOGGNAw3y4+9fYg8MQ9xnOHvuSplDH6jsVqqbhZmTnV47Hu+Bc/+13GDE5yhwW1SfqPqr76Om8/KYNHtT/5z7KpvMh0VmKz0/Lg8JCd6nHNduQG9et6nK/dD9D5cneFPfJxsG09wrC21P5KKjbGzQ3pSPYk9btQSjoXoIP/UTDwAgiGIJgeIVx/hBdr57aED/bin39dnms3z2WPbD07wZRQf0TY02iGEeagzcRIsK7d89mdByszENJLdUTbSy/dv/nNv8yZUIYB9HO2RVmjm3Ks0yMCiyrfdS1MiaPVodG4ukobwRDKcNZzfR4V2p8T342B9RyD0nVjAV1J4U4O/sUvfsXONeCR8mMY8bkkLMrfkdL95t9fikQW8VJwXZOV+MWX/zUTMkX/y/+eY2+yDgIiSe4EA+PdXzz/1/KUKwA/7yirByteAvj13+QAgIDS2lxQOyH903/I1flhxLvurGqb67n98/+ZrpkYFDCez39LdvL57/THvxlzmVI7wsG9FFdSTFMO+EkMvRGBxhn9vGS9nKz/0Dq+qUsAr3D+D1aF787/vY0nM/5m9R9yJV8nj8vOf9fz579rjdq79f/bePSQJ/uo5yUI+CTYEQe6YxX+l7dKauCPtInVYdFWCZxpAMt+C4Fw4RQECuDwzUqqtGWerN8wbXcLooOhYOW/WKtorlrpPFgzk8oB0LfdG398T2b+j4fi9fK49P5HY31q/jfbjea7+f82Hjz/m9mn0Tc6tlKFGAl3koscW6m7Hp3k2gMYCeFSLI3bUfsbte3drZI+5dZJ7mlslfShuU5yFwNYmMOe5q4GUNGptw5rb9GlE7AfM+6ksFqdbIo+qsXOMxsvtyYvW+MTpfXgNHlJthRu6dctCJKGwKLrnwKh8a5JrYoV0gviiA7/MjoHFQoweU9hMQlr5lUG7QnPPkM4V6roRAoUBU/vKIP/bQ/vpU8y/ykr94Z4vEr8h/7/Xfz35p/M+OuX187jkvsf6+uN6fivWW+8u//3Vp4l9s2vnn+H/pWW2AGoKtOqynChjftAYI/xdH3IPjoLQhcW9njGPg5K37nmgcSf+A7DFpDr0Q6IJdd0To+7RxBf40Z5rMYlPqX2FB6UBIfYgbkcHMH3I3ghmIgH4KowIeHQu4enjbh7pDNT4yrclWe7caj8kNF1z2s8AE93isctBfUsgJ6sbAEf5dMlBulhiQx9bwiusOJAHMAjhn+q7NQmSkc66jeJDVZvIpOdlLdWvisddg9c8SobyWjAgF1fsB53XfTjTPZYEAoF9EviVNjQMBh/xSzL8/H4RgjDbAEBNWCWa7NlAH/KrB4rv//R/U/2x0sNvesENCvPgn6Zgc8GuUB6oMiwrttn1pD1MPltyfnIW0y4SkyjUjOOKLJgls3KJpAC6J5cxjbvewrPhKkzFYmhg3lX6k7aw6R8kavW9jGKgt6c21KnGysrDhwYFMscg8LDsKmBAJSEzd6dgwd3t5+wx9tP7m7f2ztK3g+g4OD+7sfsh3vfO9o9fPhw/96jo739g48f3X/wIbZqfmcTdTuCzrKoIXKITcjI8CqcsZ9ov3VtfF8or4MQRQrQ3vMLmiUajq4nr5T6iCvRkLOGfoGZAi/rJaN/R+aiUyBPhctqyM+yLPaxOOtCJAlxHzAccjqfRTYFGa4gCADiOreEWv8+kARd8f1Iv9J2BehT7PFQl0AHxAyXVMzC5TPDtXGphCzU2RCqfefGj7UCEa1sjc2OQQ2zZcOJunkc9C1iZo8LVW95/1RGZBb/dJlZXbb8RKhltozAQ9UHTBktZ8kZ7dWSZ6tOdD4aSUd+v++KbHVoMLGF0Cc0IIESseOvaXBY/4Mwju998/wfI+StyEygdFsMj7ULFXWyNOkQAZo0TYERiSzIM12YiIRewBxV8iMYMhKDTsn1Qzns4rWFLTYSIALMZ9zhwOIbyo3D4AZax+BsJUv/WDcLwZjVh/l/jYBXysxiXzCNglbFIgNNp1bXmE5ew5ehtFFjab8dYn8Q6IEMxGMJ030UwCyZMPvh7Y32Nu4SPORSiR9oAsSaANGoWoasBfrJbu3t394+vPvoaPtw7879o4M79z6+xVpXb+QJ3sV9o7kE4ZlBzsqT+wTmTZJhniI3HFcVkpvSmglFaY+JLkzx/uHD3f1CmrAe3Bl3+GGQEJ0MAlknQW5qusMyuHv+yJuLW9A79/CCpEYK6AAMInhQmAd9gKc3p0EpR0bnOgsQoC5Hey5CKE7yCFAofYgRjIXbjiOfDLiZLAhu+Xiz4Zuf/50OqVIGPzF5OxAa/wlewZU9aXMdZFwj74+bdImPSXyAp0Ow5IpwuDLXh+gTZ3NBhvzYLxnLixdfTAOGeHxSm+YO+8EB28UrY+xAH/GeS9AGyPmOTROxXB579kCESfc91nmGUB/+oR7UqQcsmXQh+PIjXZ70oBGPQMbHVcA5TSDZUzAuR9L5sIzSlZkN1kt9WP5zRHu//BnDk04Y7kZcol+DbpjQ8fTp/QYZRHPEPcupRU4SN+v12c5CxqbVE96G1oLs26spBiaaRInu9D0fTCBwgZEED44hJV4nBw+QdGJZxQFGd0qcYMyQgJVXMnIasSrXQR5zBPwIz4On21VaotD5BB0X16ElFKFNoWKhdVPfatH1+qBp2gu8T/fwNAx+LYBw0FpoCPxaABEHph6WH/lafcFOA9B3I+J98l8a6GkcfIHEU4fjPsuTunuZrHuXiXo4T9KHOUHTnYknB5KbtmaUKHbHcsWHMB274M+547CDgSwSjopNh5OKFbfBgFGvE1hxSwwYdD0BFbXHgJibjwiV7v49GUW+WX/wMITmHIszNYvK3YWk3ltI6MNLZX44LTJq+uPx0beJmh+A+GAY01M0T7OWn7+1PFQ9D1XPQzWKTFEOqpmHauahWnmoVh6qXWB98lDreaj1PNRGHmojD7WZh9rMQ1ULerWanjDJZCm2pLOGvraI+S0YPo1dXwS7YFg1dmMxzzMDu7kIdoEaaOzWItgF6qGx2ws5rVnY64tgF6iTxt5YBLtAzTT25iLYBeqnsasLaUuilvf8SHTSV8bxQBL+KAb9CgX9KAf+XsWIexH9Cgt7FsNSTlNRFUPksdDF6LtqVq2Kd5bRB5jldoVs1V29ulNR3OtNrNUT82MYZVrZlQnNjkO88ML87jP8GQ6/l/baaJwNLjW6y/zQrFlXKYsy8EP5OTbepaDnRIT6Mh0xUAYVgo1A0NaUe1bJ92RXQw/yNSe65qQ0ZW1TYk96Pjkv7sheT1Cdm3TCWXIkPENdTQC4fQxBTB5kNF4m825XFIQvonAdnVghfiwywupOTUVQOXq9THylyTzSpPOEkhZH0qUQDKPOJJGAtwtmKa1Wzumcw7iPeTBNH3+fxvAIBSdGFI0kFLC0oH81GyKF4hxlGU1sNE4apKevXk2GNE+SGwQNSZp+ML7alfbKsDAY0F3+8uTqV3kVL2GB/kis6PI+KvvAdx267O8ny4vxRHsy/ukYL4m4aKZhfA0lfVipYqKV9kFBDSIRVnIBmxkw92w6dDNNnkg3a7CG0qP+O8kAJw3FTBfSwYVwqj7hgjM0OVecCJCDStp7p5e0Dv4PYzwr6oo8uFrVJ1dtfzjEfrDPbJ2Lgwi/T5NzWDDJdTNSxDBJRwP4UCj5OQ7BeNwpvqJfWCmHWAkrtHMjIwWvdF5aDUL8iQjq5DFi6r7JkvnFDQLuh6afZoBCFDuHqL7pYkApLp5JNAU6bj7JrBuSMCDe9LNYWVAibkCJvLmDk4cEibMkZ0LqbkgTTXFfPBa/u3Ar9hZtxOGibXi4QBMeiigO6bc6kn2PnAk0IFqzkmOfGYh9ZfNATENcTOdjM7pJSnyI9jGSmaUB+DwJrhB7EsXiDrltkxnEZM4DPMBM+aSMEJZlLsVmM4M628STBJ6CDtNZvE/HGbxMNnA+yVzucoqyEXOattW6egnhXJZ1McI3LiWcJDOniU7OK6eJZrOYM4bEHNtl+jcRcEjG2bxLhKGM4eyE4SXIl+QnL8HG3OOs1ON8VMqhFqVQ56Md4KXDKTS8Uj+rW42mp5Lz2LWZVO9sjgslipMs8WJUDoPZNG4UNIKcM8ZunKnxloc2jrhbkeH6AAxXNNnJKC1wnjI5/4Gp1v8753/q6+vvzn+/lScz/t/K+R/9fer8T2393f3vt/JM/9DCh8lPev9ve+fS2zQQxPH7fgrf4LKt3zWV9lAeByQQhRaBFEVo7ayLheME21Gbb8/OPqzaDUppXRPQ/A5RJg+PFM9/sk7+uwtrgNqHtMuT3HZPMuPztA/C6IP5xLgnWUL0DGt5x4xcYI0wIS9OWQRyRw4Eq39wMxxO/5e32P8noXf+4eaoqEa2/9/D/+8P+38YR9j/p2AGzvc5ARcSU44m8N2z37juT1WX93wyU98BzfzWLAHmi8FWEExE4kXuEhlvSl67LEjVVhAm9liax17MbewzHqQiyWwcMJFmaZLaOGSJx73Ms3HE0jARfGHjmCVJ5i66fCc2vx5puyzMolim02GXXYddch12uXXYpdZhl1mHMnEuX21fLPNmIs//kb0gjIfjGzg4Dqj/yw6A/X8KeuffLCov78JSIaPl2Dv/M/QG5z92PRz/T8Lsc1W0c/JaNFldKBs5M6slwbor8L8Lr8k5r9sPubIF0wZWgFhVR/JTuxItIWR2octlTt7ciOwCvFTseNPUx2lRmYoin4TyWLFVRXNelJtawBvfaqPYnHzhVSsWL7e7MvztD+g/p6d/+BFgdPXfQ/9+MJz/HUa4/8sk7ND/e1kFPc+no1fieUQb0EZOVPzh0dP/elX+KFpa3vxsx2wD+/QfuMP53yfyedT/FOzQ/7mqAufd14+tcwZTtslZLq8P2VXN19/BUDMU/8P7AlQalVVXZFsoPK6yXW7XgjXFcl3iKOHJ6ek/Kwt5hpuWNq28ih+tBezVf3hH/5EboP6nYIf+X5kqcKAc1DLZDoSwS8Pz65KuuawY5xqsMzDF48/FD8K3szW741HaStnrnccoVUd3bDk6qhyf4VXEE9DT/wY22CjGE75h7/g/Gv7+G3sxjv8nYYf+TRWohZWXsEmPqKXw1eyOmm8fonj7dW+PTGmzlE9QOB5KGEEQBEEQBEEQBEEQBEEQBEEQBEEQBEEQ5FH8AjVgmMgAoAAA"
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
