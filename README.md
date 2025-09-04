# sway-nord-setup


Single-file installer for Debian (Bookworm/Trixie+) that sets up:
- Sway + Waybar + Rofi (Nord)
- PipeWire/WirePlumber, xdg-desktop-portal-wlr (screen sharing)
- NetworkManager, Bluetooth (Blueman)
- Chromium, VS Code (idempotent repo/keyring)
- Systemd user services (Waybar, Mako, Cliphist, Polkit, Udiskie)
- Solid Nord background (no image dependency)
- Alt↔Win swap; **Alt is Mod**


## Usage (on target machine)
```bash
# Option A: run from GitHub raw
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/dist/setup.sh | sudo bash -s -- --backup


# Option B: download then run
sudo bash setup.sh --backup
```
Flags:
- `--backup` (default if non-interactive): backup existing configs then write new
- `--overwrite`: replace without asking
- `--skip`: keep existing files


## Build locally
```bash
# 1) Clone your repo
# 2) Build the installer
./scripts/build.sh
# 3) Verify
bash -n dist/setup.sh && head -n 60 dist/setup.sh
# 4) Commit & push
git add -A && git commit -m "build: update installer" && git push
```


## Layout
```
configs/
sway/config
waybar/config.jsonc
waybar/style.css
rofi/config.rasi
rofi/nord.rasi
mako/config
foot/foot.ini
kitty/kitty.conf
systemd_user/
waybar.service
mako.service
cliphist-store.service
polkit-lxqt.service
udiskie.service
scripts/
build.sh
installer/
template.sh # installer base with placeholder for embedded payload
common.sh # shared helpers used by template
packages.sh # package install steps
postinstall.sh# enable services, user env, etc.
dist/
setup.sh # generated single-file installer (commit this for curlable URL)