"""Pre-parsed text templates and range-checked wire payloads."""

import ast
import re
from dataclasses import asdict, dataclass, is_dataclass

from .expr import (Expression, ExpressionError, compile_expression,
                   expression_names, unknown_name_messages)


class PayloadError(ValueError):
    """A malformed template, payload or out-of-range segment."""


INTEGER_SEGMENTS = {
    "u8": (1, "little", False),
    "u16le": (2, "little", False), "u16be": (2, "big", False),
    "u32le": (4, "little", False), "u32be": (4, "big", False),
    "i16le": (2, "little", True), "i16be": (2, "big", True),
    "i32le": (4, "little", True), "i32be": (4, "big", True),
}


def _unescape(text):
    def replace(match):
        value = match.group(1)
        if value.startswith("x"):
            if not re.fullmatch(r"x[0-9a-fA-F]{2}", value):
                raise PayloadError("Expected two hexadecimal digits after \\x")
            byte = int(value[1:], 16)
            return chr(byte if byte < 0x80 else 0xDC00 + byte)
        return {"r": "\r", "n": "\n", "t": "\t", "\\": "\\"}[value]
    return re.sub(r"\\(x.{0,2}|[rnt\\])", replace, text)


@dataclass(frozen=True)
class Template:
    parts: tuple

    def render(self, scope):
        result = []
        for part in self.parts:
            if isinstance(part, str):
                result.append(part)
            else:
                expression, spec = part
                try:
                    result.append(format(expression.evaluate(scope), spec))
                except (ValueError, TypeError) as exc:
                    raise PayloadError(f"Cannot render {{{expression.source}}}: {exc}") from exc
        return "".join(result)


def parse_template(source: str) -> Template:
    """Check syntax without knowing runtime names; escapes affect literal text only."""
    if not isinstance(source, str):
        raise PayloadError("Template must be a string")
    parts, literal = [], []
    index = 0
    while index < len(source):
        char = source[index]
        if source[index:index + 2] in ("{{", "}}"):
            literal.append(char)
            index += 2
            continue
        if char == "}":
            raise PayloadError("Unmatched '}' in template; use '}}' for a literal brace")
        if char != "{":
            literal.append(char)
            index += 1
            continue
        parts.append(_unescape("".join(literal)))
        literal = []
        start = index + 1
        index = start
        quote, escaped, depth, colon = None, False, 0, None
        while index < len(source):
            char = source[index]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif source.startswith(quote, index):
                    index += len(quote) - 1
                    quote = None
            elif colon is not None:
                if char == "{":
                    raise PayloadError("Nested placeholders in format specs are not allowed")
                if char == "}":
                    break
            elif char in ("'", '"'):
                quote = char * 3 if source.startswith(char * 3, index) else char
                index += len(quote) - 1
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            elif char == ":" and depth == 0:
                colon = index
            elif char == "}":
                break
            elif char == "{":
                raise PayloadError("Unexpected '{' inside expression")
            index += 1
        if index == len(source):
            raise PayloadError("Unclosed '{' in template")
        expression = compile_expression(source[start:colon if colon is not None else index])
        spec = source[colon + 1:index] if colon is not None else ""
        # No runtime names are needed to reject an invalid standard format spec.
        for sample in (0, 0.0, ""):
            try:
                format(sample, spec)
                break
            except (ValueError, TypeError):
                continue
        else:
            raise PayloadError(f"Invalid format specifier: {spec!r}")
        parts.append((expression, spec))
        index += 1
    parts.append(_unescape("".join(literal)))
    return Template(tuple(parts))


def _decode_hex(text):
    try:
        return bytes.fromhex("".join(text.split()))
    except ValueError as exc:
        raise PayloadError("Expected an even number of hexadecimal digits") from exc


def _mapping(payload):
    if is_dataclass(payload):
        payload = {key: value for key, value in asdict(payload).items() if value is not None}
    return payload


def template_names(template: Template) -> set[str]:
    """Return all names referenced by expressions in a parsed template."""
    return set().union(*(expression_names(part[0]) for part in template.parts
                         if not isinstance(part, str)))


def payload_names(payload: "ParsedPayload") -> set[str]:
    """Return all scope references in a parsed text/hex/segmented payload."""
    return set().union(*(expression_names(parsed) if isinstance(parsed, Expression)
                         else template_names(parsed) for _, parsed in payload.segments))


def check_payload(payload, available_names=None):
    """Return all relative-path issues; optionally check a known static scope."""
    payload = _mapping(payload)
    issues = []
    if not isinstance(payload, dict):
        return [("", "Payload must be an object")]
    kinds = [key for key in ("text", "hex", "bytes") if key in payload]
    if len(kinds) != 1:
        issues.append(("", "Payload must contain exactly one of text, hex or bytes"))
    def check_template(source, kind, path):
        try:
            template = parse_template(source)
            if available_names is not None:
                issues.extend((path, message) for message in
                              unknown_name_messages(template_names(template), available_names))
            if kind == "ascii":
                for part in template.parts:
                    if isinstance(part, str):
                        part.encode("ascii")
            if all(isinstance(part, str) for part in template.parts):
                rendered = template.render({})
                if kind == "hex":
                    _decode_hex(rendered)
                elif kind == "ascii":
                    rendered.encode("ascii")
        except (ExpressionError, PayloadError, UnicodeError) as exc:
            issues.append((path, str(exc)))
    for kind in kinds:
        if kind != "bytes":
            check_template(payload[kind], kind, kind)
            continue
        if not isinstance(payload[kind], list):
            issues.append(("bytes", "Segments must be a list"))
            continue
        for index, segment in enumerate(payload[kind]):
            path = f"bytes[{index}]"
            if not isinstance(segment, dict) or len(segment) != 1:
                issues.append((path, "Segment must have exactly one kind"))
                continue
            name, value = next(iter(segment.items()))
            if name in ("ascii", "hex"):
                check_template(value, name, path + "." + name)
            elif name in INTEGER_SEGMENTS:
                try:
                    expression = compile_expression(value)
                    if available_names is not None:
                        issues.extend((path + "." + name, message) for message in
                                      unknown_name_messages(expression_names(expression), available_names))
                    if isinstance(expression.tree, ast.Constant):
                        _integer_bytes(name, expression.evaluate({}))
                except (ExpressionError, PayloadError) as exc:
                    issues.append((path + "." + name, str(exc)))
            else:
                issues.append((path, f"Unknown segment kind: {name}"))
    return issues


def _integer_bytes(kind, value):
    size, byteorder, signed = INTEGER_SEGMENTS[kind]
    if type(value) is not int:
        raise PayloadError(f"{kind} requires an integer, got {value!r}")
    minimum = -(1 << (size * 8 - 1)) if signed else 0
    maximum = (1 << (size * 8 - (1 if signed else 0))) - 1
    if not minimum <= value <= maximum:
        raise PayloadError(f"{kind} value {value} is outside {minimum}..{maximum}")
    return value.to_bytes(size, byteorder, signed=signed)


@dataclass(frozen=True)
class ParsedPayload:
    segments: tuple

    def render(self, scope) -> bytes:
        result = []
        for kind, parsed in self.segments:
            if isinstance(parsed, Expression):
                result.append(_integer_bytes(kind, parsed.evaluate(scope)))
            else:
                value = parsed.render(scope)
                try:
                    result.append(_decode_hex(value) if kind == "hex" else
                                  value.encode("ascii") if kind == "ascii" else
                                  value.encode("utf-8", errors="surrogateescape"))
                except UnicodeError as exc:
                    raise PayloadError(f"{kind} payload cannot encode this text: {exc}") from exc
        return b"".join(result)


def parse_payload(payload) -> ParsedPayload:
    payload = _mapping(payload)
    issues = check_payload(payload)
    if issues:
        raise PayloadError("; ".join(f"{path}: {message}" for path, message in issues))
    if "bytes" in payload:
        segments = [next(iter(segment.items())) for segment in payload["bytes"]]
    else:
        segments = [(kind, payload[kind]) for kind in ("text", "hex") if kind in payload]
    return ParsedPayload(tuple((kind, compile_expression(value) if kind in INTEGER_SEGMENTS
                                else parse_template(value)) for kind, value in segments))


def render_payload(payload, scope) -> bytes:
    return (payload if isinstance(payload, ParsedPayload) else parse_payload(payload)).render(scope)
