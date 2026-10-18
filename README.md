# Bluemock

**Simulated Bluetooth Low Energy peripherals for the Android emulator.**

Bluemock lets you test Bluetooth features of an Android app on the emulator,
with no physical device and no changes to the app under test. It runs a
virtual BLE peripheral on the emulator's own virtual radio (netsim), so the
app scans, connects, subscribes and exchanges data exactly as it would with
real hardware.

- **Describe devices in YAML**: services, characteristics, auto-replies to
  commands, internal state, and actions that push readings.
- **Drive them live** from an interactive prompt, a JSON-lines IPC stream, or
  the native macOS menu bar app.
- **Ship with presets** for common profiles (Nordic UART, HM-10 serial, Heart
  Rate, Battery) and three handheld tyre gauges.
- **Test definitions offline** with `bluemock selftest`, which checks exact
  bytes against an in-process central.

```
┌──────────────┐  YAML  ┌─────────────────┐  HCI/gRPC  ┌─────────┐  virtual BLE  ┌──────────────────┐
│ device file  │───────▶│ bluemock (CLI)  │───────────▶│ netsim  │──────────────▶│ Android emulator │
└──────────────┘        │  Google Bumble  │            └─────────┘               │   your app       │
                        └────────▲────────┘                                      └──────────────────┘
                                 │ JSON-lines IPC
                        ┌────────┴────────┐
                        │  Bluemock.app   │  macOS menu bar
                        └─────────────────┘
```

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [macOS menu bar app](#macos-menu-bar-app)
- [Bundled presets](#bundled-presets)
- [Interactive prompt](#interactive-prompt)
- [Writing your own device](#writing-your-own-device)
- [Several devices and several emulators](#several-devices-and-several-emulators)
- [Command reference](#command-reference)
- [IPC for GUI authors](#ipc-for-gui-authors)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Project layout](#project-layout)
- [License](#license)

## Requirements

- **Python 3.10+**
- **Android Emulator 33.1.4+** with an **API 33+** system image (emulator
  Bluetooth is backed by netsim from these versions on)
- Bluetooth enabled in the emulator (`bluemock doctor --fix` can turn it on)
- macOS 14+ for the optional menu bar app

The CLI runs on macOS and Linux. Windows support for the CLI is untested.

## Installation

From a clone of this repository:

```sh
git clone https://github.com/FarhanFDjabari/Bluemock.git
cd Bluemock
scripts/install.sh
```

The installer creates (or reuses) a virtual environment in
`~/.local/share/bluemock/venv` and links `~/.local/bin/bluemock`. Add
`~/.local/bin` to your `PATH` if it asks you to. Re-running it upgrades in place.

Prefer pipx? From the clone:

```sh
pipx install .
```

Bluemock pins `bumble[android]==0.0.236`. The `[android]` extra matters: plain
`bumble` lacks the netsim transport.

Check the install:

```sh
bluemock --version
```

## Quick start

Start an API 33+ emulator, then:

```sh
bluemock doctor                        # checks SDK, emulator, netsim and Bluetooth
bluemock presets list                  # see the bundled devices
bluemock run hm10-serial               # start a simulated HM-10 serial module
```

On the emulator, open **Settings › Connected devices › Pair new device**:
`BM-HM10` appears in the list. Your app can now scan for it, connect and
subscribe. The terminal shows each connection, write and notification as it
happens:

```text
08:35:02 ready: BM-HM10 (android-netsim:name=BM-HM10)
08:35:02 advertising: address='C8:37:F4:92:02:0E'
08:35:41 connected: peer='49:40:C1:54:07:C5'
08:35:41 subscribed: characteristic='serial' notify=True indicate=False
bluemock> push hello
08:35:47 tx: serial: 'hello\r\n' [68 65 6C 6C 6F 0D 0A]
```

To keep a preset as your own editable copy, use
`bluemock presets copy <preset-id>`. It lands in your device folder (see
[Writing your own device](#writing-your-own-device)).

## macOS menu bar app

Bluemock.app is a small menu bar front end for the CLI. It shows the emulator
environment, lists your devices, and starts or stops them with one click.
Expanding a running device gives you forms for its actions, its current state,
a live text/hex event log and a **Disconnect central** button. **New device…**
opens an editor that creates devices from scratch, from a preset, or by
duplicating an existing one.

Build it from the clone:

```sh
apps/macos/scripts/build.sh            # produces apps/macos/build/Bluemock.app
```

Or open `apps/macos/Bluemock/Bluemock.xcodeproj` in Xcode. Move `Bluemock.app`
to `/Applications` and launch it; it lives in the menu bar without a Dock icon.

The app drives the `bluemock` CLI, so install the CLI first. The app looks for
it on your login shell's `PATH`, in `~/.local/bin`, `/opt/homebrew/bin` and
`/usr/local/bin`, or at a path you set in **Settings**. Settings also offers
**Launch at login**.

Each running device is its own CLI process, so several devices can run at once.
The editor validates through the CLI and saves YAML through `bluemock save`.

## Bundled presets

| Preset | Advertised name | What it simulates |
| --- | --- | --- |
| `hm10-serial` | `BM-HM10` | HM-10 serial module (`FFE0`/`FFE1`), echoes writes, `push` sends text |
| `nordic-uart` | `BM-NUS` | Nordic UART Service: RX writes, TX notifications |
| `heart-rate` | `BM-HR` | Heart Rate (`180D`) measurement plus body sensor location |
| `battery` | `BM-BAT` | Battery Service (`180F`) level, readable and notifiable |
| `translogik-gauge` | `TLG-SIM-001` | TransLogik-style tread/pressure probe: command/response over HM-10 serial, RFID, battery state, settings |
| `lematec-gauge` | `DTP-SIM-001` | Lematec DTP-style gauge: framed tread/pressure packets, zero calibration |
| `shahe-gauge` | `B-1001` | Shahe-style depth gauge: binary depth with sign flag |

Every preset carries `tests:` cases, so `bluemock selftest <preset>` proves it
byte for byte. Notes on the gauges:

- The Lematec and Shahe presets only push notifications; they accept no writes.
- Apps that detect Shahe gauges by name expect `^B-\d+$`, so keep that shape
  when renaming (`--name B-1002`).
- Lematec units: `M` mm, `L` inch, `P` psi, `B` bar, `G` kg/cm², `K` kPa.
  Scaled values round half away from zero.
- TransLogik battery states: 0 good, 1 external power, 2 charging, 3 needs
  charging, 4 critically low.

The gauge presets are written from the wire formats these devices are known to
use. They are not affiliated with or endorsed by the respective manufacturers.

## Interactive prompt

`bluemock run <device>` opens a `bluemock>` prompt. Device actions become
commands; parameters go positionally in declaration order or as `name=value`.
For the TransLogik preset:

```text
tread 9.4                    push a tread depth reading
pressure psi=35              push a pressure reading
battery level=3              report "needs charging"
calibrate                    simulate the calibration button
rfid tag=SIMTAG002           push an RFID tag
```

Built-in commands:

| Command | Effect |
| --- | --- |
| `help` | List actions, their parameters and the characteristics |
| `state` | Print the current state values |
| `set name=expr` | Evaluate an expression and update an existing state value |
| `send <char> text:...` | Send a text payload template manually |
| `send <char> hex:02 01 03` | Send explicit bytes |
| `drop` | Disconnect the connected central and resume advertising |
| `quit` / `exit` | Stop the device and exit |

These names are reserved, so device actions can't be called `send`, `set`,
`state`, `drop`, `help`, `quit` or `exit`. Ctrl-C and end of input also stop
cleanly, and commands can be piped:

```sh
printf 'tread 9.4\nstate\nquit\n' | bluemock run translogik-gauge
```

Commands sent by the app get their replies automatically. For example, the
TransLogik preset answers the app's `T` query with the current tread value.
Only subscribed centrals receive notifications, even when the log shows a `tx`
line.

## Writing your own device

Device files live in `~/.config/bluemock/devices` (macOS/Linux) or
`%APPDATA%\bluemock\devices` (Windows). Set `BLUEMOCK_HOME` to use another base
folder; `XDG_CONFIG_HOME` is also honoured. `bluemock run <id>` looks for a file
path first, then `<id>.yaml` in that folder, then a bundled preset.

A minimal device:

```yaml
bluemock: 1
name: MY-SENSOR
services:
  - uuid: FFE0
    characteristics:
      - id: serial
        uuid: FFE1
        properties: [notify, write_without_response]
state:
  level: 50
rules:                                   # auto-replies to writes, first match wins
  - on_write: serial
    equals: LEVEL?
    reply: {characteristic: serial, text: "LEVEL {level}\r\n"}
actions:                                 # prompt commands, IPC actions and GUI buttons
  - id: level
    label: Push level
    params: [{name: value, type: integer, default: 50, min: 0, max: 100}]
    set: {level: "value"}
    send: {characteristic: serial, text: "LEVEL {value}\r\n"}
tests:                                   # checked by `bluemock selftest`
  - write: {characteristic: serial, text: "LEVEL?"}
    expect: {characteristic: serial, text: "LEVEL 50\r\n"}
```

Payloads can be text templates, hex, or byte segments (`u8`, `u16le`,
`u32be`, `ascii`, and more). Templates use `{expression:format}` placeholders
evaluated by a small, safe expression language, never Python `eval`. The
[device schema reference](docs/device-schema.md) documents every field.

The usual loop:

```sh
bluemock presets copy hm10-serial my-device.yaml
# edit my-device.yaml: id, name, services, rules, actions
bluemock validate my-device.yaml       # reports every error with its path
bluemock selftest my-device.yaml       # no emulator needed
bluemock run my-device.yaml
```

`selftest` starts the device on an in-process radio, connects a Bumble central,
subscribes, runs each `tests:` case and each action that has default parameters,
and compares the exact bytes. It exits 1 on any failure, which makes it usable
in CI.

## Several devices and several emulators

Every emulator on the machine shares the same netsim radio, so a running device
is visible to all of them. Run one process per device:

```sh
bluemock run translogik-gauge                      # terminal 1
bluemock run shahe-gauge                           # terminal 2
bluemock run translogik-gauge --name TLG-SIM-002   # terminal 3: second copy
```

`--name` changes the advertised name, which is how you give each emulator its
own device or match a name your app already knows. It doesn't register the
device with your app's backend. If your app only lists registered devices,
register the name there first.

Like real hardware, a device accepts **one connection at a time**. While an
emulator is connected, the device stops advertising and the other emulators
can't see it. To hand it to another emulator, disconnect it in the app, or use
`drop` (prompt), `{"cmd":"drop"}` (IPC) or **Disconnect central** (macOS app).

## Command reference

| Command | Purpose |
| --- | --- |
| `bluemock run <x> [--name N] [--transport SPEC] [--ipc]` | Run a device: interactive prompt, or JSON-lines IPC with `--ipc` |
| `bluemock selftest <x> [--json]` | Check a definition end to end on a local radio |
| `bluemock validate <x> [--json]` | Validate a definition and report every error |
| `bluemock show <x> [--json]` | Print the normalized definition (YAML, or JSON with `--json`) |
| `bluemock save <path> [--json-errors]` | Validate a JSON definition from stdin and write it as YAML |
| `bluemock presets list [--json]` | List bundled presets |
| `bluemock presets copy <id> [dest] [--force]` | Copy a preset into your device folder |
| `bluemock devices list [--json]` | List your saved devices and whether they are valid |
| `bluemock paths --json` | Show the device folder, preset folder and version |
| `bluemock doctor [--json] [--fix]` | Diagnose the emulator setup, optionally turning Bluetooth on |

`<x>` is a file path, a saved device id, or a preset id. `--transport` accepts
any Bumble transport spec; the default is `android-netsim:name=<advertised name>`.

## IPC for GUI authors

`bluemock run <x> --ipc` swaps the prompt for a machine interface: JSON events
on stdout, one per line, and JSON commands on stdin. The macOS app uses
exactly this, and other front ends can too.

```sh
printf '{"cmd":"state","id":"s1"}\n{"cmd":"action","id":"push","params":{"message":"hi"}}\n{"cmd":"stop"}\n' |
  bluemock run hm10-serial --ipc --transport local
```

Events include `ready` (with the full definition), `advertising`, `connected`,
`subscribed`, `rx`, `tx`, `state`, `error` and `stopped`. Commands are
`action`, `send`, `set` (literal JSON values), `state`, `drop` and `stop`.
`show --json` and `save` let an editor work with device files without a YAML
library. The full contract, including correlation, versioning and shutdown
rules, is in the [IPC protocol](docs/ipc-protocol.md).

## Troubleshooting

`bluemock doctor` checks Python and Bumble, the Android SDK, the emulator
version, netsim, every running emulator's API level, and its Bluetooth state.

| Symptom | Fix |
| --- | --- |
| `The bumble[android] extra is required...` | Reinstall with `scripts/install.sh` or `pipx install .`; plain `bumble` lacks the netsim transport |
| Emulator Bluetooth is off | `bluemock doctor --fix` |
| netsim not available | Start an emulator; netsim starts with it |
| Emulator API below 33 | Use an API 33+ system image and emulator 33.1.4+ |
| Device advertises but the app doesn't list it | Check the name your app filters on, its registered-device list, the service UUIDs, and the app's Bluetooth permissions |
| No reading arrives | Make sure the app connected and subscribed (the log shows `subscribed`), then run the action again |
| Startup fails with an advertising size error | Shorten the name or advertise fewer UUIDs; legacy advertising fits two 31-byte packets |

## Limitations

- BLE only; Classic Bluetooth (SPP/RFCOMM) is not implemented yet.
- One central per device at a time, matching real peripherals.
- Bluemock simulates a device's protocol, not its physical sensor.
- The menu bar app is macOS only; on Windows and Linux use the CLI.

## Project layout

```
src/bluemock/         CLI, Bumble engine, schema, expressions, IPC, doctor
src/bluemock/presets/ bundled device definitions
docs/                 device schema and IPC protocol references
apps/macos/           Bluemock.app (SwiftUI menu bar app) and its build script
scripts/install.sh    user-level installer
```

## License

Bluemock is released under the [MIT License](LICENSE).

Built on [Google Bumble](https://github.com/google/bumble) and the Android
Emulator's netsim virtual radio.
