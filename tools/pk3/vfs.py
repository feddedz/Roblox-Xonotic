"""DarkPlaces virtual filesystem resolution over a set of .pk3 files.

Mirrors fs.c @xonotic-v0.8.6:
  * FS_AddGameDirectory lists the game dir, sorts names with strcasecmp (stringlistsort),
    then FS_AddPack_Fullpath prepends each pk3 to fs_searchpaths -> the pk3 that sorts
    LAST is searched FIRST and wins on duplicate paths.
  * Lookups inside a pk3 are case-sensitive (PK3 central directory, binary search with strcmp).
  * Directory entries are not files.
  * PK3 symlinks (zip entries made on Unix/VMS/BeOS with mode S_IFLNK, fs.c L728-736) are followed on
    read exactly like FS_OpenReadFile (fs.c L2596-2691): the link text is merged with the link's own
    directory ("../" walks up), nasty paths are rejected, at most 16 levels (fs.c L2748).
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
    symlink: bool = False


MAX_QPATH = 128  # quakedef.h


def is_symlink(info: zipfile.ZipInfo) -> bool:
    # port: fs.c FS_BuildFileList_PK3 L728-736 @xonotic-v0.8.6 (C_VERSION_MADE_BY_1 = create_system)
    return info.create_system in (3, 2, 16) and ((info.external_attr >> 16) & 0o120000) == 0o120000


def check_nasty_path(path: str, isgamedir: bool = False) -> int:
    # port: fs.c FS_CheckNastyPath L2449-2493 @xonotic-v0.8.6
    if not path:
        return 2
    if "\\" in path:
        return 1
    if ":" in path:
        return 1
    if "//" in path:
        return 1
    if ".." in path:
        return 2
    if path[0] == "/":
        return 2
    if "./" in path:
        return 2
    if isgamedir and path[-1] == "/":
        return 2
    if "/." in path:
        return 2
    return 0


def merge_symlink(filename: str, link: bytes) -> str | None:
    """port: fs.c FS_OpenReadFile L2632-2686 @xonotic-v0.8.6 (path merge part); None = rejected."""
    linkbuf = link[: MAX_QPATH - 1]
    count = len(linkbuf)
    nul = linkbuf.find(b"\0")  # C string: stops at the first NUL
    fname = filename.encode("utf-8")
    ms = fname.rfind(b"/")  # mergeslash index; -1 == "mergeslash = filename" (index 0)
    if ms < 0:
        ms = 0
    st = 0  # mergestart index into linkbuf
    while linkbuf[st : st + 3] == b"../":
        st += 3
        while ms > 0:
            ms -= 1
            if fname[ms : ms + 1] == b"/":
                break
    if ms == 0:
        out = linkbuf[st:]
    else:
        need = ms + 1
        if count - st + need >= MAX_QPATH:
            return None  # "symlink: too long path rejected"
        out = fname[:need] + linkbuf[st:count]
    if nul >= 0:
        out = out.split(b"\0", 1)[0]
    path = out.decode("utf-8", "replace")
    if check_nasty_path(path, False):
        return None  # "symlink: nasty path rejected"
    return path


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
                e = Entry(info.filename, p.name, info.file_size, info.CRC, symlink=is_symlink(info))
                if prev:
                    e.shadowed = prev.shadowed + [prev.pk3]
                self.entries[info.filename] = e

    def resolve(self, vpath: str, levels: int = 16) -> str:
        """Final non-symlink path FS_OpenReadFile opens for vpath (KeyError: not found / rejected)."""
        e = self.entries[vpath]  # KeyError == file not found (case-sensitive like DarkPlaces)
        if not e.symlink:
            return vpath
        if levels <= 0:
            raise KeyError(f"symlink: {vpath}: too many levels of symbolic links")
        target = merge_symlink(vpath, self.read_raw(vpath))
        if target is None:
            raise KeyError(f"symlink: {vpath}: rejected")
        return self.resolve(target, levels - 1)

    def read_raw(self, vpath: str) -> bytes:
        e = self.entries[vpath]
        return self._zip[e.pk3].read(vpath)

    def read(self, vpath: str) -> bytes:
        return self.read_raw(self.resolve(vpath))

    def sha256(self, vpath: str) -> str:
        h = hashlib.sha256()
        vpath = self.resolve(vpath)
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
