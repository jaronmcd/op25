# OP25 (MQTT Talkgroup Totals) [Experiment]

This add-on builds and runs **OP25** and can optionally publish **per-talkgroup total airtime** to Home Assistant via **MQTT Discovery**.

It uses the patched OP25 Python modules included in this repository to:
- Track total call time per talkgroup (with optional daily reset at midnight), and
- Publish Home Assistant MQTT discovery entities for those totals, plus a cleanup button.

## Hardware notes

- The add-on is configured with `usb: true` so Home Assistant can pass SDR USB devices into the container.
- Supported SDRs depend on GNU Radio + osmosdr support (RTL-SDR, HackRF, UHD/USRP, etc.).

## Quick start

1. **Install an MQTT broker** (e.g., the Mosquitto add-on).
2. In `/share/op25/`, edit the example config file that the add-on will place there on first start:
   - `p25_single_rtl_example.json`
3. Configure the add-on:
   - **command**: point OP25 at your config, e.g.  
     `./multi_rx.py -v 1 -c /share/op25/p25_single_rtl_example.json`
   - MQTT settings (defaults assume Mosquitto add-on):
     - `mqtt_host`: `core-mosquitto`
     - `mqtt_port`: `1883`
     - enable/disable `mqtt_reset_daily` as desired
4. Start the add-on.

## Where the Home Assistant entities show up

The add-on publishes MQTT discovery under:

- `homeassistant/` (configurable via `mqtt_discovery_prefix`)
- Entity values under `op25/` (configurable via `mqtt_base_topic`)

You should see a device named **OP25** (or whatever you set in `mqtt_device_name`) with:
- One sensor per talkgroup (total time in seconds)
- A reset-at-midnight behavior if enabled
- A cleanup button to remove old talkgroups that stopped appearing

## Advanced

### Use your own OP25 fork/branch

The container builds OP25 during image build. If you want it to build from a different fork/ref, edit:

- `OP25_REPO` and `OP25_REF` args in `Dockerfile`

### Don’t append MQTT flags

If you include any `--mqtt-*` flags inside `command`, the add-on will **not** add additional MQTT flags automatically.
