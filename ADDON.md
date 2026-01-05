# OP25 Home Assistant Add-on

This repository is OP25 **plus** the Home Assistant add-on wrapper files (Dockerfile, config.yaml, run.sh, build.yaml).

## Quick start (HAOS)

1. **Put your trunking TSV (and optional talkgroup tags) in `/share/op25/`**
   - Example: `/share/op25/trunk.tsv`

2. In Home Assistant:
   - Settings → Add-ons → Add-on Store
   - Add this repo URL (once you publish it) **or** use local development by copying this folder to `/addons/local/op25`.

3. Configure the add-on:
   - `rx_args`: everything after `rx.py` (examples are in the add-on UI)
   - `http_port`: defaults to `8080`

4. Start the add-on, then open the Web UI:
   - `http://<homeassistant-host>:8080/`

## Notes

- This image builds OP25 from source against Debian's packaged GNU Radio.
- USB access is enabled (`usb: true`) so RTL-SDR/HackRF/etc can be used inside the add-on.
