# Device definition schema v1

A definition describes one BLE peripheral. YAML is the authoring and saved-file
format; JSON input is also accepted. These fields are consumed by the CLI and
exposed as the normalized device in [IPC](ipc-protocol.md).

`bluemock validate X` collects errors with paths such as `actions[0].send.text`
or `tests[2].expect.characteristic`. `--json` returns
`{"ok":false,"errors":[{"path":"...","message":"..."}]}` on failure.
Valid definitions exit 0; invalid definitions exit 1.

## Files and normalization

Device directory selection, in order:

1. If `BLUEMOCK_HOME` is set: `$BLUEMOCK_HOME/devices` on every platform.
2. On Windows: `%APPDATA%\bluemock\devices`, or the user's
   `AppData\Roaming\bluemock\devices` when APPDATA is unset.
3. On macOS/Linux, if `XDG_CONFIG_HOME` is set:
   `$XDG_CONFIG_HOME/bluemock/devices`.
4. Otherwise on macOS/Linux: `~/.config/bluemock/devices`.

`bluemock paths --json` reports the device directory, package preset directory,
and CLI version. Commands taking X resolve an existing file path first; then,
for a bare name, device-directory `X.yaml`, `X.yml`, `X.json`, in that order;
finally bundled preset id X. Searches use filenames, not internal definition
ids. Use a bare name without an extension or an explicit path.

`presets copy ID [DEST]` copies a commented template. DEST defaults to the device
directory's `ID.yaml`; overwrites require `--force`. `save PATH` reads JSON on
stdin, validates, and atomically writes YAML; use a `.yaml` destination. Invalid
input leaves the destination unchanged. Saving drops comments. `--json-errors`
uses the validation error shape above.

`show`/`save` preserve schema key order and omit optional default values: empty
description/state/rules/actions/tests/params/set, trim true, encoding text,
primary true, and absent optional objects. They keep bluemock, id, name,
advertising interval/service UUIDs, and services. Loading restores defaults, so
GUI clients must not require every optional field in normalized JSON. Omit
optional fields rather than supplying null. Use only documented fields;
unsupported fields may be discarded during normalization.

## General fields

| Key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `bluemock` | integer | required | Exactly 1 |
| `id` | string | filename stem | Non-empty identifier; filename-safe names recommended |
| `name` | string | required | Non-empty advertised local name; app filters may require a pattern |
| `description` | string | empty | Human-readable description |
| `address` | string | derived from name | Optional random static address, described below |
| `advertising` | object | default settings | Advertising fields below |
| `services` | array | required | At least one service object |
| `state` | object | empty | Initial mutable variables |
| `rules` | array | empty | Ordered write handlers |
| `actions` | array | empty | User-triggered operations |
| `tests` | array | empty | Optional selftest cases; editors must preserve this block |

Addresses are six hexadecimal octets separated by colons. The first octet must
be C0–FF (the top two bits set); FF:FF:FF:FF:FF:FF and C0:00:00:00:00:00 are
invalid. All transports use random static addressing, including explicit
addresses. Otherwise a hash of the name gives a stable address. `run --name N`
changes this derived address and the default netsim chip name; it does not
change an explicit address. Strings and references are case sensitive except
UUID spelling.

## Advertising and GATT

| Advertising key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `interval_ms` | number | 250 | Positive finite milliseconds; must be supported by the controller |
| `service_uuids` | UUID array | all primary service UUIDs | Empty array advertises none; GATT services still exist |
| `manufacturer_data` | object | omitted | Optional manufacturer advertisement |
| `manufacturer_data.company_id` | integer | required in object | 0..65535; emitted as two little-endian bytes |
| `manufacturer_data.hex` | string | required in object | Even count of hex digits, whitespace allowed; not a template |

Advertisement and scan response each have a 31-byte budget, including AD field
overhead. Flags 0x06 and the complete name go into advertising with UUID lists
grouped by 16/32/128-bit size and optional manufacturer data. If necessary UUIDs
and manufacturer data move to scan response. If the name cannot fit with flags,
a UTF-8-safe shortened name is advertised and the complete name moves to scan
response. Remaining fields may use spare advertisement space. Startup fails
clearly when everything cannot fit in the two packets; shorten the name or
reduce advertising fields. The complete name must fit in a scan-response AD
structure. Advertising restarts after disconnect.

| Service key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `uuid` | UUID | required | Service UUID |
| `primary` | boolean | true | False creates a secondary service |
| `characteristics` | array | required | At least one characteristic |

UUID strings accept 16-bit, 32-bit or 128-bit hex, case-insensitively, with an
optional 0x prefix. Short forms normalize to four/eight uppercase hex digits;
128-bit values normalize to uppercase dashed UUIDs. Undashed 32-hex-digit UUIDs
are accepted. Integer UUIDs must fit in 32 bits. Quote numeric-looking YAML
UUIDs: `"1800"` means hex 1800, while unquoted `1800` is decimal. `0x1800` also
works as an integer.

| Characteristic key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `id` | string | required | Non-empty, unique across the definition; target for references |
| `uuid` | UUID | required | Characteristic UUID |
| `properties` | string array | required | One or more of read, write, write_without_response, notify, indicate |
| `initial` | payload | omitted | Reads render this with current state; absent means empty bytes |
| `encoding` | string | text | text or hex; controls readable REPL rx/tx presentation |

Encoding does not change payload bytes or switch rules to hex matching. Reads
reflect state rather than automatically returning the last central write.
Reply/send targets must have notify or indicate; rule/write-test targets must
have write or write_without_response. Only subscribed centrals receive data.

## State, rules and actions

State maps Python identifiers (not keywords) to finite numbers, strings or
booleans. Null and collection values are not valid initial state. Declare every
variable before assigning it in a set map. Values persist until changed or the
process stops. Prefer distinct state, parameter and regex-group names.

| Rule key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `on_write` | characteristic id | required | Writable target |
| `equals` | string | omitted | Exact comparison after optional trim |
| `regex` | string | omitted | Compiled Python regex, matched using search |
| `any` | boolean | omitted | Must be true; matches every write on target |
| `trim` | boolean | true | Strip whitespace/CRLF from the matching string |
| `reply` | targeted payload | omitted | Sent after state assignments |
| `set` | expression object | empty | Existing state keys mapped to expressions |

Exactly one of equals, regex or any is required. Rules run in order and the
first match wins. Writes use UTF-8 with surrogateescape: value is raw bytes,
text is the original untrimmed string, and trim affects only matching. Regexes
use search; anchor with ^ and $ for a full match. Named groups use
`(?P<name>...)` and contain strings; unmatched optional groups can be None
(use an expression such as `v or ''` when appropriate).

All set values evaluate against one pre-write scope, then commit together.
Reply renders with updated state plus the same write/group values. A rule
without reply accepts silently; an unmatched write has no automatic response.
Assignments do not see earlier entries' newly assigned values.

| Action key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `id` | string | required | Non-empty, unique among actions; simple command names recommended; cannot be a reserved REPL command |
| `label` | string | action id | Non-empty display label |
| `params` | parameter array | empty | Ordered declarations |
| `set` | expression object | empty | Existing state keys only |
| `send` | targeted payload | omitted | Sent after assignments |

Actions evaluate all set expressions against pre-action state plus coerced
parameters, commit together, then render send with updated state and parameters.
Actions may set without sending, or send without setting.
Action ids cannot be `send`, `set`, `state`, `drop`, `help`, `quit`, or `exit`.
These names are REPL built-ins and validation reports a reserved-id error at
`actions[i].id`. Choose another action id such as `push`; the payload field
`send` is unaffected.
The `send <characteristic> text:...` command is a REPL built-in for a direct
transmission. Use a different action id, such as `push`, for action controls.

| Parameter key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `name` | string | required | Python identifier, not keyword; unique within action |
| `type` | string | required | number, integer, string, boolean or choice |
| `default` | scalar | omitted | Absent makes it required; must satisfy type/bounds/choices |
| `min` | number | omitted | Inclusive numeric lower bound; number/integer/choice only |
| `max` | number | omitted | Inclusive upper bound; must be >= min |
| `choices` | scalar array | required for choice | Non-empty finite numbers, strings or booleans |

| Type | Runtime coercion in REPL, IPC actions and action tests |
| --- | --- |
| number | Integer literals/decimal integer strings stay integer; other numeric input becomes float; booleans/non-finite values rejected |
| integer | Integer values/strings or integral floats; fractional floats rejected |
| string | Converted with str |
| boolean | Booleans, integers 1/0, case-insensitive strings true/false/1/0/yes/no |
| choice | Try each choice's type in declaration order; use first equal value or fail |

Bounds apply to numeric results, including numeric choices. A default with
min/max must be numeric. Use choices for choice parameters. Unknown parameters,
missing values and failed coercions are errors. Choices are scalars, not objects
with labels; explanatory meanings can go in the action label or YAML comments.

## Payloads

Every payload contains exactly one of text, hex or bytes. Reply, send, test write
and test expect also require characteristic, a target id. Initial has no target.

| Key | Type | Rendering |
| --- | --- | --- |
| `text` | string template | UTF-8 text; template hex escapes emit exact bytes |
| `hex` | string template | Render, remove whitespace, hex-decode an even digit count |
| `bytes` | segment array | Render one-key segments and concatenate in order |

Templates support `{expression}`, `{expression:format_spec}`, and literal braces
`{{` / `}}`. Format specs use Python formatting, such as .1f, 04d, 02X. Nested
replacement fields and !r/!s conversions are not supported. Literal template
text processes `\r`, `\n`, `\t`, `\xNN` and `\\` after YAML parsing; rendered
expression results are not processed again as template syntax.

```yaml
# YAML double-quoted escapes produce readable CRLF.
text: "T{depth:.1f}\r\n"
# Single quotes preserve this template escape for one raw FF byte.
text: 'A\xFFB'
# value must be an integer in the payload's scope.
hex: "02 {value:04X} 03"
```

YAML itself decodes double-quoted `"\xFF"` into Unicode, so use the single-quoted
form for raw byte escapes. Ordinary Unicode encodes as UTF-8. Hex payloads
should contain hex digits and whitespace rather than raw escapes.

| Integer segment | Width | Integer range |
| --- | --- | --- |
| u8 | 1 byte | 0..255 |
| u16le / u16be | 2 bytes | 0..65535 |
| u32le / u32be | 4 bytes | 0..4294967295 |
| i16le / i16be | 2 bytes | -32768..32767 |
| i32le / i32be | 4 bytes | -2147483648..2147483647 |

Integer values are integer literals or expressions returning integers, checked
for range rather than silently wrapped. le/be selects endian order. ascii and
hex segments contain templates; ascii rejects non-ASCII characters and raw
escapes >= 0x80; hex decodes rendered hexadecimal text.

```yaml
bytes:
  - {u8: 2}
  - {ascii: "01"}
  - {ascii: "{value:04d}"}
  - {ascii: M}
  - {u8: 3}
```

## Expressions and scopes

Expressions use a whitelisted AST, never eval/exec. Allowed: number/string/bool
literals, scope names, `+ - * / // % **`, unary minus/not, comparisons
`== != < <= > >= in not in is is not`, and/or, `a if condition else b`, and
positional calls to `abs round int float str min max len uniform randint`.
Random functions come from Python's random module. Attributes, subscripts,
containers, lambdas, comprehensions, f-strings, keyword arguments and other
calls are rejected. Exponent magnitude is capped at 64. Results of binary
operations are limited to 4096-bit integers and 65536-character strings.

All expressions/templates and variable names are checked before loading.
Function call names need no state declaration. Convert regex groups with int
before arithmetic. Python round uses ties-to-even; the Lematec/Shahe presets
use arithmetic for half-away-from-zero rounding, as the gauge firmware does.

| Location | Available scope |
| --- | --- |
| Characteristic initial | Current state |
| Rule set values | Pre-update state, value bytes, untrimmed text, named regex groups |
| Rule reply | Updated state plus the same write values/groups |
| Action set values | Pre-update state plus coerced parameters |
| Action send | Updated state plus coerced parameters |
| Manual send | Current state |
| Test write | Fresh initial state for the case |
| Test expect | State after the trigger; no action parameters or regex groups |
| REPL set | Pre-update current state, values as expressions |
| IPC set | No expressions; literal JSON scalars assigned to existing state keys |

Parameters shadow state. In rules write values/groups shadow state; named
groups also shadow value/text if those names are reused. Set targets must be
declared state keys; there are no temporary local declarations. Calculations
can appear directly in placeholders or integer segments.

## Selftest cases

| Test key | Type | Default | Constraints / meaning |
| --- | --- | --- | --- |
| `name` | string | generated test number | Optional result label |
| `write` | targeted payload | omitted | Central write to a writable target |
| `action` | action id | omitted | Existing action to trigger |
| `params` | parameter-value object | empty | Action tests only; coerced/validated with action defaults |
| `expect` | targeted payload or string none | required | Exact next notification on target, or silence |

Exactly one of write or action is required. Each case starts with fresh initial
state, in order, on one subscribed connection: cases cannot pass state to the
next case. Write uses a response when write is supported, otherwise write
without response. Expect waits up to 2 seconds on its target. `expect: none`
asserts no notification on any subscribed characteristic for 500 ms. Editors
must preserve tests even without a test-editing UI.

Selftest scans, connects, discovers every declared service/characteristic,
subscribes, executes these cases, then also runs every action with all-default
parameters. No emulator is needed. Output is PASS/FAIL per check plus a summary;
--json returns ok/checks. Any failed check exits 1. Avoid exact expectations of
randomly generated readings.

## Complete annotated example

```yaml
bluemock: 1
id: custom-gauge
name: BM-CUSTOM
description: Query or push a depth reading
# Omit to derive from name; explicit addresses must be unique across devices.
address: F0:F1:F2:F3:F4:F5
advertising:
  interval_ms: 250
  service_uuids: [FFE0]
  manufacturer_data: {company_id: 0x0059, hex: "0102"}
services:
  - uuid: FFE0
    primary: true
    characteristics:
      - id: serial
        uuid: FFE1
        properties: [read, write, write_without_response, notify]
        initial: {text: "T{depth:.1f}\r\n"}
        encoding: text
state:
  depth: 7.5
  window: 50
rules:
  # Specific queries precede the final silent catch-all.
  - on_write: serial
    equals: T
    trim: true
    reply: {characteristic: serial, text: "T{depth:.1f}\r\n"}
  - on_write: serial
    regex: '^AT(?P<v>\d+)$'
    set: {window: "int(v)"}
  - on_write: serial
    any: true
actions:
  - id: measure
    label: Push depth (mm)
    params:
      - {name: mm, type: number, default: 12.3, min: 0, max: 30}
    set: {depth: mm}
    send: {characteristic: serial, text: "T{depth:.1f}\r\n"}
tests:
  - name: Query initial depth
    write: {characteristic: serial, text: "T\r\n"}
    expect: {characteristic: serial, text: "T7.5\r\n"}
  - name: Push a measurement
    action: measure
    params: {mm: 9.4}
    expect: {characteristic: serial, text: "T9.4\r\n"}
  - name: Update a setting silently
    write: {characteristic: serial, text: AT80}
    expect: none
```
