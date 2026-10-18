"""Exercise a definition through a real Bumble central on an in-process radio."""

import asyncio

from bumble import att
from bumble.core import AdvertisingData, UUID
from bumble.device import Peer
from bumble.gatt import GATT_PRIMARY_SERVICE_ATTRIBUTE_TYPE, GATT_SECONDARY_SERVICE_ATTRIBUTE_TYPE
from bumble.gatt_client import ServiceProxy
from bumble.hci import Address

from .engine import Engine
from .local_radio import close_local_device, create_local_device
from .template import render_payload


def _drain(queue):
    while not queue.empty():
        queue.get_nowait()


async def _secondary_services(peer):
    """Bumble discover_all covers primary services; query secondary groups too."""
    services, start = [], 1
    while start <= 0xFFFF:
        response = await asyncio.wait_for(peer.gatt_client.send_request(att.ATT_Read_By_Group_Type_Request(
            starting_handle=start, ending_handle=0xFFFF,
            attribute_group_type=GATT_SECONDARY_SERVICE_ATTRIBUTE_TYPE)), 3)
        if isinstance(response, att.ATT_Error_Response):
            if response.error_code == att.ATT_ATTRIBUTE_NOT_FOUND_ERROR:
                break
            raise ValueError(f"Secondary service discovery failed: {response}")
        if not response or not response.attributes:
            raise ValueError("Empty secondary service discovery response")
        for handle, end, value in response.attributes:
            if handle < start or end < handle:
                raise ValueError("Invalid secondary service handle range")
            service = ServiceProxy(peer.gatt_client, handle, end, UUID.from_bytes(value), primary=False)
            await asyncio.wait_for(service.discover_characteristics(), 3)
            services.append(service)
        start = response.attributes[-1][1] + 1
    return services


class LocalSelftest:
    def __init__(self, definition):
        self.definition = definition
        self.checks = []
        self.events = []
        self.engine = Engine(definition, "local", self.events.append)
        self.central = self.controller = self.connection = None
        self.proxies = {}
        self.queues = {cid: asyncio.Queue() for cid in self.engine.characteristics}
        self.all_notifications = asyncio.Queue()

    def record(self, name, ok, detail):
        self.checks.append({"name": name, "ok": ok, "detail": detail})

    async def setup(self):
        if not await self.engine.start():
            raise ValueError(next((e["message"] for e in self.events if e["event"] == "error"), "Peripheral startup failed"))
        self.central, self.controller = create_local_device(
            "bluemock-selftest-central", Address("F1:F2:F3:F4:F5:F6"), self.engine.link)
        await self.central.power_on()
        found = asyncio.get_running_loop().create_future()
        def advertisement(report):
            name = report.data.get(AdvertisingData.COMPLETE_LOCAL_NAME)
            short = report.data.get(AdvertisingData.SHORTENED_LOCAL_NAME)
            # LocalLink does not emulate scan-response exchanges. A shortened name
            # is identified by its prefix plus the known radio address in that case.
            matches = name == self.definition.name or (
                short is not None and self.definition.name.startswith(short) and report.address == self.engine.address)
            if matches and not found.done():
                found.set_result((report.address, name or short))
        self.central.on("advertisement", advertisement)
        try:
            await self.central.start_scanning(active=True)
            address, observed_name = await asyncio.wait_for(found, 3)
        finally:
            if self.central.scanning:
                await self.central.stop_scanning()
            self.central.remove_listener("advertisement", advertisement)
        self.record("scan", True, f"Found {observed_name} at {address}")
        self.connection = await asyncio.wait_for(self.central.connect(address), 5)
        peer = Peer(self.connection)
        await asyncio.wait_for(peer.request_mtu(517), 3)
        await asyncio.wait_for(peer.discover_all(), 5)
        remaining_services = list(peer.services)
        if any(not service.primary for service in self.definition.services):
            remaining_services += await _secondary_services(peer)
        for service in self.definition.services:
            expected_type = GATT_PRIMARY_SERVICE_ATTRIBUTE_TYPE if service.primary else GATT_SECONDARY_SERVICE_ATTRIBUTE_TYPE
            remote = next((s for s in remaining_services if s.uuid == UUID(service.uuid) and s.type == expected_type), None)
            self.record(f"service {service.uuid}", remote is not None, "Discovered" if remote else "Missing service")
            if remote is None:
                continue
            remaining_services.remove(remote)
            remaining_chars = list(remote.characteristics)
            for char in service.characteristics:
                proxy = next((c for c in remaining_chars if c.uuid == UUID(char.uuid)), None)
                self.record(f"characteristic {char.id}", proxy is not None, "Discovered" if proxy else f"Missing {char.uuid}")
                if proxy is None:
                    continue
                remaining_chars.remove(proxy)
                self.proxies[char.id] = proxy
                if {"notify", "indicate"}.intersection(char.properties):
                    def notification(value, cid=char.id):
                        self.queues[cid].put_nowait(bytes(value))
                        self.all_notifications.put_nowait((cid, bytes(value)))
                    await asyncio.wait_for(proxy.subscribe(notification, prefer_notify="notify" in char.properties), 3)

    async def fresh_state(self):
        await self.engine.reset_state()
        for queue in [self.all_notifications, *self.queues.values()]:
            _drain(queue)
        self.events.clear()

    async def next_notification(self, cid, timeout=2):
        try:
            return await asyncio.wait_for(self.queues[cid].get(), timeout)
        except asyncio.TimeoutError as exc:
            errors = "; ".join(e["message"] for e in self.events if e["event"] == "error")
            raise ValueError(f"No notification on {cid} within {timeout}s" + (f": {errors}" if errors else "")) from exc

    async def execute_test(self, test):
        await self.fresh_state()
        if test.write is not None:
            cid = test.write["characteristic"]
            value = render_payload(test.write, self.engine.state)
            char = self.engine.characteristics[cid]
            await asyncio.wait_for(self.proxies[cid].write_value(value, with_response="write" in char.properties), 3)
        elif not await self.engine.run_action(test.action, test.params):
            raise ValueError("Action failed: " + "; ".join(e["message"] for e in self.events if e["event"] == "error"))
        if test.expect == "none":
            try:
                cid, actual = await asyncio.wait_for(self.all_notifications.get(), 0.5)
            except asyncio.TimeoutError:
                errors = [e["message"] for e in self.events if e["event"] == "error"]
                if errors:
                    raise ValueError("; ".join(errors))
                return "No notification during 500ms"
            raise ValueError(f"Unexpected notification on {cid}: {actual.hex(' ').upper()}")
        cid = test.expect["characteristic"]
        actual = await self.next_notification(cid)
        expected = render_payload(test.expect, self.engine.state)
        if actual != expected:
            raise ValueError(f"{cid}: expected [{expected.hex(' ').upper()}], received [{actual.hex(' ').upper()}]")
        return f"{cid}: [{actual.hex(' ').upper()}]"

    async def run_tests(self):
        for index, test in enumerate(self.definition.tests):
            name = test.name or f"test {index + 1}"
            try:
                detail = await self.execute_test(test)
                self.record(name, True, detail)
            except Exception as exc:
                self.record(name, False, str(exc))
        for action in self.definition.actions:
            if any(param.default is None for param in action.params):
                continue
            name = f"action {action.id} defaults"
            try:
                await self.fresh_state()
                if not await self.engine.run_action(action.id):
                    raise ValueError("; ".join(e["message"] for e in self.events if e["event"] == "error"))
                if action.send:
                    cid = action.send.characteristic
                    if not any(e["event"] == "tx" and e["characteristic"] == cid and
                               e.get("ref") == action.id for e in self.events):
                        raise ValueError(f"No tx event for {cid}")
                    await self.next_notification(cid)
                self.record(name, True, "Action completed" + (" and notification received" if action.send else ""))
            except Exception as exc:
                self.record(name, False, str(exc))

    async def close(self):
        try:
            await self.engine.stop()
            if self.engine.failed:
                raise ValueError("; ".join(e["message"] for e in self.events if e["event"] == "error") or "Peripheral cleanup failed")
        finally:
            if self.central:
                await close_local_device(self.central, self.controller)

    async def run(self):
        try:
            await self.setup()
            await self.run_tests()
        except Exception as exc:
            self.record("local link setup", False, str(exc))
        finally:
            try:
                await self.close()
            except Exception as exc:
                self.record("cleanup", False, str(exc))
        return {"ok": bool(self.checks) and all(check["ok"] for check in self.checks), "checks": self.checks}


async def selftest(definition):
    return await LocalSelftest(definition).run()
