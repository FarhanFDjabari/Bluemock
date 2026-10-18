"""Version 1 JSON-lines IPC; imports the radio only after isolating stdout."""

import asyncio
import copy
import json
import logging
import math
import os
import signal
import sys
from dataclasses import replace
from .ipc_writer import EventWriter, _command_context, _event
from .limits import MAX_DEFINITION_BYTES


class EventLogHandler(logging.Handler):
    def __init__(self, writer):
        super().__init__()
        self.writer = writer

    def emit(self, record):
        try:
            message = self.format(record)
        except Exception:
            message = str(record.msg)
        self.writer(_event("log", level=record.levelname.lower(), message=message))


def _required_text(command, field):
    value = command.get(field)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty string")
    return value


def _reject_constant(value):
    raise ValueError(f"Invalid JSON constant: {value}")


def _finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("JSON numbers must be finite")
    return number


async def dispatch_command(engine, command):
    """Validate framing/command fields before calling the engine's safe methods."""
    if not isinstance(command, dict):
        raise ValueError("Command must be a JSON object")
    kind = _required_text(command, "cmd")
    if kind == "action":
        action_id = _required_text(command, "id")
        params = command.get("params", {})
        if not isinstance(params, dict):
            raise ValueError("params must be an object")
        await engine.run_action(action_id, params)
    elif kind == "send":
        cid = _required_text(command, "characteristic")
        payload = {key: command[key] for key in ("text", "hex", "bytes") if key in command}
        if len(payload) != 1:
            raise ValueError("send requires exactly one of text, hex or bytes")
        await engine.send_manual(cid, payload)
    elif kind == "set":
        if "values" not in command or not isinstance(command["values"], dict):
            raise ValueError("values must be an object")
        await engine.set_state(command["values"], literal=True)
    elif kind == "state":
        engine.emit("state", values=copy.deepcopy(engine.state))
    elif kind == "drop":
        await engine.drop()
    elif kind == "stop":
        engine.shutdown.set()
        return False
    else:
        raise ValueError(f"Unknown command: {kind}")
    return True


async def _read_commands(engine):
    reader = asyncio.StreamReader(limit=MAX_DEFINITION_BYTES)
    protocol = asyncio.StreamReaderProtocol(reader)
    pipe = None
    try:
        pipe, _ = await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin)
        while not engine.shutdown.is_set():
            token = None
            try:
                raw = await reader.readline()
                if not raw:
                    return
                command = json.loads(raw.decode("utf-8"), parse_constant=_reject_constant, parse_float=_finite_float)
                if isinstance(command, dict):
                    token = _command_context.set(("id" in command, command.get("id"), command.get("cmd")))
                if not await dispatch_command(engine, command):
                    return
            except (ValueError, TypeError, UnicodeError, RecursionError) as exc:
                engine.error(exc)
            except OSError:
                raise
            except Exception as exc:
                engine.error(f"Command failed: {exc}")
            finally:
                if token is not None:
                    _command_context.reset(token)
    finally:
        if pipe is not None:
            pipe.close()


def _signals(loop, callback):
    previous = {}
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            saved = signal.getsignal(sig)
            using_loop = True
            try:
                loop.add_signal_handler(sig, callback)
            except NotImplementedError:
                using_loop = False
                signal.signal(sig, lambda signum, frame: loop.call_soon_threadsafe(callback))
            previous[sig] = (saved, using_loop)
        except (ValueError, RuntimeError):
            continue
    return previous


async def run_ipc(definition, transport_spec=None, name_override=None):
    """Run until stop, EOF, a termination signal, or fatal transport failure."""
    os.environ.setdefault("GRPC_VERBOSITY", "ERROR")
    real_stdout = sys.stdout
    writer = EventWriter(real_stdout)
    sys.stdout = sys.stderr
    root = logging.getLogger()
    saved_handlers, saved_level = root.handlers[:], root.level
    handler = EventLogHandler(writer)
    root.handlers = [handler]
    root.setLevel(logging.WARNING)
    engine = None
    pending = []
    previous_signals = {}
    failed = False
    loop = asyncio.get_running_loop()
    try:
        await writer.start()
        # These imports may load Bumble or grpc: keep them inside isolation.
        from .engine import Engine
        if name_override is not None:
            if not isinstance(name_override, str) or not name_override.strip():
                raise ValueError("Advertised name cannot be empty")
            definition = replace(definition, name=name_override)
        engine = Engine(definition, transport_spec, writer)
        writer.on_disconnect = lambda: loop.call_soon_threadsafe(engine.shutdown.set)
        previous_signals = _signals(loop, engine.shutdown.set)
        shutdown = asyncio.create_task(engine.shutdown.wait())
        startup = asyncio.create_task(engine.start())
        pending = [startup, shutdown]
        done, _ = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
        if shutdown in done and not startup.done() and engine.failed:
            # A failed start already began engine cleanup; do not cancel it.
            await startup
        if startup in done and startup.result() and not engine.shutdown.is_set():
            reader = asyncio.create_task(_read_commands(engine))
            pending.append(reader)
            done, _ = await asyncio.wait((reader, shutdown), return_when=asyncio.FIRST_COMPLETED)
            if reader in done:
                try:
                    reader.result()
                except Exception as exc:
                    writer(_event("error", message=f"Cannot read commands: {exc}", fatal=False))
    except asyncio.CancelledError:
        pass
    except Exception as exc:
        failed = True
        writer(_event("error", message=str(exc), fatal=True))
    finally:
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        try:
            if engine:
                await engine.stop()
                failed = failed or engine.failed
        except Exception as exc:
            failed = True
            writer(_event("error", message=f"Shutdown failed: {exc}", fatal=True))
        finally:
            if failed and not writer.fatal:
                writer(_event("error", message=writer.last_error or "Engine failed during shutdown", fatal=True))
            await writer.finish()
            for sig, (previous, using_loop) in previous_signals.items():
                if using_loop:
                    loop.remove_signal_handler(sig)
                signal.signal(sig, previous)
            root.handlers = saved_handlers
            root.setLevel(saved_level)
            handler.close()
            sys.stdout = real_stdout
    return 1 if failed or writer.overloaded else 0
