"""Shared resource budgets and bounded input helpers (Python 3.10+)."""

import json
import math

import yaml

MAX_FORMAT_WIDTH = 4096
MAX_STRING_LENGTH = 65536
MAX_INT_BITS = 4096
MAX_EXPONENT = 64
MAX_STATE_VALUE_BYTES = 65536
MAX_STATE_TOTAL_BYTES = 1024 * 1024
MAX_DEFINITION_BYTES = 1024 * 1024
MAX_NESTING_DEPTH = 64
REGEX_TIMEOUT_S = 0.05
MAX_MATCH_INPUT = 4096


class BudgetError(ValueError):
    """An input exceeds a supported resource budget."""


class DefinitionLoader(yaml.SafeLoader):
    """Reject graph expansion and excessive depth before constructing nodes."""

    def __init__(self, stream):
        super().__init__(stream)
        self._collection_depth = 0

    def compose_node(self, parent, index):
        event = self.peek_event()
        if isinstance(event, yaml.events.AliasEvent) or getattr(event, "anchor", None):
            raise BudgetError("YAML anchors and aliases are not supported")
        collection = isinstance(event, (yaml.events.MappingStartEvent, yaml.events.SequenceStartEvent))
        if collection:
            self._collection_depth += 1
        try:
            if self._collection_depth > MAX_NESTING_DEPTH:
                raise BudgetError(f"Nesting depth exceeds {MAX_NESTING_DEPTH}")
            return super().compose_node(parent, index)
        finally:
            if collection:
                self._collection_depth -= 1

    def flatten_mapping(self, node):
        if any(key.tag == "tag:yaml.org,2002:merge" or key.value == "<<"
               for key, _ in node.value):
            raise BudgetError("YAML merge keys (<<) are not supported")
        super().flatten_mapping(node)


def check_nesting(value):
    """Iterate rather than recurse, including programmatically supplied inputs."""
    pending = [(value, 0)]
    while pending:
        child, depth = pending.pop()
        if isinstance(child, (dict, list)):
            depth += 1
            if depth > MAX_NESTING_DEPTH:
                raise BudgetError(f"Nesting depth exceeds {MAX_NESTING_DEPTH}")
            children = child.values() if isinstance(child, dict) else child
            pending.extend((item, depth) for item in children)


def parse_json(source):
    # Scan structural depth before json.loads can exhaust the Python stack.
    depth, quoted, escaped = 0, False, False
    for char in source:
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "[{":
            depth += 1
            if depth > MAX_NESTING_DEPTH:
                raise BudgetError(f"Nesting depth exceeds {MAX_NESTING_DEPTH}")
        elif char in "]}":
            depth -= 1
    return json.loads(source)


def read_definition(path):
    """Stat before reading, then bound the read too in case the file grows."""
    if hasattr(path, "stat") and path.stat().st_size > MAX_DEFINITION_BYTES:
        raise BudgetError(f"Definition exceeds {MAX_DEFINITION_BYTES} bytes")
    with path.open("rb") as handle:
        source = handle.read(MAX_DEFINITION_BYTES + 1)
    if len(source) > MAX_DEFINITION_BYTES:
        raise BudgetError(f"Definition exceeds {MAX_DEFINITION_BYTES} bytes")
    text = source.decode("utf-8")
    data = parse_json(text) if str(path).lower().endswith(".json") else yaml.load(text, Loader=DefinitionLoader)
    check_nesting(data)
    return data


def read_stdin_json(stream):
    # Text fallback supports StringIO; normal stdin is read as bytes.
    source = getattr(stream, "buffer", stream).read(MAX_DEFINITION_BYTES + 1)
    if isinstance(source, bytes):
        if len(source) > MAX_DEFINITION_BYTES:
            raise BudgetError(f"Definition exceeds {MAX_DEFINITION_BYTES} bytes")
        source = source.decode("utf-8")
    if len(source.encode("utf-8")) > MAX_DEFINITION_BYTES:
        raise BudgetError(f"Definition exceeds {MAX_DEFINITION_BYTES} bytes")
    return parse_json(source)


def check_state(state):
    """Account for bytes as hex text in the JSON budget; never mutate state."""
    for key, value in state.items():
        if type(value) not in (str, bytes, int, float, bool) or (
                type(value) is float and not math.isfinite(value)):
            raise BudgetError(f"{key}: state values must be finite numbers, strings, bytes or booleans")
        if isinstance(value, (str, bytes)):
            size = len(value.encode("utf-8", errors="surrogatepass")) if isinstance(value, str) else len(value)
            if size > MAX_STATE_VALUE_BYTES:
                raise BudgetError(f"{key}: state value exceeds {MAX_STATE_VALUE_BYTES} bytes")
        elif isinstance(value, int) and value.bit_length() > MAX_INT_BITS:
            raise BudgetError(f"{key}: integer exceeds {MAX_INT_BITS} bits")
    encoder = json.JSONEncoder(ensure_ascii=False, allow_nan=False, separators=(",", ":"),
                               default=lambda value: value.hex())
    total = 0
    for chunk in encoder.iterencode(state):
        total += len(chunk.encode("utf-8", errors="backslashreplace"))
        if total > MAX_STATE_TOTAL_BYTES:
            raise BudgetError(f"State exceeds {MAX_STATE_TOTAL_BYTES} JSON/UTF-8 bytes")
