#!/usr/bin/env python3
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

OPTIONS_PATH = Path("/data/options.json")
APPS_DIR = Path("/opt/op25/op25/gr-op25_repeater/apps")
SHARE_OP25 = Path("/share/op25")

DEFAULTS = {
    "command": "./multi_rx.py -v 1 -c /share/op25/p25_single_rtl_example.json",
    "mqtt_host": "core-mosquitto",
    "mqtt_port": 1883,
    "mqtt_user": "",
    "mqtt_pass": "",
    "mqtt_base_topic": "op25",
    "mqtt_discovery_prefix": "homeassistant",
    "mqtt_node_id": "",
    "mqtt_device_name": "OP25",
    "mqtt_sysname": "",
    "mqtt_debug": False,
    "mqtt_reset_daily": True,
    "mqtt_tz": "America/Chicago",
}

def load_options() -> dict:
    if OPTIONS_PATH.exists():
        try:
            return json.loads(OPTIONS_PATH.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"[OP25-ADDON] WARNING: Failed to read options.json ({e}); using defaults.", flush=True)
    return {}

def ensure_example_files() -> None:
    try:
        SHARE_OP25.mkdir(parents=True, exist_ok=True)
        # Copy example JSON if user hasn't provided one
        ex_json = SHARE_OP25 / "p25_single_rtl_example.json"
        if not ex_json.exists():
            src = APPS_DIR / "p25_single_rtl_example.json"
            if src.exists():
                shutil.copy2(src, ex_json)
        # Also copy helper scripts / notes that often accompany the example
        for fname in ("README-configuration.md", "README.md", "setTrunkFreq.sh", "trunk.tsv", "tgid_tags.tsv"):
            src = APPS_DIR / fname
            dst = SHARE_OP25 / fname
            if src.exists() and not dst.exists():
                shutil.copy2(src, dst)
    except Exception as e:
        print(f"[OP25-ADDON] WARNING: Could not prepare /share/op25 examples ({e}).", flush=True)

def append_mqtt_args(argv: list[str], opts: dict) -> list[str]:
    # If user already passed mqtt flags, don't duplicate.
    if any(a.startswith("--mqtt-") for a in argv):
        return argv

    host = (opts.get("mqtt_host") or "").strip()
    if not host:
        return argv

    port = int(opts.get("mqtt_port") or 1883)
    user = (opts.get("mqtt_user") or "").strip()
    pwd  = (opts.get("mqtt_pass") or "").strip()
    base = (opts.get("mqtt_base_topic") or "op25").strip()
    disc = (opts.get("mqtt_discovery_prefix") or "homeassistant").strip()
    node = (opts.get("mqtt_node_id") or "").strip()
    devn = (opts.get("mqtt_device_name") or "OP25").strip()
    sysn = (opts.get("mqtt_sysname") or "").strip()
    debug = bool(opts.get("mqtt_debug", False))
    reset = bool(opts.get("mqtt_reset_daily", False))
    tz = (opts.get("mqtt_tz") or "America/Chicago").strip()

    out = list(argv)
    out += ["--mqtt-host", host, "--mqtt-port", str(port), "--mqtt-base-topic", base, "--mqtt-discovery-prefix", disc, "--mqtt-device-name", devn, "--mqtt-tz", tz]
    if user:
        out += ["--mqtt-user", user]
    if pwd:
        out += ["--mqtt-pass", pwd]
    if node:
        out += ["--mqtt-node-id", node]
    if sysn:
        out += ["--mqtt-sysname", sysn]
    if debug:
        out += ["--mqtt-debug"]
    if reset:
        out += ["--mqtt-reset-daily"]
    return out

def main() -> int:
    ensure_example_files()
    user_opts = load_options()
    opts = {**DEFAULTS, **(user_opts or {})}

    cmd = (opts.get("command") or DEFAULTS["command"]).strip()
    if not cmd:
        print("[OP25-ADDON] ERROR: 'command' is empty.", flush=True)
        return 2

    argv = shlex.split(cmd)
    argv = append_mqtt_args(argv, opts)

    # Some scripts are /bin/sh wrappers that expect to be executed from APPS_DIR.
    print("[OP25-ADDON] Starting:", " ".join(shlex.quote(a) for a in argv), flush=True)
    os.chdir(APPS_DIR)

    # Replace the current process so signals (stop/restart) work correctly.
    os.execvp(argv[0], argv)

if __name__ == "__main__":
    raise SystemExit(main())
