"""Definition-management CLI; engine commands register here in later phases."""

import argparse
import json
import os
import sys
import tempfile
from dataclasses import asdict
from pathlib import Path

import yaml

from . import __version__, paths, schema


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


class DefinitionDumper(yaml.SafeDumper):
    pass


def _represent_string(dumper, value):
    return dumper.represent_scalar("tag:yaml.org,2002:str", value,
                                   style="|" if "\n" in value else None)


DefinitionDumper.add_representer(str, _represent_string)


def _yaml(data):
    return yaml.dump(data, Dumper=DefinitionDumper, default_flow_style=False,
                     sort_keys=False, allow_unicode=True)


def _print(data, as_json=False):
    print(json.dumps(data, ensure_ascii=False, allow_nan=False) if as_json else _yaml(data),
          end="\n" if as_json else "")


def _errors(errors, as_json=False):
    if as_json:
        _print({"ok": not errors, "errors": [asdict(error) for error in errors]}, True)
    else:
        for error in errors:
            print(f"{error.path}: {error.message}", file=sys.stderr)


def _atomic_save(destination, content):
    """Replace only after validation and complete serialization have succeeded."""
    destination = Path(destination).expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                         dir=destination.parent, prefix=".bluemock-",
                                         suffix=".tmp", delete=False) as handle:
            temporary = handle.name
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


def _parser():
    parser = Parser(prog="bluemock", description="Manage simulated BLE device definitions")
    parser.add_argument("--version", action="version", version=__version__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "show"):
        item = commands.add_parser(command)
        item.add_argument("definition", metavar="X")
        item.add_argument("--json", action="store_true")
    save = commands.add_parser("save", description="Validate stdin JSON and save YAML; existing comments are discarded")
    save.add_argument("path", metavar="PATH")
    save.add_argument("--json-errors", action="store_true")
    presets = commands.add_parser("presets").add_subparsers(dest="operation", required=True)
    presets.add_parser("list").add_argument("--json", action="store_true")
    copy = presets.add_parser("copy")
    copy.add_argument("id", metavar="ID")
    copy.add_argument("destination", metavar="DEST", nargs="?")
    copy.add_argument("--force", action="store_true")
    devices = commands.add_parser("devices").add_subparsers(dest="operation", required=True)
    devices.add_parser("list").add_argument("--json", action="store_true")
    commands.add_parser("paths").add_argument("--json", action="store_true", required=True)
    # P2 registers run/selftest here; P3 registers doctor. No runtime imports in P1.
    return parser


def _summary(path):
    row = {"id": Path(str(path)).stem, "name": "", "description": "",
           "path": str(path), "valid": False, "error": None}
    try:
        definition = schema.load(path)
        row.update(id=definition.id, name=definition.name, description=definition.description, valid=True)
    except schema.ValidationError as exc:
        row["error"] = str(exc)
    return row


def _save(args):
    try:
        data = json.load(sys.stdin)
        definition = schema.parse_definition(data, Path(args.path).stem)
        content = _yaml(schema.to_dict(definition))
        _atomic_save(args.path, content)
    except schema.ValidationError as exc:
        _errors(exc.errors, args.json_errors)
        return 1
    except (OSError, ValueError, UnicodeError, yaml.YAMLError) as exc:
        _errors([schema.ValidationIssue("$", str(exc))], args.json_errors)
        return 1
    return 0


def _copy(args):
    preset = next((p for p in paths.presets() if Path(p.name).stem == args.id), None)
    if preset is None:
        raise ValueError(f"Unknown preset {args.id!r}; use 'bluemock presets list'")
    destination = Path(args.destination).expanduser() if args.destination else paths.device_dir() / (args.id + ".yaml")
    content = preset.read_text(encoding="utf-8")
    if args.force:
        _atomic_save(destination, content)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            with destination.open("x", encoding="utf-8", newline="\n") as handle:
                handle.write(content)
        except FileExistsError as exc:
            raise ValueError(f"{destination} already exists; use --force to overwrite") from exc
    print(destination)
    return 0


def _dispatch(args):
    if args.command == "paths":
        _print({"device_dir": str(paths.device_dir()), "preset_dir": str(paths.preset_dir()),
                "version": __version__}, True)
    elif args.command == "save":
        return _save(args)
    elif args.command in ("validate", "show"):
        try:
            definition = schema.load(paths.resolve(args.definition))
        except (schema.ValidationError, OSError) as exc:
            errors = exc.errors if isinstance(exc, schema.ValidationError) else [schema.ValidationIssue("$", str(exc))]
            _errors(errors, args.json)
            return 1
        if args.command == "show":
            _print(schema.to_dict(definition), args.json)
        elif args.json:
            _errors([], True)
        else:
            print(f"{args.definition}: valid")
    elif args.command == "presets":
        if args.operation == "copy":
            return _copy(args)
        rows = [_summary(path) for path in paths.presets()]
        if args.json:
            _print(rows, True)
        else:
            for row in rows:
                print(f"{row['id']}\t{row['name']}\t{row['description']}")
    elif args.command == "devices":
        directory = paths.device_dir()
        rows = [_summary(path) for path in sorted(directory.iterdir())
                if path.is_file() and path.suffix.lower() in (".yaml", ".yml", ".json")] if directory.exists() else []
        if args.json:
            _print(rows, True)
        else:
            for row in rows:
                status = "valid" if row["valid"] else row["error"]
                print(f"{row['id']}\t{row['name']}\t{row['path']}\t{status}")
    return 0


def main(argv=None) -> int:
    try:
        return _dispatch(_parser().parse_args(argv))
    except (OSError, ValueError, UnicodeError, yaml.YAMLError) as exc:
        print(f"$: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
