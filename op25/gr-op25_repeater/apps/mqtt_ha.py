# MQTT + Home Assistant discovery helper for OP25 talkgroup totals
# Optional dependency: paho-mqtt (python3-paho-mqtt)
#
# This module is intentionally self-contained so OP25 can run without MQTT.

from __future__ import print_function

import json
import os
import socket
import time

try:
    import paho.mqtt.client as mqtt  # type: ignore
except Exception:
    mqtt = None


def _now_iso():
    # ISO-ish timestamp for attributes/logging
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
    except Exception:
        return ""


class HaMqttTalkgroupTotals(object):
    """Publish talkgroup total durations and HA MQTT discovery sensors."""

    def __init__(self, host, port=1883, username=None, password=None,
                 base_topic="op25", discovery_prefix="homeassistant",
                 node_id=None, device_name="OP25", sysname=None,
                 keepalive=60, retain=True, debug=False):
        self.debug = bool(debug)
        self.retain = bool(retain)
        self.base_topic = str(base_topic).rstrip("/")
        self.discovery_prefix = str(discovery_prefix).rstrip("/")
        self.sysname = sysname
        self.device_name = device_name

        if node_id:
            self.node_id = str(node_id)
        else:
            # stable-ish default
            hn = os.environ.get("HOSTNAME") or socket.gethostname() or "op25"
            self.node_id = "op25_%s" % hn.replace(" ", "_").replace(".", "_")

        self._seen_tgids = set()
        self._client = None
        self._connected = False

        if mqtt is None:
            raise RuntimeError("paho-mqtt is not installed")

        cid = "%s_tg_totals" % self.node_id
        self._client = mqtt.Client(client_id=cid, clean_session=True)

        if username:
            try:
                self._client.username_pw_set(username, password=password)
            except Exception:
                # older paho versions
                self._client.username_pw_set(username, password)

        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect

        # Availability (LWT)
        self.availability_topic = "%s/status" % self.base_topic
        try:
            self._client.will_set(self.availability_topic, payload="offline", retain=True)
        except Exception:
            pass

        self._client.connect(host, int(port), keepalive=int(keepalive))
        # lightweight network loop in background thread
        self._client.loop_start()

    def _log(self, msg):
        if self.debug:
            try:
                print("[mqtt_ha] %s" % msg)
            except Exception:
                pass

    def _on_connect(self, client, userdata, flags, rc):
        self._connected = True
        self._log("connected rc=%s" % rc)
        try:
            self._client.publish(self.availability_topic, payload="online", retain=True)
        except Exception:
            pass

    def _on_disconnect(self, client, userdata, rc):
        self._connected = False
        self._log("disconnected rc=%s" % rc)

    def close(self):
        try:
            if self._client:
                self._client.publish(self.availability_topic, payload="offline", retain=True)
        except Exception:
            pass
        try:
            if self._client:
                self._client.loop_stop()
        except Exception:
            pass
        try:
            if self._client:
                self._client.disconnect()
        except Exception:
            pass

    @staticmethod
    def _safe_name(s):
        s = (s or "").strip()
        if not s:
            return ""
        return s

    def _tg_state_topic(self, tgid):
        return "%s/talkgroup/%s/total_seconds" % (self.base_topic, int(tgid))

    def _tg_config_topic(self, tgid):
        # homeassistant/sensor/<node_id>/<object_id>/config
        object_id = "tg_%s_total_seconds" % int(tgid)
        return "%s/sensor/%s/%s/config" % (self.discovery_prefix, self.node_id, object_id)

    def ensure_tg_sensor(self, tgid, tag=None):
        tgid = int(tgid)
        if tgid in self._seen_tgids:
            return
        self._seen_tgids.add(tgid)

        tag = self._safe_name(tag)
        if not tag:
            tag = "TG %d" % tgid

        name = "%s total time" % tag
        if self.sysname:
            # disambiguate if running multiple systems
            name = "%s (%s) total time" % (tag, self.sysname)

        payload = {
            "name": name,
            "unique_id": "%s_tg_%d_total_seconds" % (self.node_id, tgid),
            "state_topic": self._tg_state_topic(tgid),
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "unit_of_measurement": "s",
            "device_class": "duration",
            "state_class": "total_increasing",
            "icon": "mdi:timer-outline",
            "device": {
                "identifiers": [self.node_id],
                "name": self.device_name if not self.sysname else ("%s (%s)" % (self.device_name, self.sysname)),
                "manufacturer": "OP25",
                "model": "P25 receiver",
            },
        }

        try:
            self._client.publish(self._tg_config_topic(tgid), payload=json.dumps(payload), retain=True)
        except Exception as e:
            self._log("publish discovery failed: %s" % e)

    def publish_tg_total(self, tgid, tag, total_seconds):
        """Publish retained total seconds for talkgroup."""
        tgid = int(tgid)
        total_seconds = int(max(0, total_seconds))
        self.ensure_tg_sensor(tgid, tag=tag)

        try:
            self._client.publish(self._tg_state_topic(tgid), payload=str(total_seconds), retain=self.retain)
        except Exception as e:
            self._log("publish state failed: %s" % e)

    def publish_snapshot(self, totals_by_tgid, tags_by_tgid=None):
        """Publish a JSON snapshot of all totals (for dashboards / automations)."""
        try:
            tags_by_tgid = tags_by_tgid or {}
            out = {}
            for tgid, sec in totals_by_tgid.items():
                tgid_i = int(tgid)
                out[str(tgid_i)] = {
                    "tag": self._safe_name(tags_by_tgid.get(tgid_i, "")) or ("TG %d" % tgid_i),
                    "total_seconds": int(max(0, sec)),
                }
            payload = {
                "generated_at": _now_iso(),
                "talkgroups": out,
            }
            topic = "%s/talkgroup_totals" % self.base_topic
            self._client.publish(topic, payload=json.dumps(payload), retain=self.retain)
        except Exception as e:
            self._log("publish snapshot failed: %s" % e)
