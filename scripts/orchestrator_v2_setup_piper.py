#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import urllib.request
from pathlib import Path


VOICE_URLS = {
    "en_US-amy-medium.onnx": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx",
    "en_US-amy-medium.onnx.json": "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json",
}


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def data_root() -> Path:
    default = Path.home() / ".cmux-harness" / "orchestrator-v2"
    return Path(os.environ.get("CMUX_ORCHESTRATOR_V2_DIR") or default).expanduser()


def ensure_piper_module() -> None:
    if importlib.util.find_spec("piper") is not None:
        return
    subprocess.run([sys.executable, "-m", "pip", "install", "--user", "piper-tts"], check=True)


def download(url: str, destination: Path) -> None:
    if destination.exists() and destination.stat().st_size > 0:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_suffix(destination.suffix + ".tmp")
    with urllib.request.urlopen(url, timeout=120) as response:
        tmp.write_bytes(response.read())
    tmp.replace(destination)


def write_wrapper(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\nexec {sys.executable} -m piper \"$@\"\n", encoding="utf-8")
    path.chmod(0o755)


def upsert_env_local(values: dict[str, str]) -> None:
    env_path = repo_root() / ".env.local"
    existing = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
    seen: set[str] = set()
    output: list[str] = []
    for line in existing:
        key = line.split("=", 1)[0].strip() if "=" in line and not line.strip().startswith("#") else ""
        if key in values:
            output.append(f"{key}={values[key]}")
            seen.add(key)
        else:
            output.append(line)
    if output and output[-1].strip():
        output.append("")
    for key, value in values.items():
        if key not in seen:
            output.append(f"{key}={value}")
    env_path.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Install local Piper TTS assets for Orchestrator V2.")
    parser.add_argument("--no-env-local", action="store_true", help="Do not update repo-local .env.local.")
    args = parser.parse_args()

    ensure_piper_module()

    piper_root = data_root() / "piper"
    wrapper = piper_root / "bin" / "piper-python"
    voice = piper_root / "voices" / "en_US-amy-medium.onnx"
    config = piper_root / "voices" / "en_US-amy-medium.onnx.json"

    for name, url in VOICE_URLS.items():
        download(url, piper_root / "voices" / name)
    write_wrapper(wrapper)

    env_values = {
        "ORCHESTRATOR_V2_PIPER_BIN": str(wrapper),
        "ORCHESTRATOR_V2_PIPER_VOICE": "en_US-amy-medium.onnx",
        "ORCHESTRATOR_V2_PIPER_VOICE_PATH": str(voice),
        "ORCHESTRATOR_V2_PIPER_LENGTH_SCALE": "0.67",
    }
    if not args.no_env_local:
        upsert_env_local(env_values)

    subprocess.run(
        [
            str(wrapper),
            "--model",
            str(voice),
            "--config",
            str(config),
            "--output_file",
            str(piper_root / "piper-smoke.wav"),
            "--length-scale",
            "0.67",
        ],
        input="Orchestrator V2 Piper setup complete.",
        text=True,
        check=True,
    )

    print("Piper setup complete.")
    print(f"  binary: {wrapper}")
    print(f"  voice:  {voice}")
    if not args.no_env_local:
        print(f"  env:    {repo_root() / '.env.local'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
