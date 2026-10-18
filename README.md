# bluemock

bluemock defines simulated BLE peripherals for Android emulator testing using
readable YAML device files. This first version provides definition management,
validation, safe expressions, and binary payload templates.

Requires Python 3.10+ and, for peripheral simulation in later versions, an
Android emulator with an API 33+ system image.

Install from this checkout:

```sh
scripts/install.sh
# Alternatively:
pipx install .
```

The script installs into `~/.local/share/bluemock/venv` and links the command in
`~/.local/bin`; ensure that directory is on your PATH.

```sh
bluemock presets list
bluemock validate hm10-serial
bluemock presets copy hm10-serial
bluemock show hm10-serial --json
```

Device files live in `$BLUEMOCK_HOME/devices`, or
`$XDG_CONFIG_HOME/bluemock/devices`, or `~/.config/bluemock/devices` by default.
Windows uses `%APPDATA%\bluemock\devices` unless `BLUEMOCK_HOME` is set.
Use `bluemock paths --json` to see the resolved directories.

`bluemock save PATH` validates JSON from stdin and atomically writes YAML.
Saving replaces existing comments. Use `--json-errors` for structured errors.

Peripheral execution (`run`), environment checks (`doctor`), selftest, and the
native GUI arrive in later versions.
