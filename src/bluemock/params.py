"""Shared action parameter coercion for runtime commands and definition tests."""

import math
import re


def _get(param, name, default=None):
    return param.get(name, default) if isinstance(param, dict) else getattr(param, name, default)


def _typed(value, kind):
    if kind == "string":
        return str(value)
    if kind == "boolean":
        if isinstance(value, str):
            lowered = value.lower()
            if lowered in ("true", "1", "yes"):
                return True
            if lowered in ("false", "0", "no"):
                return False
        elif type(value) is bool or (type(value) is int and value in (0, 1)):
            return bool(value)
        raise ValueError("Expected true/false, 1/0 or yes/no")
    if type(value) is bool:
        raise ValueError("Expected a number, not a boolean")
    if kind == "integer":
        if isinstance(value, float) and not value.is_integer():
            raise ValueError("Expected an integer")
        return int(value)
    if kind == "number":
        if type(value) is int or (isinstance(value, str) and re.fullmatch(r"[+-]?\d+", value)):
            return int(value)
        return float(value)
    raise ValueError(f"Unknown parameter type: {kind}")


def coerce_param(param, value):
    kind = _get(param, "type")
    if kind == "choice":
        choices = _get(param, "choices", []) or []
        for choice in choices:
            choice_type = {str: "string", bool: "boolean", int: "integer", float: "number"}.get(type(choice))
            try:
                coerced = _typed(value, choice_type)
                if coerced == choice:
                    value = choice
                    break
            except (ValueError, TypeError, OverflowError):
                continue
        else:
            raise ValueError(f"Expected one of {choices!r}")
    else:
        value = _typed(value, kind)
    if type(value) in (int, float):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("Expected a finite number")
        minimum, maximum = _get(param, "min"), _get(param, "max")
        if minimum is not None and value < minimum:
            raise ValueError(f"Must be at least {minimum}")
        if maximum is not None and value > maximum:
            raise ValueError(f"Must be at most {maximum}")
    return value


def check_params(specs, provided):
    """Return (coerced values, all (parameter-name, message) errors)."""
    if not isinstance(provided, dict):
        return {}, [("", "Expected a parameter object")]
    specs = [p for p in specs if isinstance(_get(p, "name"), str)]
    declared = {_get(p, "name") for p in specs}
    errors = [(str(key), f"Unknown parameter: {key}") for key in provided if key not in declared]
    values = {}
    for param in specs:
        name = _get(param, "name")
        value = provided.get(name, _get(param, "default"))
        if value is None:
            errors.append((name, "Missing required parameter"))
            continue
        try:
            values[name] = coerce_param(param, value)
        except (ValueError, TypeError, OverflowError) as exc:
            errors.append((name, str(exc)))
    return values, errors
