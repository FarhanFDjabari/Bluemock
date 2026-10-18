"""LocalLink wiring follows Bumble's installed testing/test_utils.py."""

from bumble.controller import Controller
from bumble.device import Device
from bumble.hci import Address
from bumble.host import Host
from bumble.transport.common import AsyncPipeSink


def create_local_device(name, address, link):
    controller = Controller(name, link=link,
                            public_address=Address(str(address).split("/")[0], Address.PUBLIC_DEVICE_ADDRESS))
    device = Device(name=name, address=address,
                    host=Host(controller, AsyncPipeSink(controller)))
    return device, controller


async def close_local_device(device, controller):
    try:
        try:
            if device.scanning:
                await device.stop_scanning()
        finally:
            try:
                await device.stop_advertising()
            finally:
                await device.power_off()
    finally:
        if controller in controller.link.controllers:
            controller.link.remove_controller(controller)
        if not controller.terminated.done():
            controller.terminated.set_result(None)
