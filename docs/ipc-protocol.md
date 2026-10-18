# Bluemock IPC protocol v1

This document defines the protocol used by `bluemock run X --ipc`. Clients can
also supply `--name N` and `--transport SPEC`. `--transport local` uses an
in-process radio and requires no emulator.

## Framing and streams

Both directions use UTF-8 JSON lines: exactly one JSON object per line, ending
with a newline. Literal newlines inside strings must use JSON escapes. Each
stdout event is flushed immediately. Blank input lines are malformed commands,
not keepalives. Input lines are limited to 1 MiB; oversized lines produce a
nonfatal error and the reader resumes at the next line.

Stdout contains only compact JSON event objects. Human output, third-party
prints and native diagnostics cannot be interpreted as events; incidental
Python prints are redirected to stderr. Python warning/error logging becomes
`log` events. Native runtime diagnostics may still reach stderr, so clients must
drain both pipes. `GRPC_VERBOSITY=ERROR` is set before importing the radio stack.

JSON numbers must be finite. Nonstandard NaN/Infinity constants are rejected.
Commands execute sequentially. Events from the radio may arrive independently
of commands. Clients must keep reading stdout while sending commands.

## Common event fields

Every event contains `ts`, an ISO-8601 UTC timestamp, and `event`, its type.
Examples below use a fixed timestamp for readability. All listed fields are
required unless marked optional. Additional fields may appear.

### ready

Fields: `v` (protocol version, currently 1), `version` (CLI version), `device`
(complete normalized definition), `transport` (resolved transport specification).
The device includes declared actions and their parameters/defaults, suitable
for rendering forms, and preserves an optional device `tests` block. Schema
defaults may be omitted; an action with no parameters can omit `params`.
Ready is emitted after radio power-on and before advertising starts.

```json
{"ts":"2026-10-18T07:00:00+00:00","event":"ready","v":1,"version":"0.1.0","device":{"bluemock":1,"id":"example","name":"BM-EXAMPLE","advertising":{"interval_ms":250,"service_uuids":["FFE0"]},"services":[{"uuid":"FFE0","characteristics":[{"id":"serial","uuid":"FFE1","properties":["notify","write_without_response"]}]}],"state":{"battery":0,"tag":""},"actions":[{"id":"send","label":"Send text","params":[{"name":"message","type":"string","default":"hello"}],"send":{"characteristic":"serial","text":"{message}\r\n"}}]},"transport":"android-netsim:name=BM-EXAMPLE"}
```

### advertising

Field: `address` (random static Bluetooth address). Emitted when advertising
starts successfully, including after a disconnect and restart.

```json
{"ts":"2026-10-18T07:00:00+00:00","event":"advertising","address":"F0:F1:F2:F3:F4:F5"}
```

### connected

Field: `peer` (remote Bluetooth address as reported by the radio).

```json
{"ts":"2026-10-18T07:00:01+00:00","event":"connected","peer":"01:00:00:BB:BB:BB/P"}
```

### disconnected

Fields: `peer`, `reason` (integer Bluetooth disconnection reason).

```json
{"ts":"2026-10-18T07:00:02+00:00","event":"disconnected","peer":"01:00:00:BB:BB:BB/P","reason":19}
```

### subscribed

Fields: `characteristic` (definition id), `notify` (boolean), `indicate`
(boolean). A change to false/false indicates that subscription was disabled.

```json
{"ts":"2026-10-18T07:00:01+00:00","event":"subscribed","characteristic":"serial","notify":true,"indicate":false}
```

### rx

Fields: `characteristic`, `hex` (uppercase hexadecimal bytes separated by spaces),
optional `text` (present only when all bytes decode as valid UTF-8). An empty
payload has an empty hex string. Rx is a central write, before rule evaluation.

```json
{"ts":"2026-10-18T07:00:01+00:00","event":"rx","characteristic":"serial","hex":"68 69","text":"hi"}
```

### tx

Fields: `characteristic`, `hex`, optional `text` (same UTF-8 rule as rx),
`source` (`rule`, `action` or `manual`), optional `ref` (zero-based rule index or
action id). Manual sends omit ref. Tx records a send through the peripheral;
only subscribed centrals receive notifications/indications.

```json
{"ts":"2026-10-18T07:00:01+00:00","event":"tx","characteristic":"serial","hex":"68 69 0D 0A","text":"hi\r\n","source":"action","ref":"send"}
```

### state

Field: `values` (complete current state object), optional `reply_to` for a
correlated `state` command. Emitted after state updates and on explicit request.
State changes made by rules/actions are events, not acknowledgments.

```json
{"ts":"2026-10-18T07:00:01+00:00","event":"state","values":{"battery":2,"tag":"ABC"},"reply_to":"read-state-1"}
```

### log

Fields: `level` (lowercase logging level), `message` (string). Embedded newlines
are JSON-escaped and do not create additional physical lines.

```json
{"ts":"2026-10-18T07:00:01+00:00","event":"log","level":"warning","message":"Radio diagnostic"}
```

### error

Fields: `message`, `fatal` (boolean), optional `reply_to`. Fatal false leaves the
session usable. Fatal true means the engine/session is shutting down and exits
with status 1. A fatal startup error can occur before ready.

```json
{"ts":"2026-10-18T07:00:01+00:00","event":"error","message":"Unknown command: nope","fatal":false,"reply_to":"request-2"}
```

### stopped

No additional required fields. This is the final stdout event, after cleanup.
No events, including logging events, follow it.

```json
{"ts":"2026-10-18T07:00:03+00:00","event":"stopped"}
```

## Commands

Every command is an object with a non-empty string `cmd`. Unknown optional
fields are ignored. An optional `id` is echoed as `reply_to` on an error caused
by that command and on the state response to `cmd:state`. The id should be a
small JSON value; clients normally use strings or integers. No general success
acknowledgment exists. Malformed JSON has no usable correlation id.

For the action command, `id` is required and identifies the action itself; it
also supplies error correlation. There is no separate action request-id field
in v1. Correlation does not attach unrelated radio errors to a prior command.

### action

Required `id` is an existing action id. Optional `params` is an object; omitted
parameters use declared defaults, and required parameters without defaults
produce errors. Values use the definition's parameter coercion and bounds.

```json
{"cmd":"action","id":"send","params":{"message":"hi"}}
```

### send

Required `characteristic` is a notify/indicate characteristic id. Supply exactly
one of `text`, `hex`, or `bytes`, with the same payload syntax as device files.
Templates render against current state. A send can produce a tx event even
without subscribed centrals.

```json
{"cmd":"send","id":"manual-1","characteristic":"serial","text":"hello\r\n"}
{"cmd":"send","characteristic":"serial","hex":"02 01 03"}
{"cmd":"send","characteristic":"serial","bytes":[{"u8":2},{"ascii":"hello"},{"u8":3}]}
```

### set

Required `values` is an object whose keys already exist in the definition's
state. Values are **literal** finite numbers, strings or booleans, never
expressions. Strings such as `ABC` are stored directly; do not add Python
quotes. Null, arrays and objects are rejected. All keys/values are checked
before applying the update, so a bad field changes nothing. This differs from
the interactive REPL's expression-based `set` command.

```json
{"cmd":"set","id":"set-1","values":{"battery":2,"tag":"ABC"}}
```

### state

Request the complete state object. Its state event echoes an optional id.

```json
{"cmd":"state","id":"read-state-1"}
```

### drop

Disconnect every connected central. The peripheral remains available and
restarts advertising. Optional id is used for any command-caused error.

```json
{"cmd":"drop","id":"disconnect-1"}
```

### stop

Request graceful shutdown; the final response is stopped. No following commands
are processed.

```json
{"cmd":"stop"}
```

## Errors, shutdown and versioning

Malformed JSON, non-object input, missing fields, unknown commands, invalid
parameters, bad payloads, and invalid state assignments produce error events with
fatal false. Subsequent valid commands continue to work. Radio startup/loss and
unrecoverable session failures produce fatal true and exit status 1. Native
diagnostics are not protocol events and must be read from stderr.

The stop command, stdin EOF, SIGINT and SIGTERM trigger graceful cleanup:
stop advertising, disconnect centrals, close transport, then emit stopped last.
Graceful shutdown exits 0 unless an engine or cleanup failure occurred. Clients
should wait for stopped and process exit, while continuing to drain both pipes.
If stdout is closed by the client, delivery of the final event is impossible;
the process still attempts cleanup without printing a traceback.

Protocol version is ready.v, currently 1, and is independent of the CLI package
version. Adding event types or fields is non-breaking. Clients **must ignore
unknown events and unknown fields**. Incompatible framing, command semantics,
or existing required-field changes require a new protocol version and matching
GUI support.
