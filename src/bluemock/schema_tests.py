"""Optional device selftest declarations; independent of the Bluetooth runtime."""

from dataclasses import dataclass, field

from .params import check_params
from .template import check_payload


@dataclass
class TestCase:
    name: str | None = None
    write: dict | None = None
    action: str | None = None
    params: dict = field(default_factory=dict)
    expect: dict | str = "none"


def validate_tests(data, state_keys, chars, error):
    tests = data.get("tests", [])
    if not isinstance(tests, list):
        error("tests", "Expected a list")
        return
    actions = {a["id"]: a for a in data.get("actions", [])
               if isinstance(a, dict) and isinstance(a.get("id"), str)} if isinstance(data.get("actions", []), list) else {}

    def payload(value, path, properties):
        for suffix, message in check_payload(value, state_keys):
            error(path + ("." + suffix if suffix else ""), message)
        cid = value.get("characteristic") if isinstance(value, dict) else None
        if not isinstance(cid, str) or cid not in chars:
            error(path + ".characteristic", f"Unknown characteristic: {cid!r}")
        elif not properties.intersection(chars[cid]):
            error(path + ".characteristic", "Target requires " + " or ".join(sorted(properties)))

    for index, test in enumerate(tests):
        path = f"tests[{index}]"
        if not isinstance(test, dict):
            error(path, "Expected an object")
            continue
        if "name" in test and not isinstance(test["name"], str):
            error(path + ".name", "Expected a string")
        if sum(key in test for key in ("write", "action")) != 1:
            error(path, "Exactly one of write or action is required")
        if "write" in test:
            payload(test["write"], path + ".write", {"write", "write_without_response"})
            if "params" in test:
                error(path + ".params", "Parameters are only valid for action tests")
        if "action" in test:
            action = test["action"]
            if "params" in test and not isinstance(test["params"], dict):
                error(path + ".params", "Expected a parameter object")
            if not isinstance(action, str) or action not in actions:
                error(path + ".action", f"Unknown action: {action!r}")
            else:
                specs = actions[action].get("params", [])
                if isinstance(specs, list) and isinstance(test.get("params", {}), dict):
                    _, issues = check_params([p for p in specs if isinstance(p, dict)], test.get("params", {}))
                    for key, message in issues:
                        error(path + ".params" + ("." + key if key else ""), message)
        if test.get("expect") != "none":
            payload(test.get("expect"), path + ".expect", {"notify", "indicate"})


def parse_tests(data):
    return [TestCase(**{key: test[key] for key in ("name", "write", "action", "params", "expect")
                        if key in test}) for test in data.get("tests", [])]
