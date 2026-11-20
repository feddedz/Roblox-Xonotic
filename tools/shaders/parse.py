#!/usr/bin/env python3
"""Parse every Q3 shader script exactly the way DarkPlaces loads them.

Mirrors @xonotic-v0.8.6:
  fs.c FS_Search("scripts/*.shader", caseinsensitive=1): matches in every pack, de-duplicated with strcmp,
      then stringlistsort(uniq=true) -> strcasecmp order, strcasecmp-equal names collapsed.
  filematch.c matchpattern: '*' never crosses '/', '\\' or ':'.
  common.c COM_ParseToken_QuakeC: tokenizer (comments, quotes with \\n \\t escapes, single-char tokens).
  model_shared.c Mod_LoadQ3Shaders L1645-2393: control flow, including
      * parameters truncated to Q3PATHLENGTH-1 = 63 bytes, at most TEXTURE_MAXFRAMES+4 = 68 per directive
      * leading "dp_" in a directive name rewritten to "dp"
      * at most Q3SHADER_MAXLAYERS = 8 stored layers; extra layers parsed and dropped
      * a '}' ending a shader-level directive line closes the shader only in the FIRST file (fileindex == 0)
      * Q3Shader_AddToHash: first definition of a name (strcasecmp) wins, later ones ignored
Semantics (blendfunc, tcmod, ...) are NOT interpreted here: directives are kept raw, in order, for the
engine port (engine/model_shared.luau) and the converters.

Usage: python3 tools/shaders/parse.py [--build high]
Writes assets/data/shaders.json and docs/shaders.md.
"""
from __future__ import annotations

import argparse, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/pk3"))
from vfs import strcasecmp_key  # noqa: E402

Q3PATHLENGTH = 64
TEXTURE_MAXFRAMES = 64
Q3SHADER_MAXLAYERS = 8
WS = b" \t\r\n\x00"
SINGLE = b"\n{})(][:,;"
STOP = b"{})(][:,;"


class Tokenizer:
    """COM_ParseToken_QuakeC over bytes. next(returnnewline) -> bytes token or None (end)."""

    def __init__(self, data: bytes):
        self.d = data + b"\x00"
        self.i = 0

    def next(self, returnnewline: bool):
        d, i = self.d, self.i
        while True:
            # skip whitespace
            while d[i] in WS and ((d[i] not in b"\n\r") or not returnnewline):
                if d[i] == 0:
                    self.i = i
                    return None
                i += 1
            if d[i] == 0x0D and d[i + 1] == 0x0A:
                i += 1
            if d[i] == 0x2F and d[i + 1] == 0x2F:  # //
                while d[i] and d[i] not in b"\n\r":
                    i += 1
                continue
            if d[i] == 0x2F and d[i + 1] == 0x2A:  # /*
                i += 1
                while d[i] and not (d[i] == 0x2A and d[i + 1] == 0x2F):
                    i += 1
                if d[i]:
                    i += 1
                if d[i]:
                    i += 1
                continue
            break
        c = d[i]
        if c in b"\"'":
            quote = c
            out = bytearray()
            i += 1
            while d[i] and d[i] != quote:
                ch = d[i]
                if ch == 0x5C:  # backslash
                    i += 1
                    ch = d[i]
                    ch = 0x0A if ch == 0x6E else 0x09 if ch == 0x74 else ch
                out.append(ch)
                i += 1
            if d[i] == quote:
                i += 1
            self.i = i
            return bytes(out)
        if c == 0x0D:
            self.i = i + 1
            return b"\n"
        if c in SINGLE:
            self.i = i + 1
            return bytes([c])
        j = i
        while d[j] not in WS and d[j] not in STOP:
            j += 1
        self.i = j
        return d[i:j]


def trunc(b: bytes) -> bytes:
    return b[: Q3PATHLENGTH - 1]  # strlcpy into char[Q3PATHLENGTH]


def lower_eq(a: bytes, b: bytes) -> bool:
    return a.lower() == b.lower()


def read_directive(tok: Tokenizer, first: bytes):
    """The `for (j = 0; tok != "\\n" && tok != "}"; j++)` loop. Returns (params, terminator)."""
    params = []
    t = first
    j = 0
    while t is not None and t != b"\n" and t != b"}":
        if j < TEXTURE_MAXFRAMES + 4:
            if j == 0 and t[:3].lower() == b"dp_":
                params.append(trunc(b"dp" + t[3:]))
            else:
                params.append(trunc(t))
        j += 1
        t = tok.next(True)
        if t is None:
            break
    return params, t


def parse_file(data: bytes, fileindex: int):
    """Yield shader dicts in file order (before hash de-duplication)."""
    tok = Tokenizer(data)
    while True:
        name = tok.next(False)
        if name is None:
            return
        shader = {"name": trunc(name), "directives": [], "layers": [], "dropped_layers": 0}
        t = tok.next(False)
        if t is None or t != b"{":
            shader["error"] = "expected {"
            yield shader
            return  # C: break out of the file loop
        while True:
            t = tok.next(False)
            if t is None or t == b"}":
                break
            if t == b"{":
                layer = []
                while True:
                    t = tok.next(False)
                    if t is None or t == b"}":
                        break
                    if t == b"\n":
                        continue
                    params, term = read_directive(tok, t)
                    layer.append(params)
                    if term == b"}":
                        break
                if len(shader["layers"]) < Q3SHADER_MAXLAYERS:
                    shader["layers"].append(layer)
                else:
                    shader["dropped_layers"] += 1
                continue
            params, term = read_directive(tok, t)
            if fileindex == 0 and term == b"}":
                break
            if params:
                shader["directives"].append(params)
        yield shader


def matchpattern(name: str) -> bool:
    return re.fullmatch(r"scripts/[^/\\:]*\.shader", name, re.IGNORECASE) is not None


def fs_search(vpaths: list[str]) -> list[str]:
    hits = sorted({p for p in vpaths if matchpattern(p)}, key=strcasecmp_key)
    out = []
    for p in hits:  # stringlistsort(uniq=true): drop strcasecmp-equal neighbours
        if out and strcasecmp_key(out[-1]) == strcasecmp_key(p):
            continue
        out.append(p)
    return out


def dec(b: bytes) -> str:
    return b.decode("latin-1")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="high", choices=["standard", "high"])
    a = ap.parse_args()
    vroot = ROOT / f"work/vfs-{a.build}"
    vpaths = [str(p.relative_to(vroot)) for p in (vroot / "scripts").glob("*") if p.is_file()]
    if not vpaths:
        sys.exit(f"{vroot} missing: run tools/pk3/manifest.py --build {a.build} --extract")
    files = fs_search(vpaths)
    table, seen, ignored = [], {}, []
    for fi, path in enumerate(files):
        for sh in parse_file((vroot / path).read_bytes(), fi):
            key = sh["name"].lower()
            rec = {
                "name": dec(sh["name"]),
                "file": path,
                "directives": [[dec(p) for p in d] for d in sh["directives"]],
                "layers": [[[dec(p) for p in d] for d in layer] for layer in sh["layers"]],
            }
            if sh["dropped_layers"]:
                rec["dropped_layers"] = sh["dropped_layers"]
            if "error" in sh:
                rec["error"] = sh["error"]
            if key in seen:
                ignored.append({"name": rec["name"], "file": path, "kept_from": seen[key]})
                continue
            seen[key] = path
            table.append(rec)
    out = {"source": f"work/vfs-{a.build} (xonotic-v0.8.6)", "files": files, "shaders": table,
           "ignored_redefinitions": ignored}
    (ROOT / "assets/data").mkdir(parents=True, exist_ok=True)
    (ROOT / "assets/data/shaders.json").write_text(json.dumps(out, indent=1) + "\n")
    write_status_doc(table, files, ignored)
    print(f"{len(files)} files, {len(table)} shaders, {len(ignored)} ignored redefinitions", file=sys.stderr)


STAGE_KEYS = ["map", "clampmap", "animmap", "blendfunc", "rgbgen", "alphagen", "tcgen", "tcmod", "alphafunc",
              "depthfunc", "depthwrite", "detail"]


def write_status_doc(table, files, ignored):
    lines = [
        "# Shader status table",
        "",
        "Every shader DarkPlaces loads from the pinned data (generated by `tools/shaders/parse.py`; keep the",
        "**Status** and **Notes** columns when regenerating; the script preserves them). Status: `not started`,",
        "`exact`, `close`, `approximate` (approximate requires a §DIFFS entry). Features = shader-level",
        "directives and stage keywords used, so you can find every shader using e.g. `tcmod` or `deformvertexes`.",
        "",
        f"{len(table)} shaders from {len(files)} files; {len(ignored)} ignored redefinitions (first definition wins).",
        "",
        "| Shader | File | Layers | Features | Status | Notes |",
        "|---|---|---:|---|---|---|",
    ]
    prev = {}
    doc = ROOT / "docs/shaders.md"
    if doc.exists():
        for l in doc.read_text().splitlines():
            if l.startswith("| ") and not l.startswith("| Shader") and not l.startswith("|---"):
                cols = [c.strip() for c in l.strip("|").split("|")]
                if len(cols) == 6:
                    prev[cols[0].strip("`")] = (cols[4], cols[5])
    for s in table:
        feats = set()
        for d in s["directives"]:
            feats.add(d[0].lower())
        for layer in s["layers"]:
            for d in layer:
                if d and d[0].lower() in STAGE_KEYS:
                    feats.add(d[0].lower())
        status, notes = prev.get(s["name"], ("not started", ""))
        lines.append(f"| `{s['name']}` | {s['file'].removeprefix('scripts/')} | {len(s['layers'])} | "
                     f"{' '.join(sorted(feats))} | {status} | {notes} |")
    doc.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
