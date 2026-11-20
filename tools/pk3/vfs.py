"""DarkPlaces virtual filesystem resolution over a set of .pk3 files.

Mirrors fs.c @xonotic-v0.8.6:
  * FS_AddGameDirectory lists the game dir, sorts names with strcasecmp (stringlistsort),
    then FS_AddPack_Fullpath prepends each pk3 to fs_searchpaths -> the pk3 that sorts
    LAST is searched FIRST and wins on duplicate paths.
  * Lookups inside a pk3 are case-sensitive (PK3 central directory, binary search with strcmp).
  * Directory entries are not files.
Only the "data" game dir is modelled (Xonotic has no mod dirs in the release).
"""
from __future__ import annotations

import hashlib
import zipfile
from dataclasses import dataclass, field
from pathlib import Path


def strcasecmp_key(s: str) -> bytes:
    # strcasecmp compares tolower() of each byte (C locale): ASCII-only lowering.
    return bytes(b + 32 if 65 <= b <= 90 else b for b in s.encode("utf-8"))


@dataclass
class Entry:
    vpath: str
    pk3: str               # basename of the winning pk3
    size: int
    crc32: int
    shadowed: list[str] = field(default_factory=list)  # pk3s whose copy of this path is hidden


class Vfs:
    def __init__(self, pk3_paths: list[Path]):
        # sort exactly like stringlistsort over full paths in one directory
        self.pk3s = sorted(pk3_paths, key=lambda p: strcasecmp_key(str(p)))
        self.entries: dict[str, Entry] = {}
        self._zip: dict[str, zipfile.ZipFile] = {}
        for p in self.pk3s:  # later pk3 = searched earlier = wins
            z = zipfile.ZipFile(p)
            self._zip[p.name] = z
            for info in z.infolist():
                if info.is_dir():
                    continue
                prev = self.entries.get(info.filename)
                e = Entry(info.filename, p.name, info.file_size, info.CRC)
                if prev:
                    e.shadowed = prev.shadowed + [prev.pk3]
                self.entries[info.filename] = e

    def read(self, vpath: str) -> bytes:
        e = self.entries[vpath]  # KeyError == file not found (case-sensitive like DarkPlaces)
        return self._zip[e.pk3].read(vpath)

    def sha256(self, vpath: str) -> str:
        h = hashlib.sha256()
        e = self.entries[vpath]
        with self._zip[e.pk3].open(vpath) as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()


KINDS = {
    "texture": {"dds", "jpg", "jpeg", "tga", "png", "pcx", "wal", "lmp", "bmp", "ktx"},
    "model": {"md3", "iqm", "dpm", "zym", "mdl", "md2", "psk", "obj", "ase", "spr", "sp2", "spr32"},
    "sound": {"ogg", "wav", "mp3", "flac", "mid"},
    "map": {"bsp"},
    "shader": {"shader"},
    "progs": {"dat"},
    "config": {"cfg", "rc", "options", "mapinfo", "instantaction", "framegroups", "skin", "sounds",
               "rtlights", "ent", "waypoints", "hardwired", "cache", "bgs", "arena", "defs", "sp"},
    "font": {"ttf", "otf", "width"},
    "lang": {"po", "pot"},
}


def kind_of(vpath: str) -> str:
    low = vpath.lower()
    ext = low.rsplit(".", 1)[-1] if "." in low.rsplit("/", 1)[-1] else ""
    if ext == "ogg" and low.startswith("sound/cdtracks/"):
        return "music"
    if ext == "map" and low.startswith("maps/"):
        return "mapsource"   # editor sources, never loaded by the engine
    for k, exts in KINDS.items():
        if ext in exts:
            return k
    return "other"
