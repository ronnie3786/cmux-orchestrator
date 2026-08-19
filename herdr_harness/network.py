"""Local and Tailscale reachability discovery for the harness server."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
from typing import Mapping, Optional
from urllib.parse import urlparse, urlunparse


def _local_ipv4_addresses() -> list[str]:
    addresses: set[str] = set()
    for host in (socket.gethostname(), socket.getfqdn()):
        try:
            infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
        except OSError:
            continue
        for info in infos:
            address = info[4][0]
            if address and not address.startswith("127."):
                addresses.add(address)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("10.255.255.255", 1))
            address = probe.getsockname()[0]
            if address and not address.startswith("127."):
                addresses.add(address)
    except OSError:
        pass
    return sorted(addresses)


def _normalize_host(value: str) -> str:
    host = str(value or "").strip().removeprefix("http://").removeprefix("https://")
    host = host.split("/", 1)[0].strip().rstrip(".")
    if host.count(":") == 1:
        host = host.split(":", 1)[0]
    if not host or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-" for char in host):
        return ""
    return host


def _https_url(value: str) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    try:
        parsed = urlparse(raw)
        _ = parsed.port
    except ValueError:
        return ""
    if parsed.scheme.lower() != "https" or not parsed.hostname or parsed.username or parsed.password:
        return ""
    if parsed.query or parsed.fragment:
        return ""
    path = parsed.path.rstrip("/")
    return urlunparse(("https", parsed.netloc, path, "", "", ""))


def _serve_port(environ: Mapping[str, str]) -> int:
    try:
        value = int(environ.get("HERDR_HARNESS_TAILSCALE_HTTPS_PORT", "8461"))
    except (TypeError, ValueError):
        return 8461
    return value if 1 <= value <= 65535 else 8461


def _tailscale_identity(environ: Mapping[str, str]) -> dict:
    configured_url = _https_url(environ.get("HERDR_HARNESS_TAILSCALE_URL", ""))
    configured = _normalize_host(urlparse(configured_url).hostname or "")
    configured = configured or _normalize_host(environ.get("HERDR_HARNESS_TAILSCALE_HOST", ""))
    result = {"available": False, "dnsName": configured, "ipv4": "", "source": "environment" if configured else ""}
    executable = shutil.which("tailscale")
    if not executable:
        result["available"] = bool(configured)
        return result
    try:
        completed = subprocess.run(
            [executable, "status", "--json"],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )
        if completed.returncode != 0:
            result["available"] = bool(configured)
            return result
        payload = json.loads(completed.stdout)
        own = payload.get("Self") if isinstance(payload, dict) else {}
        own = own if isinstance(own, dict) else {}
        dns_name = _normalize_host(own.get("DNSName") or "")
        ips = own.get("TailscaleIPs") if isinstance(own.get("TailscaleIPs"), list) else []
        ipv4 = next((str(item) for item in ips if isinstance(item, str) and ":" not in item), "")
        result.update(
            {
                "available": bool(dns_name or ipv4 or configured),
                "dnsName": configured or dns_name,
                "ipv4": ipv4,
                "source": "tailscale status",
            }
        )
    except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError):
        result["available"] = bool(configured)
    return result


def network_payload(
    port: int,
    *,
    environ: Optional[Mapping[str, str]] = None,
    host_header: str = "",
) -> dict:
    env = os.environ if environ is None else environ
    hostname = socket.gethostname()
    normalized_hostname = hostname.rstrip(".")
    local_name = (
        normalized_hostname
        if normalized_hostname.lower().endswith(".local")
        else f"{normalized_hostname.split('.', 1)[0]}.local"
        if normalized_hostname
        else ""
    )
    tailscale = _tailscale_identity(env)
    tail_host = tailscale.get("dnsName") or tailscale.get("ipv4") or ""
    serve_port = _serve_port(env)
    configured_tail_url = _https_url(env.get("HERDR_HARNESS_TAILSCALE_URL", ""))
    if not configured_tail_url and env.get("HERDR_HARNESS_TAILSCALE_HOST") and tail_host:
        configured_tail_url = f"https://{tail_host}:{serve_port}"
    suggested_tail_url = f"https://{tail_host}:{serve_port}" if tail_host else ""
    bind_address = str(env.get("HERDR_HARNESS_HOST") or "127.0.0.1")
    is_loopback = bind_address in {"127.0.0.1", "localhost", "::1"}
    urls = {
        "localhost": f"http://localhost:{int(port)}",
        "localName": f"http://{local_name}:{int(port)}" if local_name and not is_loopback else "",
        # Identity alone does not prove that a Serve handler exists. Advertise
        # only an explicitly configured URL and keep discovery as a suggestion.
        "tailscale": configured_tail_url,
        "tailscaleSuggested": suggested_tail_url,
    }
    if host_header:
        urls["requested"] = f"http://{host_header}"
    return {
        "ok": True,
        "bindAddress": bind_address,
        "port": int(port),
        "hostname": hostname,
        "localName": local_name,
        "lanAddresses": _local_ipv4_addresses(),
        "tailscale": tailscale,
        "tailscaleServeCommand": f"tailscale serve --bg --https={serve_port} {int(port)}",
        "tailscaleServeRemoveCommand": f"tailscale serve --https={serve_port} off",
        "tailscaleServePort": serve_port,
        "urls": urls,
    }


def public_base_url(
    environ: Optional[Mapping[str, str]] = None,
    *,
    host_header: str = "",
    forwarded_proto: str = "",
) -> tuple[str, str]:
    """Resolve the externally reachable HTTPS base URL used in shareable links.

    Returns (url, source); url is "" when nothing trustworthy is configured or
    observable. Preference order: explicit HERDR_HARNESS_PUBLIC_URL, the
    configured HERDR_HARNESS_TAILSCALE_URL, then the caller's Host header —
    the latter only when an HTTPS front end vouches for it via
    X-Forwarded-Proto (tailscale serve sets it). A discovered Tailscale
    identity alone is deliberately not trusted: identity does not prove that
    a Serve handler exists, matching the network_payload policy above.
    """
    env = os.environ if environ is None else environ
    configured = _https_url(env.get("HERDR_HARNESS_PUBLIC_URL", ""))
    if configured:
        return configured, "environment"
    tailscale_url = _https_url(env.get("HERDR_HARNESS_TAILSCALE_URL", ""))
    if tailscale_url:
        return tailscale_url, "environment"
    if str(forwarded_proto or "").strip().lower() != "https":
        return "", ""
    raw_header = str(host_header or "").strip()
    host = _normalize_host(raw_header)
    if host:
        port_suffix = ""
        if ":" in raw_header and not raw_header.startswith("["):
            candidate = raw_header.rsplit(":", 1)[1]
            if candidate.isdigit() and 1 <= int(candidate) <= 65535:
                port_suffix = f":{int(candidate)}"
        return f"https://{host}{port_suffix}", "host header"
    return "", ""
