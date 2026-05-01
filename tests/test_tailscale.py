import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from cmux_harness import tailscale


class TestTailscaleDetection(unittest.TestCase):

    def test_detect_tailscale_uses_localapi_status(self):
        status = {
            "Self": {
                "DNSName": "MacBook.Example.ts.net.",
                "TailscaleIPs": ["100.89.178.110", "fd7a:115c:a1e0::1401:b292"],
            },
        }

        with patch("cmux_harness.tailscale._detect_tailnet_name_from_macos_prefs", return_value=""):
            with patch("cmux_harness.tailscale._load_localapi_status", return_value=status):
                payload = tailscale.detect_tailscale(port=9091, use_cache=False)

        self.assertTrue(payload["available"])
        self.assertEqual(payload["dnsName"], "macbook.example.ts.net")
        self.assertEqual(payload["machineName"], "macbook")
        self.assertEqual(payload["tailnetName"], "example.ts.net")
        self.assertEqual(payload["tailscaleIPv4"], "100.89.178.110")
        self.assertEqual(payload["source"], "Tailscale LocalAPI")
        self.assertEqual(payload["urls"]["bestHarness"], "http://macbook.example.ts.net:9091/harness")
        self.assertEqual(payload["urls"]["ipHarness"], "http://100.89.178.110:9091/harness")

    def test_detect_tailscale_uses_interface_fallback(self):
        ifconfig = subprocess.CompletedProcess(
            args=["ifconfig"],
            returncode=0,
            stdout="""
utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
    inet 100.64.0.1 --> 100.64.0.1 netmask 0xffff0000
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
    inet 100.89.178.110 --> 100.89.178.110 netmask 0xffffffff
en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    inet 192.168.86.24 netmask 0xffffff00 broadcast 192.168.86.255
""",
            stderr="",
        )

        def fake_run(command, **_kwargs):
            if command == ["ifconfig"]:
                return ifconfig
            return subprocess.CompletedProcess(args=command, returncode=1, stdout="", stderr="not available")

        with patch("cmux_harness.tailscale._detect_tailnet_name_from_macos_prefs", return_value=""):
            with patch("cmux_harness.tailscale._load_localapi_status", side_effect=RuntimeError("missing")):
                with patch("cmux_harness.tailscale.shutil.which", return_value=None):
                    with patch("cmux_harness.tailscale.subprocess.run", side_effect=fake_run):
                        payload = tailscale.detect_tailscale(port=9091, use_cache=False)

        self.assertTrue(payload["available"])
        self.assertEqual(payload["dnsName"], "")
        self.assertEqual(payload["tailscaleIPv4"], "100.89.178.110")
        self.assertEqual(payload["tailscaleIPv4Candidates"], ["100.64.0.1", "100.89.178.110"])
        self.assertEqual(payload["source"], "network interface")
        self.assertEqual(payload["urls"]["bestHarness"], "http://100.89.178.110:9091/harness")

    def test_detect_tailnet_name_from_macos_prefs(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            prefs_path = Path(tmpdir) / "tailscale.plist"
            profile = {
                "NetworkProfile": {
                    "MagicDNSName": "Tail1234.ts.net.",
                },
            }
            with prefs_path.open("wb") as handle:
                plistlib.dump({"com.tailscale.cached.currentProfile": json.dumps(profile).encode("utf-8")}, handle)

            with patch("cmux_harness.tailscale._MACOS_PROFILE_PREFS", prefs_path):
                tailnet_name = tailscale._detect_tailnet_name_from_macos_prefs([])

        self.assertEqual(tailnet_name, "tail1234.ts.net")


if __name__ == "__main__":
    unittest.main()
