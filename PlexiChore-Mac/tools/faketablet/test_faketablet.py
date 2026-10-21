#!/usr/bin/env python3
"""Tests for faketablet.py against mock_host.py. Never touches port 47800/47801.

  /usr/bin/python3 test_faketablet.py -v
"""

import json
import os
import random
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import faketablet as ft  # noqa: E402
import mock_host as mh  # noqa: E402

PY = sys.executable


def free_port():
    import socket
    while True:
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.close()
        if p not in (47800, 47801):
            return p


class SpsTests(unittest.TestCase):
    def check(self, w, h, **kw):
        nal = mh.make_sps(w, h, **kw)
        info = ft.parse_sps(nal)
        self.assertEqual((info["width"], info["height"]), (w, h), (w, h, kw))
        return info

    def test_common_sizes_with_cropping(self):
        for w, h in [(2560, 1600), (1600, 2560), (1920, 1080), (1080, 1920), (3840, 2160), (1280, 720),
                     (2732, 2048), (2000, 1200), (1366, 768), (2, 2), (2558, 1598)]:
            self.check(w, h)
            self.check(w, h, profile_idc=77)
            self.check(w, h, profile_idc=66, poc_type=2)
            self.check(w, h, scaling_matrix=True, poc_type=1)

    def test_1080p_crop_values(self):
        info = self.check(1920, 1080)
        self.assertEqual(info["crop"], [0, 0, 0, 4])  # 1088 - 8 rows / CropUnitY 2

    def test_chroma_and_interlaced(self):
        self.check(1920, 1080, chroma_format_idc=3)
        self.check(1920, 1080, chroma_format_idc=0)
        self.check(1920, 1080, chroma_format_idc=2)
        self.check(1920, 1080, frame_mbs_only=0)

    def test_random_sizes(self):
        rnd = random.Random(7)
        for _ in range(300):
            w = rnd.randrange(1, 2048) * 2
            h = rnd.randrange(1, 2048) * 2
            info = self.check(w, h, sps_id=rnd.randrange(0, 32), scaling_matrix=rnd.random() < 0.5)
            self.assertEqual(info["profile"], "high")

    def test_emulation_prevention(self):
        self.assertEqual(ft.unescape_rbsp(b"\x00\x00\x03\x01\x00\x00\x03\x00"), b"\x00\x00\x01\x00\x00\x00")
        raw = bytes(range(0, 4)) * 50 + b"\x00\x00\x00\x00\x01"
        self.assertEqual(ft.unescape_rbsp(mh.escape_rbsp(raw)), raw)

    def test_real_videotoolbox_sps(self):
        # SPS emitted by macOS VideoToolbox (VTCompressionSession, High/Baseline AutoLevel) for these sizes.
        vectors = [
            (1920, 1080, "high", "27640028ac56501e0089f950"),
            (1920, 1080, "baseline", "27420028ab403c0113f2a0"),
            (2560, 1600, "high", "27640032ac56500a003264"),
            (2560, 1600, "baseline", "27420032ab40140064c8"),
            (1600, 2560, "high", "27640032ac565019005064"),
            (1600, 2560, "baseline", "27420032ab403200a0c8"),
            (1366, 768, "high", "27640020ac56501581879b40"),
            (1366, 768, "baseline", "27420020ab402b030f3680"),
        ]
        for w, h, prof, hx in vectors:
            info = ft.parse_sps(bytes.fromhex(hx))
            self.assertEqual((info["width"], info["height"], info["profile"]), (w, h, prof), hx)


class FramingTests(unittest.TestCase):
    def test_reader_split_and_partial(self):
        data = ft.frame(ft.PING, struct.pack(">Q", 5)) + ft.frame(ft.CONFIG, {"a": 1}) + ft.frame(ft.REQUEST_KEYFRAME)
        r = ft.FrameReader()
        got = []
        for i in range(len(data)):  # byte by byte
            r.feed(data[i:i + 1])
            got += r.frames()
        self.assertEqual([t for t, _ in got], [ft.PING, ft.CONFIG, ft.REQUEST_KEYFRAME])
        self.assertEqual(got[1][1], b'{"a":1}')
        self.assertEqual(data[:5], b"\x06\x00\x00\x00\x08")

    def test_bad_length(self):
        r = ft.FrameReader()
        r.feed(b"\x03\x7f\xff\xff\xff")
        with self.assertRaises(ValueError):
            r.frames()

    def test_input_encoding(self):
        fr = ft.input_frame([ft.pointer(ft.KIND_TOUCH, ft.ACT_DOWN, 3, 1, 0.5, 0.25, 0.75)])
        self.assertEqual(fr[0], ft.INPUT)
        self.assertEqual(struct.unpack(">I", fr[1:5])[0], 1 + 24)
        self.assertEqual(fr[5], 1)
        self.assertEqual(fr[6:10], bytes([0, 0, 3, 1]))
        self.assertEqual(struct.unpack(">fffff", fr[10:30]), (0.5, 0.25, 0.75, 0.0, 0.0))

    def test_annexb_split(self):
        data = b"\x00\x00\x00\x01\x67\x01\x02\x00\x00\x01\x68\x03\x00\x00\x00\x01\x65\x00\x00\x03\x01"
        nals = ft.split_annexb(data)
        self.assertEqual([ft.nal_type(n) for n in nals], [7, 8, 5])
        self.assertEqual(nals[1], b"\x68\x03")

    def test_hello_shape(self):
        a = ft.parse_args(["--mode", "primary", "--fps", "120", "--orientation", "portrait", "--device-id", "x"])
        h = ft.Session(a).hello()
        for k in ("protocol", "deviceId", "deviceName", "model", "widthPx", "heightPx", "densityDpi", "refreshHz",
                  "codecs", "maxDecodeWidth", "maxDecodeHeight", "decodeModes", "h264Profiles", "h264MaxLevel",
                  "orientation", "viewportWidthPx", "viewportHeightPx", "touch", "pen", "requested"):
            self.assertIn(k, h)
        self.assertEqual((h["widthPx"], h["heightPx"], h["densityDpi"], h["refreshHz"]), (2560, 1600, 320, 120))
        self.assertEqual((h["viewportWidthPx"], h["viewportHeightPx"]), (1600, 2560))
        self.assertEqual(h["requested"]["mode"], "primary")
        self.assertEqual(h["requested"]["orientation"], "portrait")
        self.assertEqual(h["deviceId"], "x")


class EndToEnd(unittest.TestCase):
    def run_pair(self, scenario, client_args, seconds="3"):
        port = free_port()
        mock = subprocess.Popen([PY, os.path.join(HERE, "mock_host.py"), "--port", str(port), "--scenario", scenario],
                                stdout=subprocess.PIPE, text=True)
        self.assertEqual(mock.stdout.readline().strip(), "READY")
        tmp = tempfile.mkdtemp()
        client_args = [os.path.join(tmp, "out.h264") if x == "DUMP" else x for x in client_args]
        summ = os.path.join(tmp, "summary.json")
        cl = subprocess.run([PY, os.path.join(HERE, "faketablet.py"), "--port", str(port), "--seconds", seconds,
                             "--quiet", "--summary", summ] + client_args, capture_output=True, text=True, timeout=60)
        out, _ = mock.communicate(timeout=20)
        report = json.loads(out.strip().splitlines()[-1])
        summary = None
        if os.path.exists(summ):
            with open(summ) as f:
                summary = json.load(f)
        return cl, summary, report, tmp

    def test_good_full(self):
        cl, s, rep, tmp = self.run_pair("good", ["--send-input", "--input-at", "0.5", "--request-keyframe", "1",
                                                 "--settings", '{"orientation":"portrait"}', "--settings-at", "1.5",
                                                 "--dump", "DUMP"], seconds="3.5")
        self.assertEqual(cl.returncode, 0, cl.stderr + json.dumps(s, indent=1))
        self.assertEqual(s["violations"], [])
        v = s["video"]
        self.assertGreater(v["frames"], 150)
        self.assertGreater(v["fps"], 45)
        self.assertGreaterEqual(v["idrFrames"], 3)
        self.assertEqual(v["codecConfigFrames"], 3)
        self.assertEqual((v["sps"]["width"], v["sps"]["height"]), (1600, 2560))
        self.assertEqual(v["spsSizeMatchesConfig"], 3)
        self.assertEqual(len(s["configs"]), 2)
        self.assertTrue(s["settings"]["new_size"])
        self.assertIsNotNone(s["settings"]["idr_after_ms"])
        self.assertLess(s["keyframeRequestMs"][0], 500)
        self.assertGreaterEqual(s["rttMs"]["pongs"], 2)
        self.assertGreaterEqual(s["hostPingsEchoed"], 2)
        self.assertEqual(rep["received"].get("PONG", 0), s["hostPingsEchoed"])
        self.assertEqual(rep["bye"], "faketablet done")
        self.assertEqual(rep["settings"], [{"orientation": "portrait"}])
        self.assertEqual(rep["keyframeRequests"], 1)
        self.assertEqual(len(rep["inputs"]), 7)
        self.assertEqual(rep["inputs"][1][0][:6], [2, 0, 0, 1, 0.5, 0.5])  # mouse down primary at centre
        self.assertEqual(rep["inputs"][-1][0][:6], [3, 1, 0, 0, 0.0, -1.0])  # scroll
        self.assertEqual(rep["errors"], [])
        h = rep["hello"]
        self.assertEqual(h["requested"]["mode"], "extend")
        self.assertEqual(h["decodeModes"][0], {"width": 3840, "height": 2160, "maxFps": 60})
        self.assertGreater(s["dump"]["bytes"], 30000)
        with open(s["dump"]["path"], "rb") as f:
            nals = ft.split_annexb(f.read())
        self.assertEqual([ft.nal_type(n) for n in nals[:4]], [7, 8, 5, 1])
        self.assertEqual(ft.parse_sps(nals[0])["width"], 2560)

    def test_pairing(self):
        cl, s, rep, _ = self.run_pair("pairing", [], seconds="1.5")
        self.assertEqual(cl.returncode, 0, cl.stderr)
        self.assertIn("code 4821", cl.stdout)
        self.assertEqual([p["status"] for p in s["pairing"]], ["waiting", "approved"])

    def test_reject(self):
        cl, s, rep, _ = self.run_pair("reject", [], seconds="1")
        self.assertEqual(cl.returncode, 2)
        self.assertEqual(s["endReason"], "rejected")

    def expect_violation(self, scenario, needle, args=()):
        cl, s, rep, _ = self.run_pair(scenario, list(args), seconds="2.5")
        self.assertEqual(cl.returncode, 1, cl.stderr)
        self.assertTrue(any(needle in v for v in s["violations"]), s["violations"])

    def test_missing_codec_config(self):
        self.expect_violation("bad-first", "expected codec-config")

    def test_sps_mismatch(self):
        self.expect_violation("bad-sps", "SPS size 2544x1600 != CONFIG 2560x1600")

    def test_pts_backwards(self):
        self.expect_violation("pts-back", "pts went backwards")

    def test_slow_keyframe(self):
        self.expect_violation("slow-kf", "REQUEST_KEYFRAME", ["--request-keyframe", "0.5"])

    def test_eof_without_bye(self):
        self.expect_violation("no-bye", "closed the connection without BYE")

    def test_stall_counts_gaps(self):
        cl, s, rep, _ = self.run_pair("stall", [], seconds="3")
        self.assertEqual(cl.returncode, 0, cl.stderr)
        self.assertGreaterEqual(s["video"]["maxGapMs"], 250)
        self.assertGreaterEqual(s["video"]["gapsOver2xInterval"], 1)

    def test_discovery(self):
        port = free_port()
        mock = subprocess.Popen([PY, os.path.join(HERE, "mock_host.py"), "--discovery-port", str(port),
                                 "--discovery-seconds", "4", "--port", "47990"])
        try:
            cl = subprocess.run([PY, os.path.join(HERE, "faketablet.py"), "--discover", "--discover-seconds", "2",
                                 "--discovery-port", str(port), "--probe", "127.0.0.1", "--quiet"],
                                capture_output=True, text=True, timeout=20)
        finally:
            mock.wait(timeout=10)
        self.assertEqual(cl.returncode, 0, cl.stderr)
        b = json.loads(cl.stdout)["beacons"]
        self.assertEqual(b[0]["name"], "mock-host")
        self.assertEqual(b[0]["svc"], "plexichore")


class ScenarioTests(unittest.TestCase):
    def test_self_test_passes(self):
        cl = subprocess.run([PY, os.path.join(HERE, "faketablet.py"), "--self-test", "--scenario-seconds", "2.5", "--quiet"],
                            capture_output=True, text=True, timeout=240)
        self.assertEqual(cl.returncode, 0, cl.stdout + cl.stderr)
        self.assertIn("7 checks: 7 PASS, 0 WARN, 0 FAIL", cl.stdout)

    def test_unreachable_host_exits_2(self):
        port = free_port()  # nothing listens there
        cl = subprocess.run([PY, os.path.join(HERE, "faketablet.py"), "--port", str(port), "--scenario", "extend,mirror",
                             "--quiet"], capture_output=True, text=True, timeout=60)
        self.assertEqual(cl.returncode, 2, cl.stdout + cl.stderr)
        self.assertIn("FAIL", cl.stdout)

    def test_flawed_host_fails_scenario(self):
        port, stop = mh.start_scripted_host(flaws=("ignore-decoder",))
        try:
            summ = os.path.join(tempfile.mkdtemp(), "s.json")
            cl = subprocess.run([PY, os.path.join(HERE, "faketablet.py"), "--port", str(port), "--scenario", "decoder-clamp",
                                 "--scenario-seconds", "2", "--quiet", "--summary", summ],
                                capture_output=True, text=True, timeout=60)
        finally:
            stop()
        self.assertEqual(cl.returncode, 1, cl.stdout + cl.stderr)
        with open(summ) as f:
            rows = json.load(f)["rows"]
        self.assertIn(("CONFIG within decodeModes", "FAIL"), [(r["check"], r["status"]) for r in rows])

    def test_clamp_port_matches_swift_vectors(self):
        tab = [{"width": 3840, "height": 2160, "maxFps": 60}, {"width": 2560, "height": 1600, "maxFps": 120},
               {"width": 1920, "height": 1080, "maxFps": 120}]
        self.assertEqual(mh.clamp_to_decoder(3840, 2400, 120, tab), (3456, 2160, 60))   # SessionPolicyTests
        self.assertEqual(mh.clamp_to_decoder(2800, 1752, 120, tab), (2800, 1752, 60))
        self.assertEqual(mh.clamp_to_decoder(2560, 1600, 60, [{"width": 1280, "height": 720, "maxFps": 15}]), (1152, 720, 30))


if __name__ == "__main__":
    unittest.main()
