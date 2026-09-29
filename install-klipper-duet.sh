#!/bin/bash
# install-klipper-duet.sh
# Complete Klipper + Mainsail + KlipperScreen installer for
# Lenovo Duet 1 (MediaTek MT8183 / google-krane) running postmarketOS.
#
# Creates: Docker-based Klipper stack (prind) + native KlipperScreen
#          running inside GNOME as a regular window.
#
# Run as your normal user (NOT root). Idempotent — safe to re-run.
# Usage: bash install-klipper-duet.sh 2>&1 | tee ~/klipper-install.log

set -e

# --- Configuration ------------------------------------------------------
# Change these if your setup differs
PRINTER_USER="user"
PRINTER_NAME="V-Minion"          # change if different printer
DUET_HOME="/home/${PRINTER_USER}"
PRIND_DIR="${DUET_HOME}/prind"
KS_DIR="${DUET_HOME}/KlipperScreen"
UPD_DIR="${DUET_HOME}/rx3-port"  # placeholder, unused unless rx3

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. Sanity ----------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Do not run as root"
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME unset"
command -v apk >/dev/null || die "apk not found — postmarketOS/Alpine required"

say "Klipper + KlipperScreen installer for Lenovo Duet 1"
echo "    Host:  $(uname -srm)"
echo "    User:  $(id -un) (uid $(id -u))"
echo "    Home:  $HOME"

# --- 1. Fix sudo so no password is needed -------------------------------
say "Configuring passwordless sudo for wheel"
if ! sudo -n true 2>/dev/null; then
    echo "    (One password prompt is needed to install sudo rules.)"
    sudo sh -c 'echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/010_wheel_nopasswd'
    sudo chmod 440 /etc/sudoers.d/010_wheel_nopasswd
    sudo adduser "$USER" wheel 2>/dev/null || true
fi

# --- 2. Install base packages -------------------------------------------
say "Installing base system packages"
sudo apk add --no-cache \
    git curl nano bash \
    docker docker-cli-compose \
    python3 py3-pip py3-gobject3 py3-cairo py3-dbus py3-requests \
    gtk+3.0 gtk+3.0-dev librsvg font-noto font-dejavu \
    cairo cairo-dev pkgconf \
    mpv mpv-libs mpv-dev \
    gcc g++ musl-dev meson python3-dev \
    gobject-introspection gobject-introspection-dev \
    seatd wlr-randr \
    xwayland xorg-server xinit

# --- 3. Enable Docker ---------------------------------------------------
say "Enabling Docker"
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" 2>/dev/null || true

# --- 4. Clone prind -----------------------------------------------------
say "Cloning prind (Dockerised Klipper stack)"
if [ -d "$PRIND_DIR/.git" ]; then
    git -C "$PRIND_DIR" pull --ff-only || warn "prind pull failed, using local copy"
else
    git clone https://github.com/mkuf/prind.git "$PRIND_DIR"
fi
cd "$PRIND_DIR"

# --- 5. Install prind-tools helper --------------------------------------
say "Installing prind-tools helper"
sudo tee /usr/local/bin/prind-tools > /dev/null <<EOF
#!/bin/sh
cd ${PRIND_DIR}
sudo docker compose -f docker-compose.extra.tools.yaml run --rm tools "\$@"
EOF
sudo chmod +x /usr/local/bin/prind-tools

# --- 6. Configure USB passthrough for the printer -----------------------
say "Detecting printer USB serial"
PRINTER_DEV=""
for i in 1 2 3 4 5; do
    if [ -e /dev/serial/by-id/usb-Klipper_lpc1768_051013133E0D5653D0270D4F050000F5-if00 ]; then
        PRINTER_DEV="/dev/serial/by-id/usb-Klipper_lpc1768_051013133E0D5653D0270D4F050000F5-if00"
        break
    fi
    # Fall back to any ttyACM/ttyUSB
    for dev in /dev/ttyACM* /dev/ttyUSB*; do
        [ -e "$dev" ] && PRINTER_DEV="$dev" && break 2
    done
    sleep 2
done

if [ -z "$PRINTER_DEV" ]; then
    warn "Printer not detected. Plugin it and re-run, or edit the override manually."
    PRINTER_DEV="/dev/ttyACM0"
fi
echo "    Using printer device: $PRINTER_DEV"

# Compute container path (always /dev/ttyACM0 inside)
CONTAINER_DEV="/dev/ttyACM0"

# --- 7. Write docker-compose.override.yaml ------------------------------
say "Writing docker-compose.override.yaml"
cat > "$PRIND_DIR/docker-compose.override.yaml" <<EOF
services:
  klipper:
    devices:
      - ${PRINTER_DEV}:${CONTAINER_DEV}
  moonraker:
    ports:
      - "7125:7125"
EOF

# --- 8. Install printer.cfg ---------------------------------------------
say "Installing ${PRINTER_NAME} printer.cfg"
if [ -f "$PRIND_DIR/config/printer.cfg" ]; then
    cp "$PRIND_DIR/config/printer.cfg" "$PRIND_DIR/config/printer.cfg.example" 2>/dev/null || true
fi

cat > "$PRIND_DIR/config/printer.cfg" <<'CFG_END'
# V-Minion 180
# SKR V1.4 + TMC2209 UART
# CoreXZ
# NOTE: z_offset must be re-calibrated with PROBE_CALIBRATE on first run.

[exclude_object]

[mcu]
serial: /dev/ttyACM0

[printer]
kinematics: cartesian
max_velocity: 350
max_accel: 6000
max_z_velocity: 15
max_z_accel: 200
square_corner_velocity: 5.0

[stepper_x]
step_pin: P2.2
dir_pin: P2.6
enable_pin: !P2.1
microsteps: 16
rotation_distance: 40
endstop_pin: ^P1.29
position_max: 180
position_min: 0
position_endstop: 2
homing_speed: 60

[stepper_y]
step_pin: P0.19
dir_pin: P0.20
enable_pin: !P2.8
microsteps: 16
rotation_distance: 40
endstop_pin: ^P1.28
position_max: 180
position_min: -5
position_endstop: -4
homing_speed: 60

[stepper_z]
step_pin: P0.22
dir_pin: P2.11
enable_pin: !P0.21
microsteps: 16
rotation_distance: 8
endstop_pin: probe:z_virtual_endstop
position_min: -2
position_max: 150
homing_speed: 8
second_homing_speed: 3

[extruder]
step_pin: P1.15
dir_pin: !P1.14
enable_pin: !P1.16
microsteps: 16
gear_ratio: 50:10
rotation_distance: 22.6789511
nozzle_diameter: 0.400
filament_diameter: 1.750
heater_pin: P2.7
sensor_type: EPCOS 100K B57560G104F
sensor_pin: P0.24
control: pid
pid_Kp: 22.2
pid_Ki: 1.08
pid_Kd: 114
min_temp: 0
max_temp: 260
pressure_advance: 0.04

[heater_bed]
heater_pin: P2.5
sensor_type: EPCOS 100K B57560G104F
sensor_pin: P0.23
control: pid
pid_Kp: 54.027
pid_Ki: 0.770
pid_Kd: 948.182
min_temp: 0
max_temp: 120

[fan]
pin: P2.3

[heater_fan hotend_fan]
pin: P2.4
heater: extruder
heater_temp: 50

[probe]
pin: ^P0.10
x_offset: -30
y_offset: -10
speed: 5
samples: 3
samples_result: median
sample_retract_dist: 3
lift_speed: 20
z_offset: 1.600

[safe_z_home]
home_xy_position: 90,90
speed: 80
z_hop: 10
z_hop_speed: 20

[bed_mesh]
speed: 150
horizontal_move_z: 5
mesh_min: 5,5
mesh_max: 150,170
probe_count: 5,5
algorithm: bicubic
fade_start: 1
fade_end: 10

[tmc2209 stepper_x]
uart_pin: P1.10
run_current: 0.80
hold_current: 0.50
sense_resistor: 0.110
stealthchop_threshold: 0
interpolate: False

[tmc2209 stepper_y]
uart_pin: P1.9
run_current: 0.80
hold_current: 0.50
sense_resistor: 0.110
stealthchop_threshold: 0
interpolate: False

[tmc2209 stepper_z]
uart_pin: P1.8
run_current: 0.80
hold_current: 0.50
sense_resistor: 0.110
stealthchop_threshold: 0
interpolate: False

[tmc2209 extruder]
uart_pin: P1.1
run_current: 0.70
hold_current: 0.40
sense_resistor: 0.110
interpolate: False
stealthchop_threshold: 0

[idle_timeout]
timeout: 1800

[virtual_sdcard]
path: /opt/printer_data/gcodes

[pause_resume]
[display_status]
[respond]

[force_move]
enable_force_move: True

[input_shaper]
shaper_type_x: mzv
shaper_freq_x: 60
shaper_type_y: mzv
shaper_freq_y: 45

[gcode_macro START_PRINT]
description: Start Print
gcode:
    {% set BED_TEMP = params.BED_TEMP|default(60)|float %}
    {% set EXTRUDER_TEMP = params.EXTRUDER_TEMP|default(200)|float %}
    M140 S{BED_TEMP}
    M104 S150
    M190 S{BED_TEMP}
    G90
    M83
    G28
    G4 P500
    G28 Z
    BED_MESH_CLEAR
    BED_MESH_PROFILE LOAD=default
    G1 Z10 F3000
    G1 X5 Y5 F6000
    M109 S{EXTRUDER_TEMP}
    G92 E0
    G1 Z0.30 F600
    G1 E3 F180
    G4 P300
    G1 X170 E12 F1000
    G1 Y5.6 F3000
    G1 X5 E24 F1000
    G1 X10 F3000
    G92 E0
    G1 Z2 F1200

[gcode_macro END_PRINT]
description: End print sequence
gcode:
    M400
    G92 E0
    G1 E-2 F1800
    G91
    G1 Z10 F1200
    G90
    G1 X0 Y180 F6000
    M104 S0
    M140 S0
    M107
    BED_MESH_CLEAR
    M84

[gcode_macro _CLIENT_VARIABLE]
variable_retract: 1.0
variable_unretract: 0.8
variable_speed_retract: 35
variable_speed_unretract: 25
variable_custom_park_dz: 10
gcode:
CFG_END

# --- 9. Install mainsail.cfg --------------------------------------------
say "Installing mainsail.cfg (macros for PAUSE/RESUME/CANCEL)"
if [ ! -d "$DUET_HOME/mainsail-config" ]; then
    git clone https://github.com/mainsail-crew/mainsail-config.git "$DUET_HOME/mainsail-config"
fi
cp -L "$DUET_HOME/mainsail-config/mainsail.cfg" "$PRIND_DIR/config/mainsail.cfg"

# Add include line at top of printer.cfg if not present
if ! head -1 "$PRIND_DIR/config/printer.cfg" | grep -q 'include mainsail.cfg'; then
    sed -i '1i [include mainsail.cfg]' "$PRIND_DIR/config/printer.cfg"
fi

sudo chown -R "$USER:$USER" "$PRIND_DIR/config/"

# --- 10. Start the prind stack ------------------------------------------
say "Starting prind stack with Mainsail profile"
cd "$PRIND_DIR"
docker compose --profile mainsail up -d
sleep 20
docker compose --profile mainsail ps

# --- 11. Install KlipperScreen ------------------------------------------
say "Installing KlipperScreen"
if [ -d "$KS_DIR/.git" ]; then
    git -C "$KS_DIR" pull --ff-only || warn "KS pull failed"
else
    git clone https://github.com/KlipperScreen/KlipperScreen.git "$KS_DIR"
fi

say "Installing KlipperScreen Python requirements"
pip install --break-system-packages --no-deps \
    python-mpv jinja2 markupsafe requests sdbus sdbus_networkmanager \
    websocket-client psutil 2>&1 | tail -5

# --- 12. Configure GDM auto-login ---------------------------------------
say "Configuring GDM auto-login for $PRINTER_USER"
sudo mkdir -p /etc/gdm
if ! grep -q '^AutomaticLoginEnable' /etc/gdm/custom.conf 2>/dev/null; then
    sudo tee -a /etc/gdm/custom.conf > /dev/null <<EOF

[daemon]
AutomaticLoginEnable=True
AutomaticLogin=${PRINTER_USER}
EOF
fi
sudo systemctl enable --now gdm

# --- 13. Install KlipperScreen user service (windowed in GNOME) ---------
say "Installing KlipperScreen user service"
mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/klipperscreen-launch.sh" <<'EOF'
#!/bin/sh
cd /home/user/KlipperScreen
exec ./screen.py
EOF
chmod +x "$HOME/klipperscreen-launch.sh"

cat > "$HOME/.config/systemd/user/KlipperScreen.service" <<'EOF'
[Unit]
Description=KlipperScreen
After=graphical-session.target

[Service]
Type=simple
ExecStart=/home/user/klipperscreen-launch.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable KlipperScreen.service

# --- 14. Enable lingering (so service starts without manual login) ------
sudo loginctl enable-linger "$PRINTER_USER"

# --- 15. Summary --------------------------------------------------------
IP=$(ip route get 1 2>/dev/null | awk '{print $7;exit}' || echo "192.168.1.29")
cat <<EOF

============================================================
  INSTALL COMPLETE
============================================================

  Printer:         ${PRINTER_NAME}
  Printer device:  ${PRINTER_DEV} -> ${CONTAINER_DEV}
  prind dir:       ${PRIND_DIR}
  KlipperScreen:   ${KS_DIR}
  Mainsail URL:    http://${IP}/
  Moonraker API:   http://${IP}:7125/

Next steps
----------
1. Log into GNOME on the physical screen (auto-login should be on)
2. KlipperScreen should appear as a window — press F11 to fullscreen
3. In Mainsail, run PROBE_CALIBRATE to set z_offset for your printer
4. Load a G-code file and print

Verify services
---------------
  systemctl --user status KlipperScreen.service
  cd ${PRIND_DIR} && docker compose --profile mainsail ps
  curl -s http://localhost:7125/server/info | head

Logs
----
  journalctl --user -u KlipperScreen.service -n 50 --no-pager
  cd ${PRIND_DIR} && docker compose --profile mainsail logs klipper | tail -30
  docker compose --profile mainsail exec klipper tail -50 /opt/printer_data/logs/klippy.log
EOF
