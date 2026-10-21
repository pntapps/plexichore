#!/usr/bin/env python3
"""
faketablet.py - headless "fake tablet" protocol test client for PlexiChore hosts.

Speaks PlexiChore protocol v1 (see PROTOCOL.md at the repo root) exactly like the Android app
(PlexiChore/app/.../core/Protocol.kt + StreamSession.kt) for a Galaxy Tab S8, and validates what
the host sends. Python 3 stdlib only (works with macOS /usr/bin/python3, 3.9+).

Examples:
  ./faketablet.py --discover                       # list hosts answering on UDP 47801
  ./faketablet.py --seconds 10                     # connect to 127.0.0.1:47800, extend mode
  ./faketablet.py --mode mirror --fps 30 --dump out.h264 --request-keyframe 3 --send-input
  ./faketablet.py --settings '{"orientation":"portrait"}' --settings-at 4 --seconds 10

Scripted end-to-end checks against a RUNNING host (prints a PASS/WARN/FAIL table):
  ./faketablet.py --scenario all                   # extend primary mirror portrait rotate-midstream
                                                   # decoder-clamp reconnect pairing
  ./faketablet.py --scenario extend,mirror --scenario-seconds 6 --summary out.json
  ./faketablet.py --host 192.168.1.20 --scenario pairing   # Wi-Fi: approve the printed code on the host
  ./faketablet.py --self-test                      # checks this script against in-process fake hosts
                                                   # on random ports (no real host / port 47800 needed)
  Scenario exit code: 0 = no FAIL (WARNs allowed), 1 = at least one FAIL, 2 = host unreachable.

Exit code: 0 = no protocol violations, 1 = violations (listed in the JSON summary),
2 = could not connect / rejected / usage error.
"""

import argparse
import json
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import time
import uuid

# ---------------------------------------------------------------- protocol constants

TCP_PORT = 47800
UDP_PORT = 47801
PROBE = b"PLEXI?"
MAX_PAYLOAD = 16 * 1024 * 1024
HEADER = struct.Struct(">BI")

HELLO, CONFIG, VIDEO, INPUT, KEY, PING, PONG, REQUEST_KEYFRAME, SETTINGS, BYE, STATS, PAIRING = range(1, 13)
TYPE_NAMES = {
    HELLO: "HELLO", CONFIG: "CONFIG", VIDEO: "VIDEO", INPUT: "INPUT", KEY: "KEY", PING: "PING",
    PONG: "PONG", REQUEST_KEYFRAME: "REQUEST_KEYFRAME", SETTINGS: "SETTINGS", BYE: "BYE",
    STATS: "STATS", PAIRING: "PAIRING",
}
FLAG_KEYFRAME = 0x01
FLAG_CODEC_CONFIG = 0x02

KIND_TOUCH, KIND_PEN, KIND_MOUSE, KIND_SCROLL = 0, 1, 2, 3
ACT_DOWN, ACT_MOVE, ACT_UP, ACT_CANCEL, ACT_HOVER_MOVE, ACT_HOVER_EXIT = 0, 1, 2, 3, 4, 5
POINTER = struct.Struct(">BBBBfffff")  # 24 bytes

# Galaxy Tab S8 (SM-X700) as DeviceProfile.build() reports it (landscape, long edge first).
TAB_S8 = {
    "deviceName": "Galaxy Tab S8",
    "model": "SM-X700",
    "widthPx": 2560,
    "heightPx": 1600,
    "densityDpi": 320,
    "refreshHz": 120,
    "codecs": ["h264", "mjpeg"],
    "decodeModes": [{"width": 3840, "height": 2160, "maxFps": 60}, {"width": 2560, "height": 1600, "maxFps": 120}],
    "h264Profiles": ["high", "main", "baseline"],
    "h264MaxLevel": "5.1",
    "pen": True,
}


def frame(msg_type, payload=b""):
    if isinstance(payload, (dict, list)):
        payload = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    elif isinstance(payload, str):
        payload = payload.encode("utf-8")
    return HEADER.pack(msg_type, len(payload)) + payload


def now_us():
    return int(time.monotonic() * 1_000_000)


class FrameReader:
    """Incremental parser for `u8 type | u32 len | payload` frames."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf += data

    def frames(self):
        out = []
        while len(self.buf) >= HEADER.size:
            t, n = HEADER.unpack_from(self.buf, 0)
            if n > MAX_PAYLOAD:
                raise ValueError("bad frame length %d (type %d)" % (n, t))
            if len(self.buf) < HEADER.size + n:
                break
            out.append((t, bytes(self.buf[HEADER.size:HEADER.size + n])))
            del self.buf[:HEADER.size + n]
        return out


# ---------------------------------------------------------------- INPUT encoding


def pointer(kind, action, pid, buttons, x, y, pressure=0.0, tilt_x=0.0, tilt_y=0.0):
    return POINTER.pack(kind, action, pid, buttons, x, y, pressure, tilt_x, tilt_y)


def input_frame(pointers):
    if not 1 <= len(pointers) <= 10:
        raise ValueError("1..10 pointers")
    return frame(INPUT, bytes([len(pointers)]) + b"".join(pointers))


def demo_input_frames():
    """Mouse hover + left click at the centre, a touch tap, then a 1-notch scroll down. Like InputEncoder.kt."""
    seq = []
    seq.append(("mouse hover-move 0.5,0.5", input_frame([pointer(KIND_MOUSE, ACT_HOVER_MOVE, 0, 0, 0.5, 0.5)])))
    seq.append(("mouse down (primary) 0.5,0.5", input_frame([pointer(KIND_MOUSE, ACT_DOWN, 0, 1, 0.5, 0.5, 1.0)])))
    seq.append(("mouse up 0.5,0.5", input_frame([pointer(KIND_MOUSE, ACT_UP, 0, 0, 0.5, 0.5)])))
    seq.append(("touch down 0.5,0.5", input_frame([pointer(KIND_TOUCH, ACT_DOWN, 0, 1, 0.5, 0.5, 0.8)])))
    seq.append(("touch move 0.51,0.5", input_frame([pointer(KIND_TOUCH, ACT_MOVE, 0, 1, 0.51, 0.5, 0.8)])))
    seq.append(("touch up 0.51,0.5", input_frame([pointer(KIND_TOUCH, ACT_UP, 0, 0, 0.51, 0.5)])))
    seq.append(("scroll dy=-1 (down)", input_frame([pointer(KIND_SCROLL, ACT_MOVE, 0, 0, 0.0, -1.0)])))
    return seq


# ---------------------------------------------------------------- H.264 Annex-B / SPS


def split_annexb(data):
    """Returns a list of NAL unit payloads (without start codes)."""
    nals = []
    i, n = 0, len(data)
    starts = []
    while i + 3 <= n:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append((i, i + 3))
            i += 3
        else:
            i += 1
    for k, (sc, begin) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else n
        nal = data[begin:end]
        # trailing zero belongs to the next 4-byte start code (00 00 00 01)
        while nal and nal[-1] == 0 and k + 1 < len(starts):
            nal = nal[:-1]
        if nal:
            nals.append(bytes(nal))
    return nals


def starts_with_start_code(data):
    return data[:3] == b"\x00\x00\x01" or data[:4] == b"\x00\x00\x00\x01"


def nal_type(nal):
    return nal[0] & 0x1F


def unescape_rbsp(nal):
    """Removes emulation prevention bytes (00 00 03 -> 00 00)."""
    out = bytearray()
    zeros = 0
    for b in nal:
        if zeros >= 2 and b == 3:
            zeros = 0
            continue
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


class BitReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.pos >> 3
            if byte >= len(self.data):
                raise ValueError("SPS truncated")
            v = (v << 1) | ((self.data[byte] >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def ue(self):
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
            if zeros > 31:
                raise ValueError("bad exp-Golomb code")
        return (1 << zeros) - 1 + self.u(zeros)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)


HIGH_PROFILES = (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)
PROFILE_NAMES = {66: "baseline", 77: "main", 88: "extended", 100: "high", 110: "high10", 122: "high422", 244: "high444"}


def _skip_scaling_list(br, size):
    last, nxt = 8, 8
    for _ in range(size):
        if nxt != 0:
            nxt = (last + br.se() + 256) % 256
        last = last if nxt == 0 else nxt


def parse_sps(nal):
    """Parses an SPS NAL unit (header byte included). Returns dict with width/height (cropping applied)."""
    if nal_type(nal) != 7:
        raise ValueError("not an SPS (nal type %d)" % nal_type(nal))
    br = BitReader(unescape_rbsp(nal[1:]))
    profile_idc = br.u(8)
    constraints = br.u(8)
    level_idc = br.u(8)
    sps_id = br.ue()
    chroma_format_idc = 1
    separate_colour_plane = 0
    bit_depth_luma = bit_depth_chroma = 8
    if profile_idc in HIGH_PROFILES:
        chroma_format_idc = br.ue()
        if chroma_format_idc == 3:
            separate_colour_plane = br.u(1)
        bit_depth_luma = br.ue() + 8
        bit_depth_chroma = br.ue() + 8
        br.u(1)  # qpprime_y_zero_transform_bypass_flag
        if br.u(1):  # seq_scaling_matrix_present_flag
            for i in range(8 if chroma_format_idc != 3 else 12):
                if br.u(1):
                    _skip_scaling_list(br, 16 if i < 6 else 64)
    br.ue()  # log2_max_frame_num_minus4
    poc_type = br.ue()
    if poc_type == 0:
        br.ue()
    elif poc_type == 1:
        br.u(1)
        br.se()
        br.se()
        for _ in range(br.ue()):
            br.se()
    max_ref_frames = br.ue()
    br.u(1)  # gaps_in_frame_num_value_allowed_flag
    w_mbs = br.ue() + 1
    h_map_units = br.ue() + 1
    frame_mbs_only = br.u(1)
    if not frame_mbs_only:
        br.u(1)  # mb_adaptive_frame_field_flag
    br.u(1)  # direct_8x8_inference_flag
    crop = [0, 0, 0, 0]
    if br.u(1):
        crop = [br.ue() for _ in range(4)]  # left, right, top, bottom
    vui = br.u(1)
    width = w_mbs * 16
    height = (2 - frame_mbs_only) * h_map_units * 16
    if chroma_format_idc == 0 or separate_colour_plane:
        cux, cuy = 1, 2 - frame_mbs_only
    else:
        sub_w = 1 if chroma_format_idc == 3 else 2
        sub_h = 2 if chroma_format_idc == 1 else 1
        cux, cuy = sub_w, sub_h * (2 - frame_mbs_only)
    width -= cux * (crop[0] + crop[1])
    height -= cuy * (crop[2] + crop[3])
    return {
        "profile_idc": profile_idc, "profile": PROFILE_NAMES.get(profile_idc, str(profile_idc)),
        "constraint_flags": constraints, "level_idc": level_idc, "level": "%d.%d" % divmod(level_idc, 10),
        "sps_id": sps_id, "chroma_format_idc": chroma_format_idc, "bit_depth_luma": bit_depth_luma,
        "bit_depth_chroma": bit_depth_chroma, "poc_type": poc_type, "max_ref_frames": max_ref_frames,
        "frame_mbs_only": frame_mbs_only, "crop": crop, "vui": vui, "width": width, "height": height,
    }


# ---------------------------------------------------------------- discovery


def discover(seconds, port=UDP_PORT, probe_targets=None, quiet=False):
    """Listens for beacons and sends PLEXI? probes. Returns the list of distinct beacons."""
    # Listener on the beacon port (broadcast beacons) + a separate ephemeral socket for probes, so
    # unicast replies are not swallowed by a host bound to the same port on this machine.
    listen = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    listen.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        try:
            listen.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError:
            pass
    try:
        listen.bind(("", port))
    except OSError as e:
        if not quiet:
            print("note: cannot bind UDP %d (%s); only probe replies will be seen" % (port, e), file=sys.stderr)
        listen.close()
        listen = None
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    probe.bind(("", 0))
    socks = [probe] + ([listen] if listen else [])
    targets = probe_targets or ["255.255.255.255", "127.0.0.1"]
    found = {}
    end = time.monotonic() + seconds
    next_probe = 0.0
    while True:
        t = time.monotonic()
        if t >= end:
            break
        if t >= next_probe:
            for tgt in targets:
                try:
                    probe.sendto(PROBE, (tgt, port))
                except OSError as e:
                    if not quiet:
                        print("probe to %s failed: %s" % (tgt, e), file=sys.stderr)
            next_probe = t + 1.0
        r, _, _ = select.select(socks, [], [], min(0.2, end - t))
        for s in r:
            data, addr = s.recvfrom(65535)
            if not data.startswith(b"{"):
                continue  # our own / another tablet's PLEXI?
            try:
                b = json.loads(data.decode("utf-8"))
            except ValueError:
                if not quiet:
                    print("bad beacon from %s: %r" % (addr, data[:80]), file=sys.stderr)
                continue
            if not isinstance(b, dict) or b.get("svc") != "plexichore":
                continue
            key = (b.get("id"), addr[0])
            if key not in found:
                b["_from"] = "%s:%d" % addr
                b["_via"] = "probe-reply" if s is probe else "beacon"
                found[key] = b
                if not quiet:
                    print("beacon %s -> %s" % (b["_from"], json.dumps(b)))
    for s in socks:
        s.close()
    return list(found.values())


# ---------------------------------------------------------------- session


class Session:
    def __init__(self, args):
        self.a = args
        self.violations = []
        self.warnings = []
        self.events = []
        self.t0 = time.monotonic()
        self.sock = None
        self.reader = FrameReader()
        self.dump = open(args.dump, "wb") if args.dump else None
        # Device profile (decoder caps) this fake tablet announces; scenarios override parts of it.
        self.profile = dict(TAB_S8)
        self.profile.update(getattr(args, "profile_overrides", None) or {})
        self.sps_infos = []  # every SPS seen: {"t", "width", "height", "profile", "config": (w, h)}
        self.video_before_approval = 0
        self.first_idr_t = None
        self.closed_after_bye_ms = None  # host closed the socket this long after our BYE (None = not seen)

        self.configs = []
        self.config = None
        self.pairing = []
        self.awaiting_approval = False
        self.host_bye = None
        self.stats = []
        self.counts = {}
        self.last_rx = time.monotonic()

        # video state
        self.video_msgs = 0
        self.frames = 0  # non-codec-config VIDEO messages (pictures)
        self.idr_count = 0
        self.codec_config_count = 0
        self.video_bytes = 0
        self.first_frame_t = None
        self.last_frame_t = None
        self.arrivals = []
        self.max_gap_ms = 0.0
        self.gaps_over_2x = 0
        self.last_pts = None
        self.equal_pts = 0
        self.nal_hist = {}
        self.sps_info = None
        self.have_sps = self.have_pps = False
        self.expect = "codec-config"  # "codec-config" -> "idr" -> None
        self.expect_since = None
        self.dims_checked = 0

        # pings
        self.ping_sent = 0
        self.rtts = []
        self.host_pings = 0

        # keyframe request
        self.kf_requested_at = None
        self.kf_results = []

        # settings
        self.settings_sent_at = None
        self.settings_result = None
        self.config_before_settings = None

        self.inputs_sent = []

    # -- helpers
    def t(self):
        return round(time.monotonic() - self.t0, 3)

    def log(self, msg):
        if not self.a.quiet:
            print("[%7.3f] %s" % (self.t(), msg), flush=True)

    def violate(self, msg):
        self.violations.append("t=%.3f %s" % (self.t(), msg))
        print("[%7.3f] VIOLATION: %s" % (self.t(), msg), file=sys.stderr, flush=True)

    def warn(self, msg):
        self.warnings.append("t=%.3f %s" % (self.t(), msg))
        self.log("warning: " + msg)

    def send(self, data):
        self.sock.sendall(data)

    # -- HELLO
    def hello(self):
        a = self.a
        portrait = a.orientation == "portrait"
        P = self.profile
        vw, vh = (P["heightPx"], P["widthPx"]) if portrait else (P["widthPx"], P["heightPx"])
        if a.viewport:
            vw, vh = a.viewport
        modes = P["decodeModes"]
        largest = max(modes, key=lambda m: m["width"] * m["height"])
        requested = {
            "mode": a.mode, "monitorIndex": a.monitor, "resolutionScale": a.scale, "fps": a.fps,
            "bitrateKbps": a.bitrate, "quality": a.quality, "codec": "h264", "touchMode": a.touch_mode,
            "position": a.position, "scalePercent": a.scale_percent, "orientation": a.orientation,
        }
        # Key order mirrors Protocol.hello() in the Android app.
        return {
            "protocol": 1, "deviceId": a.device_id, "deviceName": P["deviceName"], "model": P["model"],
            "widthPx": P["widthPx"], "heightPx": P["heightPx"], "densityDpi": P["densityDpi"],
            "refreshHz": P["refreshHz"], "codecs": P["codecs"],
            "maxDecodeWidth": largest["width"], "maxDecodeHeight": largest["height"],
            "decodeModes": modes, "h264Profiles": P["h264Profiles"], "h264MaxLevel": P["h264MaxLevel"],
            "orientation": a.orientation, "viewportWidthPx": vw, "viewportHeightPx": vh,
            "touch": True, "pen": P["pen"], "requested": requested,
        }

    # -- message handlers
    def on_config(self, payload):
        try:
            cfg = json.loads(payload.decode("utf-8"))
        except ValueError as e:
            self.violate("CONFIG is not valid JSON: %s" % e)
            return
        self.log("CONFIG %s" % json.dumps(cfg))
        prev = self.config
        self.config = cfg
        self.configs.append({"t": self.t(), "config": cfg})
        self.awaiting_approval = False
        for k in ("codec", "width", "height", "fps", "mode"):
            if k not in cfg:
                self.violate("CONFIG missing '%s'" % k)
        w, h = cfg.get("width", 0), cfg.get("height", 0)
        if not (isinstance(w, int) and isinstance(h, int)) or w <= 0 or h <= 0 or w % 2 or h % 2:
            self.violate("CONFIG width/height must be positive even ints, got %r x %r" % (w, h))
        if cfg.get("mode") not in ("extend", "primary", "mirror"):
            self.violate("CONFIG mode %r invalid" % cfg.get("mode"))
        elif cfg.get("mode") != self.a.mode and prev is None:
            self.warn("host fell back from %s to %s" % (self.a.mode, cfg.get("mode")))
        if not self._fits_decoder(w, h, cfg.get("fps", 0)):
            self.violate("CONFIG %sx%s@%s exceeds the tablet's decodeModes" % (w, h, cfg.get("fps")))
        if cfg.get("codec", "h264") != "h264":
            self.warn("codec %r: H.264 checks disabled" % cfg.get("codec"))
        # A new size (or the first CONFIG) must be followed by codec-config + IDR.
        if prev is None or (prev.get("width"), prev.get("height")) != (w, h) or prev.get("codec") != cfg.get("codec"):
            self.expect = "codec-config"
            self.expect_since = time.monotonic()
            self.have_sps = self.have_pps = False
        if self.settings_sent_at is not None and self.settings_result is None:
            dt = (time.monotonic() - self.settings_sent_at) * 1000
            self.settings_result = {"config_after_ms": round(dt, 1), "config": cfg, "new_size": prev is None or
                                    (prev.get("width"), prev.get("height")) != (w, h), "idr_after_ms": None}
            self.log("SETTINGS -> new CONFIG after %.0f ms" % dt)

    def _fits_decoder(self, w, h, fps):
        if not isinstance(w, int) or not isinstance(h, int):
            return False
        lo, sh = max(w, h), min(w, h)
        for m in self.profile["decodeModes"]:
            if lo <= max(m["width"], m["height"]) and sh <= min(m["width"], m["height"]) and fps <= m["maxFps"]:
                return True
        return False

    def on_video(self, payload, t_rx):
        if len(payload) < 9:
            self.violate("VIDEO payload too short (%d bytes)" % len(payload))
            return
        pts, flags = struct.unpack_from(">QB", payload, 0)
        data = payload[9:]
        self.video_msgs += 1
        self.video_bytes += len(payload)
        if self.config is None:
            self.violate("VIDEO before CONFIG")
        if self.awaiting_approval:
            self.video_before_approval += 1
            self.violate("VIDEO while PAIRING is waiting for approval")
        if self.dump:
            self.dump.write(data)
        codec = (self.config or {}).get("codec", "h264")
        if codec != "h264":
            self._count_picture(pts, t_rx, flags & FLAG_KEYFRAME)
            return
        if not starts_with_start_code(data):
            self.violate("VIDEO data is not Annex-B (no start code), flags=%d" % flags)
            return
        nals = split_annexb(data)
        types = [nal_type(n) for n in nals]
        for ty in types:
            self.nal_hist[ty] = self.nal_hist.get(ty, 0) + 1
        for n in nals:
            if nal_type(n) == 7:
                self._check_sps(n)
                self.have_sps = True
            elif nal_type(n) == 8:
                self.have_pps = True
        is_cfg = bool(flags & FLAG_CODEC_CONFIG)
        has_idr = 5 in types
        if self.video_msgs <= 3 and not self.a.quiet:
            self.log("VIDEO #%d pts=%d flags=%d nals=%s bytes=%d" % (self.video_msgs, pts, flags, types, len(data)))

        if is_cfg:
            self.codec_config_count += 1
            if 7 not in types or 8 not in types:
                self.violate("codec-config VIDEO without SPS+PPS (nal types %s)" % types)
            if any(ty in (1, 5) for ty in types):
                self.warn("codec-config VIDEO also carries slice data (nal types %s)" % types)
            if self.expect == "codec-config":
                self.expect = "idr"
            return

        # picture frame
        if self.expect == "codec-config":
            if 7 in types and 8 in types and has_idr:
                self.warn("SPS/PPS inline with IDR without codec-config flag")
                self.expect = "idr"
            else:
                self.violate("expected codec-config (flags bit1, SPS+PPS) first, got flags=%d nals=%s" % (flags, types))
                self.expect = "idr"
        if self.expect == "idr":
            if not has_idr:
                self.violate("expected IDR (nal 5) after codec-config, got flags=%d nals=%s" % (flags, types))
            self.expect = None
        if has_idr:
            self.idr_count += 1
            if self.first_idr_t is None:
                self.first_idr_t = self.t()
            if not (flags & FLAG_KEYFRAME):
                self.violate("IDR frame without keyframe flag (flags=%d)" % flags)
            if not (self.have_sps and self.have_pps):
                self.violate("IDR without preceding SPS/PPS")
            if self.kf_requested_at is not None:
                dt = (t_rx - self.kf_requested_at) * 1000
                self.kf_results.append(round(dt, 1))
                self.log("IDR %.1f ms after REQUEST_KEYFRAME" % dt)
                if dt > self.a.keyframe_deadline_ms:
                    self.violate("IDR came %.0f ms after REQUEST_KEYFRAME (> %d ms)" % (dt, self.a.keyframe_deadline_ms))
                self.kf_requested_at = None
            if self.settings_result is not None and self.settings_result.get("idr_after_ms") is None:
                self.settings_result["idr_after_ms"] = round((t_rx - self.settings_sent_at) * 1000, 1)
        elif flags & FLAG_KEYFRAME:
            self.violate("keyframe flag set but no IDR NAL (nals=%s)" % types)
        if not any(ty in (1, 5) for ty in types):
            self.violate("picture VIDEO without slice NAL (nals=%s)" % types)
        self._count_picture(pts, t_rx, has_idr)

    def _count_picture(self, pts, t_rx, key):
        if self.last_pts is not None:
            if pts < self.last_pts:
                self.violate("pts went backwards: %d -> %d" % (self.last_pts, pts))
            elif pts == self.last_pts:
                self.equal_pts += 1
        self.last_pts = pts
        self.frames += 1
        if self.first_frame_t is None:
            self.first_frame_t = t_rx
        if self.last_frame_t is not None:
            gap = (t_rx - self.last_frame_t) * 1000
            fps = (self.config or {}).get("fps") or self.a.fps
            if gap > self.max_gap_ms:
                self.max_gap_ms = gap
            if gap > 2 * 1000.0 / fps:
                self.gaps_over_2x += 1
            if gap > 600:
                self.warn("VIDEO gap %.0f ms (host should send >= 1 frame / 500 ms)" % gap)
        self.last_frame_t = t_rx

    def _check_sps(self, nal):
        try:
            info = parse_sps(nal)
        except ValueError as e:
            self.violate("SPS parse error: %s" % e)
            return
        self.sps_info = info
        cfg = self.config or {}
        self.sps_infos.append({"t": self.t(), "width": info["width"], "height": info["height"],
                               "profile": info["profile"], "profile_idc": info["profile_idc"],
                               "config": (cfg.get("width"), cfg.get("height"))})
        if cfg and (info["width"], info["height"]) != (cfg.get("width"), cfg.get("height")):
            self.violate("SPS size %dx%d != CONFIG %sx%s" % (info["width"], info["height"], cfg.get("width"), cfg.get("height")))
        else:
            self.dims_checked += 1
        allowed = {"baseline": (66,), "main": (77,), "high": (100,)}
        ok_idc = set()
        for name in self.profile["h264Profiles"] or ["high", "main", "baseline"]:
            ok_idc.update(allowed.get(name.lower(), ()))
        if info["profile_idc"] not in ok_idc:  # PROTOCOL.md: Main/Baseline when h264Profiles lacks "high"
            self.violate("SPS profile %s not in HELLO h264Profiles %s" % (info["profile"], self.profile["h264Profiles"]))
        lvl = self.profile.get("h264MaxLevel") or ""
        try:
            max_level = int(round(float(lvl) * 10))
        except ValueError:
            max_level = None
        if max_level is not None and info["level_idc"] > max_level:
            self.warn("SPS level %s above h264MaxLevel %s" % (info["level"], lvl))

    def handle(self, t, payload, t_rx):
        name = TYPE_NAMES.get(t, "0x%02X" % t)
        self.counts[name] = self.counts.get(name, 0) + 1
        if t == VIDEO:
            self.on_video(payload, t_rx)
        elif t == CONFIG:
            self.on_config(payload)
        elif t == PING:
            self.host_pings += 1
            if len(payload) != 8:
                self.violate("PING payload must be 8 bytes, got %d" % len(payload))
            self.send(frame(PONG, payload))
        elif t == PONG:
            if len(payload) >= 8:
                sent = struct.unpack(">Q", payload[:8])[0]
                rtt = (now_us() - sent) / 1000.0
                if 0 <= rtt < 60000:
                    self.rtts.append(rtt)
                else:
                    self.violate("PONG does not echo our PING payload")
            else:
                self.violate("PONG payload %d bytes" % len(payload))
        elif t == STATS:
            try:
                st = json.loads(payload.decode("utf-8"))
                self.stats.append(st)
                if self.a.verbose:
                    self.log("STATS %s" % json.dumps(st))
            except ValueError:
                self.violate("STATS is not JSON")
        elif t == PAIRING:
            try:
                p = json.loads(payload.decode("utf-8"))
            except ValueError:
                self.violate("PAIRING is not JSON")
                return
            self.pairing.append(p)
            st = p.get("status")
            if st == "waiting":
                self.awaiting_approval = True
                print("PAIRING: waiting for approval on the host, code %s" % p.get("code"), flush=True)
            elif st == "approved":
                self.awaiting_approval = False
                self.log("PAIRING approved")
            elif st == "rejected":
                self.log("PAIRING rejected")
                raise SessionEnd("rejected")
            else:
                self.violate("PAIRING unknown status %r" % st)
        elif t == BYE:
            self.host_bye = payload.decode("utf-8", "replace")
            self.log("host BYE: %r" % self.host_bye)
            raise SessionEnd("host-bye")
        elif t in (HELLO, INPUT, KEY, REQUEST_KEYFRAME, SETTINGS):
            self.violate("host sent tablet->host message %s" % name)
        else:
            self.warn("unknown message type 0x%02X (%d bytes) skipped" % (t, len(payload)))

    # -- main loop
    def run(self):
        a = self.a
        try:
            self.sock = socket.create_connection((a.host, a.port), timeout=5)
        except OSError as e:
            print("cannot connect to %s:%d: %s" % (a.host, a.port, e), file=sys.stderr)
            return "connect-failed"
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 << 20)
        self.sock.settimeout(2.0)
        self.log("connected to %s:%d" % (a.host, a.port))
        hello = self.hello()
        self.log("HELLO %s" % json.dumps(hello))
        self.sock.settimeout(2.0)
        self.send(frame(HELLO, hello))
        self.sock.settimeout(2.0)

        start = time.monotonic()
        streaming_start = None
        next_ping = start + 1.0
        kf_done = settings_done = input_done = False
        input_queue = []
        end_reason = "time"
        self.last_rx = start
        try:
            while True:
                tnow = time.monotonic()
                if self.config is not None and streaming_start is None:
                    streaming_start = tnow
                # session time counts from the first CONFIG (pairing wait excluded)
                if streaming_start is not None and tnow - streaming_start >= a.seconds:
                    break
                if streaming_start is None and not self.awaiting_approval and tnow - start > 10:
                    self.violate("no CONFIG within 10 s of HELLO")
                    end_reason = "no-config"
                    break
                if self.awaiting_approval and tnow - start > a.approval_timeout:
                    end_reason = "approval-timeout"
                    break
                if tnow - self.last_rx > 5 and not self.awaiting_approval:
                    self.violate("no message from host for 5 s (dead connection)")
                    end_reason = "dead"
                    break
                if tnow >= next_ping:
                    self.send(frame(PING, struct.pack(">Q", now_us())))
                    self.ping_sent += 1
                    next_ping += 1.0
                if streaming_start is not None:
                    el = tnow - streaming_start
                    if a.request_keyframe is not None and not kf_done and el >= a.request_keyframe:
                        kf_done = True
                        self.log("-> REQUEST_KEYFRAME")
                        self.kf_requested_at = time.monotonic()
                        self.send(frame(REQUEST_KEYFRAME))
                    if a.send_input and not input_done and el >= a.input_at:
                        input_done = True  # queue the events 30 ms apart without blocking the reader
                        input_queue = [(tnow + 0.03 * i, d, fr) for i, (d, fr) in enumerate(demo_input_frames())]
                    while input_queue and input_queue[0][0] <= tnow:
                        _, desc, fr = input_queue.pop(0)
                        self.log("-> INPUT %s" % desc)
                        self.send(fr)
                        self.inputs_sent.append(desc)
                    if a.settings and not settings_done and el >= a.settings_at:
                        settings_done = True
                        self.log("-> SETTINGS %s" % a.settings)
                        self.config_before_settings = self.config
                        self.settings_sent_at = time.monotonic()
                        self.send(frame(SETTINGS, json.loads(a.settings)))
                    if self.kf_requested_at is not None and (tnow - self.kf_requested_at) * 1000 > a.keyframe_deadline_ms:
                        self.violate("no IDR within %d ms of REQUEST_KEYFRAME" % a.keyframe_deadline_ms)
                        self.kf_results.append(None)
                        self.kf_requested_at = None
                r, _, _ = select.select([self.sock], [], [], 0.02)
                if not r:
                    continue
                try:
                    data = self.sock.recv(1 << 20)
                except BlockingIOError:
                    continue
                if not data:
                    self.violate("host closed the connection without BYE")
                    end_reason = "eof"
                    break
                t_rx = time.monotonic()
                self.last_rx = t_rx
                self.reader.feed(data)
                for t, payload in self.reader.frames():
                    self.handle(t, payload, t_rx)
        except SessionEnd as e:
            end_reason = str(e)
        except ValueError as e:
            self.violate("framing error: %s" % e)
            end_reason = "framing"
        except ConnectionResetError:
            self.violate("host closed the connection without BYE (reset)")
            end_reason = "eof"
        except OSError as e:
            self.violate("socket error: %s" % e)
            end_reason = "socket-error"
        if self.kf_requested_at is not None:
            self.violate("no IDR after REQUEST_KEYFRAME before the session ended")
            self.kf_results.append(None)
        if self.settings_sent_at is not None:
            if self.settings_result is None:
                self.violate("no CONFIG after SETTINGS")
            elif self.settings_result["new_size"] and self.settings_result["idr_after_ms"] is None:
                self.violate("no codec-config + IDR after the post-SETTINGS CONFIG with a new size")
        if end_reason not in ("host-bye", "eof", "rejected") and not getattr(a, "abrupt_close", False):
            try:
                self.sock.settimeout(0.3)
                self.send(frame(BYE, "faketablet done"))
                self._await_close_after_bye(getattr(a, "bye_wait", 0.0))
            except OSError:
                pass
        try:
            self.sock.close()
        except OSError:
            pass
        if self.dump:
            self.dump.close()
        return end_reason

    def _await_close_after_bye(self, seconds):
        """After our BYE the host should close the socket (PROTOCOL.md: "BYE ... Then close")."""
        if seconds <= 0:
            return
        sent = time.monotonic()
        end = sent + seconds
        while time.monotonic() < end:
            r, _, _ = select.select([self.sock], [], [], 0.05)
            if not r:
                continue
            try:
                data = self.sock.recv(1 << 20)
            except (BlockingIOError, socket.timeout):
                continue
            except OSError:
                data = b""
            if not data:
                self.closed_after_bye_ms = round((time.monotonic() - sent) * 1000, 1)
                return

    def summary(self, end_reason):
        dur = (self.last_frame_t - self.first_frame_t) if self.frames > 1 else 0.0
        out = {
            "host": "%s:%d" % (self.a.host, self.a.port),
            "endReason": end_reason,
            "ok": not self.violations and end_reason not in ("connect-failed", "rejected", "approval-timeout"),
            "requested": {"mode": self.a.mode, "fps": self.a.fps, "orientation": self.a.orientation},
            "pairing": self.pairing,
            "configs": self.configs,
            "messages": self.counts,
            "video": {
                "messages": self.video_msgs, "frames": self.frames, "idrFrames": self.idr_count,
                "codecConfigFrames": self.codec_config_count,
                "fps": round((self.frames - 1) / dur, 2) if dur > 0 else 0,
                "bitrateKbps": round(self.video_bytes * 8 / dur / 1000, 1) if dur > 0 else 0,
                "bytes": self.video_bytes,
                "maxGapMs": round(self.max_gap_ms, 1), "gapsOver2xInterval": self.gaps_over_2x,
                "equalPts": self.equal_pts,
                "nalTypes": {str(k): v for k, v in sorted(self.nal_hist.items())},
                "sps": self.sps_info, "spsSizeMatchesConfig": self.dims_checked,
            },
            "rttMs": {
                "pingsSent": self.ping_sent, "pongs": len(self.rtts),
                "min": round(min(self.rtts), 2) if self.rtts else None,
                "avg": round(sum(self.rtts) / len(self.rtts), 2) if self.rtts else None,
                "max": round(max(self.rtts), 2) if self.rtts else None,
            },
            "hostPingsEchoed": self.host_pings,
            "lastStats": self.stats[-1] if self.stats else None,
            "keyframeRequestMs": self.kf_results,
            "settings": self.settings_result,
            "inputsSent": self.inputs_sent,
            "hostBye": self.host_bye,
            "closedAfterByeMs": self.closed_after_bye_ms,
            "firstIdrT": self.first_idr_t,
            "spsSeen": self.sps_infos,
            "profile": {k: self.profile[k] for k in ("decodeModes", "h264Profiles", "h264MaxLevel")},
            "warnings": self.warnings,
            "violations": self.violations,
        }
        return out


class SessionEnd(Exception):
    pass


def ffmpeg_check(path):
    ff = shutil.which("ffmpeg")
    if not ff:
        return {"ffmpeg": None, "note": "ffmpeg not installed; SPS was parsed instead"}
    p = subprocess.run([ff, "-v", "error", "-i", path, "-f", "null", "-"], capture_output=True, text=True)
    errs = p.stderr.strip().splitlines()
    return {"ffmpeg": ff, "exitCode": p.returncode, "errors": errs[:20]}


# ---------------------------------------------------------------- scripted end-to-end scenarios

SCENARIOS = ["extend", "primary", "mirror", "portrait", "rotate-midstream", "decoder-clamp", "reconnect", "pairing"]
PASS, WARN, FAIL = "PASS", "WARN", "FAIL"
LINKS = ("usb-cable", "usb-wireless-adb", "usb-tether", "wifi")
# Violations about the H.264 codec-config / IDR ordering (reported by their own check).
H264_WORDS = ("codec-config", "IDR", "SPS+PPS", "SPS/PPS", "keyframe flag", "Annex-B", "slice NAL")

# Decoder of a budget tablet: nothing above 1080p, 60 fps above 720p, no High profile.
CLAMP_PROFILE = {
    "decodeModes": [{"width": 1920, "height": 1080, "maxFps": 60}, {"width": 1280, "height": 720, "maxFps": 120}],
    "h264Profiles": ["main", "baseline"],
    "h264MaxLevel": "4.1",
}


class Checks:
    """Collects (scenario, check, status, detail) rows."""

    def __init__(self, scenario):
        self.scenario = scenario
        self.rows = []

    def add(self, name, status, detail=""):
        self.rows.append({"scenario": self.scenario, "check": name, "status": status, "detail": str(detail)})
        return status

    def ok(self, name, cond, detail="", fail=FAIL):
        return self.add(name, PASS if cond else fail, detail)

    @property
    def failed(self):
        return any(r["status"] == FAIL for r in self.rows)


def scenario_args(base, **kw):
    """Session args for a scenario: the user's connection options + scenario overrides."""
    argv = ["--host", base.host, "--port", str(base.port), "--quiet", "--seconds", str(base.scenario_seconds),
            "--approval-timeout", str(base.approval_timeout)]
    a = parse_args(argv)
    a.bye_wait = 2.0
    a.device_id = base.device_id
    for k, v in kw.items():
        setattr(a, k, v)
    return a


def run_session(a):
    s = Session(a)
    reason = s.run()
    return s, s.summary(reason)


def check_config_fields(ck, cfg):
    problems = []
    types = {"codec": str, "width": int, "height": int, "fps": int, "bitrateKbps": int, "mode": str,
             "hostName": str, "hostOs": str, "monitors": list, "virtualDisplayAvailable": bool}
    for k, ty in types.items():
        if k not in cfg:
            problems.append("missing %s" % k)
        elif not isinstance(cfg[k], ty) or (ty is int and isinstance(cfg[k], bool)):
            problems.append("%s is %s" % (k, type(cfg[k]).__name__))
    if cfg.get("codec") not in ("h264", "mjpeg"):
        problems.append("codec %r" % cfg.get("codec"))
    if cfg.get("hostOs") not in ("windows", "macos"):
        problems.append("hostOs %r" % cfg.get("hostOs"))
    if cfg.get("mode") not in ("extend", "primary", "mirror"):
        problems.append("mode %r" % cfg.get("mode"))
    w, h = cfg.get("width"), cfg.get("height")
    if isinstance(w, int) and isinstance(h, int) and (w <= 0 or h <= 0 or w % 2 or h % 2):
        problems.append("size %sx%s not positive even" % (w, h))
    if isinstance(cfg.get("fps"), int) and not 1 <= cfg["fps"] <= 240:
        problems.append("fps %s" % cfg["fps"])
    for m in cfg.get("monitors") or []:
        if not isinstance(m, dict) or not {"index", "name", "width", "height"} <= set(m):
            problems.append("monitor entry %r" % (m,))
            break
    sp = cfg.get("scalePercent")
    if sp is not None and (not isinstance(sp, int) or not (sp == 0 or 100 <= sp <= 300)):
        problems.append("scalePercent %r" % sp)
    if "link" in cfg and cfg["link"] not in LINKS:
        problems.append("link %r" % cfg["link"])
    if "encoder" in cfg and not isinstance(cfg["encoder"], str):
        problems.append("encoder %r" % cfg["encoder"])
    ck.ok("CONFIG fields", not problems, "; ".join(problems) or
          "%sx%s@%s %s host=%s/%s link=%s scale=%s" % (w, h, cfg.get("fps"), cfg.get("codec"), cfg.get("hostName"),
                                                        cfg.get("hostOs"), cfg.get("link", "-"), cfg.get("scalePercent", "-")))


def common_checks(ck, s, summ, a, expect_mode=None, min_fps=1.5, bye=True):
    """Checks every streaming scenario shares. Returns the first CONFIG (or None)."""
    if summ["endReason"] == "connect-failed":
        ck.add("connect", FAIL, "cannot connect to %s" % summ["host"])
        return None
    if summ["endReason"] in ("rejected", "approval-timeout"):
        ck.add("connect", FAIL, "pairing %s (approve the tablet on the host, or use USB/loopback)" % summ["endReason"])
        return None
    if not summ["configs"]:
        ck.add("CONFIG received", FAIL, "no CONFIG (end: %s)" % summ["endReason"])
        return None
    cfg = summ["configs"][0]["config"]
    ck.add("CONFIG received", PASS, "after %.0f ms" % (summ["configs"][0]["t"] * 1000))
    check_config_fields(ck, cfg)
    if expect_mode:
        if cfg.get("mode") == expect_mode:
            ck.add("CONFIG mode", PASS, expect_mode)
        elif cfg.get("mode") == "mirror" and cfg.get("virtualDisplayAvailable") is False:
            ck.add("CONFIG mode", WARN, "fell back to mirror (virtualDisplayAvailable=false)")
        else:
            ck.add("CONFIG mode", FAIL, "asked %s, got %s" % (expect_mode, cfg.get("mode")))
    v = summ["video"]
    h264v = [x for x in s.violations if any(w in x for w in H264_WORDS)]
    if cfg.get("codec") == "h264":
        ck.ok("SPS/PPS (flags bit1) before IDR", v["codecConfigFrames"] >= 1 and v["idrFrames"] >= 1 and not h264v,
              "; ".join(h264v[:3]) or "codec-config=%d idr=%d" % (v["codecConfigFrames"], v["idrFrames"]))
        size_v = [x for x in s.violations if "SPS size" in x or "SPS profile" in x or "SPS parse" in x]
        ck.ok("SPS matches CONFIG", v["spsSizeMatchesConfig"] >= 1 and not size_v,
              "; ".join(size_v[:2]) or ("SPS %sx%s %s level %s" % (v["sps"]["width"], v["sps"]["height"], v["sps"]["profile"],
                                                                   v["sps"]["level"]) if v["sps"] else "no SPS"))
    else:
        ck.add("SPS/PPS (flags bit1) before IDR", WARN, "codec %s: H.264 checks skipped" % cfg.get("codec"))
    last_fps = summ["configs"][-1]["config"].get("fps") or a.fps
    if v["frames"] < 2:
        ck.add("frame rate", FAIL, "%d frames" % v["frames"])
    elif v["fps"] > last_fps * 1.25 + 2:
        ck.add("frame rate", FAIL, "%.1f fps > CONFIG fps %s" % (v["fps"], last_fps))
    elif v["maxGapMs"] > 1000:
        ck.add("frame rate", FAIL, "gap %.0f ms (host must send >= 1 frame / 500 ms)" % v["maxGapMs"])
    elif v["fps"] < min_fps or v["maxGapMs"] > 600:
        ck.add("frame rate", WARN, "%.1f fps, max gap %.0f ms (static screen?)" % (v["fps"], v["maxGapMs"]))
    else:
        ck.add("frame rate", PASS, "%.1f fps (CONFIG %s), max gap %.0f ms, %d stutters" %
               (v["fps"], last_fps, v["maxGapMs"], v["gapsOver2xInterval"]))
    r = summ["rttMs"]
    pong_v = [x for x in s.violations if "PONG" in x]
    ck.ok("PONG", r["pongs"] >= 1 and not pong_v,
          "; ".join(pong_v) or "%d/%d pings answered, rtt avg %s ms" % (r["pongs"], r["pingsSent"], r["avg"]))
    if summ["hostPingsEchoed"] == 0:
        ck.add("host PING", WARN, "host sent no PING")
    if bye:
        if summ["endReason"] != "time":
            ck.add("clean BYE", FAIL, "session ended early: %s %s" % (summ["endReason"], summ["hostBye"] or ""))
        elif summ["closedAfterByeMs"] is None:
            ck.add("clean BYE", WARN, "host did not close the socket within 2 s of our BYE")
        else:
            ck.add("clean BYE", PASS, "host closed %.0f ms after BYE" % summ["closedAfterByeMs"])
    known = set(h264v) | set(pong_v) | {x for x in s.violations if "SPS" in x}
    other = [x for x in s.violations if x not in known]
    ck.ok("no other violations", not other, "; ".join(other[:3]) + (" (+%d)" % (len(other) - 3) if len(other) > 3 else ""))
    return cfg


def sc_mode(base, mode):
    ck = Checks(mode)
    a = scenario_args(base, mode=mode)
    s, summ = run_session(a)
    cfg = common_checks(ck, s, summ, a, expect_mode=mode)
    if cfg:
        sp = cfg.get("scalePercent")
        if cfg.get("mode") == "mirror":
            ck.ok("mirror: landscape, no scale", cfg["width"] >= cfg["height"] and not sp,
                  "%sx%s scalePercent=%s" % (cfg["width"], cfg["height"], sp))
        else:
            ck.ok("scalePercent applied", isinstance(sp, int) and 100 <= sp <= 300, "scalePercent=%s" % sp, fail=WARN)
            ck.ok("landscape stream", cfg["width"] > cfg["height"], "%sx%s" % (cfg["width"], cfg["height"]))
    return ck, [summ]


def sc_portrait(base):
    ck = Checks("portrait")
    a = scenario_args(base, mode="extend", orientation="portrait")
    s, summ = run_session(a)
    cfg = common_checks(ck, s, summ, a, expect_mode="extend")
    if cfg:
        ck.ok("portrait CONFIG (height > width)", cfg["height"] > cfg["width"],
              "%sx%s%s" % (cfg["width"], cfg["height"], "" if cfg["height"] > cfg["width"] else
                           " (protocol allows landscape when no portrait mode exists)"), fail=WARN)
    return ck, [summ]


def sc_rotate(base):
    ck = Checks("rotate-midstream")
    at = min(2.0, base.scenario_seconds / 2)
    a = scenario_args(base, mode="extend", settings='{"orientation":"portrait"}', settings_at=at,
                      seconds=max(base.scenario_seconds, at + 2.5))
    s, summ = run_session(a)
    cfg = common_checks(ck, s, summ, a, expect_mode="extend")
    if cfg:
        res = summ["settings"]
        if not res:
            ck.add("new CONFIG after SETTINGS", FAIL, "none")
        else:
            new = res["config"]
            ck.add("new CONFIG after SETTINGS", PASS, "%sx%s after %.0f ms" % (new["width"], new["height"], res["config_after_ms"]))
            ck.ok("rotated to portrait", new["height"] > new["width"], "%sx%s" % (new["width"], new["height"]), fail=WARN)
            if res["new_size"]:
                ck.ok("codec-config + IDR at new size", res["idr_after_ms"] is not None,
                      "IDR %s ms after SETTINGS" % res["idr_after_ms"])
                last = summ["spsSeen"][-1] if summ["spsSeen"] else None
                ck.ok("SPS follows new size", last is not None and (last["width"], last["height"]) == (new["width"], new["height"]),
                      "last SPS %s" % ("%sx%s" % (last["width"], last["height"]) if last else "none"))
    return ck, [summ]


def sc_clamp(base):
    ck = Checks("decoder-clamp")
    a = scenario_args(base, mode="extend", fps=120, profile_overrides=CLAMP_PROFILE)
    s, summ = run_session(a)
    cfg = common_checks(ck, s, summ, a, expect_mode="extend")
    if cfg:
        w, h, fps = cfg["width"], cfg["height"], cfg["fps"]
        fits = s._fits_decoder(w, h, fps)
        ck.ok("CONFIG within decodeModes", fits and max(w, h) <= 1920 and min(w, h) <= 1080,
              "%sx%s@%s vs %s" % (w, h, fps, ",".join("%dx%d@%d" % (m["width"], m["height"], m["maxFps"])
                                                    for m in CLAMP_PROFILE["decodeModes"])))
        sps = summ["video"]["sps"]
        ck.ok("H.264 profile not High", sps is not None and sps["profile_idc"] in (66, 77),
              "SPS profile %s (tablet lists %s)" % (sps["profile"] if sps else "none", CLAMP_PROFILE["h264Profiles"]))
    return ck, [summ]


def sc_reconnect(base):
    ck = Checks("reconnect")
    summaries = []
    secs = max(1.5, base.scenario_seconds / 2)
    plan = [("1st (ends with BYE)", False), ("2nd (dropped without BYE)", True), ("3rd (after drop)", False)]
    for i, (label, abrupt) in enumerate(plan):
        a = scenario_args(base, mode="extend", seconds=secs, abrupt_close=abrupt)
        t = time.monotonic()
        s, summ = run_session(a)
        summaries.append(summ)
        if not summ["configs"]:
            ck.add("session " + label, FAIL, "no CONFIG (end: %s)" % summ["endReason"])
            continue
        cfg_ms = summ["configs"][0]["t"] * 1000
        idr = summ["firstIdrT"]
        good = idr is not None and not s.violations
        ck.ok("session " + label, good, "CONFIG %.0f ms, first IDR %s ms, %.1f fps%s" %
              (cfg_ms, "%.0f" % (idr * 1000) if idr is not None else "none", summ["video"]["fps"],
               "; " + s.violations[0] if s.violations else ""))
        if i == 0 and summ["closedAfterByeMs"] is None:
            ck.add("clean BYE", WARN, "host did not close within 2 s of BYE")
        if abrupt:
            time.sleep(0.5)  # host notices the drop (EOF) right away; reconnect like the tablet does
        else:
            time.sleep(0.2)
        del t
    return ck, summaries


def sc_pairing(base):
    ck = Checks("pairing")
    a = scenario_args(base, mode="extend", device_id=str(uuid.uuid4()), seconds=min(base.scenario_seconds, 3.0))
    print("pairing: connecting to %s:%d as a NEW device; approve on the host if it asks (code is printed)" %
          (base.host, base.port), flush=True)
    s, summ = run_session(a)
    p = summ["pairing"]
    if summ["endReason"] == "connect-failed":
        ck.add("connect", FAIL, "cannot connect")
        return ck, [summ]
    if not p:
        loop = base.host.startswith("127.") or base.host in ("localhost", "::1")
        ck.add("PAIRING", PASS if loop else WARN,
               "no PAIRING: auto-approved" + (" (loopback/USB)" if loop else " (unknown Wi-Fi device was NOT asked to pair)"))
    else:
        statuses = [x.get("status") for x in p]
        codes = {x.get("code") for x in p}
        ck.ok("PAIRING messages", all(st in ("waiting", "approved", "rejected") for st in statuses) and statuses[0] == "waiting",
              "statuses %s" % statuses)
        code = p[0].get("code")
        ck.ok("PAIRING code", isinstance(code, str) and len(code) == 4 and code.isdigit() and len(codes) == 1,
              "code %r" % code)
        if statuses[-1] == "rejected":
            ck.add("approved", WARN, "rejected on the host")
            return ck, [summ]
        ck.ok("approved before CONFIG", "approved" in statuses and summ["configs"], "statuses %s" % statuses)
        ck.ok("no VIDEO while waiting", s.video_before_approval == 0, "%d frames" % s.video_before_approval)
    if summ["configs"]:
        common_checks(ck, s, summ, a, expect_mode=None)
    elif summ["endReason"] == "approval-timeout":
        ck.add("approved", FAIL, "not approved within %ss" % base.approval_timeout)
    return ck, [summ]


def run_scenarios(base, names):
    funcs = {
        "extend": lambda: sc_mode(base, "extend"), "primary": lambda: sc_mode(base, "primary"),
        "mirror": lambda: sc_mode(base, "mirror"), "portrait": lambda: sc_portrait(base),
        "rotate-midstream": lambda: sc_rotate(base), "decoder-clamp": lambda: sc_clamp(base),
        "reconnect": lambda: sc_reconnect(base), "pairing": lambda: sc_pairing(base),
    }
    rows, details = [], {}
    for n in names:
        if not base.quiet:
            print("== scenario %s" % n, flush=True)
        try:
            ck, summ = funcs[n]()
        except Exception as e:  # a crash in one scenario must not hide the others
            ck, summ = Checks(n), []
            ck.add("scenario ran", FAIL, "%s: %s" % (type(e).__name__, e))
        rows += ck.rows
        details[n] = summ
        time.sleep(0.3)  # let the host tear the previous session down (virtual display release)
    return rows, details


def print_table(rows, out=sys.stdout):
    cols = [("scenario", 16), ("check", 32), ("status", 6), ("detail", 0)]
    width = {k: max([w, len(k)] + [len(r[k]) for r in rows]) if w else 0 for k, w in cols}
    width = {k: min(v, 34) if k != "detail" else 0 for k, v in width.items()}
    line = "+-" + "-+-".join("-" * width[k] for k, _ in cols[:-1]) + "-+-" + "-" * 60
    out.write(line + "\n")
    out.write("| " + " | ".join(k.upper().ljust(width[k]) for k, _ in cols[:-1]) + " | DETAIL\n")
    out.write(line + "\n")
    prev = None
    for r in rows:
        sc = r["scenario"] if r["scenario"] != prev else ""
        prev = r["scenario"]
        out.write("| " + " | ".join([sc.ljust(width["scenario"]), r["check"][:34].ljust(width["check"]),
                                     r["status"].ljust(width["status"])]) + " | " + r["detail"] + "\n")
    out.write(line + "\n")
    n = {st: sum(1 for r in rows if r["status"] == st) for st in (PASS, WARN, FAIL)}
    bad = sorted({r["scenario"] for r in rows if r["status"] == FAIL})
    out.write("%d checks: %d PASS, %d WARN, %d FAIL%s\n" % (len(rows), n[PASS], n[WARN], n[FAIL],
                                                           (" -- failing: " + ", ".join(bad)) if bad else ""))


def scenario_main(a):
    names = []
    for item in a.scenario:
        for n in item.split(","):
            n = n.strip()
            if n == "all":
                names += SCENARIOS
            elif n in SCENARIOS:
                names.append(n)
            else:
                print("unknown scenario %r (choose from %s, all)" % (n, ", ".join(SCENARIOS)), file=sys.stderr)
                return 2
    names = list(dict.fromkeys(names))
    rows, details = run_scenarios(a, names)
    print_table(rows)
    if a.summary:
        with open(a.summary, "w") as f:
            json.dump({"rows": rows, "sessions": details}, f, indent=2, default=str)
    if rows and all(r["check"] == "connect" and r["status"] == FAIL for r in rows if r["check"] == "connect") and \
            any(r["check"] == "connect" for r in rows) and all(
                any(r["check"] == "connect" and r["scenario"] == n for r in rows) for n in names):
        return 2
    return 1 if any(r["status"] == FAIL for r in rows) else 0


# ---------------------------------------------------------------- self-test (no real host involved)


def self_test(a):
    """Runs the scenarios against in-process fake hosts on random high ports (never 47800): a correct host must
    pass every check, and each deliberately broken host must trip the check that guards that behaviour."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import mock_host  # noqa: E402  (imports this module; only needed here)

    results = []

    def run(label, flaws, scenarios, pairing=False, expect_fail=None):
        port, stop = mock_host.start_scripted_host(flaws=flaws, pairing=pairing)
        assert port not in (TCP_PORT, UDP_PORT)
        base = argparse.Namespace(**vars(a))
        base.host, base.port, base.quiet = "127.0.0.1", port, True
        try:
            rows, _ = run_scenarios(base, scenarios)
        finally:
            stop()
        fails = [(r["scenario"], r["check"]) for r in rows if r["status"] == FAIL]
        if expect_fail is None:
            ok = not fails
            detail = "all %d checks pass" % len(rows) if ok else "unexpected FAIL: %s" % fails
        else:
            ok = expect_fail in fails
            detail = ("detected (%s / %s FAIL)" % expect_fail) if ok else "NOT detected; fails were %s" % fails
        results.append({"scenario": "self-test", "check": label, "status": PASS if ok else FAIL, "detail": detail})
        if not a.quiet:
            print("self-test %-34s %s  %s" % (label, PASS if ok else FAIL, detail), flush=True)

    run("correct host passes all", (), SCENARIOS)
    run("correct host with pairing", (), ["pairing"], pairing=True)
    run("detects missing codec-config", ("no-codec-config",), ["extend"],
        expect_fail=("extend", "SPS/PPS (flags bit1) before IDR"))
    run("detects ignored decodeModes", ("ignore-decoder",), ["decoder-clamp"],
        expect_fail=("decoder-clamp", "CONFIG within decodeModes"))
    run("detects High profile to Main-only", ("ignore-decoder",), ["decoder-clamp"],
        expect_fail=("decoder-clamp", "H.264 profile not High"))
    run("detects missing PONG", ("no-pong",), ["mirror"], expect_fail=("mirror", "PONG"))
    run("detects ignored rotation", ("ignore-rotate",), ["rotate-midstream"],
        expect_fail=("rotate-midstream", "new CONFIG after SETTINGS"))
    print_table(results)
    return 0 if all(r["status"] == PASS for r in results) else 1


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Headless fake tablet for PlexiChore hosts (protocol v1).")
    p.add_argument("--discover", action="store_true", help="listen for UDP beacons + send PLEXI? probes, then exit")
    p.add_argument("--discover-seconds", type=float, default=4.0)
    p.add_argument("--discovery-port", type=int, default=UDP_PORT)
    p.add_argument("--probe", action="append", help="unicast PLEXI? target (repeatable); default broadcast + 127.0.0.1")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=TCP_PORT)
    p.add_argument("--mode", choices=["extend", "primary", "mirror"], default="extend")
    p.add_argument("--fps", type=int, choices=[30, 60, 90, 120], default=60)
    p.add_argument("--bitrate", type=int, default=20000, help="requested bitrateKbps")
    p.add_argument("--scale", type=float, default=1.0, help="requested resolutionScale 0.5..1.0")
    p.add_argument("--scale-percent", type=int, default=0, help="requested scalePercent (0 = auto)")
    p.add_argument("--quality", choices=["performance", "balanced", "quality"], default="balanced")
    p.add_argument("--touch-mode", choices=["touch", "mouse", "none"], default="touch")
    p.add_argument("--position", choices=["right", "left", "top", "bottom"], default="right")
    p.add_argument("--monitor", type=int, default=0, help="mirror: host monitor index")
    p.add_argument("--orientation", choices=["landscape", "portrait"], default="landscape")
    p.add_argument("--viewport", type=lambda s: tuple(int(v) for v in s.lower().split("x")), help="WxH viewport")
    p.add_argument("--device-id", default=None, help="stable deviceId (default: random uuid4 per run)")
    p.add_argument("--seconds", type=float, default=10.0, help="stream duration after the first CONFIG")
    p.add_argument("--approval-timeout", type=float, default=120.0)
    p.add_argument("--dump", help="write the raw Annex-B stream here (e.g. out.h264)")
    p.add_argument("--send-input", action="store_true", help="send mouse click/touch tap at centre + a scroll")
    p.add_argument("--input-at", type=float, default=2.0, help="seconds after CONFIG to send input")
    p.add_argument("--settings", help="JSON sent as SETTINGS, e.g. '{\"orientation\":\"portrait\"}'")
    p.add_argument("--settings-at", type=float, default=3.0, help="seconds after CONFIG to send SETTINGS")
    p.add_argument("--request-keyframe", type=float, nargs="?", const=2.0, default=None, metavar="SEC",
                   help="send REQUEST_KEYFRAME SEC seconds after CONFIG (default 2) and expect an IDR")
    p.add_argument("--keyframe-deadline-ms", type=int, default=500)
    p.add_argument("--summary", help="also write the JSON summary to this file")
    p.add_argument("--scenario", action="append", metavar="NAME",
                   help="scripted checks: %s or all (repeatable / comma separated); prints a table" % "|".join(SCENARIOS))
    p.add_argument("--scenario-seconds", type=float, default=4.0, help="stream time per scenario session")
    p.add_argument("--self-test", action="store_true",
                   help="run the scenarios against in-process fake hosts on random ports (no real host needed)")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--verbose", action="store_true", help="print STATS too")
    a = p.parse_args(argv)
    if a.settings:
        try:
            if not isinstance(json.loads(a.settings), dict):
                raise ValueError
        except ValueError:
            p.error("--settings must be a JSON object")
    if not a.device_id:
        a.device_id = str(uuid.uuid4())
    return a


def main(argv=None):
    a = parse_args(argv)
    if a.self_test:
        return self_test(a)
    if a.scenario:
        return scenario_main(a)
    if a.discover:
        found = discover(a.discover_seconds, a.discovery_port, a.probe, a.quiet)
        print(json.dumps({"beacons": found}, indent=2))
        return 0 if found else 1
    s = Session(a)
    reason = s.run()
    out = s.summary(reason)
    if a.dump and os.path.exists(a.dump):
        out["dump"] = {"path": a.dump, "bytes": os.path.getsize(a.dump)}
        out["dump"].update(ffmpeg_check(a.dump))
        if out["dump"].get("exitCode"):
            s.violations.append("ffmpeg failed to decode the dump")
            out["violations"] = s.violations
            out["ok"] = False
    text = json.dumps(out, indent=2)
    print(text)
    if a.summary:
        with open(a.summary, "w") as f:
            f.write(text + "\n")
    if reason in ("connect-failed", "rejected", "approval-timeout"):
        return 2
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
