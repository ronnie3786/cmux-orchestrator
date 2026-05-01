import base64
import copy
import ipaddress
import json
import os
import plistlib
import re
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path


_TAILSCALE_IPV4_NETWORK = ipaddress.ip_network("100.64.0.0/10")
_MACOS_TAILSCALE_DIR = Path("/Library/Tailscale")
_MACOS_PROFILE_PREFS = Path.home() / "Library" / "Preferences" / "io.tailscale.ipn.macsys.plist"
_CACHE_TTL_SECONDS = 10.0
_CACHE_LOCK = threading.Lock()
_CACHE = {"port": None, "time": 0.0, "payload": None}


def detect_tailscale(port=9091, use_cache=True):
    """Return locally detectable Tailscale connectivity details."""
    if use_cache:
        now = time.monotonic()
        with _CACHE_LOCK:
            if _CACHE["payload"] is not None and _CACHE["port"] == port and now - _CACHE["time"] < _CACHE_TTL_SECONDS:
                return copy.deepcopy(_CACHE["payload"])

    payload = _detect_tailscale_uncached(port)

    if use_cache:
        with _CACHE_LOCK:
            _CACHE.update({"port": port, "time": time.monotonic(), "payload": copy.deepcopy(payload)})

    return payload


def _detect_tailscale_uncached(port):
    errors = []
    tailnet_name = _detect_tailnet_name_from_macos_prefs(errors)

    detected = _detect_from_localapi(errors)
    if not detected["dnsName"] and not detected["tailscaleIPv4"]:
        detected = _detect_from_cli_status(errors)
    if not detected["tailscaleIPv4"]:
        detected["tailscaleIPv4"] = _detect_ipv4_from_cli(errors)
        if detected["tailscaleIPv4"] and not detected["source"]:
            detected["source"] = "tailscale ip"
    if not detected["tailscaleIPv4"]:
        interface_ips = _detect_ipv4s_from_interfaces(errors)
        detected["tailscaleIPv4Candidates"] = interface_ips
        detected["tailscaleIPv4"] = _choose_interface_ipv4(interface_ips)
        if detected["tailscaleIPv4"] and not detected["source"]:
            detected["source"] = "network interface"
    else:
        detected["tailscaleIPv4Candidates"] = [detected["tailscaleIPv4"]]

    dns_name = _normalize_dns_name(detected["dnsName"])
    tailscale_ipv4 = detected["tailscaleIPv4"]
    tailnet_name = tailnet_name or _tailnet_from_dns_name(dns_name)
    magic_dns_url = f"http://{dns_name}:{port}/harness" if dns_name else ""
    ip_url = f"http://{tailscale_ipv4}:{port}/harness" if tailscale_ipv4 else ""
    best_url = magic_dns_url or ip_url

    return {
        "available": bool(best_url),
        "dnsName": dns_name,
        "machineName": _machine_name_from_dns_name(dns_name),
        "tailnetName": tailnet_name,
        "tailscaleIPv4": tailscale_ipv4,
        "tailscaleIPv4Candidates": detected.get("tailscaleIPv4Candidates", []),
        "source": detected["source"] if best_url else "",
        "error": "; ".join(errors[:3]),
        "urls": {
            "magicDnsHarness": magic_dns_url,
            "ipHarness": ip_url,
            "bestHarness": best_url,
        },
    }


def _empty_detection():
    return {"dnsName": "", "tailscaleIPv4": "", "tailscaleIPv4Candidates": [], "source": ""}


def _detect_from_localapi(errors):
    try:
        status = _load_localapi_status()
    except Exception as exc:
        errors.append(f"localapi: {exc}")
        return _empty_detection()
    return _extract_status_detection(status, "Tailscale LocalAPI")


def _load_localapi_status():
    port = _read_macos_localapi_port()
    if not port:
        raise RuntimeError("port not found")
    proof_path = _MACOS_TAILSCALE_DIR / f"sameuserproof-{port}"
    try:
        proof = proof_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise RuntimeError("same-user proof not readable") from exc
    if not proof:
        raise RuntimeError("same-user proof empty")

    request = urllib.request.Request(f"http://127.0.0.1:{port}/localapi/v0/status")
    token = base64.b64encode(f":{proof}".encode("utf-8")).decode("ascii")
    request.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(request, timeout=0.7) as response:
            return json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise RuntimeError(str(exc)) from exc


def _read_macos_localapi_port():
    path = _MACOS_TAILSCALE_DIR / "ipnport"
    try:
        if path.is_symlink():
            value = os.readlink(path)
        else:
            value = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    match = re.search(r"\d+", value)
    return match.group(0) if match else ""


def _detect_from_cli_status(errors):
    tailscale_bin = shutil.which("tailscale")
    if not tailscale_bin:
        return _empty_detection()
    try:
        completed = subprocess.run(
            [tailscale_bin, "status", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=1.2,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append(f"tailscale status: {exc}")
        return _empty_detection()
    if completed.returncode != 0:
        message = (completed.stderr or completed.stdout or "").strip()
        if message:
            errors.append(f"tailscale status: {message}")
        return _empty_detection()
    try:
        return _extract_status_detection(json.loads(completed.stdout), "tailscale status")
    except json.JSONDecodeError as exc:
        errors.append(f"tailscale status: {exc}")
        return _empty_detection()


def _detect_ipv4_from_cli(errors):
    tailscale_bin = shutil.which("tailscale")
    if not tailscale_bin:
        return ""
    try:
        completed = subprocess.run(
            [tailscale_bin, "ip", "-4"],
            check=False,
            capture_output=True,
            text=True,
            timeout=1.2,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append(f"tailscale ip: {exc}")
        return ""
    if completed.returncode != 0:
        message = (completed.stderr or completed.stdout or "").strip()
        if message:
            errors.append(f"tailscale ip: {message}")
        return ""
    return _first_tailscale_ipv4(completed.stdout.splitlines())


def _detect_tailnet_name_from_macos_prefs(errors):
    try:
        with _MACOS_PROFILE_PREFS.open("rb") as handle:
            prefs = plistlib.load(handle)
    except OSError:
        return ""
    for key in ("com.tailscale.cached.currentProfile", "com.tailscale.cached.profiles"):
        value = prefs.get(key)
        if not isinstance(value, bytes):
            continue
        try:
            decoded = json.loads(value.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            errors.append(f"tailscale prefs: {exc}")
            continue
        profiles = decoded if isinstance(decoded, list) else [decoded]
        for profile in profiles:
            if not isinstance(profile, dict):
                continue
            network = profile.get("NetworkProfile") or {}
            magic_dns_name = network.get("MagicDNSName") or ""
            if magic_dns_name:
                return _normalize_dns_name(magic_dns_name)
    return ""


def _detect_ipv4s_from_interfaces(errors):
    try:
        completed = subprocess.run(
            ["ifconfig"],
            check=False,
            capture_output=True,
            text=True,
            timeout=1.2,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append(f"ifconfig: {exc}")
        return []
    if completed.returncode != 0:
        message = (completed.stderr or completed.stdout or "").strip()
        if message:
            errors.append(f"ifconfig: {message}")
        return []
    matches = re.findall(r"\binet\s+(\d+\.\d+\.\d+\.\d+)\b", completed.stdout)
    return _unique_ips(ip for ip in matches if _is_tailscale_ipv4(ip))


def _extract_status_detection(status, source):
    if not isinstance(status, dict):
        return _empty_detection()
    self_status = status.get("Self") if isinstance(status.get("Self"), dict) else {}
    dns_name = _normalize_dns_name(self_status.get("DNSName") or status.get("DNSName") or "")
    ips = []
    for value in (self_status.get("TailscaleIPs"), status.get("TailscaleIPs")):
        if isinstance(value, list):
            ips.extend(str(ip) for ip in value)
    tailscale_ipv4 = _first_tailscale_ipv4(ips)
    return {
        "dnsName": dns_name,
        "tailscaleIPv4": tailscale_ipv4,
        "tailscaleIPv4Candidates": [tailscale_ipv4] if tailscale_ipv4 else [],
        "source": source if dns_name or tailscale_ipv4 else "",
    }


def _normalize_dns_name(value):
    return str(value or "").strip().strip(".").lower()


def _tailnet_from_dns_name(dns_name):
    parts = _normalize_dns_name(dns_name).split(".")
    if len(parts) < 3:
        return ""
    return ".".join(parts[1:])


def _machine_name_from_dns_name(dns_name):
    parts = _normalize_dns_name(dns_name).split(".")
    return parts[0] if len(parts) >= 3 else ""


def _first_tailscale_ipv4(values):
    for value in values:
        ip = str(value or "").strip()
        if _is_tailscale_ipv4(ip):
            return ip
    return ""


def _is_tailscale_ipv4(value):
    try:
        return ipaddress.ip_address(value) in _TAILSCALE_IPV4_NETWORK
    except ValueError:
        return False


def _unique_ips(values):
    seen = set()
    unique = []
    for value in values:
        if value not in seen:
            unique.append(value)
            seen.add(value)
    return unique


def _choose_interface_ipv4(values):
    for value in values:
        if value != "100.64.0.1":
            return value
    return values[0] if len(values) == 1 else ""
