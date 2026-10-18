"""Shared device storage and bundled definition discovery."""

import os
import sys
from importlib import resources
from pathlib import Path


def device_dir() -> Path:
    if os.environ.get("BLUEMOCK_HOME"):
        return Path(os.environ["BLUEMOCK_HOME"]).expanduser() / "devices"
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA", Path.home() / "AppData/Roaming")) / "bluemock/devices"
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    return base / "bluemock/devices"


def preset_dir():
    """Return package resources (a Traversable, also supported by zipped installs)."""
    return resources.files("bluemock").joinpath("presets")


def presets():
    return sorted((p for p in preset_dir().iterdir() if p.name.endswith(".yaml")), key=lambda p: p.name)


def resolve(value: str):
    """Find an existing file, a user definition, or a bundled preset, in order."""
    candidate = Path(value).expanduser()
    tried = [str(candidate)]
    if candidate.is_file():
        return candidate
    # Only identifiers, never absolute paths or traversal, are searched in libraries.
    if value and Path(value).name == value and value not in {".", ".."}:
        for suffix in (".yaml", ".yml", ".json"):
            candidate = device_dir() / (value + suffix)
            tried.append(str(candidate))
            if candidate.is_file():
                return candidate
        candidate = preset_dir().joinpath(value + ".yaml")
        tried.append(str(candidate))
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"Definition {value!r} was not found; tried: " + ", ".join(tried))
