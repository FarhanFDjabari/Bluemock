"""Bounded environment diagnostics; only Bluetooth enablement is auto-fixed."""

import contextlib
import csv
import importlib
import os
import platform
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path


TIMEOUT = 5


def _run(command, timeout=TIMEOUT):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                                encoding="utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return False, f"Command timed out after {timeout:g}s: {_command(command)}"
    except (OSError, ValueError) as exc:
        return False, str(exc)
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    if result.returncode:
        return False, f"exit {result.returncode}: {output or _command(command)}"
    return True, output


def _command(parts):
    return subprocess.list2cmdline(parts) if os.name == "nt" else shlex.join(parts)


def _check(check_id, ok, detail, fix=None):
    result = {"id": check_id, "ok": bool(ok), "detail": str(detail)}
    if fix is not None:
        result["fix"] = fix
    return result


def _is_path(path, kind="file"):
    try:
        return path.is_dir() if kind == "dir" else path.is_file()
    except OSError:
        return False


def _sdk():
    candidates = []
    for variable in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(variable):
            candidates.append(Path(os.environ[variable]).expanduser())
    candidates += [Path.home() / "Library/Android/sdk", Path.home() / "Android/Sdk"]
    if os.environ.get("LOCALAPPDATA"):
        candidates.append(Path(os.environ["LOCALAPPDATA"]) / "Android/Sdk")
    for candidate in candidates:
        if _is_path(candidate, "dir"):
            return candidate, candidates
    return None, candidates


def _ini_path(netsim_module=None):
    # Delegate to the pinned implementation when importable; fallback matches
    # bumble 0.0.236 transport/android_netsim.py:get_ini_dir/ini_file_name(0).
    if netsim_module is not None:
        directory = netsim_module.get_ini_dir()
        return directory / netsim_module.ini_file_name(0) if directory else None
    directory = None
    if sys.platform == "darwin":
        if os.environ.get("TMPDIR"):
            directory = Path(os.environ["TMPDIR"])
        elif os.environ.get("HOME"):
            directory = Path(os.environ["HOME"]) / "Library/Caches/TemporaryItems"
    elif sys.platform == "linux":
        if os.environ.get("XDG_RUNTIME_DIR"):
            directory = Path(os.environ["XDG_RUNTIME_DIR"])
        else:
            temporary = Path(os.environ.get("TMPDIR", "/tmp"))
            if _is_path(temporary, "dir"):
                directory = temporary
    elif sys.platform == "win32" and os.environ.get("LOCALAPPDATA"):
        directory = Path(os.environ["LOCALAPPDATA"]) / "Temp"
    return directory / "netsim.ini" if directory else None


def _netsim_process():
    if os.name == "nt":
        ok, output = _run(["tasklist", "/FI", "IMAGENAME eq netsimd.exe", "/FO", "CSV", "/NH"])
        return ok and any(row and row[0].lower() == "netsimd.exe" for row in csv.reader(output.splitlines()))
    ok, output = _run(["pgrep", "-x", "netsimd"])
    if ok and output.strip():
        return True
    ok, output = _run(["ps", "-A", "-o", "comm="])
    return ok and any(Path(line.strip()).name == "netsimd" for line in output.splitlines())


def inspect_environment():
    os.environ.setdefault("GRPC_VERBOSITY", "ERROR")
    checks = [_check("python", sys.version_info >= (3, 10), f"Python {platform.python_version()}")]
    netsim_module = None
    try:
        with contextlib.redirect_stdout(sys.stderr):
            bumble = importlib.import_module("bumble")
            netsim_module = importlib.import_module("bumble.transport.android_netsim")
        checks.append(_check("bumble", True, f"Bumble {bumble.__version__}; android-netsim import OK"))
    except Exception as exc:
        checks.append(_check("bumble", False, f"Bumble android transport import failed: {exc}",
                             _command([sys.executable, "-m", "pip", "install", "bumble[android]==0.0.236"])))
    sdk, candidates = _sdk()
    checks.append(_check("sdk", sdk is not None, str(sdk) if sdk else
                         "Android SDK not found; checked: " + ", ".join(map(str, candidates))))
    suffix = ".exe" if os.name == "nt" else ""
    emulator = sdk / "emulator" / ("emulator" + suffix) if sdk else None
    adb = sdk / "platform-tools" / ("adb" + suffix) if sdk else None
    if emulator is not None and _is_path(emulator):
        ok, output = _run([str(emulator), "-version"])
        match = re.search(r"emulator\s+version\s+(\d+)\.(\d+)\.(\d+)", output, re.IGNORECASE)
        version = tuple(map(int, match.groups())) if match else None
        detail = f"{emulator}: version {'.'.join(match.groups())}" if ok and match else output or "Cannot parse emulator version"
        supported = ok and version is not None and version >= (33, 1, 4)
        checks.append(_check("emulator", supported, detail if supported else detail + "; requires >= 33.1.4"))
    else:
        checks.append(_check("emulator", False, f"Emulator binary not found: {emulator or 'SDK unavailable'}"))
    adb_found = adb is not None and _is_path(adb)
    checks.append(_check("adb", adb_found, str(adb) if adb_found else "platform-tools adb not found"))
    devices_ok, devices_output = _run([str(adb), "devices"]) if adb_found else (False, "adb unavailable")
    serials = [fields[0] for line in devices_output.splitlines()
               if len(fields := line.split()) >= 2 and fields[0].startswith("emulator-") and fields[1] == "device"] if devices_ok else []
    if not serials:
        checks.append(_check("netsim", False, "start an emulator; netsim starts with it"))
    else:
        try:
            ini = _ini_path(netsim_module)
            running = _netsim_process()
            exists = ini is not None and _is_path(ini)
            detail = "netsimd is running" if running else f"netsim discovery file: {ini}" if exists else "netsimd not found and netsim discovery INI is missing"
            checks.append(_check("netsim", running or exists, detail))
        except Exception as exc:
            checks.append(_check("netsim", False, str(exc)))
    labels = {}
    for serial in serials:
        ok, name_output = _run([str(adb), "-s", serial, "emu", "avd", "name"])
        name = next((line.strip() for line in name_output.splitlines() if line.strip() and line.strip() != "OK"), "") if ok else ""
        labels[serial] = f"{name} ({serial})" if name else serial
    checks.append(_check("devices", devices_ok and bool(serials), ", ".join(labels.values()) if serials else
                         "No running emulator-* devices" + (f"; {devices_output}" if not devices_ok else "")))
    for serial in serials:
        label = labels[serial]
        ok, api_output = _run([str(adb), "-s", serial, "shell", "getprop", "ro.build.version.sdk"])
        api = int(api_output.strip()) if ok and api_output.strip().isdigit() else None
        detail = f"{label} · API {api}" if api is not None else f"{label} · API query failed: {api_output}"
        checks.append(_check("api:" + serial, ok and api is not None and api >= 33,
                             detail if api is not None and api >= 33 else detail + "; requires API 33+"))
        ok, bt_output = _run([str(adb), "-s", serial, "shell", "settings", "get", "global", "bluetooth_on"])
        enabled = ok and bt_output.strip() == "1"
        detail = f"{label} · BT on" if enabled else f"{label} · Bluetooth is off ({bt_output or 'unknown'})"
        fix = _command(["adb", "-s", serial, "shell", "cmd", "bluetooth_manager", "enable"])
        checks.append(_check("bluetooth:" + serial, enabled, detail, None if enabled else fix))
    return {"ok": all(check["ok"] for check in checks), "checks": checks}, adb


def doctor(fix=False):
    """Return final diagnostics; auto-fix only failed Bluetooth checks on emulators."""
    report, adb = inspect_environment()
    if not fix:
        return report
    failures = {}
    for check in report["checks"]:
        if check["ok"] or not check["id"].startswith("bluetooth:") or adb is None:
            continue
        serial = check["id"].split(":", 1)[1]
        ok, output = _run([str(adb), "-s", serial, "shell", "cmd", "bluetooth_manager", "enable"])
        if not ok:
            failures[check["id"]] = "Bluetooth enable failed: " + output
            continue
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            ok, state = _run([str(adb), "-s", serial, "shell", "settings", "get", "global", "bluetooth_on"],
                             timeout=max(0.01, min(TIMEOUT, remaining)))
            if ok and state.strip() == "1":
                break
            time.sleep(min(0.2, max(0, deadline - time.monotonic())))
        else:
            failures[check["id"]] = "Bluetooth did not turn on within 5s"
    final, _ = inspect_environment()
    for check in final["checks"]:
        if not check["ok"] and check["id"] in failures:
            check["detail"] += "; " + failures[check["id"]]
    return final
