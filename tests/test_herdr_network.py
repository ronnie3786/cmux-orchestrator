import unittest
from unittest.mock import patch

from herdr_harness.network import network_payload


class HerdrNetworkTests(unittest.TestCase):
    def test_exact_tailscale_url_and_dedicated_serve_port_are_preserved(self):
        environ = {
            "HERDR_HARNESS_TAILSCALE_URL": "https://workstation.tailnet.ts.net:8461/herdr/",
            "HERDR_HARNESS_TAILSCALE_HTTPS_PORT": "8461",
        }
        with patch("herdr_harness.network.shutil.which", return_value=None), patch(
            "herdr_harness.network.socket.gethostname", return_value="workstation.lan"
        ), patch("herdr_harness.network._local_ipv4_addresses", return_value=[]):
            payload = network_payload(9092, environ=environ)

        self.assertEqual(payload["localName"], "workstation.local")
        self.assertEqual(payload["urls"]["tailscale"], "https://workstation.tailnet.ts.net:8461/herdr")
        self.assertEqual(payload["tailscaleServeCommand"], "tailscale serve --bg --https=8461 9092")
        self.assertEqual(payload["tailscaleServeRemoveCommand"], "tailscale serve --https=8461 off")

    def test_tailscale_identity_is_not_advertised_as_a_verified_handler(self):
        fake_status = '{"Self":{"DNSName":"workstation.tailnet.ts.net.","TailscaleIPs":["100.64.0.1"]}}'
        completed = type("Completed", (), {"returncode": 0, "stdout": fake_status})()
        with patch("herdr_harness.network.shutil.which", return_value="/usr/bin/tailscale"), patch(
            "herdr_harness.network.subprocess.run", return_value=completed
        ), patch("herdr_harness.network.socket.gethostname", return_value="workstation"), patch(
            "herdr_harness.network._local_ipv4_addresses", return_value=[]
        ):
            payload = network_payload(9092, environ={})

        self.assertEqual(payload["urls"]["tailscale"], "")
        self.assertEqual(payload["urls"]["tailscaleSuggested"], "https://workstation.tailnet.ts.net:8461")


if __name__ == "__main__":
    unittest.main()
