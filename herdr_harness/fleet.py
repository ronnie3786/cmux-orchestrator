"""Local Fleet catalog management for Herdr Harness.

The Fleet API deliberately has a small trust boundary.  A catalog is always
read from the one configured checkout, catalog entries are constrained to the
catalog's ``skills`` and ``pi-extensions`` trees, and installation targets are
resolved once at manager construction.  Nothing in ``fleet.json`` is treated
as a command line.  CLI recipes are inventory-only and may provide bounded,
output-discarding read-only probes.

This module uses only the Python standard library.  It is usable without a
running Herdr connection, which is important for inventory and recovery when
the native agent is unavailable.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
import platform
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Optional


DEFAULT_CATALOG_REPOSITORY = "git@github.com:ronnie3786/personal-claude-plugin.git"
DEFAULT_CATALOG_RELATIVE_PATH = ".local/share/herdr-fleet/personal-claude-plugin"
DEFAULT_STATE_RELATIVE_PATH = ".local/share/herdr-fleet/state.json"
MAX_CATALOG_BYTES = 4 * 1024 * 1024
MAX_CATALOG_ITEMS = 1024
MAX_ITEM_FILES = 4096
MAX_ITEM_FILE_BYTES = 32 * 1024 * 1024
MAX_SUBPROCESS_SECONDS = 120.0
DEFAULT_SUBPROCESS_SECONDS = 30.0
LOCAL_CLI_COMMANDS = ("gh", "acli", "slack", "pi", "codex", "claude", "herdr")
CLI_COMMAND_ALLOWLIST = frozenset(LOCAL_CLI_COMMANDS)
READONLY_CLASSIFICATIONS = frozenset({"external", "readonly", "read_only", "unclassified", "orphan"})
READONLY_PROBE_ARGV = frozenset(
    {
        ("gh", "auth", "status"),
        ("slack", "auth", "list", "--no-color", "--skip-update"),
        ("pi", "--version"),
        ("pi", "--list-models"),
        ("herdr", "workspace", "list"),
    }
)

_SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SAFE_FORMULA_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+@/-]{0,127}$")
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._~/-]{0,191}$")
_SAFE_ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$")
_HEX_RE = re.compile(r"^[0-9a-fA-F]{7,128}$")
_SENSITIVE_KEY_RE = re.compile(
    r"(?:token|secret|password|passwd|api[_-]?key|private[_-]?key|authorization|credential)",
    re.IGNORECASE,
)


class FleetError(Exception):
    """A safe, client-facing Fleet API error."""

    def __init__(self, message: str, *, code: str = "fleet_error", status: int = 400):
        super().__init__(message)
        self.code = code
        self.status = status


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _safe_text(value: Any, *, maximum: int = 256) -> str:
    if not isinstance(value, str):
        return ""
    value = value.replace("\x00", "").strip()
    return value[:maximum]


def _safe_relative(value: Any, label: str, *, maximum: int = 512) -> str:
    """Validate a slash-separated relative path without resolving it."""

    if not isinstance(value, str) or not value or len(value) > maximum:
        raise FleetError(f"{label} is invalid", code="invalid_fleet_path", status=400)
    if "\x00" in value or "\\" in value or value.startswith("/"):
        raise FleetError(f"{label} is invalid", code="invalid_fleet_path", status=400)
    # PurePosixPath normalizes repeated separators, so inspect the raw parts
    # first.  This prevents a catalog from hiding traversal in ``a//../b``.
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise FleetError(f"{label} is invalid", code="invalid_fleet_path", status=400)
    return "/".join(parts)


def _safe_item_id(value: Any, label: str = "itemId") -> str:
    if not isinstance(value, str) or not _SAFE_ID_RE.fullmatch(value):
        raise FleetError(f"{label} is invalid", code="invalid_fleet_item", status=400)
    if ".." in value or "//" in value:
        raise FleetError(f"{label} is invalid", code="invalid_fleet_item", status=400)
    return value


def _item_writable(writable: bool, classification: str) -> bool:
    return bool(writable and classification.strip().lower().replace("-", "_") not in READONLY_CLASSIFICATIONS)


def _safe_env_name(value: Any) -> str:
    if not isinstance(value, str) or not _SAFE_ENV_RE.fullmatch(value):
        raise FleetError("auth environment name is invalid", code="invalid_catalog", status=400)
    return value


def _home_from_environment(environ: Mapping[str, Any]) -> Path:
    configured = environ.get("HOME")
    if configured is None or configured == "":
        configured = os.path.expanduser("~")
    if not isinstance(configured, str) or not os.path.isabs(configured):
        raise FleetError("HOME must be an absolute path", code="invalid_fleet_home", status=500)
    path = Path(configured).resolve(strict=False)
    if not path.is_dir():
        raise FleetError("Fleet home is unavailable", code="fleet_home_unavailable", status=503)
    return path


def _configured_path(
    environ: Mapping[str, Any],
    names: tuple[str, ...],
    default: Path,
    *,
    label: str,
) -> Path:
    raw: Any = None
    for name in names:
        if environ.get(name):
            raw = environ.get(name)
            break
    if raw is None:
        return default
    if not isinstance(raw, str) or "\x00" in raw:
        raise FleetError(f"{label} is invalid", code="invalid_fleet_path", status=500)
    path = Path(os.path.expanduser(raw))
    if not path.is_absolute():
        raise FleetError(f"{label} must be an absolute path", code="invalid_fleet_path", status=500)
    return path


def _path_is_within(base: Path, candidate: Path) -> bool:
    try:
        return os.path.commonpath((str(base), str(candidate))) == str(base)
    except ValueError:
        return False


def _resolved_child(base: Path, relative: str, *, label: str) -> Path:
    """Resolve an existing-or-new child and enforce containment."""

    # macOS commonly aliases /var through /private/var.  Canonicalize the
    # trusted base as well as the candidate so that this harmless alias does
    # not look like an escape.  A symlink at the base itself is still rejected,
    # because callers must explicitly resolve only the supported install-root
    # symlink before reaching this helper.
    if base.is_symlink():
        raise FleetError(f"{label} escapes its managed root", code="fleet_path_escape", status=400)
    canonical_base = base.resolve(strict=False)
    candidate = (canonical_base / PurePosixPath(relative)).resolve(strict=False)
    if not _path_is_within(canonical_base, candidate):
        raise FleetError(f"{label} escapes its managed root", code="fleet_path_escape", status=400)
    return candidate


def _path_has_symlink_component(base: Path, candidate: Path) -> bool:
    """Check lexical path components below a resolved managed root."""

    try:
        relative = candidate.relative_to(base)
    except ValueError:
        return True
    cursor = base
    try:
        for part in relative.parts:
            cursor = cursor / part
            if cursor.is_symlink():
                return True
    except OSError:
        return True
    return False


def _ensure_root(path: Path, *, allow_root_symlink: bool, create: bool = True) -> Path:
    """Create an install root and return its resolved destination.

    ``~/.agents/skills`` is intentionally allowed to be a symlink on the
    supported Macs.  The symlink itself is never replaced, and all later
    containment checks use the resolved destination returned here.
    """

    try:
        if path.is_symlink():
            if not allow_root_symlink:
                raise FleetError(
                    "managed root may not be a symlink",
                    code="fleet_root_symlink",
                    status=409,
                )
            resolved = path.resolve(strict=True)
            if not resolved.is_dir():
                raise FleetError("managed root is not a directory", code="fleet_root_invalid", status=409)
            return resolved
        if not path.exists() and not create:
            return path.resolve(strict=False)
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        resolved = path.resolve(strict=True)
        if not resolved.is_dir():
            raise FleetError("managed root is not a directory", code="fleet_root_invalid", status=409)
        return resolved
    except FleetError:
        raise
    except OSError:
        raise FleetError("managed root is unavailable", code="fleet_root_unavailable", status=503)


def _safe_checkout_path(path: Path) -> Path:
    """Resolve a checkout without accepting a symlinked managed root."""

    try:
        if path.is_symlink():
            raise FleetError(
                "managed catalog checkout may not be a symlink",
                code="catalog_checkout_symlink",
                status=409,
            )
        if path.exists() and not path.is_dir():
            raise FleetError(
                "managed catalog checkout is not a directory",
                code="catalog_checkout_invalid",
                status=409,
            )
        return path.resolve(strict=False)
    except FleetError:
        raise
    except OSError:
        raise FleetError("managed catalog checkout is unavailable", code="catalog_checkout_unavailable", status=503)


def _tree_has_symlink(path: Path) -> bool:
    try:
        for root, dirs, files in os.walk(path, topdown=True, followlinks=False):
            for name in (*dirs, *files):
                if (Path(root) / name).is_symlink():
                    return True
    except OSError:
        return True
    return False


def _tree_digest(path: Path) -> Optional[str]:
    """Return a deterministic digest, or ``None`` for unsafe/unreadable data."""

    if path.is_symlink() or not path.exists():
        return None
    digest = hashlib.sha256()
    count = 0
    try:
        if path.is_file():
            stat = path.stat()
            if stat.st_size > MAX_ITEM_FILE_BYTES:
                return None
            digest.update(b"file\0")
            with path.open("rb") as handle:
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
            return digest.hexdigest()
        if not path.is_dir() or _tree_has_symlink(path):
            return None
        for root, dirs, files in os.walk(path, topdown=True, followlinks=False):
            dirs.sort()
            files.sort()
            root_path = Path(root)
            relative_root = root_path.relative_to(path).as_posix()
            for name in dirs:
                count += 1
                if count > MAX_ITEM_FILES:
                    return None
                digest.update(b"dir\0")
                digest.update((relative_root + "/" + name).encode("utf-8", "strict"))
            for name in files:
                count += 1
                if count > MAX_ITEM_FILES:
                    return None
                file_path = root_path / name
                stat = file_path.stat()
                if stat.st_size > MAX_ITEM_FILE_BYTES:
                    return None
                relative = (root_path / name).relative_to(path).as_posix()
                digest.update(b"file\0")
                digest.update(relative.encode("utf-8", "strict"))
                with file_path.open("rb") as handle:
                    while True:
                        chunk = handle.read(1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
        return digest.hexdigest()
    except (OSError, UnicodeError, ValueError):
        return None


def _catalog_file_digest(path: Path) -> Optional[str]:
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_CATALOG_BYTES:
            return None
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def _redact_environment_auth(environ: Mapping[str, Any]) -> dict[str, Any]:
    """Expose only boolean auth state, never a credential or path."""

    api_configured = bool(_safe_text(environ.get("HERDR_HARNESS_API_TOKEN")))
    manage_configured = bool(_safe_text(environ.get("HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN")))
    manage_file = _safe_text(environ.get("HERDR_HARNESS_ACTIVE_WORK_MANAGE_TOKEN_FILE"))
    if not manage_file:
        home = _safe_text(environ.get("HOME"))
        if home and os.path.isabs(home):
            manage_file = str(Path(home) / ".config" / "herdr-harness" / "active-work-manage-token")
    if manage_file:
        try:
            manage_configured = manage_configured or Path(manage_file).is_file()
        except OSError:
            pass
    ingest_configured = bool(_safe_text(environ.get("HERDR_HARNESS_ACTIVE_WORK_INGEST_TOKEN")))
    apns_configured = all(
        bool(_safe_text(environ.get(name)))
        for name in ("HERDR_APNS_KEY_ID", "HERDR_APNS_TEAM_ID", "HERDR_APNS_KEY_PATH")
    )
    return {
        "api": {"configured": api_configured},
        "activeWork": {
            "manageConfigured": manage_configured,
            "ingestConfigured": ingest_configured,
        },
        "push": {"configured": apns_configured},
    }


def _machine_metadata(environ: Mapping[str, Any], session: str = "") -> dict[str, Any]:
    return {
        "platform": _safe_text(platform.system(), maximum=32) or "unknown",
        "release": _safe_text(platform.release(), maximum=64),
        "architecture": _safe_text(platform.machine(), maximum=32),
        "python": f"{platform.python_version().split('.')[0]}.{platform.python_version().split('.')[1]}",
    }


def _canonical_repository(value: str) -> str:
    """Canonicalize a repository identifier without accepting credentials."""

    value = value.strip()
    if not value or "\x00" in value or any(ch.isspace() for ch in value):
        raise FleetError("catalog repository is invalid", code="invalid_catalog_repository", status=500)
    if value.startswith("/"):
        return str(Path(value).resolve(strict=False))
    if value.startswith("file://"):
        parsed = urllib.parse.urlsplit(value)
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise FleetError("catalog repository is invalid", code="invalid_catalog_repository", status=500)
        return str(Path(urllib.parse.unquote(parsed.path)).resolve(strict=False))
    # Treat the only allowlisted GitHub repository's SSH and HTTPS spellings
    # as the same origin.  Credentials, query strings, and fragments remain
    # forbidden above.
    github_match = re.fullmatch(
        r"(?:git@github\.com:|ssh://git@github\.com/|https://github\.com/|http://github\.com/)?(.+)",
        value,
        re.IGNORECASE,
    )
    if github_match and github_match.group(1).lower().rstrip("/") == "ronnie3786/personal-claude-plugin.git":
        return "github.com/ronnie3786/personal-claude-plugin.git"
    # SSH scp syntax has no URL username field, but the host and path are still
    # constrained to the configured value by the exact comparison below.
    parsed = urllib.parse.urlsplit(value)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise FleetError("catalog repository is invalid", code="invalid_catalog_repository", status=500)
    return value.rstrip("/")


def _repository_from_environment(environ: Mapping[str, Any]) -> str:
    raw = ""
    for name in (
        "HERDR_FLEET_CATALOG_REPOSITORY",
        "HERDR_FLEET_REPOSITORY",
        "HERDR_FLEET_CATALOG_REPO",
        "HERDR_FLEET_REPO",
    ):
        if environ.get(name):
            raw = str(environ[name])
            break
    if not raw:
        # Keep a cloneable spelling for the default.  _canonical_repository is
        # used at every trust comparison boundary, so the spelling here does
        # not weaken the allowlist.
        return DEFAULT_CATALOG_REPOSITORY
    candidate = _canonical_repository(raw)
    # A local checkout is useful for hermetic tests and for an operator who
    # has intentionally staged the catalog locally.  All network spellings
    # must resolve to the one private GitHub repository, and HTTP is not an
    # acceptable transport for the real catalog.
    if os.path.isabs(raw) or raw.startswith("file://"):
        test_mode = str(environ.get("HERDR_FLEET_TEST_MODE", "")).strip().lower() in {"1", "true", "yes"}
        # Local repository overrides are intentionally a test-only escape hatch.
        # Production must always use the one private GitHub origin, even when a
        # caller can influence the service environment.
        if not test_mode:
            raise FleetError(
                "local catalog repositories are only available in Fleet tests",
                code="invalid_catalog_repository",
                status=500,
            )
        return candidate
    if raw.lower().startswith("http://"):
        raise FleetError("catalog repository is invalid", code="invalid_catalog_repository", status=500)
    if candidate != "github.com/ronnie3786/personal-claude-plugin.git":
        raise FleetError("catalog repository is not allowlisted", code="invalid_catalog_repository", status=500)
    if not raw.lower().startswith(("git@github.com:", "ssh://git@github.com/", "https://github.com/")):
        raise FleetError("catalog repository is invalid", code="invalid_catalog_repository", status=500)
    return raw.rstrip("/")


def _subprocess_timeout(environ: Mapping[str, Any]) -> float:
    try:
        value = float(environ.get("HERDR_FLEET_COMMAND_TIMEOUT_SECONDS", DEFAULT_SUBPROCESS_SECONDS))
    except (TypeError, ValueError):
        value = DEFAULT_SUBPROCESS_SECONDS
    return max(1.0, min(MAX_SUBPROCESS_SECONDS, value))


def _which(environ: Mapping[str, Any], command: str) -> Optional[str]:
    """Resolve an executable using the service's environment, not globals."""

    configured_path = environ.get("PATH")
    path = configured_path if isinstance(configured_path, str) else None
    return shutil.which(command, path=path)


def _run_command(
    executable: str,
    args: list[str],
    *,
    cwd: Optional[Path],
    timeout: float,
    error_code: str,
    status: int = 502,
    discard_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run a fixed argv command with no shell and generic diagnostics."""

    try:
        command_options: dict[str, Any] = {
            "cwd": str(cwd) if cwd is not None else None,
            "timeout": timeout,
            "check": False,
            "shell": False,
        }
        if discard_output:
            command_options.update(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            command_options.update(capture_output=True, text=True)
        result = subprocess.run([executable, *args], **command_options)
    except FileNotFoundError as exc:
        raise FleetError("required adapter is unavailable", code="adapter_unavailable", status=503) from exc
    except subprocess.TimeoutExpired as exc:
        raise FleetError("Fleet operation timed out", code="fleet_timeout", status=504) from exc
    except OSError as exc:
        raise FleetError("Fleet operation could not start", code=error_code, status=status) from exc
    if result.returncode != 0:
        raise FleetError("Fleet operation failed", code=error_code, status=status)
    return result


def _git(executable: str, args: list[str], *, cwd: Path, timeout: float, code: str = "catalog_git_error") -> subprocess.CompletedProcess[str]:
    return _run_command(executable, ["-c", "protocol.version=2", *args], cwd=cwd, timeout=timeout, error_code=code)


class _CatalogItem:
    __slots__ = (
        "id",
        "type",
        "name",
        "source",
        "target",
        "adapter",
        "formula",
        "command",
        "auth_env",
        "version_argv",
        "auth_argv",
        "version_timeout",
        "auth_timeout",
        "read_only_checks",
        "auth_check",
        "writable",
        "classification",
        "destination",
    )

    def __init__(
        self,
        *,
        item_id: str,
        item_type: str,
        name: str,
        source: str = "",
        target: str = "",
        adapter: str = "",
        formula: str = "",
        command: str = "",
        auth_env: tuple[str, ...] = (),
        version_argv: tuple[str, ...] = (),
        auth_argv: tuple[str, ...] = (),
        version_timeout: Optional[float] = None,
        auth_timeout: Optional[float] = None,
        read_only_checks: tuple[tuple[tuple[str, ...], str, float], ...] = (),
        auth_check: bool = False,
        writable: bool = True,
        classification: str = "managed",
        destination: str = "agents",
    ) -> None:
        self.id = item_id
        self.type = item_type
        self.name = name
        self.source = source
        self.target = target
        self.adapter = adapter
        self.formula = formula
        self.command = command
        self.auth_env = auth_env
        self.version_argv = version_argv
        self.auth_argv = auth_argv
        self.version_timeout = version_timeout
        self.auth_timeout = auth_timeout
        self.read_only_checks = read_only_checks
        self.auth_check = auth_check
        self.writable = writable
        self.classification = classification
        self.destination = destination


class _Catalog:
    def __init__(self, *, checkout: Path, revision: str, fleet_file_digest: str, items: list[_CatalogItem]) -> None:
        self.checkout = checkout
        self.revision = revision
        self.fleet_file_digest = fleet_file_digest
        self.items = items


class FleetManager:
    """Manage one machine's checkout, install roots, and inventory state."""

    def __init__(self, *, environ: Optional[Mapping[str, Any]] = None, session: str = "") -> None:
        self.environ: dict[str, Any] = dict(os.environ if environ is None else environ)
        self.home = _home_from_environment(self.environ)
        self.repository = _repository_from_environment(self.environ)
        explicit_checkout = any(
            bool(self.environ.get(name))
            for name in ("HERDR_FLEET_CATALOG_PATH", "HERDR_FLEET_CHECKOUT_PATH", "HERDR_FLEET_REPO_PATH")
        )
        self._checkout_explicit = explicit_checkout
        self.managed_checkout = _safe_checkout_path(
            _configured_path(
                self.environ,
                ("HERDR_FLEET_CATALOG_PATH", "HERDR_FLEET_CHECKOUT_PATH", "HERDR_FLEET_REPO_PATH"),
                self.home / DEFAULT_CATALOG_RELATIVE_PATH,
                label="Fleet catalog checkout",
            )
        )
        self.checkout = self.managed_checkout
        self.state_path = _configured_path(
            self.environ,
            ("HERDR_FLEET_STATE_PATH", "HERDR_HARNESS_FLEET_STATE_PATH"),
            self.home / DEFAULT_STATE_RELATIVE_PATH,
            label="Fleet state path",
        )
        self._quarantine_path = _configured_path(
            self.environ,
            ("HERDR_FLEET_QUARANTINE_PATH", "HERDR_HARNESS_FLEET_QUARANTINE_PATH"),
            self.home / ".local" / "share" / "herdr-fleet" / "quarantine",
            label="Fleet quarantine path",
        )
        self.quarantine_root = _ensure_root(self._quarantine_path, allow_root_symlink=False, create=False)
        self._skills_path = self.home / ".agents" / "skills"
        self._pi_extensions_path = self.home / ".pi" / "agent" / "extensions"
        self._rocketbot_skills_path = self.home / ".hermes" / "profiles" / "rocketbot" / "skills"
        self.skills_root = _ensure_root(
            self._skills_path,
            allow_root_symlink=True,
            create=False,
        )
        self.pi_extensions_root = _ensure_root(
            self._pi_extensions_path,
            allow_root_symlink=True,
            create=False,
        )
        self.rocketbot_skills_root = _ensure_root(
            self._rocketbot_skills_path,
            allow_root_symlink=False,
            create=False,
        )
        self.timeout = _subprocess_timeout(self.environ)
        self.session = session or str(self.environ.get("HERDR_SESSION") or "")
        self._lock = threading.RLock()

    def _checkout_candidates(self) -> list[Path]:
        if self._checkout_explicit:
            return [self.managed_checkout]
        # These are the two known sync-skills source locations.  They are
        # candidates only after the Git remote is verified, never merely
        # because a similarly named directory exists.
        return [
            self.home / "Documents" / "Development" / "personal-claude-plugin",
            self.home / "Code" / "ronnie3786" / "personal-claude-plugin",
            self.managed_checkout,
        ]

    def _trusted_existing_checkout(
        self,
        *,
        require_git: bool = True,
        require_current: bool = True,
    ) -> Optional[Path]:
        if require_git:
            try:
                git = self._git_executable()
            except FleetError as exc:
                if exc.code == "adapter_unavailable":
                    return None
                raise
        else:
            git = _which(self.environ, "git")
        for candidate in self._checkout_candidates():
            managed_candidate = candidate == self.managed_checkout
            try:
                candidate = _safe_checkout_path(candidate)
            except FleetError:
                if self._checkout_explicit or managed_candidate:
                    raise
                # A same-name source path that is a symlink or a non-directory
                # is not a candidate.  Continue to the next known location,
                # never follow or mutate it.
                continue
            managed_candidate = candidate == self.managed_checkout
            if not candidate.exists():
                continue
            git_metadata = candidate / ".git"
            if (
                not candidate.is_dir()
                or candidate.is_symlink()
                or git_metadata.is_symlink()
                or not (git_metadata.is_dir() or git_metadata.is_file())
            ):
                if managed_candidate:
                    raise FleetError(
                        "managed catalog checkout is not a regular Git checkout",
                        code="catalog_checkout_invalid",
                        status=409,
                    )
                continue
            if git is None:
                continue
            try:
                # Implicit user checkouts are only reusable when they satisfy
                # the same branch, upstream, and cleanliness boundary as a
                # managed checkout.  A sync may still select a clean stale
                # checkout so it can fetch and fast-forward it below.
                self._validate_trusted_checkout_for_read(candidate, require_current=require_current)
            except FleetError:
                # An invalid implicit user checkout is left untouched and
                # ignored.  Explicit configuration and the managed fallback
                # remain strict, so an unsafe managed checkout can never be
                # silently replaced by a clone.
                if self._checkout_explicit or managed_candidate:
                    raise
                continue
            return candidate
        return None

    def _select_checkout(self, *, require_existing: bool = False, require_current: bool = True) -> Path:
        if self._checkout_explicit:
            return self.managed_checkout
        existing = self._trusted_existing_checkout(require_current=require_current)
        if existing is not None:
            self.checkout = existing
            return existing
        if require_existing:
            raise FleetError("Fleet catalog is not synced", code="catalog_unavailable", status=503)
        self.checkout = self.managed_checkout
        return self.managed_checkout

    def _item_root(self, item: _CatalogItem) -> Path:
        if item.type == "pi_extension":
            return self.pi_extensions_root
        if item.type == "skill" and item.destination == "rocketbot":
            return self.rocketbot_skills_root
        return self.skills_root

    @staticmethod
    def _record_matches_item(record: Any, item: _CatalogItem) -> bool:
        """Return whether persisted ownership belongs to this exact target.

        Older state files predate the RocketBot destination field.  Treat a
        missing destination as the historical agents root only, preserving
        compatibility without allowing a record to cross safe roots.
        """

        if not isinstance(record, dict):
            return False
        if record.get("type") != item.type or record.get("source") != item.source or record.get("target") != item.target:
            return False
        if item.type == "skill":
            return record.get("destination", "agents") == item.destination
        return True

    # ------------------------------------------------------------------
    # State and catalog discovery

    def _empty_state(self) -> dict[str, Any]:
        return {"version": 1, "catalog": {}, "managed": {}}

    def _load_state(self, *, strict: bool = False) -> dict[str, Any]:
        if not self.state_path.exists():
            return self._empty_state()
        try:
            if self.state_path.is_symlink() or not self.state_path.is_file():
                raise OSError("not a regular state file")
            with self.state_path.open("rb") as handle:
                raw = handle.read(MAX_CATALOG_BYTES)
                if len(raw) == MAX_CATALOG_BYTES:
                    raise OSError("state file too large")
            value = json.loads(raw.decode("utf-8"))
            if not isinstance(value, dict) or value.get("version") != 1:
                raise ValueError("unsupported state")
            managed = value.get("managed", {})
            if not isinstance(managed, dict):
                raise ValueError("invalid managed state")
            return value
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            if strict:
                raise FleetError("Fleet state is invalid", code="fleet_state_invalid", status=409) from exc
            return self._empty_state()

    def _save_state(self, state: dict[str, Any]) -> None:
        parent = self.state_path.parent
        try:
            parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if self.state_path.is_symlink():
                raise OSError("state path is a symlink")
            fd, temporary = tempfile.mkstemp(prefix=".fleet-state-", suffix=".tmp", dir=str(parent))
            temporary_path = Path(temporary)
            try:
                os.fchmod(fd, 0o600)
                encoded = json.dumps(state, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
                view = memoryview(encoded)
                while view:
                    written = os.write(fd, view)
                    view = view[written:]
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(temporary_path, self.state_path)
            try:
                directory_fd = os.open(parent, os.O_RDONLY)
            except OSError:
                directory_fd = -1
            if directory_fd >= 0:
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
        except OSError as exc:
            try:
                if "temporary_path" in locals() and temporary_path.exists():
                    temporary_path.unlink()
            except OSError:
                pass
            raise FleetError("Fleet state could not be saved", code="fleet_state_write_failed", status=503) from exc

    def _git_executable(self) -> str:
        executable = _which(self.environ, "git")
        if not executable:
            raise FleetError("Git adapter is unavailable", code="adapter_unavailable", status=503)
        return executable

    def _revision(self, checkout: Path) -> str:
        result = _git(self._git_executable(), ["rev-parse", "HEAD"], cwd=checkout, timeout=self.timeout)
        revision = _safe_text(result.stdout, maximum=128).splitlines()[0] if result.stdout else ""
        if not _HEX_RE.fullmatch(revision):
            raise FleetError("catalog revision is invalid", code="catalog_invalid", status=409)
        return revision.lower()

    def _read_catalog(self, checkout: Path) -> _Catalog:
        fleet_file = checkout / "fleet.json"
        fleet_digest = _catalog_file_digest(fleet_file)
        if fleet_digest is None:
            raise FleetError("fleet.json is required", code="catalog_invalid", status=409)
        try:
            with fleet_file.open("rb") as handle:
                raw = handle.read(MAX_CATALOG_BYTES + 1)
            if len(raw) > MAX_CATALOG_BYTES:
                raise FleetError("fleet.json is too large", code="catalog_invalid", status=409)
            value = json.loads(raw.decode("utf-8"))
        except FleetError:
            raise
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise FleetError("fleet.json is invalid", code="catalog_invalid", status=409) from exc
        if not isinstance(value, dict):
            raise FleetError("fleet.json must contain an object", code="catalog_invalid", status=409)
        if type(value.get("schemaVersion")) is not int or value.get("schemaVersion") != 1:
            raise FleetError("fleet.json schema version is unsupported", code="catalog_invalid", status=409)
        if value.get("catalogId") != "herdr-fleet":
            raise FleetError("fleet.json catalog identity is invalid", code="catalog_invalid", status=409)
        revision = self._revision(checkout)
        items = self._parse_catalog_items(checkout, value)
        return _Catalog(checkout=checkout, revision=revision, fleet_file_digest=fleet_digest, items=items)

    def _parse_auth_env(self, value: Any) -> tuple[str, ...]:
        if value is None:
            return ()
        if isinstance(value, str):
            values = [value]
        elif isinstance(value, list):
            values = value[:16]
        else:
            raise FleetError("catalog auth metadata is invalid", code="catalog_invalid", status=409)
        return tuple(_safe_env_name(item) for item in values)

    @staticmethod
    def _entries(value: Any) -> list[Any]:
        if value is None:
            return []
        if isinstance(value, list):
            return value
        if isinstance(value, dict):
            # A mapping keyed by item name is a convenient, safe shorthand.
            return [dict(item, name=name) if isinstance(item, dict) else {"name": name, "value": item} for name, item in value.items()]
        raise FleetError("catalog item list is invalid", code="catalog_invalid", status=409)

    @staticmethod
    def _argv(value: Any, command: str, *, fixed: Optional[tuple[str, ...]] = None) -> tuple[str, ...]:
        """Validate an optional read-only argv recipe.

        An inventory-only recipe may describe how to ask a known executable
        for a version or auth status.  It may not select a different
        executable, contain shell syntax, or carry unbounded output.  The
        executable must be the first argv element, even when the catalog also
        carries an explicit command field.
        """

        if fixed is not None:
            return fixed
        if value is None:
            return ()
        if not isinstance(value, list) or not 1 <= len(value) <= 16:
            raise FleetError("catalog argv is invalid", code="catalog_invalid", status=409)
        result = tuple(value)
        if result[0] != command:
            raise FleetError("catalog argv executable is invalid", code="catalog_invalid", status=409)
        for token in result:
            if not isinstance(token, str) or not token or len(token) > 128 or "\x00" in token:
                raise FleetError("catalog argv is invalid", code="catalog_invalid", status=409)
            if any(character.isspace() for character in token) or token.startswith(";"):
                raise FleetError("catalog argv is invalid", code="catalog_invalid", status=409)
            if any(character in token for character in ";&|<>$`()"):
                raise FleetError("catalog argv is invalid", code="catalog_invalid", status=409)
        return result

    def _probe_timeout(self, value: Any) -> float:
        """Return a bounded timeout for one catalog read-only probe."""

        if value is None:
            return min(self.timeout, 15.0)
        if isinstance(value, bool):
            raise FleetError("catalog probe timeout is invalid", code="catalog_invalid", status=409)
        try:
            timeout = float(value)
        except (TypeError, ValueError) as exc:
            raise FleetError("catalog probe timeout is invalid", code="catalog_invalid", status=409) from exc
        if not math.isfinite(timeout) or not 1.0 <= timeout <= 15.0:
            raise FleetError("catalog probe timeout is invalid", code="catalog_invalid", status=409)
        return timeout

    def _parse_read_only_check(self, value: Any, command: str) -> tuple[tuple[str, ...], str, float]:
        """Validate one exact, output-discarding read-only check."""

        if not isinstance(value, dict):
            raise FleetError("catalog read-only check is invalid", code="catalog_invalid", status=409)
        if value.get("readOnly") is not True or str(value.get("outputPolicy", "")).strip().lower() != "discard":
            raise FleetError("catalog read-only check must discard output", code="catalog_invalid", status=409)
        raw_argv = value.get("argv") if "argv" in value else value.get("command")
        if isinstance(raw_argv, str):
            argv: list[Any] = [raw_argv]
        elif isinstance(raw_argv, list):
            argv = list(raw_argv)
        else:
            raise FleetError("catalog read-only check argv is invalid", code="catalog_invalid", status=409)
        if "args" in value:
            args = value.get("args")
            if not isinstance(args, list):
                raise FleetError("catalog read-only check args are invalid", code="catalog_invalid", status=409)
            argv.extend(args)
        if not argv or argv[0] != command:
            raise FleetError("catalog read-only check executable is invalid", code="catalog_invalid", status=409)
        normalized = FleetManager._argv(argv, command)
        if normalized not in READONLY_PROBE_ARGV:
            raise FleetError("catalog read-only check is not allowlisted", code="catalog_invalid", status=409)
        check_name = str(value.get("name") or value.get("kind") or value.get("id") or "").strip().lower().replace("-", "_")
        if not check_name:
            tokens = {token.lower() for token in normalized[1:]}
            if tokens.intersection({"auth", "authentication", "status", "whoami", "login"}):
                check_name = "auth"
            elif tokens.intersection({"version", "--version", "-v"}):
                check_name = "version"
        if check_name in {"version_check", "versioncheck"}:
            check_name = "version"
        elif check_name in {"auth_check", "authcheck", "authentication"}:
            check_name = "auth"
        return normalized, check_name, self._probe_timeout(value.get("timeoutSeconds"))

    def _skill_classifications(self, checkout: Path) -> dict[str, str]:
        """Read the optional upstream ownership classification file."""

        path = checkout / "skills" / ".config" / "classifications.json"
        if path.is_symlink() or not path.is_file():
            return {}
        try:
            if path.stat().st_size > 512 * 1024:
                raise OSError("classification file too large")
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise FleetError("skill classifications are invalid", code="catalog_invalid", status=409) from exc
        result: dict[str, str] = {}

        def add(key: Any, classification: Any) -> None:
            if not isinstance(key, str) or not isinstance(classification, str):
                return
            normalized = classification.strip().lower().replace("-", "_")
            if normalized not in {"external", "personal", "work", "managed", "readonly", "read_only", "unclassified", "orphan"}:
                return
            # Match by a safe leaf name as well as a source-relative name.
            result[key.strip("/")] = "external" if normalized == "external" else normalized

        if isinstance(value, dict):
            # Supported forms include {"foo": "external"},
            # {"external": ["foo", ...]}, and a list-bearing object under
            # ``classifications``.
            nested = value.get("classifications")
            if isinstance(nested, dict):
                for key, classification in nested.items():
                    if isinstance(classification, dict):
                        add(key, classification.get("classification") or classification.get("ownership") or "")
                    else:
                        add(key, classification)
            for key, classification in value.items():
                if key == "classifications":
                    continue
                if isinstance(classification, list):
                    for item in classification:
                        add(item, key)
                elif isinstance(classification, dict):
                    add(key, classification.get("classification") or classification.get("ownership") or "")
                else:
                    add(key, classification)
        elif isinstance(value, list):
            for entry in value:
                if isinstance(entry, dict):
                    add(entry.get("name") or entry.get("path"), entry.get("classification") or entry.get("ownership") or "")
        return result

    @staticmethod
    def _skill_classification(classifications: Mapping[str, str], source: str, target: str) -> str:
        source = source.strip("/")
        target = target.strip("/")
        for key in (source, f"skills/{source}", target, PurePosixPath(source).name):
            value = classifications.get(key)
            if value:
                return value
        return ""

    @staticmethod
    def _skill_root_specs(value: Any) -> list[dict[str, Any]]:
        """Normalize manifest-declared skill groups.

        The catalog's real tree contains nested vendor packages.  A manifest
        must therefore opt into the roots and scan depth that define actual
        installable skills.  With no manifest, only the conventional flat
        one-level roots are scanned.
        """

        if value is None:
            return []
        if isinstance(value, dict) and not any(key in value for key in ("path", "root", "source", "group")):
            entries = []
            for group_name, group_value in value.items():
                if isinstance(group_value, dict):
                    entries.append(dict(group_value, group=group_name))
                else:
                    entries.append({"path": group_value, "group": group_name})
        else:
            entries = value if isinstance(value, list) else [value]
        specs: list[dict[str, Any]] = []
        for entry in entries:
            if isinstance(entry, str):
                entry = {"path": entry}
            if not isinstance(entry, dict):
                raise FleetError("catalog skill root is invalid", code="catalog_invalid", status=409)
            group = str(entry.get("group") or "").strip().lower()
            path = entry.get("path") or entry.get("root") or entry.get("source")
            if path is None:
                # An informational/external group may intentionally have no
                # source root.  Its members are still surfaced from the
                # concrete roots and classifications file.
                if group in {"external", "readonly", "read_only"} or entry.get("writable") is False or entry.get("managed") is False:
                    continue
                raise FleetError("catalog skill root path is required", code="catalog_invalid", status=409)
            if not isinstance(path, str):
                raise FleetError("catalog skill root path is required", code="catalog_invalid", status=409)
            path = path.removeprefix("skills/")
            path = "" if path in {".", ""} else _safe_relative(path, "skill root")
            recursive = bool(entry.get("recursive", entry.get("scanRecursively", entry.get("scan_recursively", False))))
            if str(entry.get("discovery") or "").strip().lower() in {"recursive", "recurse"}:
                recursive = True
            try:
                default_depth = 8 if recursive else 1
                scan_depth = int(entry.get("scanDepth", entry.get("scan_depth", entry.get("maxDepth", entry.get("max_depth", default_depth)))))
            except (TypeError, ValueError) as exc:
                raise FleetError("catalog skill root depth is invalid", code="catalog_invalid", status=409) from exc
            if not 1 <= scan_depth <= 8:
                raise FleetError("catalog skill root depth is invalid", code="catalog_invalid", status=409)
            if recursive and "scanDepth" not in entry and "scan_depth" not in entry and "maxDepth" not in entry and "max_depth" not in entry:
                scan_depth = 8
            target_policy_raw = entry.get("targetPolicy", entry.get("target_policy"))
            if target_policy_raw is None:
                target_policy_raw = "preserve-relative" if entry.get("preserveRelativePaths", entry.get("preserve_relative_paths", False)) or entry.get("destinationMode", entry.get("destination_mode")) in {"preserve", "preserveRelative", "preserve-relative"} else "flat"
            target_policy = str(target_policy_raw).strip().lower().replace("_", "-")
            if target_policy not in {"flat", "preserve-relative", "preserve"}:
                raise FleetError("catalog skill target policy is invalid", code="catalog_invalid", status=409)
            classification = str(entry.get("classification") or entry.get("ownership") or "").strip().lower().replace("-", "_")
            if not classification and group in {"personal", "work"}:
                classification = group
            raw_destination = entry.get("destination") or entry.get("destinationRoot") or entry.get("destination_root") or "agents"
            destination_text = str(raw_destination).strip().lower().replace("_", "-").rstrip("/")
            if destination_text in {"agents", "agent", "agents-skills", "claude", "~/.agents/skills", ".agents/skills"}:
                destination = "agents"
            elif destination_text in {"rocketbot", "rocketbot-skills", "~/.hermes/profiles/rocketbot/skills", ".hermes/profiles/rocketbot/skills"}:
                destination = "rocketbot"
            else:
                raise FleetError("catalog skill destination is not allowed", code="catalog_invalid", status=409)
            specs.append(
                {
                    "path": path,
                    "scan_depth": scan_depth,
                    "recursive": recursive,
                    "target_policy": target_policy,
                    "destination": destination,
                    "classification": classification,
                    "writable": bool(entry.get("writable", entry.get("managed", group in {"personal", "work"} or classification not in {"external", "readonly", "read_only"}))),
                }
            )
        return specs

    @staticmethod
    def _skill_source_paths(root: Path, *, scan_depth: int, recursive: bool = False) -> list[tuple[str, Path]]:
        """Find skill package directories at exactly the requested depth."""

        if not root.is_dir() or root.is_symlink():
            return []
        found: list[tuple[str, Path]] = []
        for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
            dirs[:] = sorted(item for item in dirs if not item.startswith("."))
            current_path = Path(current)
            depth = len(current_path.relative_to(root).parts)
            # ``scan_depth`` is a hard traversal boundary for both direct and
            # recursive groups.  Without pruning recursive children here, a
            # deeply nested vendor skill tree could exceed the manifest's
            # declared maximum and unexpectedly become installable.
            if depth >= scan_depth:
                dirs[:] = []
            if (depth < 1 or depth > scan_depth or (not recursive and depth != scan_depth)) or "SKILL.md" not in files:
                continue
            candidate = current_path / "SKILL.md"
            if candidate.is_symlink() or not candidate.is_file() or _tree_has_symlink(current_path):
                raise FleetError("catalog skill contains a symlink", code="catalog_invalid", status=409)
            found.append((current_path.relative_to(root.parent).as_posix(), current_path))
        return found

    def _parse_catalog_items(self, checkout: Path, value: dict[str, Any]) -> list[_CatalogItem]:
        parsed: dict[str, _CatalogItem] = {}
        classifications = self._skill_classifications(checkout)
        # Flat names must be unique within one destination.  RocketBot is a
        # separate, explicitly allowlisted root, so a package may safely use
        # the same relative name there as an agents skill.
        skill_targets: dict[tuple[str, str], str] = {}
        extension_targets: dict[str, str] = {}

        def add(item: _CatalogItem) -> None:
            if len(parsed) >= MAX_CATALOG_ITEMS and item.id not in parsed:
                raise FleetError("catalog contains too many items", code="catalog_invalid", status=409)
            existing = parsed.get(item.id)
            if existing is None:
                parsed[item.id] = item
            elif (
                existing.type != item.type
                or existing.source != item.source
                or existing.target != item.target
                or existing.destination != item.destination
            ):
                raise FleetError("catalog contains duplicate item IDs", code="catalog_invalid", status=409)

        def add_skill(
            *,
            source: str,
            candidate: Path,
            item_id: Optional[str] = None,
            name: Optional[str] = None,
            target: Optional[str] = None,
            writable: bool = False,
            classification: str = "",
            auth_env: tuple[str, ...] = (),
            allow_nested_target: bool = False,
            destination: str = "agents",
        ) -> None:
            source = _safe_relative(source, "skill path")
            target = _safe_relative(target or PurePosixPath(source).name, "skill target")
            if "/" in target and (destination != "rocketbot" or not allow_nested_target):
                raise FleetError("skill targets must be flat", code="catalog_invalid", status=409)
            classification = (self._skill_classification(classifications, source, target) or classification).lower().replace("-", "_")
            if not classification:
                classification = "managed" if writable else "readonly"
            writable = _item_writable(writable, classification)
            target_key = (destination, target)
            if target_key in skill_targets and skill_targets[target_key] != source:
                raise FleetError("catalog contains duplicate skill targets", code="catalog_invalid", status=409)
            skill_targets[target_key] = source
            source_root = checkout / "skills"
            lexical_source = source_root / PurePosixPath(source)
            if _path_has_symlink_component(source_root, lexical_source):
                raise FleetError("catalog skill source contains a symlink", code="catalog_invalid", status=409)
            resolved = _resolved_child(source_root, source, label="skill source")
            if not resolved.is_dir() or not (resolved / "SKILL.md").is_file() or (resolved / "SKILL.md").is_symlink():
                raise FleetError("catalog skill source is unavailable", code="catalog_invalid", status=409)
            if _tree_has_symlink(resolved):
                raise FleetError("catalog skill contains a symlink", code="catalog_invalid", status=409)
            item_id = _safe_item_id(item_id or f"skill:{source}")
            add(
                _CatalogItem(
                    item_id=item_id,
                    item_type="skill",
                    name=_safe_text(name or PurePosixPath(target).name, maximum=128),
                    source=f"skills/{source}",
                    target=target,
                    auth_env=auth_env,
                    writable=writable,
                    classification=classification or ("managed" if writable else "readonly"),
                    destination=destination,
                )
            )

        # Skills are discovered only from manifest-declared roots/groups.  A
        # conventional fallback handles a simple catalog without recursively
        # exposing nested vendor packages.  Explicit entries can still point to
        # any concrete package under skills/.
        discovered_skill_paths: dict[str, tuple[Path, dict[str, Any]]] = {}
        skills_dir = checkout / "skills"
        roots_value = value.get("skillRoots", value.get("skill_roots", value.get("skillGroups", value.get("skill_groups"))))
        root_specs = self._skill_root_specs(roots_value)
        if not root_specs:
            conventional = [name for name in ("personal", "work") if (skills_dir / name).is_dir()]
            if conventional:
                root_specs = [{"path": name, "scan_depth": 1, "target_policy": "flat", "classification": name, "writable": True, "destination": "agents"} for name in conventional]
            else:
                root_specs = [{"path": "", "scan_depth": 1, "target_policy": "flat", "classification": "", "writable": False, "destination": "agents"}]
        for spec in root_specs:
            root = _resolved_child(skills_dir, spec["path"], label="skill root") if spec["path"] else skills_dir.resolve(strict=False)
            for full_source, candidate in self._skill_source_paths(
                root,
                scan_depth=spec["scan_depth"],
                recursive=bool(spec.get("recursive")),
            ):
                source = full_source.removeprefix("skills/")
                discovered_skill_paths[source] = (candidate, spec)
        explicit_skills = self._entries(value.get("skills"))
        explicit_skill_sources: set[str] = set()
        for entry in explicit_skills:
            if isinstance(entry, str):
                entry = {"name": entry}
            if not isinstance(entry, dict):
                raise FleetError("catalog skill entry is invalid", code="catalog_invalid", status=409)
            raw_path = entry.get("path") or entry.get("source") or entry.get("name")
            if not isinstance(raw_path, str):
                raise FleetError("catalog skill path is required", code="catalog_invalid", status=409)
            raw_path = raw_path.removesuffix("/SKILL.md").rstrip("/")
            source = _safe_relative(raw_path, "skill path")
            if source.startswith("skills/"):
                source = source[len("skills/") :]
            explicit_skill_sources.add(source)
            classification = str(entry.get("classification") or entry.get("ownership") or "")
            writable = bool(entry.get("writable", entry.get("managed", classification.lower() not in {"external", "readonly", "read_only"})))
            target = entry.get("target") or entry.get("installName") or entry.get("install_name") or entry.get("name") or PurePosixPath(source).name
            explicit_target_policy = str(entry.get("targetPolicy", entry.get("target_policy", "flat"))).strip().lower().replace("_", "-")
            explicit_destination = entry.get("destination") or entry.get("destinationRoot") or entry.get("destination_root") or "agents"
            explicit_destination = str(explicit_destination).strip().lower().replace("_", "-").rstrip("/")
            if explicit_destination in {"agents", "agent", "agents-skills", "claude", "~/.agents/skills", ".agents/skills"}:
                explicit_destination = "agents"
            elif explicit_destination in {"rocketbot", "rocketbot-skills", "~/.hermes/profiles/rocketbot/skills", ".hermes/profiles/rocketbot/skills"}:
                explicit_destination = "rocketbot"
            else:
                raise FleetError("catalog skill destination is not allowed", code="catalog_invalid", status=409)
            add_skill(
                source=source,
                candidate=_resolved_child(checkout / "skills", source, label="skill source"),
                item_id=entry.get("id"),
                name=entry.get("name"),
                target=target,
                writable=writable,
                classification=classification,
                auth_env=self._parse_auth_env(entry.get("authEnv") or entry.get("auth_env")),
                allow_nested_target=explicit_target_policy in {"preserve", "preserve-relative"},
                destination=explicit_destination,
            )
        for source, (candidate, spec) in sorted(discovered_skill_paths.items()):
            if source in explicit_skill_sources:
                continue
            if spec["target_policy"] == "flat":
                target = PurePosixPath(source).name
            else:
                target = source
                if spec["path"] and target.startswith(spec["path"] + "/"):
                    target = target[len(spec["path"]) + 1 :]
            add_skill(
                source=source,
                candidate=candidate,
                target=target,
                writable=bool(spec["writable"]),
                classification=spec.get("classification", ""),
                allow_nested_target=spec["target_policy"] in {"preserve", "preserve-relative"},
                destination=spec.get("destination", "agents"),
            )

        # Pi extensions are regular files or directories below pi-extensions.
        # The common case is one .ts/.js file per item, but preserving a
        # relative directory allows package-style extensions too.
        discovered_extensions: dict[str, Path] = {}
        extensions_dir = checkout / "pi-extensions"
        if extensions_dir.is_dir() and not extensions_dir.is_symlink():
            # Auto-discover only standalone top-level JS/TS extensions.  A
            # declared package directory owns all of its descendants.
            for name in sorted(os.listdir(extensions_dir)):
                candidate = extensions_dir / name
                if name.startswith(".") or candidate.is_symlink():
                    continue
                if candidate.is_file() and candidate.suffix.lower() in {".js", ".mjs", ".cjs", ".ts", ".mts", ".cts"}:
                    discovered_extensions[_safe_relative(name, "Pi extension path")] = candidate
        explicit_extensions = value.get("piExtensions", value.get("pi_extensions", value.get("pi-extensions")))
        pi_defaults: dict[str, Any] = {}
        if isinstance(explicit_extensions, dict):
            pi_defaults = explicit_extensions
            declared_destination = explicit_extensions.get("destination")
            if declared_destination is not None:
                normalized_destination = str(declared_destination).strip().lower().replace("_", "-").rstrip("/")
                if normalized_destination not in {"~/.pi/agent/extensions", ".pi/agent/extensions", "pi-extensions"}:
                    raise FleetError("catalog Pi extension destination is not allowed", code="catalog_invalid", status=409)
            declared_path = explicit_extensions.get("path")
            if declared_path is not None and str(declared_path).removeprefix("./").rstrip("/") not in {"pi-extensions", ""}:
                raise FleetError("catalog Pi extension root is invalid", code="catalog_invalid", status=409)
        # The production manifest wraps entries with the source root and
        # destination metadata.  Only the entries are item declarations.
        if isinstance(explicit_extensions, dict) and "entries" in explicit_extensions:
            explicit_extensions = explicit_extensions.get("entries")
        explicit_extension_paths: set[str] = set()
        for entry in self._entries(explicit_extensions):
            if isinstance(entry, str):
                entry = {"path": entry}
            if not isinstance(entry, dict):
                raise FleetError("catalog Pi extension entry is invalid", code="catalog_invalid", status=409)
            raw_path = entry.get("path") or entry.get("source") or entry.get("name")
            if not isinstance(raw_path, str):
                raise FleetError("catalog Pi extension path is required", code="catalog_invalid", status=409)
            # Directory entries in fleet.json are commonly written with a
            # trailing slash, for example ``response-audio/``.  Normalize
            # that presentation without relaxing traversal checks.
            raw_path = raw_path.rstrip("/")
            relative = _safe_relative(raw_path, "Pi extension path")
            if relative.startswith("pi-extensions/"):
                relative = relative[len("pi-extensions/") :]
            lexical_source = extensions_dir / PurePosixPath(relative)
            if _path_has_symlink_component(extensions_dir, lexical_source):
                raise FleetError("catalog Pi extension source contains a symlink", code="catalog_invalid", status=409)
            candidate = _resolved_child(extensions_dir, relative, label="Pi extension source")
            if not candidate.exists() or not (candidate.is_file() or candidate.is_dir()):
                raise FleetError("catalog Pi extension source is unavailable", code="catalog_invalid", status=409)
            if _tree_has_symlink(candidate) if candidate.is_dir() else candidate.is_symlink():
                raise FleetError("catalog Pi extension contains a symlink", code="catalog_invalid", status=409)
            discovered_extensions[relative] = candidate
            item_id = _safe_item_id(entry.get("id") or f"pi-extension:{relative}")
            if relative in extension_targets and extension_targets[relative] != item_id:
                raise FleetError("catalog contains duplicate Pi extension targets", code="catalog_invalid", status=409)
            extension_targets[relative] = item_id
            explicit_extension_paths.add(relative)
            adapter = str(entry.get("adapter") or "managed").strip().lower()
            classification = str(entry.get("classification") or entry.get("ownership") or pi_defaults.get("classification") or pi_defaults.get("ownership") or "").strip().lower().replace("-", "_")
            default_writable = pi_defaults.get("writable", pi_defaults.get("managed", pi_defaults.get("sync") != "never"))
            if not classification:
                classification = "managed" if adapter == "managed" else adapter
            writable = bool(entry.get("writable", entry.get("managed", default_writable)))
            writable = _item_writable(writable, classification)
            add(
                _CatalogItem(
                    item_id=item_id,
                    item_type="pi_extension",
                    name=_safe_text(entry.get("name") or PurePosixPath(relative).name, maximum=128),
                    source=f"pi-extensions/{relative}",
                    target=relative,
                    auth_env=self._parse_auth_env(entry.get("authEnv") or entry.get("auth_env")),
                    writable=writable,
                    classification=classification,
                )
            )
        for relative in sorted(discovered_extensions):
            if relative in explicit_extension_paths:
                continue
            item_id = _safe_item_id(f"pi-extension:{relative}")
            if item_id not in parsed:
                add(
                    _CatalogItem(
                        item_id=item_id,
                        item_type="pi_extension",
                        name=PurePosixPath(relative).name,
                        source=f"pi-extensions/{relative}",
                        target=relative,
                        writable=False,
                        classification="readonly",
                    )
                )

        # CLI recipes are declarative and inventory-only.  Even a legacy
        # Homebrew recipe is never allowed to install, upgrade, or remove a
        # command through Fleet.  Catalog checks may only run known
        # executables with explicit output-discarding policy.
        cli_value = value.get("cli", value.get("cliRecipes", value.get("cli_recipes", value.get("cliCatalog", value.get("cli_catalog")))))
        if isinstance(cli_value, dict) and "entries" in cli_value:
            cli_value = cli_value.get("entries")
        for entry in self._entries(cli_value):
            if isinstance(entry, str):
                entry = {"formula": entry}
            if not isinstance(entry, dict):
                raise FleetError("catalog CLI entry is invalid", code="catalog_invalid", status=409)
            raw_adapter = entry.get("adapter") or entry.get("provider")
            adapter = str(raw_adapter or "").strip().lower()
            formula = entry.get("formula") or entry.get("package") or ""
            # A command-only recipe is inventory-only by default.  Apply this
            # before adapter validation so the exact cliCatalog shape can omit
            # both ``adapter`` and Homebrew ``formula`` safely.
            if not raw_adapter:
                adapter = "homebrew" if formula else "inventory"
            if adapter not in {"homebrew", "brew", "inventory", "readonly", "read_only"}:
                raise FleetError("catalog CLI adapter is not allowed", code="catalog_adapter_forbidden", status=409)
            raw_command = entry.get("command") or entry.get("executable") or entry.get("name")
            if isinstance(raw_command, list):
                if len(raw_command) != 1:
                    raise FleetError("catalog CLI command is invalid", code="catalog_invalid", status=409)
                command = raw_command[0] if raw_command else ""
            else:
                command = raw_command or (formula.split("/")[-1].split("@")[0] if formula else "")
            if not isinstance(command, str) or not _SAFE_NAME_RE.fullmatch(command):
                raise FleetError("catalog CLI command is invalid", code="catalog_invalid", status=409)
            if command not in CLI_COMMAND_ALLOWLIST or entry.get("allowlisted") is False:
                raise FleetError("catalog CLI command is not allowlisted", code="catalog_adapter_forbidden", status=409)
            if adapter in {"homebrew", "brew"} and (not isinstance(formula, str) or not _SAFE_FORMULA_RE.fullmatch(formula) or ".." in formula):
                raise FleetError("catalog CLI formula is invalid", code="catalog_invalid", status=409)
            if adapter in {"inventory", "readonly", "read_only"} and formula and (not isinstance(formula, str) or not _SAFE_FORMULA_RE.fullmatch(formula) or ".." in formula):
                raise FleetError("catalog CLI formula is invalid", code="catalog_invalid", status=409)
            auth_env = self._parse_auth_env(entry.get("authEnv") or entry.get("auth_env"))
            auth_check = bool(entry.get("checkAuth", entry.get("authCheck", False)))
            read_only_checks = entry.get("readOnlyChecks", entry.get("read_only_checks"))
            if read_only_checks is not None and not isinstance(read_only_checks, (list, dict)):
                raise FleetError("catalog read-only checks are invalid", code="catalog_invalid", status=409)
            check_entries: list[Any] = []
            if isinstance(read_only_checks, list):
                if len(read_only_checks) > 16:
                    raise FleetError("catalog has too many read-only checks", code="catalog_invalid", status=409)
                check_entries = read_only_checks
            elif isinstance(read_only_checks, dict):
                # A mapping is retained as a compatibility spelling, but each
                # value still has to be a complete checked recipe with the
                # same safety metadata as list entries.
                if "command" in read_only_checks or "argv" in read_only_checks:
                    check_entries = [read_only_checks]
                else:
                    if len(read_only_checks) > 16:
                        raise FleetError("catalog has too many read-only checks", code="catalog_invalid", status=409)
                    for kind, check in read_only_checks.items():
                        if not isinstance(check, dict):
                            raise FleetError("catalog read-only check is invalid", code="catalog_invalid", status=409)
                        normalized_check = dict(check)
                        normalized_check.setdefault("kind", kind)
                        check_entries.append(normalized_check)
            has_version_argv = "versionArgv" in entry or "version_argv" in entry
            has_auth_argv = "authArgv" in entry or "auth_argv" in entry
            direct_version_argv: Any = entry.get("versionArgv") if "versionArgv" in entry else entry.get("version_argv")
            direct_auth_argv: Any = entry.get("authArgv") if "authArgv" in entry else entry.get("auth_argv")
            version_check: Optional[tuple[str, ...]] = None
            auth_check_argv: Optional[tuple[str, ...]] = None
            version_timeout = self._probe_timeout(None)
            auth_timeout = self._probe_timeout(None)
            validated_checks: list[tuple[tuple[str, ...], str, float]] = []
            for check in check_entries:
                check_argv, check_name, check_timeout = self._parse_read_only_check(check, command)
                validated_checks.append((check_argv, check_name, check_timeout))
                if check_name == "version":
                    if version_check is None:
                        version_check = check_argv
                        version_timeout = check_timeout
                elif check_name == "auth":
                    if auth_check_argv is None:
                        auth_check_argv = check_argv
                    auth_timeout = check_timeout

            # Explicit convenience fields may not smuggle in a second probe.
            # They are accepted only as exact aliases of a validated check,
            # including the argv executable and every argument.
            if has_version_argv:
                normalized_direct = self._argv(direct_version_argv, command)
                matching = next((timeout for argv, _name, timeout in validated_checks if argv == normalized_direct), None)
                if matching is None:
                    raise FleetError("catalog versionArgv must match a read-only check", code="catalog_invalid", status=409)
                version_check = normalized_direct
                version_timeout = matching
            if has_auth_argv:
                normalized_direct = self._argv(direct_auth_argv, command)
                matching = next((timeout for argv, _name, timeout in validated_checks if argv == normalized_direct), None)
                if matching is None:
                    raise FleetError("catalog authArgv must match a read-only check", code="catalog_invalid", status=409)
                auth_check_argv = normalized_direct
                auth_timeout = matching
            if auth_check_argv is not None:
                auth_check = True
            if command == "slack":
                auth_check = True
                fixed_slack_auth = ("slack", "auth", "list", "--no-color", "--skip-update")
                if auth_check_argv != fixed_slack_auth:
                    raise FleetError("Slack auth check is not the fixed read-only command", code="catalog_invalid", status=409)
                auth_argv = self._argv(None, command, fixed=fixed_slack_auth)
            else:
                auth_argv = auth_check_argv or ()
            version_argv = version_check or ()
            item_id = _safe_item_id(entry.get("id") or f"cli:{formula or command}")
            classification = str(entry.get("classification") or entry.get("ownership") or "").strip().lower().replace("-", "_")
            read_only_classification = classification in READONLY_CLASSIFICATIONS
            # Deliberately false for every CLI recipe, including Homebrew.
            writable = False
            add(
                _CatalogItem(
                    item_id=item_id,
                    item_type="cli",
                    name=_safe_text(entry.get("name") or command, maximum=128),
                    adapter="homebrew" if adapter in {"homebrew", "brew"} else "inventory",
                    formula=formula,
                    command=command,
                    auth_env=auth_env,
                    version_argv=version_argv,
                    auth_argv=auth_argv,
                    version_timeout=version_timeout,
                    auth_timeout=auth_timeout,
                    read_only_checks=tuple(validated_checks),
                    auth_check=auth_check,
                    writable=writable,
                    classification=classification or ("readonly" if read_only_classification or not writable else "managed"),
                )
            )
        return list(sorted(parsed.values(), key=lambda item: (item.type, item.id)))

    def _validate_trusted_checkout_for_read(self, checkout: Path, *, require_current: bool = True) -> None:
        """Validate a checkout without fetching or changing it.

        Inventory and actions share this read boundary.  A checkout is trusted
        only when it is a regular Git worktree on exactly ``main`` tracking
        exactly ``origin/main``, with no staged, unstaged, untracked, or
        ignored files.  For reads, local HEAD must also equal the local
        ``origin/main`` ref.  Sync performs the network operation separately
        after the same identity and cleanliness checks, so a GET can never
        repair or mutate a checkout.
        """

        if checkout.is_symlink() or not checkout.is_dir():
            raise FleetError("Fleet catalog checkout is unavailable", code="catalog_unavailable", status=503)
        git_metadata = checkout / ".git"
        if git_metadata.is_symlink() or not (git_metadata.is_dir() or git_metadata.is_file()):
            raise FleetError(
                "managed catalog checkout is not a regular Git checkout",
                code="catalog_checkout_invalid",
                status=409,
            )
        git = self._git_executable()
        self._verify_remote(git, checkout)
        branch_result = _git(
            git,
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            cwd=checkout,
            timeout=self.timeout,
            code="catalog_checkout_invalid",
        )
        branch = _safe_text(branch_result.stdout, maximum=128).splitlines()[0] if branch_result.stdout else ""
        if branch != "main":
            raise FleetError("managed catalog checkout must use main", code="catalog_checkout_invalid", status=409)
        upstream_result = _git(
            git,
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            cwd=checkout,
            timeout=self.timeout,
            code="catalog_checkout_invalid",
        )
        upstream = _safe_text(upstream_result.stdout, maximum=256).splitlines()[0] if upstream_result.stdout else ""
        if upstream != "origin/main":
            raise FleetError(
                "managed catalog checkout must track origin/main",
                code="catalog_checkout_invalid",
                status=409,
            )
        dirty = _git(
            git,
            ["status", "--porcelain=v2", "--untracked-files=all", "--ignored=matching"],
            cwd=checkout,
            timeout=self.timeout,
            code="catalog_git_error",
        )
        if _safe_text(dirty.stdout, maximum=MAX_CATALOG_BYTES):
            raise FleetError(
                "managed catalog checkout has local or ignored changes",
                code="catalog_dirty",
                status=409,
            )
        if require_current:
            counts = _git(
                git,
                ["rev-list", "--left-right", "--count", "HEAD...origin/main"],
                cwd=checkout,
                timeout=self.timeout,
                code="catalog_checkout_invalid",
            )
            try:
                ahead, behind = [int(part) for part in _safe_text(counts.stdout, maximum=128).split()[:2]]
            except (TypeError, ValueError) as exc:
                raise FleetError("catalog revision could not be verified", code="catalog_checkout_invalid", status=409) from exc
            if ahead or behind:
                raise FleetError(
                    "managed catalog checkout is stale or diverged",
                    code="catalog_checkout_stale",
                    status=409,
                )

    def _checkout_catalog(self, *, require_sync: bool = False) -> _Catalog:
        try:
            checkout = self._select_checkout(require_existing=require_sync)
        except FleetError:
            if require_sync:
                raise
            raise
        git_metadata = checkout / ".git"
        if (
            not checkout.is_dir()
            or checkout.is_symlink()
            or git_metadata.is_symlink()
            or not (git_metadata.is_dir() or git_metadata.is_file())
        ):
            if require_sync:
                raise FleetError("Fleet catalog is not synced", code="catalog_unavailable", status=503)
            raise FleetError("Fleet catalog is unavailable", code="catalog_unavailable", status=503)
        self._validate_trusted_checkout_for_read(checkout)
        return self._read_catalog(checkout)

    # ------------------------------------------------------------------
    # Git synchronization

    def _verify_remote(self, git: str, checkout: Path) -> None:
        result = _git(git, ["remote", "get-url", "origin"], cwd=checkout, timeout=self.timeout)
        configured = _canonical_repository(self.repository)
        observed_raw = _safe_text(result.stdout, maximum=4096).splitlines()[0] if result.stdout else ""
        observed = _canonical_repository(observed_raw)
        if not hmac.compare_digest(configured, observed):
            raise FleetError(
                "managed catalog remote is not the allowlisted repository",
                code="catalog_remote_forbidden",
                status=409,
            )

    def _sync_existing(self, checkout: Path) -> None:
        git = self._git_executable()
        git_metadata = checkout / ".git"
        if (
            checkout.is_symlink()
            or not checkout.is_dir()
            or git_metadata.is_symlink()
            or not (git_metadata.is_dir() or git_metadata.is_file())
        ):
            # A pre-existing same-name directory is never treated as a clone
            # destination and is never removed to make room for one.
            raise FleetError(
                "managed catalog checkout is not a regular Git checkout",
                code="catalog_checkout_invalid",
                status=409,
            )
        self._validate_trusted_checkout_for_read(checkout, require_current=False)
        upstream = "origin/main"
        # Validate local branch/upstream before any network mutation.  A
        # detached, non-main, or manually altered checkout is rejected
        # without fetching or merging.
        _git(git, ["fetch", "--prune", "origin"], cwd=checkout, timeout=self.timeout, code="catalog_sync_failed")
        counts = _git(
            git,
            ["rev-list", "--left-right", "--count", f"HEAD...{upstream}"],
            cwd=checkout,
            timeout=self.timeout,
            code="catalog_sync_failed",
        )
        try:
            ahead, behind = [int(part) for part in _safe_text(counts.stdout, maximum=128).split()[:2]]
        except (ValueError, TypeError):
            raise FleetError("catalog divergence could not be determined", code="catalog_sync_failed", status=502)
        if ahead:
            raise FleetError(
                "managed catalog checkout has local commits",
                code="catalog_diverged",
                status=409,
            )
        if behind:
            _git(
                git,
                ["merge", "--ff-only", upstream],
                cwd=checkout,
                timeout=self.timeout,
                code="catalog_sync_failed",
            )

    def sync(self, body: Optional[Mapping[str, Any]] = None) -> dict[str, Any]:
        """Clone or fast-forward the allowlisted catalog and return inventory."""

        body = dict(body or {})
        forbidden = {"repo", "repository", "url", "checkout", "path", "source"}
        if forbidden.intersection(body):
            raise FleetError(
                "catalog repository and checkout are server configured",
                code="catalog_target_forbidden",
                status=400,
            )
        with self._lock:
            # Select an already trusted sync-skills source before falling back
            # to the managed checkout.  This prevents duplicate clones and
            # rejects arbitrary same-name directories by their remote.
            checkout = self._select_checkout(require_existing=False, require_current=False)
            parent = checkout.parent
            try:
                parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            except OSError as exc:
                raise FleetError("Fleet catalog parent is unavailable", code="catalog_unavailable", status=503) from exc
            if checkout.is_symlink():
                raise FleetError("managed catalog checkout may not be a symlink", code="catalog_checkout_symlink", status=409)
            if checkout.exists():
                if not checkout.is_dir():
                    raise FleetError("managed catalog checkout is not a directory", code="catalog_checkout_invalid", status=409)
                # _select_checkout may have selected the managed destination
                # after finding no trusted source.  An existing managed path
                # still has to prove its remote before any fetch.
                self._sync_existing(checkout)
            else:
                git = self._git_executable()
                # The repository value is process configuration, never request
                # data.  The argv separator prevents a configured URL that
                # starts with a dash from becoming an option.
                temporary = parent / f".{checkout.name}.fleet-clone-{uuid.uuid4().hex}"
                while temporary.exists() or temporary.is_symlink():
                    temporary = parent / f".{checkout.name}.fleet-clone-{uuid.uuid4().hex}"

                def cleanup_temporary() -> None:
                    if temporary.is_symlink() or temporary.is_file():
                        try:
                            temporary.unlink()
                        except OSError:
                            pass
                    elif temporary.is_dir():
                        try:
                            shutil.rmtree(temporary)
                        except OSError:
                            pass

                try:
                    _run_command(
                        git,
                        ["clone", "--depth=1", "--", self.repository, str(temporary)],
                        cwd=parent,
                        timeout=self.timeout,
                        error_code="catalog_clone_failed",
                        status=502,
                    )
                    self._validate_trusted_checkout_for_read(temporary)
                    # Never replace a checkout that appeared while cloning.
                    # The temporary sibling is exclusively owned by this
                    # request and is the only path that may be cleaned up on
                    # failure.
                    if checkout.exists() or checkout.is_symlink():
                        raise FleetError(
                            "managed catalog checkout appeared during clone",
                            code="catalog_checkout_conflict",
                            status=409,
                        )
                    os.replace(temporary, checkout)
                except FleetError:
                    # A failed clone can leave partial data, but only the
                    # unique temporary sibling belongs to this operation.
                    cleanup_temporary()
                    raise
                except OSError as exc:
                    cleanup_temporary()
                    raise FleetError("managed catalog checkout could not be promoted", code="catalog_checkout_failed", status=503) from exc
            catalog = self._read_catalog(checkout)
            state = self._load_state(strict=True)
            state["catalog"] = {
                "revision": catalog.revision,
                "fleetFileDigest": catalog.fleet_file_digest,
                "syncedAt": _now(),
            }
            self._save_state(state)
            return self._sync_response(catalog, state=state)

    # ------------------------------------------------------------------
    # Inventory

    @staticmethod
    def _target_display(item: _CatalogItem) -> str:
        if item.type == "skill":
            prefix = "~/.hermes/profiles/rocketbot/skills" if item.destination == "rocketbot" else "~/.agents/skills"
            return f"{prefix}/{item.target}"
        if item.type == "pi_extension":
            return f"~/.pi/agent/extensions/{item.target}"
        return item.command

    def _checkout_display(self, checkout: Optional[Path] = None) -> str:
        checkout = checkout or self.checkout
        try:
            relative = checkout.resolve(strict=False).relative_to(self.home)
        except ValueError:
            return "configured catalog"
        return "~/" + relative.as_posix()

    def _auth_for_item(self, item: _CatalogItem) -> Optional[dict[str, Any]]:
        if not item.auth_env and not item.auth_check:
            return None
        if item.auth_env:
            return {
                "configured": all(bool(_safe_text(self.environ.get(name))) for name in item.auth_env),
                "required": True,
            }
        return {
            "configured": None,
            "required": True,
            "checkAvailable": bool(_which(self.environ, item.command)),
            "status": "notChecked",
        }

    def _filesystem_item_state(self, item: _CatalogItem) -> tuple[str, str, Optional[str]]:
        root = self._item_root(item)
        # Existing upstream symlinks are deliberately unmanaged.  Do not
        # resolve or follow them as if they were Herdr-owned content.
        lexical_target = root / PurePosixPath(item.target)
        if _path_has_symlink_component(root, lexical_target):
            return "unmanaged", item.classification or "unmanaged", None
        target = _resolved_child(root, item.target, label="Fleet install target")
        if not lexical_target.exists():
            return "missing", item.classification or "not_installed", None
        digest = _tree_digest(target)
        if digest is None:
            return "drifted", item.classification or "unmanaged", None
        return "installed", item.classification or "unmanaged", digest

    def _cli_item_state(self, item: _CatalogItem, record: Optional[dict[str, Any]] = None) -> tuple[str, str, Optional[str], bool]:
        command_path = _which(self.environ, item.command)
        if command_path:
            # Inventory is a read-only metadata pass.  It uses PATH presence
            # only, and does not invoke every recipe on every GET.  An
            # explicit checkAuth action below is the sole command probe.
            version = None
            managed = bool(
                isinstance(record, dict)
                and record.get("type") == "cli"
                and record.get("adapter") == item.adapter
                and record.get("formula") == item.formula
            )
            return "installed", "managed" if managed else "unmanaged", version, bool(command_path)
        managed = bool(
            isinstance(record, dict)
            and record.get("type") == "cli"
            and record.get("adapter") == item.adapter
            and record.get("formula") == item.formula
        )
        return "missing", "managed" if managed else "not_installed", None, False

    def _item_payload(self, catalog: _Catalog, item: _CatalogItem, state: dict[str, Any]) -> dict[str, Any]:
        record = state.get("managed", {}).get(item.id)
        managed_record = record if isinstance(record, dict) else None
        if item.type == "cli":
            status, ownership, observed, adapter_available = self._cli_item_state(item, managed_record)
            installed = status == "installed"
            digest = observed
            current = installed
            drifted = False
            missing = not installed
            managed = ownership == "managed"
            if item.classification == "external":
                ownership = "external"
                managed = False
            auth = self._auth_for_item(item)
            result: dict[str, Any] = {
                "id": item.id,
                "type": item.type,
                "name": item.name,
                "adapter": item.adapter,
                "formula": item.formula,
                "command": item.command,
                "target": self._target_display(item),
                "status": "current" if current else "missing",
                "installed": installed,
                "current": current,
                "drifted": drifted,
                "missing": missing,
                "outdated": False,
                "managed": managed,
                "ownership": ownership,
                "classification": item.classification,
                "canAdopt": False,
                "adapterAvailable": adapter_available,
            }
            if digest:
                result["version"] = digest
            result["installable"] = _item_writable(item.writable, item.classification)
            if item.auth_check or item.auth_env:
                result["authCheckAvailable"] = bool(_which(self.environ, item.command))
            if auth is not None:
                result["auth"] = auth
            return result
        status, ownership, observed_digest = self._filesystem_item_state(item)
        managed = self._record_matches_item(managed_record, item)
        expected_digest = managed_record.get("digest") if managed_record else None
        source_root = catalog.checkout / ("skills" if item.type == "skill" else "pi-extensions")
        source_relative = item.source.split("/", 1)[1] if "/" in item.source else item.source
        source_path = _resolved_child(source_root, source_relative, label="Fleet catalog source")
        catalog_digest = _tree_digest(source_path)
        installed = status != "missing"
        content_current = bool(installed and catalog_digest and observed_digest == catalog_digest)
        current = content_current
        outdated = bool(installed and managed and catalog_digest and observed_digest == expected_digest and expected_digest != catalog_digest)
        drifted = bool(installed and not content_current and not outdated)
        missing = not installed
        if managed:
            ownership = "managed"
        else:
            ownership = "unmanaged"
        if item.classification == "external":
            ownership = "external"
            managed = False
        result = {
            "id": item.id,
            "type": item.type,
            "name": item.name,
            "source": item.source,
            "target": self._target_display(item),
            "status": "current" if current else ("missing" if missing else ("outdated" if outdated else "drifted")),
            "installed": installed,
            "current": current,
            "drifted": drifted,
            "outdated": outdated,
            "missing": missing,
            "managed": managed,
            "ownership": ownership,
            "classification": item.classification,
            "canAdopt": bool(_item_writable(item.writable, item.classification) and not managed and not missing and catalog_digest and observed_digest == catalog_digest),
            "installable": _item_writable(item.writable, item.classification),
        }
        auth = self._auth_for_item(item)
        if auth is not None:
            result["auth"] = auth
        return result

    def _sync_response(self, catalog: _Catalog, *, state: dict[str, Any], include_inventory: bool = False) -> dict[str, Any]:
        items = [self._item_payload(catalog, item, state) for item in catalog.items]
        skills = [item for item in items if item["type"] == "skill"]
        extensions = [item for item in items if item["type"] == "pi_extension"]
        cli = [item for item in items if item["type"] == "cli"]
        response: dict[str, Any] = {
            "ok": True,
            "catalogRevision": catalog.revision,
            "catalog": {
                "available": True,
                "state": "synced",
                "revision": catalog.revision,
                "catalogName": "personal-claude-plugin",
                "syncedAt": state.get("catalog", {}).get("syncedAt"),
                "itemCounts": {"skills": len(skills), "piExtensions": len(extensions), "cli": len(cli)},
            },
            "skills": skills,
            "piExtensions": extensions,
            "cli": cli,
            "cliRecipes": cli,
            "items": items,
            "generatedAt": _now(),
        }
        if include_inventory:
            response["inventory"] = response.copy()
        return response

    def _local_basics(self, state: dict[str, Any]) -> dict[str, Any]:
        """Return read-only local probes when no catalog checkout is trusted."""

        extensions: list[dict[str, Any]] = []
        root = self.pi_extensions_root
        try:
            if root.is_dir() and not root.is_symlink():
                for name in sorted(os.listdir(root)):
                    if name.startswith("."):
                        continue
                    candidate = root / name
                    if candidate.is_symlink() or not (candidate.is_file() or candidate.is_dir()):
                        continue
                    if candidate.is_file() and candidate.suffix.lower() not in {".js", ".mjs", ".cjs", ".ts", ".mts", ".cts"}:
                        continue
                    try:
                        relative = _safe_relative(name, "Pi extension path")
                    except FleetError:
                        continue
                    extensions.append(
                        {
                            "id": f"pi-extension:{relative}",
                            "type": "pi_extension",
                            "name": _safe_text(candidate.name, maximum=128),
                            "target": f"~/.pi/agent/extensions/{relative}",
                            "status": "installed",
                            "installed": True,
                            "current": None,
                            "drifted": False,
                            "missing": False,
                            "managed": False,
                            "ownership": "unmanaged",
                            "classification": "readonly",
                            "canAdopt": False,
                            "installable": False,
                        }
                    )
        except OSError:
            extensions = []

        cli: list[dict[str, Any]] = []
        for command in LOCAL_CLI_COMMANDS:
            if not _which(self.environ, command):
                continue
            item = _CatalogItem(
                item_id=f"cli:{command}",
                item_type="cli",
                name=command,
                adapter="inventory",
                command=command,
                auth_argv=("slack", "auth", "list", "--no-color", "--skip-update") if command == "slack" else (),
                auth_check=command == "slack",
                writable=False,
                classification="readonly",
            )
            cli.append(self._item_payload(_Catalog(checkout=self.checkout, revision="", fleet_file_digest="", items=[]), item, state))

        items = extensions + cli
        return {
            "skills": [],
            "piExtensions": extensions,
            "cli": cli,
            "cliRecipes": cli,
            "items": items,
        }

    def inventory(self) -> dict[str, Any]:
        with self._lock:
            state = self._load_state(strict=False)
            try:
                catalog = self._checkout_catalog(require_sync=False)
            except FleetError as exc:
                # Inventory is intentionally useful before the first clone and
                # while Git is unavailable.  Do not expose exception details.
                basics = self._local_basics(state)
                counts = {
                    "skills": len(basics["skills"]),
                    "piExtensions": len(basics["piExtensions"]),
                    "cli": len(basics["cli"]),
                }
                return {
                    "ok": True,
                    "machine": _machine_metadata(self.environ, self.session),
                    "auth": _redact_environment_auth(self.environ),
                    "catalogRevision": state.get("catalog", {}).get("revision"),
                    "catalog": {
                        "available": False,
                        "revision": state.get("catalog", {}).get("revision"),
                        "catalogName": "personal-claude-plugin",
                        "state": "notSynced" if exc.code in {"catalog_unavailable", "adapter_unavailable"} else "unavailable",
                        "itemCounts": counts,
                    },
                    **basics,
                    "generatedAt": _now(),
                }
            result = self._sync_response(catalog, state=state)
            result["machine"] = _machine_metadata(self.environ, self.session)
            result["auth"] = _redact_environment_auth(self.environ)
            # Reorder is unnecessary for JSON, but keeping these at the top
            # makes the response pleasant to inspect in curl and tests.
            return result

    # ------------------------------------------------------------------
    # Actions

    def _copy_item(self, item: _CatalogItem, source: Path, target: Path) -> None:
        if source.is_symlink() or (source.is_dir() and _tree_has_symlink(source)):
            raise FleetError("catalog item contains a symlink", code="catalog_invalid", status=409)
        target_parent = target.parent
        try:
            target_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        except OSError as exc:
            raise FleetError("Fleet install target is unavailable", code="fleet_target_unavailable", status=503) from exc
        # Check every existing component after creation.  A symlink nested in
        # an install path could otherwise redirect a copy outside the root.
        cursor = target_parent
        roots = {self.skills_root, self.pi_extensions_root, self.rocketbot_skills_root}
        while cursor not in roots and cursor != cursor.parent:
            if cursor.is_symlink():
                raise FleetError("Fleet install target contains a symlink", code="fleet_path_escape", status=409)
            cursor = cursor.parent
        temporary: Optional[Path] = None
        try:
            if source.is_dir():
                temporary = Path(tempfile.mkdtemp(prefix=".herdr-fleet-", dir=str(target_parent)))
                shutil.rmtree(temporary)
                shutil.copytree(source, temporary, symlinks=False, copy_function=shutil.copy2)
            else:
                fd, temporary_name = tempfile.mkstemp(prefix=".herdr-fleet-", dir=str(target_parent))
                os.close(fd)
                temporary = Path(temporary_name)
                shutil.copy2(source, temporary)
            if target.exists() or target.is_symlink():
                raise FleetError("install target must be absent before atomic install", code="fleet_target_conflict", status=409)
            os.replace(temporary, target)
            temporary = None
        except FleetError:
            raise
        except OSError as exc:
            raise FleetError("Fleet item could not be installed", code="fleet_install_failed", status=503) from exc
        finally:
            if temporary is not None:
                try:
                    if temporary.is_dir() and not temporary.is_symlink():
                        shutil.rmtree(temporary)
                    elif temporary.exists() or temporary.is_symlink():
                        temporary.unlink()
                except OSError:
                    pass

    def _quarantine_target(self, item: _CatalogItem, target: Path, root: Path) -> Optional[Path]:
        """Atomically move a managed target into private Fleet quarantine."""

        self.quarantine_root = _ensure_root(self._quarantine_path, allow_root_symlink=False, create=True)
        try:
            self.quarantine_root.chmod(0o700)
        except OSError as exc:
            raise FleetError("Fleet quarantine is unavailable", code="fleet_quarantine_failed", status=503) from exc
        lexical_target = root / PurePosixPath(item.target)
        if _path_has_symlink_component(root, lexical_target):
            raise FleetError(
                "only Herdr-managed copies may be removed",
                code="fleet_target_unmanaged",
                status=409,
            )
        if not lexical_target.exists():
            return None
        if target != lexical_target.resolve(strict=False):
            raise FleetError("Fleet install target is invalid", code="fleet_path_escape", status=409)
        safe_id = re.sub(r"[^A-Za-z0-9._-]", "-", item.id)[:48] or "item"
        destination = self.quarantine_root / f"{int(time.time())}-{safe_id}-{uuid.uuid4().hex[:12]}"
        if destination.exists() or destination.is_symlink():
            raise FleetError("Fleet quarantine is unavailable", code="fleet_quarantine_failed", status=503)
        try:
            # os.replace is atomic on the supported local filesystems.  An
            # EXDEV failure is surfaced without falling back to copy/delete.
            os.replace(lexical_target, destination)
        except OSError as exc:
            raise FleetError("Fleet quarantine could not preserve the item", code="fleet_quarantine_failed", status=503) from exc
        return destination

    def _quarantine_record(self, item: _CatalogItem, destination: Optional[Path], *, digest: Optional[str]) -> Optional[dict[str, Any]]:
        if destination is None:
            return None
        try:
            relative = destination.relative_to(self.quarantine_root).as_posix()
        except ValueError as exc:
            raise FleetError("Fleet quarantine path is invalid", code="fleet_quarantine_failed", status=503) from exc
        # This record is persisted for local recovery only and is intentionally
        # never copied into the HTTP response.
        return {
            "itemId": item.id,
            "type": item.type,
            "path": relative,
            "digest": digest,
            "movedAt": _now(),
        }

    def _remove_item(self, item: _CatalogItem, state: dict[str, Any]) -> bool:
        managed = state.get("managed", {})
        record = managed.get(item.id) if isinstance(managed, dict) else None
        if not self._record_matches_item(record, item):
            raise FleetError(
                "only Herdr-managed copies may be removed",
                code="fleet_target_unmanaged",
                status=409,
            )
        root = self._item_root(item)
        lexical_target = root / PurePosixPath(item.target)
        if _path_has_symlink_component(root, lexical_target):
            raise FleetError(
                "only Herdr-managed copies may be removed",
                code="fleet_target_unmanaged",
                status=409,
            )
        target = _resolved_child(root, item.target, label="Fleet install target")
        prior_digest = _tree_digest(target) if target.exists() and not target.is_symlink() else None
        destination = self._quarantine_target(item, target, root)
        previous_managed = dict(record)
        managed.pop(item.id, None)
        quarantine_record = self._quarantine_record(item, destination, digest=prior_digest)
        if quarantine_record is not None:
            state.setdefault("quarantine", []).append(quarantine_record)
        try:
            self._save_state(state)
        except FleetError:
            # Preserve the old ownership record if state persistence fails.
            managed[item.id] = previous_managed
            if destination is not None and destination.exists() and not destination.is_symlink():
                try:
                    os.replace(destination, lexical_target)
                except OSError:
                    pass
            raise
        return True

    def _prepare_install_roots(self) -> None:
        # GET inventory never creates directories.  Mutating actions opt into
        # root creation immediately before they need it.
        self.skills_root = _ensure_root(self._skills_path, allow_root_symlink=True, create=True)
        self.pi_extensions_root = _ensure_root(self._pi_extensions_path, allow_root_symlink=True, create=True)
        self.rocketbot_skills_root = _ensure_root(self._rocketbot_skills_path, allow_root_symlink=False, create=True)
        self.quarantine_root = _ensure_root(self._quarantine_path, allow_root_symlink=False, create=True)
        try:
            self.quarantine_root.chmod(0o700)
        except OSError as exc:
            raise FleetError("Fleet quarantine is unavailable", code="fleet_quarantine_failed", status=503) from exc

    def _run_auth_check(self, item: _CatalogItem) -> dict[str, Any]:
        """Perform a bounded, output-free authentication check."""

        checked_at = _now()
        if item.auth_env:
            configured = all(bool(_safe_text(self.environ.get(name))) for name in item.auth_env)
            return {
                "configured": configured,
                "status": "configured" if configured else "missing",
                "checked": True,
                "checkedAt": checked_at,
            }
        argv = item.auth_argv
        if not argv:
            return {"configured": None, "status": "unsupported", "checked": False, "checkedAt": checked_at}
        executable = _which(self.environ, argv[0])
        if not executable:
            return {"configured": False, "status": "unavailable", "checked": True, "checkedAt": checked_at}
        try:
            # Deliberately discard stdout/stderr.  In particular, Slack's auth
            # output can contain account or workspace details.
            _run_command(
                executable,
                list(argv[1:]),
                cwd=None,
                timeout=item.auth_timeout or self._probe_timeout(None),
                error_code="auth_check_failed",
                discard_output=True,
            )
        except FleetError:
            return {"configured": False, "status": "failed", "checked": True, "checkedAt": checked_at}
        return {"configured": True, "status": "ok", "checked": True, "checkedAt": checked_at}

    def action(self, item_id: str, action: str) -> dict[str, Any]:
        item_id = _safe_item_id(item_id)
        raw_action = _safe_text(action, maximum=16)
        action_key = raw_action.lower()
        normalized_action = "checkAuth" if action_key in {"checkauth", "auth_check", "authcheck"} else action_key
        if normalized_action not in {"install", "update", "remove", "adopt", "checkAuth"}:
            raise FleetError("action must be install, update, remove, adopt, or checkAuth", code="invalid_fleet_action", status=400)
        with self._lock:
            catalog = self._checkout_catalog(require_sync=True)
            item = next((candidate for candidate in catalog.items if candidate.id == item_id), None)
            if item is None:
                raise FleetError("Fleet item not found", code="fleet_item_not_found", status=404)
            state = self._load_state(strict=True)
            managed = state.setdefault("managed", {})
            record = managed.get(item.id)

            if normalized_action == "checkAuth":
                if item.type != "cli" or not item.auth_check and not item.auth_env:
                    raise FleetError("Fleet item does not support auth checks", code="fleet_action_forbidden", status=400)
                auth = self._run_auth_check(item)
                payload = self._item_payload(catalog, item, state)
                payload["auth"] = auth
                return {
                    "ok": True,
                    "action": normalized_action,
                    "item": payload,
                    "inventory": self.inventory(),
                    "catalogRevision": catalog.revision,
                    "generatedAt": _now(),
                }

            if not _item_writable(item.writable, item.classification):
                raise FleetError(
                    "this Fleet item is read-only or externally owned",
                    code="fleet_action_forbidden",
                    status=409,
                )

            if item.type == "cli":
                # There is intentionally no CLI mutation adapter.  PATH
                # provenance and Homebrew metadata are inventory-only; Fleet
                # never installs, upgrades, or removes a command.
                raise FleetError("CLI recipes are inventory-only", code="fleet_action_forbidden", status=409)

            self._prepare_install_roots()
            source_root_name = "skills" if item.type == "skill" else "pi-extensions"
            source_prefix = source_root_name + "/"
            if not item.source.startswith(source_prefix):
                raise FleetError("Fleet catalog source is invalid", code="catalog_invalid", status=409)
            source_relative = item.source[len(source_prefix) :]
            source_root = catalog.checkout / source_root_name
            source = _resolved_child(source_root, source_relative, label="Fleet catalog source")
            root = self._item_root(item)
            lexical_target = root / PurePosixPath(item.target)
            if _path_has_symlink_component(root, lexical_target):
                raise FleetError("install target is an unmanaged symlink", code="fleet_target_unmanaged", status=409)
            target = _resolved_child(root, item.target, label="Fleet install target")
            owns_target = self._record_matches_item(record, item)

            if normalized_action == "remove":
                if not owns_target:
                    raise FleetError(
                        "only Herdr-managed copies may be removed",
                        code="fleet_target_unmanaged",
                        status=409,
                    )
                self._remove_item(item, state)
                return {
                    "ok": True,
                    "action": normalized_action,
                    "item": self._item_payload(catalog, item, state),
                    "catalogRevision": catalog.revision,
                    "generatedAt": _now(),
                }

            if not source.exists() or source.is_symlink() or not (source.is_dir() if item.type == "skill" else source.is_file() or source.is_dir()):
                raise FleetError("Fleet catalog source is unavailable", code="catalog_invalid", status=409)
            if item.type == "skill" and not (source / "SKILL.md").is_file():
                raise FleetError("Fleet skill source is unavailable", code="catalog_invalid", status=409)
            if _tree_has_symlink(source):
                raise FleetError("catalog item contains a symlink", code="catalog_invalid", status=409)
            source_digest = _tree_digest(source)
            if source_digest is None:
                raise FleetError("Fleet catalog source is unreadable", code="catalog_invalid", status=409)

            target_exists = lexical_target.exists() or lexical_target.is_symlink()
            if normalized_action == "adopt":
                if not target_exists or lexical_target.is_symlink() or owns_target:
                    raise FleetError("Fleet target cannot be adopted", code="fleet_target_unmanaged", status=409)
                if _tree_digest(target) != source_digest:
                    raise FleetError("existing target differs from catalog", code="fleet_target_drifted", status=409)
                managed[item.id] = {
                    "type": item.type,
                    "source": item.source,
                    "target": item.target,
                    "destination": item.destination,
                    "digest": source_digest,
                    "catalogRevision": catalog.revision,
                    "adoptedAt": _now(),
                }
                self._save_state(state)
                return {
                    "ok": True,
                    "action": normalized_action,
                    "item": self._item_payload(catalog, item, state),
                    "catalogRevision": catalog.revision,
                    "generatedAt": _now(),
                }

            if target_exists and not owns_target:
                # A byte-identical pre-existing copy can be safely adopted by
                # install, which makes bootstrap idempotent without replacing
                # upstream content.  A differing copy is never overwritten.
                if normalized_action == "install" and _tree_digest(target) == source_digest:
                    managed[item.id] = {
                        "type": item.type,
                        "source": item.source,
                        "target": item.target,
                        "destination": item.destination,
                        "digest": source_digest,
                        "catalogRevision": catalog.revision,
                        "adoptedAt": _now(),
                    }
                    self._save_state(state)
                    return {
                        "ok": True,
                        "action": "adopt",
                        "item": self._item_payload(catalog, item, state),
                        "catalogRevision": catalog.revision,
                        "generatedAt": _now(),
                    }
                raise FleetError("install target is not managed by Herdr", code="fleet_target_unmanaged", status=409)
            if target_exists and owns_target and _tree_digest(target) == source_digest and normalized_action == "install":
                return {
                    "ok": True,
                    "action": normalized_action,
                    "item": self._item_payload(catalog, item, state),
                    "catalogRevision": catalog.revision,
                    "generatedAt": _now(),
                }

            prior_record = dict(record) if owns_target and isinstance(record, dict) else None
            prior_digest = _tree_digest(target) if target_exists and not lexical_target.is_symlink() else None
            destination = self._quarantine_target(item, target, root) if target_exists else None
            quarantine_record = self._quarantine_record(item, destination, digest=prior_digest)
            try:
                self._copy_item(item, source, target)
                if _tree_digest(target) != source_digest:
                    raise FleetError("installed Fleet item failed verification", code="fleet_install_failed", status=503)
            except FleetError:
                if target.exists() or target.is_symlink():
                    try:
                        self._quarantine_target(item, target, root)
                    except FleetError:
                        pass
                if destination is not None and destination.exists() and not destination.is_symlink():
                    try:
                        os.replace(destination, lexical_target)
                    except OSError:
                        pass
                raise
            if quarantine_record is not None:
                state.setdefault("quarantine", []).append(quarantine_record)
            managed[item.id] = {
                "type": item.type,
                "source": item.source,
                "target": item.target,
                "destination": item.destination,
                "digest": source_digest,
                "catalogRevision": catalog.revision,
                "managedAt": _now(),
            }
            state["catalog"] = {
                "revision": catalog.revision,
                "fleetFileDigest": catalog.fleet_file_digest,
                "syncedAt": state.get("catalog", {}).get("syncedAt") or _now(),
            }
            try:
                self._save_state(state)
            except FleetError:
                # Move the newly installed copy out of the live tree before
                # restoring the last-known-good quarantined version.
                failed_destination = self._quarantine_target(item, target, root)
                if destination is not None and destination.exists() and not destination.is_symlink():
                    try:
                        os.replace(destination, lexical_target)
                    except OSError:
                        pass
                if prior_record is not None:
                    managed[item.id] = prior_record
                else:
                    managed.pop(item.id, None)
                raise
            payload = self._item_payload(catalog, item, state)
            return {
                "ok": True,
                "action": normalized_action,
                "item": payload,
                "catalogRevision": catalog.revision,
                "generatedAt": _now(),
            }


__all__ = ["DEFAULT_CATALOG_REPOSITORY", "FleetError", "FleetManager"]
