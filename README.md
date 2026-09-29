# Klipper on Lenovo Duet 1 (postmarketOS)

Complete setup for running **Klipper + Moonraker + Mainsail + KlipperScreen**
on a Lenovo Duet 1 (MediaTek MT8183, `google-krane`) running postmarketOS,
controlling a Rat Rig V-Minion 3D printer.

## Why this approach?

The standard **KIAUH** installer cannot run on postmarketOS because it requires:

- Debian-based package management (`apt`) — postmarketOS uses **Alpine** (`apk`)
- A pre-configured Debian `/etc/os-release` — KIAUH's parser fails on postmarketOS

The solution is to run the Klipper stack in **Docker** using the
[prind](https://github.com/mkuf/prind) project. Docker containers bring their
own Debian-based environment, so postmarketOS never has to satisfy KIAUH's
assumptions.

KlipperScreen is installed **natively** (not in Docker) because it needs to
talk directly to the display and touchscreen, which is simpler outside a
container.

## Architecture

| Component | Where it runs | Purpose |
|---|---|---|
| **Docker** | Host | Container runtime |
| **prind / klipper** | Container | Klipper firmware host |
| **prind / moonraker** | Container | Klipper API on port 7125 |
| **prind / mainsail** | Container | Web UI on port 80 |
| **prind / traefik** | Container | Reverse proxy |
| **KlipperScreen** | Host (GNOME) | Touchscreen UI |

## Prerequisites

- Lenovo Duet 1 with postmarketOS (systemd variant) installed
- Network access
- USB cable to the printer
- The printer must be powered on and connected before running the installer

## Installation

1. **Save the installer script on the Duet** as `~/install-klipper-duet.sh`.

2. **Make it executable and run it:**

   ```bash
   chmod +x ~/install-klipper-duet.sh
   bash ~/install-klipper-duet.sh 2>&1 | tee ~/klipper-install.log
   ```

3. **Wait for it to complete** — the first run downloads Docker images and
   installs many packages. It can take 10–15 minutes.

4. **Reboot** to bring up GDM and auto-login:

   ```bash
   sudo reboot
   ```

5. **After reboot**, GNOME auto-logs in as `user`, and KlipperScreen starts
   as a window inside GNOME.

## Using KlipperScreen

- **Fullscreen**: With KlipperScreen focused, press **F11** or **Super+↑**
- **Return to desktop**: Press **Super** to open GNOME's activity view
- **Restart**: `systemctl --user restart KlipperScreen.service`

## Using Mainsail

Open a browser on any device on the same network and go to:

```
http://<duet-ip>/
```

For example: `http://192.168.1.29/`

Mainsail gives you the full Klipper interface — file browser, temperature
graphs, console, macros, and job control.

## Important services

```bash
# Docker containers
cd ~/prind && docker compose --profile mainsail ps

# KlipperScreen (user service)
systemctl --user status KlipperScreen.service

# Auto-start on boot (system services)
systemctl status gdm --no-pager
systemctl status docker --no-pager
```

## Logs

```bash
# KlipperScreen
journalctl --user -u KlipperScreen.service -n 50 --no-pager

# Klipper (Docker container)
cd ~/prind
docker compose --profile mainsail logs klipper | tail -50
docker compose --profile mainsail exec klipper tail -50 /opt/printer_data/logs/klippy.log

# Moonraker
docker compose --profile mainsail exec moonraker tail -50 /opt/printer_data/logs/moonraker.log

# Docker
sudo journalctl -u docker -n 50 --no-pager
```

## Common tasks

### Restart everything

```bash
cd ~/prind
docker compose --profile mainsail restart
systemctl --user restart KlipperScreen.service
```

### Update Klipper

```bash
cd ~/prind
docker compose --profile mainsail pull
docker compose --profile mainsail up -d
```

### Change printer USB device

If the printer's serial changes (different board, different USB port), edit
`~/prind/docker-compose.override.yaml` and update the `devices:` path. Then:

```bash
cd ~/prind
docker compose --profile mainsail up -d
```

### Re-calibrate the Z offset

In Mainsail's console, or from KlipperScreen, run:

```
PROBE_CALIBRATE
```

Follow the prompts, then `ACCEPT` and `SAVE_CONFIG`. Klipper will restart
with the new offset.

### Switch to Fluidd instead of Mainsail

```bash
cd ~/prind
docker compose --profile mainsail down
docker compose --profile fluidd up -d
```

(Only one web frontend can run at a time behind Traefik.)

## Troubleshooting

### KlipperScreen not starting

```bash
systemctl --user status KlipperScreen.service
journalctl --user -u KlipperScreen.service -n 50 --no-pager
```

Common causes:

- **`cannot open display`** → You're logged in over SSH without a graphical
  session. Log into GNOME on the physical screen.
- **`Connection refused` to Moonraker** → The prind stack isn't running:
  `cd ~/prind && docker compose --profile mainsail up -d`
- **`ModuleNotFoundError`** → A Python dependency is missing. Install it:
  `pip install --break-system-packages <module>`

### Mainsail shows "Initializing" forever

Moonraker isn't reachable. Check:

```bash
curl -s http://localhost:7125/server/info | head
```

If empty, the port mapping is missing. Ensure
`~/prind/docker-compose.override.yaml` contains:

```yaml
services:
  moonraker:
    ports:
      - "7125:7125"
```

Then `docker compose --profile mainsail up -d`.

### Klipper says "Unable to open serial port"

The container can't see the printer. Check:

```bash
ls -l /dev/serial/by-id/
docker compose exec klipper ls -l /dev/ttyACM0
```

If the host sees the device but the container doesn't, the override
passthrough is wrong. Update `~/prind/docker-compose.override.yaml` and
restart.

### Klipper config error about mainsail.cfg

The include line is present but the file is missing. Re-run:

```bash
cp -L ~/mainsail-config/mainsail.cfg ~/prind/config/mainsail.cfg
sudo chown user:user ~/prind/config/mainsail.cfg
cd ~/prind && docker compose restart klipper
```

### Klipper config error about z_offset

Some Klipper versions require `z_offset` explicitly. Ensure the `[probe]`
section in `~/prind/config/printer.cfg` contains:

```
z_offset: 1.600
```

(Re-run `PROBE_CALIBRATE` afterwards to get the correct value.)

### Docker "permission denied"

Your user isn't in the `docker` group yet. Fix:

```bash
sudo usermod -aG docker $USER
```

Then **log out and back in** (or reboot) for it to take effect.

## Differences from a stock Raspberry Pi setup

| Feature | RPi + KIAUH | Duet + prind |
|---|---|---|
| Package manager | `apt` (Debian) | `apk` (Alpine) |
| Klipper install | Native system packages | Docker container |
| Service manager | `systemd` | `systemd` (both work) |
| Config path | `~/printer_data/` | `~/prind/config/` |
| G-code path | `~/printer_data/gcodes/` | `~/prind/gcode/` |
| Web UI port | `:80` | `:80` (via Traefik) |
| Moonraker API | `:7125` | `:7125` (published) |
| KlipperScreen | Native install | Native install |

## File locations

| File | Path |
|---|---|
| Main install script | `~/install-klipper-duet.sh` |
| Installation log | `~/klipper-install.log` |
| prind repo | `~/prind/` |
| Printer config | `~/prind/config/printer.cfg` |
| Mainsail macros | `~/prind/config/mainsail.cfg` |
| G-code files | `~/prind/gcode/` |
| Docker override | `~/prind/docker-compose.override.yaml` |
| KlipperScreen | `~/KlipperScreen/` |
| KlipperScreen launch | `~/klipperscreen-launch.sh` |
| KlipperScreen service | `~/.config/systemd/user/KlipperScreen.service` |
| Klipper logs | `~/prind/` (via `docker compose logs`) |

## Reverting to a clean state

To stop and remove the Klipper stack:

```bash
cd ~/prind
docker compose --profile mainsail down -v

sudo systemctl disable --now docker 2>/dev/null
systemctl --user disable --now KlipperScreen.service 2>/dev/null
sudo rm -rf ~/prind ~/KlipperScreen ~/mainsail-config
sudo rm /usr/local/bin/prind-tools
```

## References

- [prind project](https://github.com/mkuf/prind) — Dockerised Klipper stack
- [Klipper documentation](https://www.klipper3d.org/)
- [KlipperScreen documentation](https://klipperscreen.readthedocs.io/)
- [Mainsail](https://docs.mainsail.xyz/)
- [postmarketOS wiki](https://wiki.postmarketos.org/)
