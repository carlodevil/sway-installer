## sway-nord-setup

Single-file installer for Debian (Bookworm/Trixie+) that configures a Sway-based
desktop with sane defaults and user services.

 It installs and configures (idempotent where possible):
- sway, waybar, rofi (Nord theme)
- PipeWire / WirePlumber and xdg-desktop-portal-wlr
- NetworkManager, Bluetooth (Blueman)
- Chromium and VS Code (adds repo/keyring idempotently)
- Systemd user units (waybar, mako, cliphist, polkit, udiskie)

## Quick usage (on the target Debian machine)
Option A — run directly from GitHub (recommended for quick installs):

```bash
curl -fsSL https://raw.githubusercontent.com/carlodevil/sway-installer/main/dist/setup.sh | sudo bash -s -- --backup
```

Option B — download and inspect before running:

```bash
curl -fsSL -o setup.sh https://raw.githubusercontent.com/carlodevil/sway-installer/main/dist/setup.sh
sudo bash setup.sh --backup
```

Installer flags:
- `--backup` (default in non-interactive mode): back up existing files then write new
- `--overwrite`: replace without asking
- `--skip`: keep existing files

## Build locally
Prerequisites: `bash`, `tar`, `gzip`, `base64` (these are available on Ubuntu runners).

On Windows use WSL (recommended) or Git Bash / MSYS2 that provides a POSIX shell.

```bash
# build the single-file installer locally
./scripts/build.sh

# quick checks
bash -n dist/setup.sh        # syntax-check the generated installer
grep -q "__PAYLOAD_B64__" dist/setup.sh && echo "? missing payload injection" || echo "? payload injected"
head -n 10 dist/setup.sh     # preview

# commit & push the updated dist if desired
git add dist/setup.sh && git commit -m "build(ci): update dist/setup.sh" && git push
```

If the tarball is not created, inspect `.build`:

```bash
ls -la .build
ls -la .build/payload.tgz
```

The build script will now fail early with a helpful message if the tarball is missing or empty.

## CI (GitHub Actions)
- Workflow: `.github/workflows/build.yml`
- Runs on `ubuntu-latest`.
- Steps:
	- checkout the repo
	- run `scripts/build.sh` (now executed with `bash -x` in the workflow for easier debugging)
	- upload `dist/setup.sh` as an artifact
	- on a tag, re-run the build and create a GitHub Release with `dist/setup.sh`

If CI reports the tarball wasn't created, check the Build step logs in Actions — the `bash -x` trace plus the added diagnostic step will print the contents of the workspace and `.build` so you can see whether `tar` ran and whether `.build/payload.tgz` exists.

Common CI pitfalls
- missing `tar` or unexpected shell on runner (we use `bash` explicitly in the workflow)
- file path problems: the script packs `configs` and `systemd_user` from the repo root — ensure those directories exist in the checkout
- base64 differences: the build uses a portable encoding (`base64 | tr -d '\n'`) to avoid implementation flags

## Repo layout (important files)
```
configs/                # configuration tree bundled into the installer
systemd_user/           # systemd user unit files bundled into the installer
installer/template.sh   # installer template with payload placeholder
scripts/build.sh        # creates .build/payload.tgz and writes dist/setup.sh
.github/workflows/build.yml  # CI build + release
dist/setup.sh           # generated single-file installer (committed or built by CI)
```

## Troubleshooting
- If `dist/setup.sh` still contains the literal `__PAYLOAD_B64__` placeholder after running `./scripts/build.sh`, run the script with tracing to see where it fails:

```bash
bash -x ./scripts/build.sh
```

- If CI fails, open the Action run and paste the Build step logs here and I will help interpret them.

---
Updated: reflect the latest build and CI behavior and add diagnostics for missing tarball.
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
curl -fsSL https://raw.githubusercontent.com/carlodevil/sway-installer/dist/setup.sh | sudo bash -s -- --backup


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