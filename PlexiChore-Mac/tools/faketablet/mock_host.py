#!/usr/bin/env python3
"""
mock_host.py - tiny synthetic PlexiChore host for testing faketablet.py (stdlib only).

Serves ONE tablet connection with a canned H.264-shaped stream: real SPS/PPS bit syntax (so the
SPS parser can be checked, including cropping), fake slice payloads (NAL 5 / NAL 1). Never use port
47800 for tests; the default here is 47990.

  ./mock_host.py --port 47990 [--scenario good|pairing|bad-first|bad-sps|pts-back|slow-kf|no-bye]
                 [--discovery-port 47991]

It records what the tablet sent and prints a JSON report on exit (stdout) for the tests to check.
"""

import argparse
import json
import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import faketablet as ft  # noqa: E402


# ---------------------------------------------------------------- SPS/PPS writer


class BitWriter:
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        for i in range(n - 1, -1, -1):
            self.bits.append((v >> i) & 1)

    def ue(self, v):
        v += 1
        n = v.bit_length()
        self.u(n - 1, 0)
        self.u(n, v)

    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def rbsp(self):
        self.bits.append(1)  # rbsp_stop_one_bit
        while len(self.bits) % 8:
            self.bits.append(0)
        return bytes(int("".join(map(str, self.bits[i:i + 8])), 2) for i in range(0, len(self.bits), 8))


def escape_rbsp(rbsp):
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def make_sps(width, height, profile_idc=100, level_idc=51, chroma_format_idc=1, frame_mbs_only=1,
             scaling_matrix=False, poc_type=0, sps_id=0):
    """Builds an SPS NAL (header byte + escaped RBSP) for the given output size."""
    w_mbs = (width + 15) // 16
    sub_w = 1 if chroma_format_idc in (0, 3) else 2
    sub_h = 2 if chroma_format_idc == 1 else 1
    if chroma_format_idc == 0:
        cux, cuy = 1, 2 - frame_mbs_only
    else:
        cux, cuy = sub_w, sub_h * (2 - frame_mbs_only)
    unit_h = 16 * (2 - frame_mbs_only)
    h_units = (height + unit_h - 1) // unit_h
    crop_r = (w_mbs * 16 - width)
    crop_b = (h_units * unit_h - height)
    assert crop_r % cux == 0 and crop_b % cuy == 0, "size not representable"
    bw = BitWriter()
    bw.u(8, profile_idc)
    bw.u(8, 0)
    bw.u(8, level_idc)
    bw.ue(sps_id)
    if profile_idc in ft.HIGH_PROFILES:
        bw.ue(chroma_format_idc)
        if chroma_format_idc == 3:
            bw.u(1, 0)
        bw.ue(0)
        bw.ue(0)
        bw.u(1, 0)
        bw.u(1, 1 if scaling_matrix else 0)
        if scaling_matrix:
            for i in range(8 if chroma_format_idc != 3 else 12):
                present = i in (0, 6)
                bw.u(1, 1 if present else 0)
                if present:
                    size = 16 if i < 6 else 64
                    for j in range(size):
                        bw.se(1 if j % 3 else -2)
    bw.ue(0)  # log2_max_frame_num_minus4
    bw.ue(poc_type)
    if poc_type == 0:
        bw.ue(2)
    elif poc_type == 1:
        bw.u(1, 0)
        bw.se(-3)
        bw.se(5)
        bw.ue(2)
        bw.se(7)
        bw.se(-1)
    bw.ue(1)  # max_num_ref_frames
    bw.u(1, 0)
    bw.ue(w_mbs - 1)
    bw.ue(h_units - 1)
    bw.u(1, frame_mbs_only)
    if not frame_mbs_only:
        bw.u(1, 0)
    bw.u(1, 1)  # direct_8x8_inference
    if crop_r or crop_b:
        bw.u(1, 1)
        bw.ue(0)
        bw.ue(crop_r // cux)
        bw.ue(0)
        bw.ue(crop_b // cuy)
    else:
        bw.u(1, 0)
    bw.u(1, 0)  # vui_parameters_present_flag
    return bytes([0x67]) + escape_rbsp(bw.rbsp())


PPS = bytes([0x68, 0xEE, 0x3C, 0x80])
SC = b"\x00\x00\x00\x01"


def slice_nal(idr, size, seed):
    body = bytes(((seed * 31 + i * 7) & 0xFF) for i in range(size))
    return bytes([0x65 if idr else 0x41]) + escape_rbsp(b"\x88" + body)


def video(pts, flags, data):
    return ft.frame(ft.VIDEO, struct.pack(">QB", pts, flags) + data)


# ---------------------------------------------------------------- server


class MockHost:
    def __init__(self, a):
        self.a = a
        self.report = {"scenario": a.scenario, "received": {}, "hello": None, "inputs": [], "settings": [],
                       "bye": None, "keyframeRequests": 0, "errors": []}
        self.lock = threading.Lock()
        self.wlock = threading.Lock()
        self.stop = False
        self.size = None
        self.pending_idr = False
        self.frame_no = 0
        self.pts = 0
        self.pending_orientation = None
        self.flaws = set()
        self.stream_fps = None  # frame cadence; None = the requested fps

    def send(self, c, data):
        with self.wlock:
            c.sendall(data)

    def codec_config(self, c):
        w, h = self.size
        if self.a.scenario == "bad-sps":
            w, h = w - 16, h
        sps = make_sps(w, h, profile_idc=100, level_idc=51, scaling_matrix=True)
        self.send(c, video(self.pts, ft.FLAG_CODEC_CONFIG, SC + sps + SC + PPS))

    def picture(self, c, idr):
        self.frame_no += 1
        self.pts += 16667
        pts = self.pts
        if self.a.scenario == "pts-back" and self.frame_no == 20:
            pts -= 100000
        nal = slice_nal(idr, 200 if not idr else 2000, self.frame_no)
        self.send(c, video(pts, ft.FLAG_KEYFRAME if idr else 0, SC + nal))

    def config(self, c, hello, orientation):
        req = hello.get("requested", {})
        w, h = 2560, 1600
        if orientation == "portrait" and req.get("mode") != "mirror":
            w, h = h, w
        self.size = (w, h)
        cfg = {"codec": "h264", "width": w, "height": h, "fps": req.get("fps", 60),
               "bitrateKbps": req.get("bitrateKbps", 20000), "mode": req.get("mode", "extend"),
               "hostName": "mock-host", "hostOs": "macos", "monitors": [{"index": 0, "name": "Primary", "width": 3024, "height": 1964}],
               "virtualDisplayAvailable": True, "scalePercent": 200, "link": "usb-cable"}
        self.send(c, ft.frame(ft.CONFIG, cfg))

    def reader(self, c):
        rd = ft.FrameReader()
        orientation = None
        try:
            while not self.stop:
                data = c.recv(65536)
                if not data:
                    break
                rd.feed(data)
                for t, p in rd.frames():
                    name = ft.TYPE_NAMES.get(t, str(t))
                    with self.lock:
                        self.report["received"][name] = self.report["received"].get(name, 0) + 1
                    if t == ft.HELLO:
                        self.report["hello"] = json.loads(p.decode())
                        self.hello_evt.set()
                    elif t == ft.PING:
                        if "no-pong" not in self.flaws:
                            self.send(c, ft.frame(ft.PONG, p))
                    elif t == ft.INPUT:
                        n = p[0]
                        if len(p) != 1 + 24 * n:
                            self.report["errors"].append("INPUT length %d for count %d" % (len(p), n))
                        else:
                            self.report["inputs"].append([list(ft.POINTER.unpack_from(p, 1 + 24 * i)) for i in range(n)])
                    elif t == ft.REQUEST_KEYFRAME:
                        self.report["keyframeRequests"] += 1
                        if self.a.scenario == "slow-kf":
                            threading.Timer(0.9, self._set_pending).start()
                        else:
                            self.pending_idr = True
                    elif t == ft.SETTINGS:
                        s = json.loads(p.decode())
                        self.report["settings"].append(s)
                        if "orientation" in s:
                            orientation = s["orientation"]
                            self.pending_orientation = orientation
                    elif t == ft.BYE:
                        self.report["bye"] = p.decode()
                        self.stop = True
                        return
                    elif t == ft.PONG:
                        pass
        except OSError:
            pass
        self.stop = True

    def _set_pending(self):
        self.pending_idr = True

    def serve_once(self, srv):
        c, addr = srv.accept()
        self.serve_conn(c)

    def before_config(self, c, hello):
        """Hook for subclasses (pairing). Returns False to drop the connection."""
        return True

    def serve_conn(self, c):
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.hello_evt = threading.Event()
        threading.Thread(target=self.reader, args=(c,), daemon=True).start()
        if not self.hello_evt.wait(5):
            self.report["errors"].append("no HELLO")
            c.close()
            return
        hello = self.report["hello"]
        sc = self.a.scenario
        try:
            if not self.before_config(c, hello):
                return
            if sc == "pairing":
                self.send(c, ft.frame(ft.PAIRING, {"status": "waiting", "code": "4821"}))
                time.sleep(1.5)
                self.send(c, ft.frame(ft.PAIRING, {"status": "approved", "code": "4821"}))
            if sc == "reject":
                self.send(c, ft.frame(ft.PAIRING, {"status": "waiting", "code": "4821"}))
                time.sleep(0.3)
                self.send(c, ft.frame(ft.PAIRING, {"status": "rejected", "code": "4821"}))
                time.sleep(0.5)
                c.close()
                return
            self.config(c, hello, hello.get("requested", {}).get("orientation", "landscape"))
            if sc != "bad-first":
                self.codec_config(c)
            self.picture(c, True)
            interval = 1.0 / (self.stream_fps or hello["requested"]["fps"])
            nxt = time.monotonic()
            last_ping = last_stats = time.monotonic()
            start = time.monotonic()
            while not self.stop:
                nxt += interval
                d = nxt - time.monotonic()
                if d > 0:
                    time.sleep(d)
                if sc == "stall" and 2.0 < time.monotonic() - start < 2.3:
                    continue
                if self.pending_orientation and "ignore-rotate" in self.flaws:
                    self.pending_orientation = None
                if self.pending_orientation:
                    o, self.pending_orientation = self.pending_orientation, None
                    time.sleep(0.2)  # "re-create the virtual monitor"
                    self.config(c, hello, o)
                    self.pending_idr = True
                if self.pending_idr:
                    self.pending_idr = False
                    self.codec_config(c)
                    self.picture(c, True)
                else:
                    self.picture(c, False)
                t = time.monotonic()
                if t - last_ping >= 1:
                    last_ping = t
                    self.send(c, ft.frame(ft.PING, struct.pack(">Q", 123456789)))
                if t - last_stats >= 1:
                    last_stats = t
                    self.send(c, ft.frame(ft.STATS, {"captureFps": 60, "encodeMs": 1.2, "bitrateKbps": 900}))
                if sc == "no-bye" and t - start > 2:
                    c.close()
                    break
        except OSError as e:
            if not self.stop:
                self.report["errors"].append("send: %s" % e)
        finally:
            time.sleep(0.2)
            try:
                c.close()
            except OSError:
                pass


# ---------------------------------------------------------------- scripted host (faketablet --self-test)


def even(v):
    return max(2, int(round(v)) & ~1)


def clamp_to_decoder(w, h, fps, modes):
    """Python port of SessionPolicy.clampToDecoder (PROTOCOL.md "Decode capabilities")."""
    modes = [m for m in (modes or []) if m.get("width", 0) > 0 and m.get("height", 0) > 0 and m.get("maxFps", 0) > 0]
    if not modes:
        return w, h, fps
    bl, bs = max(w, h), min(w, h)
    edges = lambda m: (max(m["width"], m["height"]), min(m["width"], m["height"]))  # noqa: E731
    covering = [m for m in modes if edges(m)[0] >= bl and edges(m)[1] >= bs]
    if covering:
        return w, h, min(fps, max(max(m["maxFps"] for m in covering), 30))
    pool = [m for m in modes if m["maxFps"] >= 30] or modes
    best = max(pool, key=lambda m: m["width"] * m["height"])
    ml, ms = edges(best)
    f = min(1.0, ml / bl, ms / bs)
    return even(w * f), even(h * f), min(fps, max(best["maxFps"], 30))


class ScriptedHost(MockHost):
    """A protocol-correct synthetic host (decoder clamp, profile choice, portrait, rotation, pairing) that serves
    any number of connections; `flaws` switch individual behaviours off so faketablet's checks can be proven to
    fail. Used in-process by `faketablet.py --self-test`; never binds 47800."""

    PROFILE_IDC = {"high": 100, "main": 77, "baseline": 66}

    def __init__(self, flaws=(), pairing=False):
        super().__init__(argparse.Namespace(scenario="bad-first" if "no-codec-config" in flaws else "good"))
        self.flaws = set(flaws)
        self.pairing = pairing
        self.profile_idc = 100

    def before_config(self, c, hello):
        if not self.pairing:
            return True
        self.send(c, ft.frame(ft.PAIRING, {"status": "waiting", "code": "4821"}))
        time.sleep(0.5)
        self.send(c, ft.frame(ft.PAIRING, {"status": "approved", "code": "4821"}))
        return True

    def config(self, c, hello, orientation):
        req = hello.get("requested", {})
        mode = req.get("mode", "extend")
        fps = req.get("fps", 60)
        if mode == "mirror":
            w, h = 1920, 1080  # the "Mac desktop": always landscape
        else:
            lw, sw = max(hello["widthPx"], hello["heightPx"]), min(hello["widthPx"], hello["heightPx"])
            scale = req.get("resolutionScale", 1.0)
            w, h = (sw, lw) if orientation == "portrait" else (lw, sw)
            w, h = even(w * scale), even(h * scale)
        if "ignore-decoder" not in self.flaws:
            w, h, fps = clamp_to_decoder(w, h, fps, hello.get("decodeModes"))
            profs = [p.lower() for p in (hello.get("h264Profiles") or [])]
            self.profile_idc = 100 if not profs or "high" in profs else (77 if "main" in profs else 66)
        self.size = (w, h)
        self.stream_fps = fps
        cfg = {"codec": "h264", "width": w, "height": h, "fps": fps,
               "bitrateKbps": req.get("bitrateKbps", 20000), "mode": mode,
               "hostName": "scripted-host", "hostOs": "macos",
               "monitors": [{"index": 0, "name": "Built-in Retina Display", "width": 1512, "height": 982}],
               "virtualDisplayAvailable": True, "scalePercent": 0 if mode == "mirror" else 200,
               "link": "usb-cable", "encoder": "fake"}
        self.send(c, ft.frame(ft.CONFIG, cfg))

    def codec_config(self, c):
        w, h = self.size
        sps = make_sps(w, h, profile_idc=self.profile_idc, level_idc=51 if self.profile_idc == 100 else 41)
        self.send(c, video(self.pts, ft.FLAG_CODEC_CONFIG, SC + sps + SC + PPS))


def start_scripted_host(flaws=(), pairing=False):
    """Starts a ScriptedHost on 127.0.0.1:<random high port> in daemon threads. Returns (port, stop())."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    port = srv.getsockname()[1]
    if port in (ft.TCP_PORT, ft.UDP_PORT):
        srv.close()
        return start_scripted_host(flaws, pairing)
    srv.listen(8)
    srv.settimeout(0.2)
    stop = threading.Event()

    def loop():
        while not stop.is_set():
            try:
                c, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            h = ScriptedHost(flaws, pairing)
            threading.Thread(target=h.serve_conn, args=(c,), daemon=True).start()
        srv.close()

    threading.Thread(target=loop, daemon=True).start()
    return port, stop.set


def beacon_responder(port, stop_evt, tcp_port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    s.settimeout(0.2)
    beacon = json.dumps({"svc": "plexichore", "v": 1, "id": "mock-0000", "name": "mock-host", "os": "macos",
                         "port": tcp_port, "virtualDisplay": True}).encode()
    while not stop_evt.is_set():
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            continue
        if data == ft.PROBE:
            s.sendto(beacon, addr)
    s.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=47990)
    p.add_argument("--scenario", default="good",
                   choices=["good", "pairing", "reject", "bad-first", "bad-sps", "pts-back", "slow-kf", "no-bye", "stall"])
    p.add_argument("--discovery-port", type=int, default=0, help="answer PLEXI? probes on this UDP port (127.0.0.1)")
    p.add_argument("--discovery-seconds", type=float, default=6)
    a = p.parse_args()
    if a.port == ft.TCP_PORT:
        p.error("refusing to bind 47800 (reserved for the real host)")
    if a.discovery_port:
        if a.discovery_port == ft.UDP_PORT:
            p.error("refusing to bind 47801")
        ev = threading.Event()
        threading.Thread(target=beacon_responder, args=(a.discovery_port, ev, a.port), daemon=True).start()
        time.sleep(a.discovery_seconds)
        ev.set()
        return
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(1)
    print("READY", flush=True)
    srv.settimeout(15)
    m = MockHost(a)
    try:
        m.serve_once(srv)
    except socket.timeout:
        m.report["errors"].append("no connection")
    srv.close()
    print(json.dumps(m.report), flush=True)


if __name__ == "__main__":
    main()
