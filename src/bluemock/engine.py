"""One BLE peripheral, with an event-only interface for REPL and future IPC."""

import os

os.environ.setdefault("GRPC_VERBOSITY", "ERROR")

import asyncio
import copy
import math
import regex
from datetime import datetime, timezone

from bumble.device import Device
from bumble.gatt import Characteristic, CharacteristicValue, Service
from bumble.hci import OwnAddressType
from bumble.link import LocalLink
from bumble.transport import open_transport

from . import __version__
from .advertising import advertising_data, device_address
from .expr import compile_expression
from .limits import MAX_MATCH_INPUT, REGEX_TIMEOUT_S, check_state
from .local_radio import close_local_device, create_local_device
from .params import check_params
from .schema import to_dict
from .template import parse_payload


class Engine:
    def __init__(self, definition, transport_spec=None, on_event=None):
        self.definition = definition
        self._uses_default_transport = not transport_spec
        self.transport_spec = transport_spec or f"android-netsim:name={definition.name}"
        self.on_event = on_event or (lambda event: None)
        self.state = copy.deepcopy(definition.state)
        check_state(self.state)
        self.characteristics = {c.id: c for s in definition.services for c in s.characteristics}
        self.actions = {a.id: a for a in definition.actions}
        self.address = device_address(definition)
        self.device = self.transport = self.controller = self.link = None
        self.gatt = {}
        self.connections = set()
        self.shutdown = asyncio.Event()
        self.failed = self._stopping = self._stopped = False
        self._lock = asyncio.Lock()
        self._monitor = None
        self._restart_tasks = set()
        self._payloads = {}
        self._sets = {}
        self._rules = []
        for index, rule in enumerate(definition.rules):
            self._rules.append((index, rule, regex.compile(rule.regex, regex.VERSION0) if rule.regex is not None else None))
            self._compile_set(rule)
            if rule.reply:
                self._payloads[id(rule.reply)] = parse_payload(rule.reply)
        for action in definition.actions:
            self._compile_set(action)
            if action.send:
                self._payloads[id(action.send)] = parse_payload(action.send)
        for char in self.characteristics.values():
            if char.initial:
                self._payloads[id(char.initial)] = parse_payload(char.initial)

    def _compile_set(self, owner):
        self._sets[id(owner)] = {key: compile_expression(value) for key, value in owner.set.items()}

    def emit(self, event, **fields):
        self.on_event({"ts": datetime.now(timezone.utc).isoformat(), "event": event, **fields})

    def error(self, error, fatal=False):
        self.emit("error", message=str(error), fatal=fatal)

    def _transport_message(self, error):
        hint = " Is an Android emulator (API 33+) running with Bluetooth on? Try: bluemock doctor" if self.transport_spec.startswith("android-netsim") else ""
        return str(error) + hint

    def _wire_event(self, event, cid, value, **fields):
        fields.update(characteristic=cid, hex=value.hex(" ").upper())
        try:
            fields["text"] = value.decode("utf-8")
        except UnicodeDecodeError:
            pass
        self.emit(event, **fields)

    def _render(self, payload, scope):
        return self._payloads[id(payload)].render(scope)

    def _read(self, cid):
        try:
            payload = self.characteristics[cid].initial
            return self._render(payload, self.state) if payload else b""
        except Exception as exc:
            self.error(exc)
            return b""

    def _build_gatt(self):
        for service in self.definition.services:
            characteristics = []
            for char in service.characteristics:
                properties = Characteristic.Properties(0)
                permissions = 0
                for name in char.properties:
                    properties |= getattr(Characteristic.Properties, name.upper())
                if "read" in char.properties:
                    permissions |= Characteristic.READABLE
                if {"write", "write_without_response"}.intersection(char.properties):
                    permissions |= Characteristic.WRITEABLE
                async def write(connection, value, cid=char.id):
                    await self.handle_write(cid, value)
                value = CharacteristicValue(read=lambda connection, cid=char.id: self._read(cid), write=write)
                attribute = Characteristic(char.uuid, properties, permissions, value)
                self.gatt[char.id] = attribute
                characteristics.append(attribute)
            self.device.add_service(Service(service.uuid, characteristics, primary=service.primary))
        self.device.on("connection", self._connected)
        self.device.on("characteristic_subscription", self._subscribed)

    def _connected(self, connection):
        self.connections.add(connection)
        self.emit("connected", peer=str(connection.peer_address))
        def disconnected(reason):
            self.connections.discard(connection)
            self.emit("disconnected", peer=str(connection.peer_address), reason=reason)
            if not self._stopping:
                task = asyncio.create_task(self._restart_advertising())
                self._restart_tasks.add(task)
                task.add_done_callback(self._restart_tasks.discard)
        connection.on("disconnection", disconnected)

    def _subscribed(self, connection, characteristic, notify, indicate):
        cid = next((key for key, value in self.gatt.items() if value is characteristic), None)
        if cid is not None:
            self.emit("subscribed", characteristic=cid, notify=bool(notify), indicate=bool(indicate))

    async def start(self):
        try:
            if self._uses_default_transport and any(c in self.definition.name for c in ",=:"):
                raise ValueError("The default netsim name cannot contain ',', '=' or ':'; supply --transport explicitly")
            self._advertisement, self._scan_response = advertising_data(self.definition)
            if self.transport_spec == "local":
                self.link = LocalLink()
                self.device, self.controller = create_local_device(self.definition.name, self.address, self.link)
            else:
                self.transport = await open_transport(self.transport_spec)
                self.device = Device.with_hci(self.definition.name, self.address,
                                              self.transport.source, self.transport.sink)
            self._build_gatt()
            await self.device.power_on()
            self.emit("ready", v=1, version=__version__, device=to_dict(self.definition), transport=self.transport_spec)
            await self._advertise()
            if self.transport:
                self._monitor = asyncio.create_task(self._watch_transport())
            return True
        except Exception as exc:
            self.failed = True
            self.error(self._transport_message(exc), fatal=True)
            await self.stop()
            return False

    async def _advertise(self):
        # Own restart tasks so stop can cancel them before disconnecting peers.
        await self.device.start_advertising(
            own_address_type=OwnAddressType.RANDOM, auto_restart=False,
            advertising_data=self._advertisement, scan_response_data=self._scan_response,
            advertising_interval_min=self.definition.advertising.interval_ms,
            advertising_interval_max=self.definition.advertising.interval_ms)
        self.emit("advertising", address=str(self.address))

    async def _restart_advertising(self):
        try:
            await self._advertise()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.failed = True
            self.error(self._transport_message(f"Cannot restart advertising: {exc}"), fatal=True)
            self.shutdown.set()

    async def _watch_transport(self):
        try:
            await asyncio.shield(self.transport.source.terminated)
            if not self._stopping:
                self.failed = True
                self.error(self._transport_message("Bluetooth transport disconnected."), fatal=True)
                self.shutdown.set()
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            self.failed = True
            self.error(self._transport_message(exc), fatal=True)
            self.shutdown.set()

    def _apply_set(self, owner, scope):
        updates = {key: expression.evaluate(scope) for key, expression in self._sets[id(owner)].items()}
        if updates:
            self._commit_state(updates)

    def _commit_state(self, updates):
        candidate = {**self.state, **updates}
        check_state(candidate)
        self.state = candidate
        self.emit("state", values=copy.deepcopy(self.state))

    async def _send(self, cid, value, source, ref=None):
        char = self.characteristics.get(cid)
        if char is None:
            raise ValueError(f"Unknown characteristic: {cid}")
        if not {"notify", "indicate"}.intersection(char.properties):
            raise ValueError(f"Characteristic {cid} requires notify or indicate")
        if "notify" in char.properties:
            await self.device.notify_subscribers(self.gatt[cid], value)
        if "indicate" in char.properties:
            await self.device.indicate_subscribers(self.gatt[cid], value)
        self._wire_event("tx", cid, value, source=source, **({"ref": ref} if ref is not None else {}))

    async def handle_write(self, cid, value):
        try:
            async with self._lock:
                self._wire_event("rx", cid, value)
                text = value.decode("utf-8", errors="surrogateescape")
                for index, rule, regex in self._rules:
                    if rule.on_write != cid:
                        continue
                    matched_text = text.strip() if rule.trim else text
                    try:
                        match = regex.search(matched_text[:MAX_MATCH_INPUT], timeout=REGEX_TIMEOUT_S) if regex else None
                    except TimeoutError:
                        self.error(f"Rule {index} regex timed out after {REGEX_TIMEOUT_S:g}s")
                        continue
                    if not (rule.any or (rule.equals is not None and rule.equals == matched_text) or match):
                        continue
                    extras = {"value": value, "text": text, **(match.groupdict() if match else {})}
                    self._apply_set(rule, {**self.state, **extras})
                    if rule.reply:
                        await self._send(rule.reply.characteristic,
                                         self._render(rule.reply, {**self.state, **extras}), "rule", index)
                    break
            return True
        except Exception as exc:
            self.error(exc)
            return False

    async def run_action(self, action_id, params=None):
        try:
            async with self._lock:
                action = self.actions.get(action_id)
                if action is None:
                    raise ValueError(f"Unknown action: {action_id}")
                values, errors = check_params(action.params, {} if params is None else params)
                if errors:
                    raise ValueError("; ".join(f"{key}: {message}" for key, message in errors))
                self._apply_set(action, {**self.state, **values})
                if action.send:
                    await self._send(action.send.characteristic,
                                     self._render(action.send, {**self.state, **values}), "action", action_id)
            return True
        except Exception as exc:
            self.error(exc)
            return False

    async def send_manual(self, characteristic_id, payload_dict):
        try:
            async with self._lock:
                value = parse_payload(payload_dict).render(self.state)
                await self._send(characteristic_id, value, "manual")
            return True
        except Exception as exc:
            self.error(exc)
            return False

    async def set_state(self, values, *, literal=False):
        try:
            async with self._lock:
                if not isinstance(values, dict):
                    raise ValueError("State values must be an object")
                for key in values:
                    if key not in self.definition.state:
                        raise ValueError(f"Unknown state variable: {key}")
                if literal:
                    for key, value in values.items():
                        if type(value) not in (str, int, float, bool) or (
                                type(value) is float and not math.isfinite(value)):
                            raise ValueError(f"{key}: state literals must be finite numbers, strings or booleans")
                    updates = copy.deepcopy(values)
                else:
                    updates = {key: compile_expression(value).evaluate(self.state) for key, value in values.items()}
                self._commit_state(updates)
            return True
        except Exception as exc:
            self.error(exc)
            return False

    async def reset_state(self):
        async with self._lock:
            check_state(self.definition.state)
            self.state = copy.deepcopy(self.definition.state)
            self.emit("state", values=copy.deepcopy(self.state))

    async def drop(self):
        results = await asyncio.gather(*(asyncio.wait_for(c.disconnect(), 3) for c in list(self.connections)), return_exceptions=True)
        for result in results:
            if isinstance(result, Exception):
                self.error(f"Disconnect failed: {result}")
        return not any(isinstance(result, Exception) for result in results)

    async def _cleanup(self, operation, label):
        try:
            result = await asyncio.wait_for(operation, 5)
            if result is False:
                self.failed = True
        except Exception as exc:
            self.failed = True
            self.error(f"{label}: {exc}")

    async def stop(self):
        if self._stopping or self._stopped:
            return
        self._stopping = True
        self.shutdown.set()
        for task in self._restart_tasks:
            task.cancel()
        await asyncio.gather(*self._restart_tasks, return_exceptions=True)
        if self._monitor:
            self._monitor.cancel()
            await asyncio.gather(self._monitor, return_exceptions=True)
        try:
            if self.device:
                await self._cleanup(self.device.stop_advertising(), "Stop advertising failed")
                await self._cleanup(self.drop(), "Disconnect failed")
                if self.controller:
                    await self._cleanup(close_local_device(self.device, self.controller), "Local radio cleanup failed")
                else:
                    await self._cleanup(self.device.power_off(), "Bluetooth power off failed")
        except Exception as exc:
            self.failed = True
            self.error(f"Bluetooth cleanup failed: {exc}")
        finally:
            if self.transport:
                try:
                    await self.transport.close()
                except Exception as exc:
                    self.failed = True
                    self.error(f"Transport cleanup failed: {exc}")
            self._stopped = True
            self.emit("stopped")
