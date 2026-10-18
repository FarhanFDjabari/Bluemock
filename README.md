# bluemock

Simulate BLE peripherals for the Android emulator without changing the app
under test. bluemock runs a Bumble peripheral over the emulator's netsim radio.
YAML files define services, characteristics, responses, state, and controls for
pushing readings. Each running process represents one device.

## Requirements and installation

- Python 3.10 or newer.
- Android SDK emulator 33.1.4 or newer, with an API 33+ system image.
- Emulator Bluetooth enabled; `bluemock doctor` checks the environment.

From a checkout on macOS or Linux:

```sh
scripts/install.sh
```

The script creates/reuses `~/.local/share/bluemock/venv` and links
`~/.local/bin/bluemock`. Add `~/.local/bin` to PATH if prompted. Alternatively,
with pipx installed, install from a checkout on any supported CLI platform:

```sh
pipx install .
```

The package pins `bumble[android]==0.0.236`, including netsim dependencies, and
installs PyYAML. Run `bluemock --version` to check the command is available.

## Quick start

Start an API 33+ emulator, then:

```sh
bluemock doctor
bluemock presets list
bluemock presets copy translogik-gauge
bluemock run translogik-gauge
```

Open your app on the emulator, or open **Settings > Connected devices > Pair new
device** to find `TLG-SIM-001`. Seeing a device in that list confirms advertising;
an app connects and subscribes to receive readings. The run terminal shows
connections, received writes, notifications, and errors above its prompt.

At the `bluemock>` prompt, push readings or inspect state:

```text
tread 12.3
pressure psi=35
battery level=3
calibrate
rfid tag=SIMTAG002
state
help
quit
```

Battery states are 0 battery good, 1 external power, 2 charging, 3 needs charging,
and 4 battery critically low. A query from the app such as `T` receives the
current tread value; a tread action also pushes an unsolicited reading.

## Bundled devices

All seven presets include local selftest cases and can be copied as templates.

| Preset | Advertised name | Behavior |
| --- | --- | --- |
| hm10-serial | BM-HM10 | FFE0/FFE1 serial echo and text send |
| nordic-uart | BM-NUS | Nordic UART RX writes and TX notifications |
| heart-rate | BM-HR | 180D heart rate and readable body sensor location |
| battery | BM-BAT | 180F readable/notifiable charge percentage |
| translogik-gauge | TLG-SIM-001 | Command/response tread, pressure, battery, settings and RFID |
| lematec-gauge | DTP-SIM-001 | Framed tread/pressure packets and zero-calibration event |
| shahe-gauge | B-1001 | Binary depth magnitude and sign flag |

Lematec and Shahe only push notifications; they do not accept writes. Shahe
names must match `^B-\d+$` for applications that detect that gauge by name.
Lematec units are M mm, L inch, P psi, B bar, G kg/cm², and K kPa; enter the
value in the selected unit. Lematec and Shahe preserve their Swift simulators'
half-away rounding when scaling readings to wire integers.

## REPL commands

Actions accept positional parameters in declaration order or `name=value`
parameters. `help` lists each action's label and parameters plus characteristic
ids. Declared defaults fill omitted parameters; a required parameter must be
supplied. Examples for a running TransLogik definition:

Action ids may not be "send", "set", "state", "drop", "help", "quit", or "exit"; these names are REPL commands. The HM-10/Nordic presets use the action id "push".

| Command | Effect |
| --- | --- |
| `tread 9.4` | Set and push tread depth |
| `send serial text:hello` | Send a text template manually |
| `send serial hex:02 01 03` | Send explicit bytes |
| `set tread_mm=tread_mm+1` | Evaluate an expression and update existing state |
| `state` | Print current state |
| `drop` | Disconnect centrals and resume advertising |
| `help` | Show actions and commands |
| `quit` / `exit` | Stop the peripheral and exit |

Ctrl-C and stdin EOF also stop cleanly. Commands can be piped, for example:

```sh
printf 'tread 9.4\nstate\nquit\n' | bluemock run translogik-gauge
```

Only subscribed centrals receive notifications, even when a tx line is shown.
The characteristic's encoding controls whether readable logs include decoded
text or hex only.

## Device names and multiple devices

Use a name that your app already recognizes or has registered:

```sh
bluemock run translogik-gauge --name TLG-123456
```

This changes the advertised name and default netsim chip name. It does not add a
device to your app's account or registered-device list. Without an explicit
address in the file, the name also determines a stable random static address.

Run simultaneous devices in separate terminals:

```sh
# Terminal 1
bluemock run translogik-gauge
# Terminal 2
bluemock run shahe-gauge
```

For several copies of one preset, give each a different `--name`. Preserve app
name filters, for example `--name B-1002` for a second Shahe. Default netsim
transport specs use `android-netsim:name=<name>`, allowing separate chip instances.
Automatically generated chip names cannot contain comma, equals, or colon.
If files set explicit addresses, choose a distinct valid address for each device.

## Your own device and selftest

Copy a preset, edit its YAML, then validate and selftest:

```sh
bluemock paths --json
bluemock presets copy hm10-serial my-device.yaml
# Edit my-device.yaml, including its id and advertised name.
bluemock validate my-device.yaml
bluemock selftest my-device.yaml
bluemock run my-device.yaml
```

See the [device schema reference](docs/device-schema.md) for every field,
payload templates, safe expressions, scopes, rules, and annotated examples.
The default device directory is `~/.config/bluemock/devices` on macOS/Linux,
or `%APPDATA%\bluemock\devices` on Windows. `BLUEMOCK_HOME` selects a base whose
devices subdirectory is used; macOS/Linux also support `XDG_CONFIG_HOME`.

```sh
bluemock selftest translogik-gauge
bluemock selftest shahe-gauge --json
```

Selftest needs no emulator: it scans, connects, discovers, subscribes, and checks
exact bytes through a second Bumble device on a local radio. Each declared case
starts with initial state. The exit code is 1 if any check fails. It also runs
actions whose parameters all have defaults. `bluemock run X --transport local`
uses an isolated local radio; an Android emulator cannot see that transport.

`show X [--json]` returns normalized definitions, `devices list [--json]` lists
saved files, and `save PATH [--json-errors]` validates JSON from stdin before an
atomic YAML write. Use a `.yaml` save destination; saving does not preserve
comments. `presets copy` refuses to overwrite an existing file without `--force`.

## IPC for GUI authors

`run --ipc` replaces the human REPL with flushed JSON-lines events on stdout and
JSON-lines commands on stdin. See the [IPC protocol](docs/ipc-protocol.md) for
event shapes, correlation, versioning, and shutdown rules.

## macOS app

Build the menu bar app from a checkout with:

```sh
apps/macos/scripts/build.sh
```

The script creates `apps/macos/build/Bluemock.app`; you can also open
`apps/macos/Bluemock/Bluemock.xcodeproj` in Xcode. Move `Bluemock.app` to
`/Applications` to install it, then launch it. Bluemock appears in the menu bar
without a Dock icon.

Install the CLI first with `scripts/install.sh`, or set its executable path in
Bluemock Settings. The panel shows environment status and supported Bluetooth
fixes, and starts or stops devices. Expand a running device to trigger actions,
inspect state, view a text or hex event log, or disconnect the central. Choose
**New device…** to start from a blank definition, a preset, or a duplicate.
The editor validates through the CLI and saves YAML through `bluemock save`.

Enable **Launch at login** in Settings to start Bluemock automatically. Each
running device uses a separate CLI process, so multiple peripherals can run at
once.

## macOS app

Build the menu bar app from a checkout with:

```sh
apps/macos/scripts/build.sh
```

The script creates `apps/macos/build/Bluemock.app`; you can also open
`apps/macos/Bluemock/Bluemock.xcodeproj` in Xcode. Move `Bluemock.app` to
`/Applications` to install it, then launch it. Bluemock appears in the menu bar
and does not add a Dock icon.

Install the CLI first with `scripts/install.sh`, or set its executable path in
Bluemock Settings. The panel shows environment status and supported Bluetooth
fixes, and starts or stops devices. Expand a running device to trigger actions,
inspect state, view a text or hex event log, or disconnect the central. Choose
**New device…** to start from a blank definition, a preset, or an existing
device. The editor validates through the CLI and saves YAML through
`bluemock save`.

Enable **Launch at login** in Settings to start Bluemock automatically. Each
running device uses a separate CLI process, so multiple peripherals can run at
once.

## macOS app

Build the menu bar app from a checkout with:

```sh
apps/macos/scripts/build.sh
```

The script creates `apps/macos/build/Bluemock.app`; you can also open
`apps/macos/Bluemock/Bluemock.xcodeproj` in Xcode. Move `Bluemock.app` to
`/Applications` to install it, then launch it. Bluemock appears in the menu bar
and does not add a Dock icon.

Install the CLI first with `scripts/install.sh`, or set its executable path in
Bluemock Settings. The panel shows the environment status, lets you apply
supported Bluetooth fixes, and starts or stops devices. Expand a running device
to trigger its actions, inspect state, view the text or hex event log, or
disconnect the central. Choose **New device…** to create a definition, start
from a preset, or duplicate a saved device. The editor validates through the
CLI and saves YAML through `bluemock save`.

Settings can register Bluemock to launch at login. Each running device is a
separate CLI process, so several peripherals can run at once.

```sh
printf '{"cmd":"state","id":"s1"}\n{"cmd":"action","id":"push","params":{"message":"hi"}}\n{"cmd":"stop"}\n' |
  bluemock run hm10-serial --ipc --transport local
```

An IPC set assigns literal JSON values to existing state keys; REPL set
evaluates expressions. GUI editors can read `show --json` and write through
`save --json-errors` without implementing YAML themselves.

## Troubleshooting and limitations

Run `bluemock doctor --json` for structured diagnostics. Doctor reports the SDK,
emulator version, netsim, connected emulators, their AVD/API, and Bluetooth state.

| Problem | Next step |
| --- | --- |
| Missing android-netsim transport or grpc dependency | Reinstall this checkout with the installer or pipx; plain bumble lacks the required bumble[android] extra |
| Emulator Bluetooth is off | Run `bluemock doctor --fix` to enable it and recheck |
| netsim is unavailable | Start an emulator; netsim starts with it, then rerun doctor |
| System image API is below 33 | Use an API 33+ AVD; also ensure emulator binary version >= 33.1.4 |
| Device advertises but your app does not list it | Check expected name, registered-device list, service UUIDs, and app permissions |
| No reading arrives | Confirm the app connected and subscribed, then invoke the appropriate action |

BLE is supported; Classic SPP/RFCOMM is not implemented yet. Legacy BLE
advertising uses two 31-byte packets, so oversized names/advertising fields can
fail at startup. This simulates device protocols rather than physical sensors.
The native menu bar app runs on macOS; Windows and Linux currently use the CLI.
