# MQTT + Home Assistant discovery helper for OP25 talkgroup totals
# Optional dependency: paho-mqtt (python3-paho-mqtt)
#
# This module is intentionally self-contained so OP25 can run without MQTT.

from __future__ import print_function

import json
import os
import socket
import time
import threading

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


def _expand_path(p):
    if not p:
        return None
    try:
        return os.path.expanduser(p)
    except Exception:
        return p


def _read_json(path):
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except Exception:
        return None


def _atomic_write_json(path, data):
    try:
        d = os.path.dirname(path)
        if d and (not os.path.isdir(d)):
            try:
                os.makedirs(d)
            except Exception:
                pass
        tmp = "%s.tmp" % path
        with open(tmp, 'w') as f:
            json.dump(data, f, sort_keys=True)
        try:
            os.replace(tmp, path)
        except Exception:
            # python2 fallback
            os.rename(tmp, path)
        return True
    except Exception:
        return False


class HaMqttTalkgroupTotals(object):
    """Publish talkgroup total durations and HA MQTT discovery sensors."""

    def __init__(self, host, port=1883, username=None, password=None,
                 base_topic="op25", discovery_prefix="homeassistant",
                 node_id=None, device_name="OP25", sysname=None,
                 keepalive=60, retain=True, debug=False,
                 entity_store_path=None, enable_cleanup_button=True):
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

        # Track discovered talkgroups; persisted so we can clean up HA entities later.
        self._seen_tgids = set()
        self._store_lock = threading.Lock()
        self._store_dirty = False
        self._last_store_flush = 0.0
        self._entity_store = {}  # tgid(int) -> {tag: str, last_seen: float}

        default_store = os.environ.get('OP25_MQTT_ENTITY_STORE') or "~/.op25_mqtt_entities.json"
        self.entity_store_path = _expand_path(entity_store_path or default_store)
        if self.entity_store_path:
            self._load_entity_store()

        self.enable_cleanup_button = bool(enable_cleanup_button)
        self.cleanup_command_topic = "%s/command/cleanup_talkgroups" % self.base_topic
        self._cleanup_in_progress = False
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
        self._client.on_message = self._on_message

        # Availability (LWT)
        self.availability_topic = "%s/status" % self.base_topic
        try:
            self._client.will_set(self.availability_topic, payload="offline", retain=True)
        except Exception:
            pass

        self._client.connect(host, int(port), keepalive=int(keepalive))
        # lightweight network loop in background thread
        self._client.loop_start()

    # ---- persistence / cleanup ------------------------------------------------

    def _load_entity_store(self):
        path = self.entity_store_path
        if not path:
            return
        data = _read_json(path) or {}
        tg = data.get('talkgroups') or {}
        try:
            for k, v in tg.items():
                try:
                    tgid = int(k)
                except Exception:
                    continue
                tag = (v or {}).get('tag') or ""
                last_seen = (v or {}).get('last_seen')
                try:
                    last_seen = float(last_seen) if last_seen is not None else 0.0
                except Exception:
                    last_seen = 0.0
                self._entity_store[tgid] = {'tag': tag, 'last_seen': last_seen}
                self._seen_tgids.add(tgid)
        except Exception:
            pass

    def _flush_entity_store(self, force=False):
        if not self.entity_store_path:
            return
        now = time.time()
        if (not force) and (not self._store_dirty):
            return
        # throttle writes to avoid excessive disk IO
        if (not force) and (now - self._last_store_flush) < 5.0:
            return
        with self._store_lock:
            payload = {
                'updated_at': _now_iso(),
                'talkgroups': {},
            }
            for tgid, meta in self._entity_store.items():
                payload['talkgroups'][str(int(tgid))] = {
                    'tag': (meta or {}).get('tag') or "",
                    'last_seen': float((meta or {}).get('last_seen') or 0.0),
                }
            ok = _atomic_write_json(self.entity_store_path, payload)
            if ok:
                self._store_dirty = False
                self._last_store_flush = now

    def _store_mark_seen(self, tgid, tag=None):
        tgid = int(tgid)
        with self._store_lock:
            meta = self._entity_store.get(tgid) or {'tag': '', 'last_seen': 0.0}
            if tag:
                meta['tag'] = self._safe_name(tag) or meta.get('tag', '')
            meta['last_seen'] = time.time()
            self._entity_store[tgid] = meta
            self._store_dirty = True
        self._flush_entity_store(force=False)

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

        # Subscribe for host commands (HA buttons)
        try:
            if self.enable_cleanup_button:
                self._client.subscribe(self.cleanup_command_topic)
        except Exception:
            pass

        # Publish discovery for host-level helper entities
        try:
            if self.enable_cleanup_button:
                self._publish_cleanup_button_discovery()
        except Exception:
            pass

    def _on_disconnect(self, client, userdata, rc):
        self._connected = False
        self._log("disconnected rc=%s" % rc)

    def _on_message(self, client, userdata, msg):
        try:
            topic = getattr(msg, 'topic', '')
            payload = getattr(msg, 'payload', b'')
            try:
                payload_s = payload.decode('utf-8', 'ignore') if hasattr(payload, 'decode') else str(payload)
            except Exception:
                payload_s = ''

            if topic == self.cleanup_command_topic:
                # Any press triggers cleanup
                self._log("cleanup requested payload=%s" % payload_s)
                self.cleanup_all_talkgroup_entities()
        except Exception as e:
            self._log("on_message error: %s" % e)

    def close(self):
        try:
            self._flush_entity_store(force=True)
        except Exception:
            pass
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

    def _host_button_config_topic(self, object_id):
        return "%s/button/%s/%s/config" % (self.discovery_prefix, self.node_id, object_id)

    def _publish_cleanup_button_discovery(self):
        """Expose a Home Assistant MQTT button to clean up discovered TG entities."""
        object_id = "cleanup_talkgroups"
        payload = {
            "name": "Cleanup talkgroup entities",
            "unique_id": "%s_cleanup_talkgroups" % self.node_id,
            "command_topic": self.cleanup_command_topic,
            "payload_press": "PRESS",
            "availability_topic": self.availability_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "icon": "mdi:broom",
            "device": {
                "identifiers": [self.node_id],
                "name": self.device_name if not self.sysname else ("%s (%s)" % (self.device_name, self.sysname)),
                "manufacturer": "OP25",
                "model": "P25 receiver",
            },
        }
        self._client.publish(self._host_button_config_topic(object_id), payload=json.dumps(payload), retain=True)

    def cleanup_all_talkgroup_entities(self):
        """Remove all known/discovered talkgroup entities from Home Assistant.

        This works by publishing an empty retained payload to each entity's discovery config topic,
        which Home Assistant interprets as a removal request.
        """
        if self._cleanup_in_progress:
            return
        self._cleanup_in_progress = True
        try:
            # Combine persisted store + in-memory set
            with self._store_lock:
                tgids = set(self._seen_tgids)
                tgids.update(self._entity_store.keys())

            for tgid in sorted(list(tgids)):
                try:
                    # Remove HA entity
                    self._client.publish(self._tg_config_topic(tgid), payload="", retain=True)
                    # Clear retained state topic too (hygiene)
                    self._client.publish(self._tg_state_topic(tgid), payload="", retain=True)
                except Exception:
                    pass

            # Clear snapshot
            try:
                self._client.publish("%s/talkgroup_totals" % self.base_topic, payload="", retain=True)
            except Exception:
                pass

            # Clear local tracking
            with self._store_lock:
                self._seen_tgids = set()
                self._entity_store = {}
                self._store_dirty = True
            self._flush_entity_store(force=True)
        finally:
            self._cleanup_in_progress = False

    def ensure_tg_sensor(self, tgid, tag=None):
        tgid = int(tgid)
        if tgid in self._seen_tgids:
            # still update persisted last_seen/tag
            try:
                self._store_mark_seen(tgid, tag=tag)
            except Exception:
                pass
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

        # persist for later cleanup
        try:
            self._store_mark_seen(tgid, tag=tag)
        except Exception:
            pass

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
