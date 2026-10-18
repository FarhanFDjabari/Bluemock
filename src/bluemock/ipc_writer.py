"""Bounded JSON event delivery over a nonblocking asyncio stdout pipe."""

import asyncio
from collections import deque
import contextvars
from datetime import datetime, timezone
import json
import os
import stat
import sys
import threading

from .limits import (IPC_SHUTDOWN_DRAIN_S, IPC_WRITE_CHUNK_BYTES,
                     MAX_IPC_QUEUE_BYTES, MAX_IPC_QUEUE_EVENTS)

_command_context = contextvars.ContextVar("bluemock_ipc_command", default=None)
_DROPPABLE = frozenset(("rx", "tx", "log"))


def _event(kind, **fields):
    return {"ts": datetime.now(timezone.utc).isoformat(), "event": kind, **fields}


def _encode(event):
    return (json.dumps(event, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            + "\n").encode("utf-8", errors="backslashreplace")


class _PipeProtocol(asyncio.Protocol):
    def __init__(self, disconnected):
        self.writable = asyncio.Event()
        self.writable.set()
        self.closed = asyncio.get_running_loop().create_future()
        self.disconnected = disconnected

    def pause_writing(self):
        self.writable.clear()

    def resume_writing(self):
        self.writable.set()

    def connection_lost(self, exc):
        self.disconnected()
        self.writable.set()
        if not self.closed.done():
            self.closed.set_result(None)


class EventWriter:
    def __init__(self, stream):
        self.stream = stream
        self.stopped = self.broken = self.overloaded = False
        self.fatal = False
        self.last_error = self.final_event = self.on_disconnect = None
        self._loop = asyncio.get_running_loop()
        self._queue = deque()
        self._bytes = self._events = self._dropped = 0
        self._wake = asyncio.Event()
        self._lock = threading.RLock()
        self._notification_pending = self._finishing = False
        self._transport = self._protocol = self._pump_task = None
        self._file = None
        self._original_blocking = None

    async def start(self):
        # Own a duplicate, not sys.stdout; aborting it cannot flush Python buffers.
        pipe = os.fdopen(os.dup(self.stream.fileno()), "wb", buffering=0)
        mode = os.fstat(pipe.fileno()).st_mode
        if stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode):
            self._original_blocking = os.get_blocking(self.stream.fileno())
            try:
                self._protocol = _PipeProtocol(self._disconnected)
                self._transport, _ = await self._loop.connect_write_pipe(lambda: self._protocol, pipe)
            except BaseException:
                pipe.close()
                raise
            self._transport.set_write_buffer_limits(high=IPC_WRITE_CHUNK_BYTES, low=0)
        else:
            # File/terminal redirection retains the same bounded queue.
            self._file = pipe
        self._pump_task = asyncio.create_task(self._pump())

    def _disconnected(self):
        if not self.broken:
            self.broken = True
            if self.on_disconnect:
                self.on_disconnect()
        self._wake.set()

    def _notify(self):
        # At most one cross-thread callback may be waiting, even during a flood.
        if not self._notification_pending:
            self._notification_pending = True
            self._loop.call_soon_threadsafe(self._wakeup)

    def _wakeup(self):
        with self._lock:
            self._notification_pending = False
        self._wake.set()

    def _fits(self, data):
        return (self._events < MAX_IPC_QUEUE_EVENTS and
                self._bytes + len(data) <= MAX_IPC_QUEUE_BYTES)

    def _remove(self, entry):
        self._queue.remove(entry)
        self._events -= 1
        self._bytes -= len(entry[1])

    def _append(self, event, data):
        if event["event"] == "overflow" and self._queue and self._queue[-1][0]["event"] == "stopped":
            self._queue.insert(len(self._queue) - 1, (event, data))
        else:
            self._queue.append((event, data))
        self._events += 1
        self._bytes += len(data)
        self._notify()

    def _overload(self):
        # There is no bounded way to retain arbitrary protected output forever.
        already_overloaded = self.overloaded
        self.overloaded = True
        for entry in list(self._queue):
            self._remove(entry)
        if not already_overloaded:
            self._loop.call_soon_threadsafe(self._report_overload)

    def _report_overload(self):
        print("IPC output overloaded: protected events exceeded the bounded queue; shutting down",
              file=sys.stderr, flush=True)
        if self.on_disconnect:
            self.on_disconnect()

    def __call__(self, event):
        with self._lock:
            if self.stopped or self.broken or self._finishing:
                return
            if event["event"] == "stopped":
                self.final_event = dict(event)
                return
            if not self.overloaded:
                self._enqueue(dict(event))

    def _enqueue(self, event):
        context = _command_context.get()
        if context and context[0] and (event["event"] == "error" or
                                      (event["event"] == "state" and context[2] == "state")):
            event["reply_to"] = context[1]
        try:
            data = _encode(event)
        except (ValueError, TypeError, RecursionError) as exc:
            event = _event("error", message=f"Cannot serialize {event.get('event')} event: {exc}", fatal=False)
            if context and context[0]:
                event["reply_to"] = context[1]
            try:
                data = _encode(event)
            except (ValueError, TypeError, RecursionError):
                event.pop("reply_to", None)
                data = _encode(event)
        kind = event["event"]
        if kind == "error":
            self.fatal = self.fatal or event.get("fatal", False)
            self.last_error = event["message"]
        # Coalesce only queued output: a partially written line is immutable.
        if kind == "state":
            for entry in list(self._queue):
                if entry[0]["event"] == "state":
                    self._remove(entry)
        elif kind == "error":
            for entry in list(self._queue):
                old = entry[0]
                if (old["event"] == "error" and old.get("message") == event.get("message")
                        and old.get("fatal") == event.get("fatal")
                        and old.get("reply_to") == event.get("reply_to")):
                    event["count"] = old.get("count", 1) + 1
                    self._remove(entry)
                    data = _encode(event)
                    break
        if not self._fits(data):
            if kind in _DROPPABLE:
                self._dropped += 1
                return
            for entry in list(self._queue):
                if entry[0]["event"] in _DROPPABLE:
                    self._remove(entry)
                    self._dropped += 1
                    if self._fits(data):
                        break
        if not self._fits(data):
            self._overload()
            return
        self._append(event, data)

    def _overflow(self):
        if self._dropped and not self.overloaded and not self.stopped:
            event = _event("overflow", dropped=self._dropped)
            data = _encode(event)
            if self._fits(data):
                self._dropped = 0
                self._append(event, data)

    async def _pump(self):
        while not self.broken:
            with self._lock:
                self._overflow()
                entry = self._queue.popleft() if self._queue else None
                self._wake.clear()
                finished = self._finishing
            if entry is None:
                if finished:
                    return
                await self._wake.wait()
                continue
            event, data = entry
            # Keep this in-flight record charged against both queue budgets.
            try:
                for start in range(0, len(data), IPC_WRITE_CHUNK_BYTES):
                    if self.broken:
                        return
                    chunk = data[start:start + IPC_WRITE_CHUNK_BYTES]
                    if self._transport:
                        self._transport.write(chunk)
                        await self._protocol.writable.wait()
                    else:
                        pending = memoryview(chunk)
                        while pending:
                            count = self._file.write(pending)
                            if not count:
                                raise OSError("IPC output stopped accepting bytes")
                            pending = pending[count:]
                if event["event"] == "stopped":
                    self.stopped = True
            except (BrokenPipeError, OSError, ValueError, RuntimeError):
                self._disconnected()
                return
            finally:
                with self._lock:
                    self._events -= 1
                    self._bytes -= len(data)

    async def finish(self):
        """Bound the entire drain/close operation, then discard buffered output."""
        with self._lock:
            if not self.broken:
                self._overflow()
                event = self.final_event or _event("stopped")
                self._enqueue(event)
                if self.overloaded and not self._queue:
                    data = _encode(event)
                    if self._fits(data):
                        self._append(event, data)
            self._finishing = True
            self._notify()
        closed_cleanly = False
        async def drain():
            nonlocal closed_cleanly
            if self._pump_task:
                await self._pump_task
            if self._transport:
                self._transport.close()
                await self._protocol.closed
                closed_cleanly = True
        try:
            await asyncio.wait_for(drain(), IPC_SHUTDOWN_DRAIN_S)
        except (asyncio.TimeoutError, OSError):
            pass
        finally:
            if self._pump_task:
                self._pump_task.cancel()
                await asyncio.gather(self._pump_task, return_exceptions=True)
            if self._transport and not closed_cleanly:
                self._transport.abort()
            if self._file:
                self._file.close()
            if self._original_blocking is not None:
                try:
                    os.set_blocking(self.stream.fileno(), self._original_blocking)
                except (OSError, ValueError):
                    pass
            with self._lock:
                self._queue.clear()
                self._bytes = self._events = 0
