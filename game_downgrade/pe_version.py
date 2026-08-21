"""Read the FileVersion string (e.g. "1.7.99.0") out of a Windows PE exe's
VERSIONINFO resource. This is the version people actually mean when they
say "1.7.99" or "1.6.1170", unlike Steam's internal buildid, which has no
fixed relationship to it and has to be looked up externally to mean
anything.

No PE library dependency: this walks just enough of the PE/resource format
by hand. Returns None (never raises) if anything looks unexpected, so
callers can fall back to the buildid.
"""
from __future__ import annotations

import struct
from pathlib import Path

_RT_VERSION = 16
_VS_VERSION_KEY = "VS_VERSION_INFO\x00".encode("utf-16-le")
_VS_FIXEDFILEINFO_SIGNATURE = 0xFEEF04BD


def read_file_version(exe_path: Path) -> str | None:
    try:
        return _read_file_version(exe_path.read_bytes())
    except (struct.error, IndexError, UnicodeError):
        return None


def _rva_to_offset(sections: list[tuple[int, int, int]], rva: int) -> int | None:
    for virtual_size, virtual_addr, raw_ptr in sections:
        if virtual_addr <= rva < virtual_addr + virtual_size:
            return rva - virtual_addr + raw_ptr
    return None


def _resource_dir_entries(data: bytes, dir_offset: int) -> list[tuple[int, int]]:
    named, ids = struct.unpack_from("<HH", data, dir_offset + 12)
    return [
        struct.unpack_from("<II", data, dir_offset + 16 + i * 8)
        for i in range(named + ids)
    ]


def _read_file_version(data: bytes) -> str | None:
    if data[:2] != b"MZ":
        return None
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset : pe_offset + 4] != b"PE\0\0":
        return None

    file_header_offset = pe_offset + 4
    num_sections = struct.unpack_from("<H", data, file_header_offset + 2)[0]
    size_of_optional = struct.unpack_from("<H", data, file_header_offset + 16)[0]
    optional_offset = file_header_offset + 20

    magic = struct.unpack_from("<H", data, optional_offset)[0]
    data_dir_offset = optional_offset + (96 if magic == 0x10B else 112)
    resource_rva = struct.unpack_from("<I", data, data_dir_offset + 2 * 8)[0]

    sections = [
        struct.unpack_from("<IIxxxxI", data, optional_offset + size_of_optional + i * 40 + 8)
        for i in range(num_sections)
    ]
    resource_base = _rva_to_offset(sections, resource_rva)
    if resource_base is None:
        return None

    # Resource tree is Type -> Name -> Language; RT_VERSION is a fixed type
    # id, and real exes only ever have one name/language for it, so just
    # walk down: find RT_VERSION at the root, then take the first entry at
    # each level below.
    version_entry = next(
        (offset for type_id, offset in _resource_dir_entries(data, resource_base) if type_id == _RT_VERSION),
        None,
    )
    if version_entry is None or not version_entry & 0x80000000:
        return None
    name_entries = _resource_dir_entries(data, resource_base + (version_entry & 0x7FFFFFFF))
    if not name_entries or not name_entries[0][1] & 0x80000000:
        return None
    lang_entries = _resource_dir_entries(data, resource_base + (name_entries[0][1] & 0x7FFFFFFF))
    if not lang_entries or lang_entries[0][1] & 0x80000000:
        return None

    data_rva, _size = struct.unpack_from("<II", data, resource_base + lang_entries[0][1])
    version_info = _rva_to_offset(sections, data_rva)
    if version_info is None:
        return None

    # VS_VERSIONINFO: wLength, wValueLength, wType, then the null-terminated
    # UTF-16LE key, then padding to a 4-byte boundary, then VS_FIXEDFILEINFO.
    key_start = version_info + 6
    if data[key_start : key_start + len(_VS_VERSION_KEY)] != _VS_VERSION_KEY:
        return None
    fixed_offset = (key_start + len(_VS_VERSION_KEY) + 3) & ~3

    signature = struct.unpack_from("<I", data, fixed_offset)[0]
    if signature != _VS_FIXEDFILEINFO_SIGNATURE:
        return None
    ms, ls = struct.unpack_from("<II", data, fixed_offset + 8)
    return ".".join(str(part) for part in (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF))
