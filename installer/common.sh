#!/usr/bin/env bash
set -euo pipefail


log() { echo -e "\033[1;36m[setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; }


require_root() {
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Run as root: sudo $0 [--backup|--overwrite|--skip]"; exit 1; fi
}


get_target_user() {
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then echo "$SUDO_USER"; else
read -rp "Enter username to configure: " TUSER; echo "$TUSER"; fi
}


PROMPT_MODE=${PROMPT_MODE:-ask}
while [[ ${1:-} ]]; do
case "$1" in
-y|--overwrite) PROMPT_MODE=overwrite ;;
--backup) PROMPT_MODE=backup ;;
--skip) PROMPT_MODE=skip ;;
esac; shift || true
done


prompt_choice() {
local prompt=$1
if [[ "$PROMPT_MODE" != "ask" || ! -t 0 ]]; then
case "$PROMPT_MODE" in
overwrite) echo o;; backup|'') echo b;; skip) echo s;; *) echo b;;
esac; return
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
log "$name exists: $dst"; local choice; choice=$(prompt_choice "Replace $name?")
case "$choice" in
o) log "Overwriting $dst"; write_user_file "$dst" "$content" ;;
b) local bak="${dst}.bak.$(date +%Y%m%d-%H%M%S)"; as_user "mv '$dst' '$bak'" || true; log "Backed up to $bak"; write_user_file "$dst" "$content" ;;
s) log "Skipped $name" ;;
esac
else
write_user_file "$dst" "$content"
fi
}