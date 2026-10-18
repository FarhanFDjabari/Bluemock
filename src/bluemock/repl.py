"""Interactive and piped commands; only this presentation layer prints events."""

import asyncio
import copy
import re
import shlex
import signal
import sys
from contextlib import nullcontext

from .schema import RESERVED_ACTION_IDS


def event_printer(engine):
    def output(event):
        kind = event["event"]
        fields = {key: value for key, value in event.items() if key not in ("ts", "event")}
        if kind == "ready":
            detail = f"{engine.definition.name} ({event['transport']})"
        elif kind in ("rx", "tx"):
            cid = event["characteristic"]
            char = engine.characteristics[cid]
            text = repr(event["text"]) + " " if char.encoding != "hex" and "text" in event else ""
            detail = f"{cid}: {text}[{event['hex']}]"
        else:
            detail = " ".join(f"{key}={value!r}" for key, value in fields.items())
        print(f"{event['ts'][11:19]} {kind}: {detail}", flush=True)
    return output


def _assignments(text):
    """Keep Python quotes and spaces; a new unquoted key= begins the next value."""
    chunks, start, quote, escaped, depth = [], 0, None, False, 0
    for index, char in enumerate(text):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char.isspace() and depth == 0 and re.match(r"\s+[A-Za-z_]\w*=", text[index:]):
            chunks.append(text[start:index].strip())
            start = index + 1
    chunks.append(text[start:].strip())
    values = {}
    for chunk in chunks:
        if not chunk:
            continue
        key, separator, value = chunk.partition("=")
        if not separator or not key.strip() or not value.strip():
            raise ValueError("Use set name=expression [name=expression ...]")
        if key.strip() in values:
            raise ValueError(f"Duplicate state variable: {key.strip()}")
        values[key.strip()] = value.strip()
    if not values:
        raise ValueError("Use set name=expression [name=expression ...]")
    return values


def _help(engine):
    print("Commands: <action> [params], send <characteristic> text:...|hex:..., set name=expr, state, drop, help, quit")
    for action in engine.definition.actions:
        params = " ".join(f"{p.name}:{p.type}" + (f"={p.default!r}" if p.default is not None else " (required)")
                          for p in action.params)
        print(f"  {action.id} {params} — {action.label}")
    for cid, char in engine.characteristics.items():
        print(f"  characteristic {cid}: {', '.join(char.properties)}")


async def dispatch_line(engine, line):
    """Return False only for quit/exit; invalid commands emit nonfatal errors."""
    try:
        line = line.lstrip()
        if not line.strip():
            return True
        pieces = line.split(None, 1)
        command, remainder = pieces[0], pieces[1] if len(pieces) > 1 else ""
        if command in ("quit", "exit"):
            return False
        if command == "help":
            _help(engine)
        elif command == "state":
            engine.emit("state", values=copy.deepcopy(engine.state))
        elif command == "drop":
            await engine.drop()
        elif command == "set":
            await engine.set_state(_assignments(remainder))
        elif command == "send":
            pieces = remainder.split(None, 1)
            if len(pieces) != 2:
                raise ValueError("Use send <characteristic> text:<template> or hex:<template>")
            cid, payload = pieces
            kind, separator, value = payload.partition(":")
            if not separator or kind not in ("text", "hex"):
                raise ValueError("Payload must start with text: or hex:")
            await engine.send_manual(cid, {kind: value})
        elif command not in RESERVED_ACTION_IDS and command in engine.actions:
            action = engine.actions[command]
            params, position = {}, 0
            for token in shlex.split(remainder):
                key, separator, value = token.partition("=")
                if not separator:
                    while position < len(action.params) and action.params[position].name in params:
                        position += 1
                    if position >= len(action.params):
                        raise ValueError(f"Too many parameters for {command}")
                    key, value = action.params[position].name, token
                    position += 1
                if key in params:
                    raise ValueError(f"Duplicate parameter: {key}")
                params[key] = value
            await engine.run_action(command, params)
        else:
            raise ValueError(f"Unknown command: {command}; type help")
    except Exception as exc:
        engine.error(exc)
    return True


async def _plain_reader():
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin)
    return reader, transport


async def run_repl(engine):
    """Race input against shutdown so transport loss and SIGTERM cannot hang stdin."""
    tty = sys.stdin.isatty()
    reader = pipe = session = None
    if tty:
        from prompt_toolkit import PromptSession
        from prompt_toolkit.patch_stdout import patch_stdout
        session = PromptSession()
        context = patch_stdout()
    else:
        context = nullcontext()
    loop = asyncio.get_running_loop()
    handlers = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, engine.shutdown.set)
            handlers.append(sig)
        except (NotImplementedError, RuntimeError):
            pass
    shutdown = asyncio.create_task(engine.shutdown.wait())
    pending_input = None
    try:
        with context:
            if not tty:
                reader, pipe = await _plain_reader()
            while not engine.shutdown.is_set():
                try:
                    pending_input = asyncio.create_task(session.prompt_async("bluemock> ") if tty else reader.readline())
                    done, _ = await asyncio.wait((pending_input, shutdown), return_when=asyncio.FIRST_COMPLETED)
                    if shutdown in done:
                        break
                    line = pending_input.result()
                    if not tty:
                        if not line:
                            break
                        line = line.decode("utf-8", errors="surrogateescape").rstrip("\r\n")
                    if not await dispatch_line(engine, line):
                        break
                except (EOFError, KeyboardInterrupt):
                    break
    except (OSError, ValueError, RuntimeError) as exc:
        engine.error(f"Cannot read commands: {exc}")
    finally:
        tasks = [task for task in (pending_input, shutdown) if task is not None]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for sig in handlers:
            loop.remove_signal_handler(sig)
        if pipe:
            pipe.close()


async def run(definition, transport_spec=None):
    from .engine import Engine
    engine = Engine(definition, transport_spec)
    engine.on_event = event_printer(engine)
    try:
        if await engine.start():
            await run_repl(engine)
    finally:
        await engine.stop()
    return 1 if engine.failed else 0
