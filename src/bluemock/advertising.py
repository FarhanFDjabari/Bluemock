"""Legacy BLE advertisement packing, with explicit 31-byte capacity checks."""

import hashlib

from bumble.core import AdvertisingData, UUID
from bumble.hci import Address


def device_address(definition):
    if definition.address:
        return Address(definition.address, Address.RANDOM_DEVICE_ADDRESS)
    octets = bytearray(hashlib.sha256(definition.name.encode("utf-8")).digest()[:6])
    octets[0] |= 0xC0
    if octets in (bytearray.fromhex("C00000000000"), bytearray.fromhex("FFFFFFFFFFFF")):
        octets[-1] ^= 1
    return Address(":".join(f"{byte:02X}" for byte in octets), Address.RANDOM_DEVICE_ADDRESS)


def _size(entries):
    return sum(len(value) + 2 for _, value in entries)


def advertising_data(definition):
    """Keep every field or fail clearly when two legacy packets cannot hold it."""
    ad = AdvertisingData
    name = definition.name.encode("utf-8")
    flags = [(ad.FLAGS, b"\x06")]
    complete_name = (ad.COMPLETE_LOCAL_NAME, name)
    extras = []
    grouped = {2: [], 4: [], 16: []}
    types = {2: ad.COMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS,
             4: ad.COMPLETE_LIST_OF_32_BIT_SERVICE_CLASS_UUIDS,
             16: ad.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS}
    for value in definition.advertising.service_uuids:
        raw = bytes(UUID(value))
        grouped[len(raw)].append(raw)
    for size, values in grouped.items():
        if values:
            extras.append((types[size], b"".join(values)))
    manufacturer = definition.advertising.manufacturer_data
    if manufacturer:
        extras.append((ad.MANUFACTURER_SPECIFIC_DATA,
                       manufacturer.company_id.to_bytes(2, "little") + bytes.fromhex("".join(manufacturer.hex.split()))))
    advertisement, response = flags + [complete_name], []
    if _size(advertisement + extras) <= 31:
        advertisement += extras
    else:
        response = extras
    if _size(advertisement) > 31:
        short = name[:26].decode("utf-8", errors="ignore").encode("utf-8")
        advertisement = flags + [(ad.SHORTENED_LOCAL_NAME, short)]
        response = [complete_name] + extras
    # Fill spare advertisement room when a complete name in scan response uses it.
    while _size(response) > 31:
        movable = next((entry for entry in response if entry != complete_name and
                        _size(advertisement + [entry]) <= 31), None)
        if movable is None and advertisement[1][0] == ad.SHORTENED_LOCAL_NAME:
            fixed = [entry for index, entry in enumerate(advertisement) if index != 1]
            movable = next((entry for entry in response if entry != complete_name and
                            _size(fixed + [(ad.SHORTENED_LOCAL_NAME, b"")] + [entry]) <= 31), None)
            if movable:
                budget = 31 - _size(fixed + [(ad.SHORTENED_LOCAL_NAME, b"")] + [movable])
                short = name[:budget].decode("utf-8", errors="ignore").encode("utf-8")
                advertisement[1] = (ad.SHORTENED_LOCAL_NAME, short)
        if movable is None:
            raise ValueError("Name, service UUIDs and manufacturer data do not fit in two 31-byte BLE packets; shorten the name or reduce advertising fields")
        advertisement.append(movable)
        response.remove(movable)
    return bytes(ad(advertisement)), bytes(ad(response))
