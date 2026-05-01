import socket
import subprocess
import shutil


BONJOUR_SERVICE_TYPE = "_cmux-harness._tcp"


class BonjourAdvertiser:
    """Advertise the harness server on the LAN using macOS dns-sd."""

    def __init__(self, port, name=None):
        self.port = int(port)
        hostname = socket.gethostname() or "Mac"
        self.name = name or f"cmux harness on {hostname}"
        self.process = None

    def start(self):
        dns_sd = shutil.which("dns-sd")
        if not dns_sd:
            return False
        command = [
            dns_sd,
            "-R",
            self.name,
            BONJOUR_SERVICE_TYPE,
            "local",
            str(self.port),
            "path=/harness",
        ]
        try:
            self.process = subprocess.Popen(
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            self.process = None
            return False
        return True

    def stop(self):
        if self.process is None:
            return
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        self.process = None
