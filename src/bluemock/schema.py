"""The v1 definition contract, normalization and structural validation.

Runtime expression scope comprises state variables, action parameters, regex named
groups, value (raw write bytes), and text (decoded, untrimmed write text).
Loading never evaluates user expressions or imports the Bluetooth runtime.
Explicit and derived Bluetooth addresses are random static addresses on every
transport, never public addresses.
"""

import keyword
import math
import re
import uuid
from dataclasses import dataclass, field, fields, is_dataclass
from pathlib import Path
from typing import Any

import yaml
import regex

from .limits import BudgetError, check_nesting, check_state, read_definition
from .expr import (ExpressionError, compile_expression,
                   expression_names, unknown_name_messages)
from .template import check_payload
from .schema_tests import TestCase, parse_tests, validate_tests

RESERVED_ACTION_IDS = frozenset(("send", "set", "state", "drop", "help", "quit", "exit"))


@dataclass
class ValidationIssue:
    path: str
    message: str


class ValidationError(ValueError):
    def __init__(self, errors):
        self.errors = errors
        super().__init__("\n".join(f"{e.path}: {e.message}" for e in errors))


@dataclass
class ManufacturerData:
    company_id: int
    hex: str


@dataclass
class Advertising:
    interval_ms: float = 250
    service_uuids: list[str] = field(default_factory=list)
    manufacturer_data: ManufacturerData | None = None


@dataclass
class Payload:
    characteristic: str | None = None
    text: str | None = None
    hex: str | None = None
    bytes: list[dict[str, Any]] | None = None


@dataclass
class Characteristic:
    id: str
    uuid: str
    properties: list[str]
    initial: Payload | None = None
    encoding: str = "text"


@dataclass
class Service:
    uuid: str
    characteristics: list[Characteristic]
    primary: bool = True


@dataclass
class Rule:
    on_write: str
    equals: str | None = None
    regex: str | None = None
    any: bool | None = None
    trim: bool = True
    reply: Payload | None = None
    set: dict[str, Any] = field(default_factory=dict)


@dataclass
class Param:
    name: str
    type: str
    default: Any = None
    min: float | None = None
    max: float | None = None
    choices: list[Any] | None = None


@dataclass
class Action:
    id: str
    label: str
    params: list[Param] = field(default_factory=list)
    set: dict[str, Any] = field(default_factory=dict)
    send: Payload | None = None


@dataclass
class Definition:
    bluemock: int
    id: str
    name: str
    description: str = ""
    address: str | None = None
    advertising: Advertising = field(default_factory=Advertising)
    services: list[Service] = field(default_factory=list)
    state: dict[str, Any] = field(default_factory=dict)
    rules: list[Rule] = field(default_factory=list)
    actions: list[Action] = field(default_factory=list)
    tests: list[TestCase] = field(default_factory=list)


def normalize_uuid(value) -> str:
    if type(value) is int:
        if not 0 <= value <= 0xFFFFFFFF:
            raise ValueError("UUID integer must fit in 32 bits")
        value = f"{value:04X}"
    if not isinstance(value, str):
        raise ValueError("UUID must be hexadecimal text or an integer")
    value = value.removeprefix("0x").removeprefix("0X")
    if re.fullmatch(r"[0-9a-fA-F]{1,8}", value):
        return value.upper().zfill(4 if len(value) <= 4 else 8)
    if re.fullmatch(r"[0-9a-fA-F]{32}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value):
        return str(uuid.UUID(value)).upper()
    raise ValueError("Expected a 16-bit, 32-bit or 128-bit hexadecimal UUID")


def validate(data, stem="device") -> list[ValidationIssue]:
    if isinstance(data, Definition):
        data = to_dict(data)
    try:
        check_nesting(data)
    except BudgetError as exc:
        return [ValidationIssue("$", str(exc))]
    errors = []
    def error(path, message):
        errors.append(ValidationIssue(path or "$", message))
    def obj(value, path):
        if not isinstance(value, dict):
            error(path, "Expected an object")
            return {}
        return value
    def seq(value, path):
        if not isinstance(value, list):
            error(path, "Expected a list")
            return []
        return value
    def text(value, path, nonempty=False):
        if not isinstance(value, str) or (nonempty and not value.strip()):
            error(path, "Expected a non-empty string" if nonempty else "Expected a string")
    def number(value, path):
        ok = type(value) is int or (type(value) is float and math.isfinite(value))
        if not ok:
            error(path, "Expected a finite number")
        return ok
    def identifier(value, path):
        if not isinstance(value, str) or not value.isidentifier() or keyword.iskeyword(value):
            error(path, "Expected an expression variable name")
    def check_uuid(value, path):
        try:
            normalize_uuid(value)
        except ValueError as exc:
            error(path, str(exc))
    def expression(value, path, scope):
        try:
            parsed = compile_expression(value)
            for message in unknown_name_messages(expression_names(parsed), scope):
                error(path, message)
        except ExpressionError as exc:
            error(path, str(exc))
    def payload(value, path, scope, target=False):
        value = obj(value, path)
        for suffix, message in check_payload(value, scope):
            error(path + ("." + suffix if suffix else ""), message)
        if target:
            reference(value.get("characteristic"), path + ".characteristic", {"notify", "indicate"})
    def reference(value, path, properties):
        if not isinstance(value, str) or value not in chars:
            error(path, f"Unknown characteristic: {value!r}")
        elif not properties.intersection(chars[value]):
            error(path, "Target requires " + " or ".join(sorted(properties)))
    def assignments(value, path, scope):
        for key, expr in obj(value, path).items():
            identifier(key, path + "." + str(key))
            if key not in state_keys:
                error(path + "." + str(key), f"Unknown state variable {key!r}; declare it under state")
            expression(expr, path + "." + str(key), scope)
    data = obj(data, "$")
    state = obj(data.get("state", {}), "state")
    try:
        check_state(state)
    except (ValueError, TypeError, RecursionError) as exc:
        error("$", str(exc))
    state_keys = {key for key in state if isinstance(key, str)}
    if type(data.get("bluemock")) is not int or data.get("bluemock") != 1:
        error("bluemock", "Required schema version is 1")
    text(data.get("id", stem), "id", True)
    text(data.get("name"), "name", True)
    if "description" in data:
        text(data["description"], "description")
    if "address" in data and (not isinstance(data["address"], str) or
                             not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", data["address"])):
        error("address", "Expected six colon-separated hexadecimal octets")
    elif "address" in data:
        address = data["address"].upper()
        if int(address[:2], 16) < 0xC0 or address in ("FF:FF:FF:FF:FF:FF", "C0:00:00:00:00:00"):
            error("address", "address must be a random static address (first octet C0-FF)")
    chars = {}
    services = seq(data.get("services", []), "services")
    if not services:
        error("services", "At least one service is required")
    for i, service in enumerate(services):
        path = f"services[{i}]"
        service = obj(service, path)
        check_uuid(service.get("uuid"), path + ".uuid")
        if type(service.get("primary", True)) is not bool:
            error(path + ".primary", "Expected a boolean")
        characteristics = seq(service.get("characteristics", []), path + ".characteristics")
        if not characteristics:
            error(path + ".characteristics", "At least one characteristic is required")
        for j, char in enumerate(characteristics):
            cp = f"{path}.characteristics[{j}]"
            char = obj(char, cp)
            cid = char.get("id")
            text(cid, cp + ".id", True)
            check_uuid(char.get("uuid"), cp + ".uuid")
            props = seq(char.get("properties", []), cp + ".properties")
            if not props or any(p not in ("read", "write", "write_without_response", "notify", "indicate") for p in props):
                error(cp + ".properties", "Expected read, write, write_without_response, notify or indicate")
            if isinstance(cid, str):
                if cid in chars:
                    error(cp + ".id", f"Duplicate characteristic id: {cid}")
                chars[cid] = [p for p in props if isinstance(p, str)]
            if char.get("encoding", "text") not in ("text", "hex"):
                error(cp + ".encoding", "Expected text or hex")
            if "initial" in char:
                payload(char["initial"], cp + ".initial", state_keys)
    ad = obj(data.get("advertising", {}), "advertising")
    if number(ad.get("interval_ms", 250), "advertising.interval_ms") and ad.get("interval_ms", 250) <= 0:
        error("advertising.interval_ms", "Must be positive")
    for i, value in enumerate(seq(ad.get("service_uuids", []), "advertising.service_uuids")):
        check_uuid(value, f"advertising.service_uuids[{i}]")
    if "manufacturer_data" in ad:
        md = obj(ad["manufacturer_data"], "advertising.manufacturer_data")
        if type(md.get("company_id")) is not int or not 0 <= md["company_id"] <= 65535:
            error("advertising.manufacturer_data.company_id", "Expected an integer in 0..65535")
        try:
            if not isinstance(md.get("hex"), str):
                raise ValueError("Expected hexadecimal text")
            bytes.fromhex("".join(md["hex"].split()))
        except ValueError as exc:
            error("advertising.manufacturer_data.hex", str(exc))
    for key, value in state.items():
        identifier(key, "state." + str(key))
        if type(value) not in (int, float, bool, str):
            error("state." + str(key), "Expected a number, string or boolean")
        elif type(value) in (int, float):
            number(value, "state." + str(key))
    for i, rule in enumerate(seq(data.get("rules", []), "rules")):
        path = f"rules[{i}]"
        rule = obj(rule, path)
        scope = state_keys | {"value", "text"}
        reference(rule.get("on_write"), path + ".on_write", {"write", "write_without_response"})
        if sum(key in rule for key in ("equals", "regex", "any")) != 1:
            error(path, "Exactly one of equals, regex or any is required")
        for key in ("equals", "regex"):
            if key in rule:
                text(rule[key], path + "." + key)
        if isinstance(rule.get("regex"), str):
            try:
                scope.update(regex.compile(rule["regex"], regex.VERSION0).groupindex)
            except (regex.error, RecursionError) as exc:
                error(path + ".regex", str(exc))
        if "any" in rule and rule["any"] is not True:
            error(path + ".any", "Expected true")
        if type(rule.get("trim", True)) is not bool:
            error(path + ".trim", "Expected a boolean")
        if "reply" in rule:
            payload(rule["reply"], path + ".reply", scope, True)
        assignments(rule.get("set", {}), path + ".set", scope)
    action_ids = set()
    for i, action in enumerate(seq(data.get("actions", []), "actions")):
        path = f"actions[{i}]"
        action = obj(action, path)
        aid = action.get("id")
        text(aid, path + ".id", True)
        text(action.get("label", aid), path + ".label", True)
        if isinstance(aid, str):
            if aid in action_ids:
                error(path + ".id", f"Duplicate action id: {aid}")
            if aid in RESERVED_ACTION_IDS:
                error(path + ".id", f"Action id {aid!r} is reserved for a built-in command; choose another id")
            action_ids.add(aid)
        names = set()
        for j, param in enumerate(seq(action.get("params", []), path + ".params")):
            pp = f"{path}.params[{j}]"
            param = obj(param, pp)
            name, kind = param.get("name"), param.get("type")
            identifier(name, pp + ".name")
            if isinstance(name, str):
                if name in names:
                    error(pp + ".name", f"Duplicate parameter name: {name}")
                names.add(name)
            if kind not in ("number", "integer", "string", "boolean", "choice"):
                error(pp + ".type", "Expected number, integer, string, boolean or choice")
            choices = seq(param.get("choices", []), pp + ".choices")
            if kind == "choice" and not choices:
                error(pp + ".choices", "Choice parameters require non-empty choices")
            for index, choice in enumerate(choices):
                if type(choice) not in (int, float, str, bool):
                    error(f"{pp}.choices[{index}]", "Expected a number, string or boolean")
                elif type(choice) in (int, float):
                    number(choice, f"{pp}.choices[{index}]")
            bounds = {key: param[key] for key in ("min", "max") if key in param and number(param[key], pp + "." + key)}
            if bounds and kind not in ("number", "integer", "choice"):
                error(pp, "min/max bounds require a numeric parameter or numeric choice")
            if "min" in bounds and "max" in bounds and bounds["min"] > bounds["max"]:
                error(pp + ".max", "Must be greater than or equal to min")
            if "default" in param:
                value = param["default"]
                valid = {"number": type(value) in (int, float), "integer": type(value) is int,
                         "string": isinstance(value, str), "boolean": type(value) is bool,
                         "choice": value in choices}.get(kind if isinstance(kind, str) else "", False)
                if not valid:
                    error(pp + ".default", "Default does not match parameter type or choices")
                if type(value) in (int, float):
                    number(value, pp + ".default")
                    if ("min" in bounds and value < bounds["min"]) or ("max" in bounds and value > bounds["max"]):
                        error(pp + ".default", "Default is outside min/max bounds")
                elif bounds:
                    error(pp + ".default", "A default with min/max bounds must be numeric")
                if choices and value not in choices:
                    error(pp + ".default", "Default is not in choices")
        scope = state_keys | names
        assignments(action.get("set", {}), path + ".set", scope)
        if "send" in action:
            payload(action["send"], path + ".send", scope, True)
    validate_tests(data, state_keys, chars, error)
    return errors


def parse_definition(data, stem="device") -> Definition:
    errors = validate(data, stem)
    if errors:
        raise ValidationError(errors)
    def payload(value):
        return Payload(**{k: value[k] for k in ("characteristic", "text", "hex", "bytes") if k in value}) if value is not None else None
    services = [Service(normalize_uuid(s["uuid"]), [Characteristic(c["id"], normalize_uuid(c["uuid"]),
                c["properties"], payload(c.get("initial")), c.get("encoding", "text"))
                for c in s["characteristics"]], s.get("primary", True)) for s in data["services"]]
    ad = data.get("advertising", {})
    advertising = Advertising(ad.get("interval_ms", 250), [normalize_uuid(u) for u in ad.get("service_uuids",
                [s.uuid for s in services if s.primary])], ManufacturerData(ad["manufacturer_data"]["company_id"],
                ad["manufacturer_data"]["hex"]) if "manufacturer_data" in ad else None)
    rules = [Rule(r["on_write"], r.get("equals"), r.get("regex"), r.get("any"), r.get("trim", True),
                  payload(r.get("reply")), r.get("set", {})) for r in data.get("rules", [])]
    actions = [Action(a["id"], a.get("label", a["id"]), [Param(**{k: p[k] for k in
               ("name", "type", "default", "min", "max", "choices") if k in p}) for p in a.get("params", [])],
               a.get("set", {}), payload(a.get("send"))) for a in data.get("actions", [])]
    return Definition(1, data.get("id", stem), data["name"], data.get("description", ""),
                      data.get("address"), advertising, services, data.get("state", {}), rules, actions, parse_tests(data))


def load(path) -> Definition:
    try:
        path = path if hasattr(path, "open") else Path(path)
        return parse_definition(read_definition(path), Path(str(path)).stem)
    except ValidationError:
        raise
    except (OSError, UnicodeError, ValueError, RecursionError, yaml.YAMLError) as exc:
        raise ValidationError([ValidationIssue("$", str(exc))]) from exc


def to_dict(definition: Definition) -> dict:
    """Return ordered schema keys, omitting only contextual schema defaults."""
    defaults = {
        Definition: {"description": "", "state": {}, "rules": [], "actions": [], "tests": []},
        Characteristic: {"encoding": "text"}, Service: {"primary": True},
        Rule: {"trim": True, "set": {}}, Action: {"params": [], "set": {}},
        TestCase: {"params": {}},
    }
    def clean(value):
        if is_dataclass(value):
            omitted = defaults.get(type(value), {})
            result = {}
            for item in fields(value):
                child = getattr(value, item.name)
                if child is None or (item.name in omitted and child == omitted[item.name]):
                    continue
                result[item.name] = clean(child)
            return result
        if isinstance(value, dict):
            return {k: clean(v) for k, v in value.items()}
        if isinstance(value, list):
            return [clean(v) for v in value]
        return value
    return clean(definition)
