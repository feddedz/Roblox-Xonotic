#!/usr/bin/env python3
"""Reader for QuakeC progs files (progs.dat, csprogs.dat, menu.dat), PROG_VERSION 6.

Mirrors the on-disk structs of pr_comp.h and the load + validation of prvm_edict.c PRVM_Prog_Load
L1916-… @xonotic-v0.8.6, without the engine-side "required globals/fields" that the engine appends
(those depend on which VM loads the file; see docs/subsystems/qcvm.md).

Facts this relies on (verified in the pinned source):
  * PRVM_64 is NOT defined (qtypes.h L43) -> prvm_vec_t = float, prvm_int_t = int: every global and
    entity field slot is 4 bytes, so a Luau buffer with readf32/readi32 at ofs*4 has the C layout.
  * statement operands are read as unsigned short; IF/IFNOT's b and GOTO's a are re-read as signed
    short and are relative to the statement index.
  * function.first_statement < 0 means builtin number -first_statement.

CLI: python3 tools/qcaot/progs.py work/vfs-high/progs.dat [--json out.json]   prints a summary.
"""
from __future__ import annotations

import json, struct, sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

PROG_VERSION = 6
MAX_PARMS = 8
DEF_SAVEGLOBAL = 1 << 15
OFS_RETURN, OFS_PARM0, RESERVED_OFS = 1, 4, 28

OPS = ["DONE", "MUL_F", "MUL_V", "MUL_FV", "MUL_VF", "DIV_F", "ADD_F", "ADD_V", "SUB_F", "SUB_V",
       "EQ_F", "EQ_V", "EQ_S", "EQ_E", "EQ_FNC", "NE_F", "NE_V", "NE_S", "NE_E", "NE_FNC",
       "LE", "GE", "LT", "GT", "LOAD_F", "LOAD_V", "LOAD_S", "LOAD_ENT", "LOAD_FLD", "LOAD_FNC",
       "ADDRESS", "STORE_F", "STORE_V", "STORE_S", "STORE_ENT", "STORE_FLD", "STORE_FNC",
       "STOREP_F", "STOREP_V", "STOREP_S", "STOREP_ENT", "STOREP_FLD", "STOREP_FNC",
       "RETURN", "NOT_F", "NOT_V", "NOT_S", "NOT_ENT", "NOT_FNC", "IF", "IFNOT",
       "CALL0", "CALL1", "CALL2", "CALL3", "CALL4", "CALL5", "CALL6", "CALL7", "CALL8",
       "STATE", "GOTO", "AND", "OR", "BITAND", "BITOR"]
OP = {n: i for i, n in enumerate(OPS)}
# etype_t (pr_comp.h): ev_void, ev_string, ev_float, ev_vector, ev_entity, ev_field, ev_function, ev_pointer
ETYPES = ["void", "string", "float", "vector", "entity", "field", "function", "pointer"]


class ProgsError(Exception):
    pass


@dataclass
class Statement:
    op: int
    a: int  # unsigned short as loaded
    b: int
    c: int
    jump: int = -1  # absolute target for IF/IFNOT/GOTO


@dataclass
class Def:
    type: int  # without DEF_SAVEGLOBAL
    saveglobal: bool
    ofs: int
    name: str


@dataclass
class Function:
    index: int
    first_statement: int
    parm_start: int
    locals: int
    name: str
    file: str
    numparms: int
    parm_size: list[int]

    @property
    def builtin(self) -> int | None:
        return -self.first_statement if self.first_statement < 0 else None


@dataclass
class Progs:
    path: str
    version: int
    crc: int
    statements: list[Statement]
    globaldefs: list[Def]
    fielddefs: list[Def]
    functions: list[Function]
    strings: bytes
    globals_raw: bytes  # numglobals * 4 bytes, little-endian, exactly as in the file
    entityfields: int
    stats: dict = field(default_factory=dict)

    @property
    def numglobals(self) -> int:
        return len(self.globals_raw) // 4

    def string(self, ofs: int) -> str:
        end = self.strings.index(b"\0", ofs)
        return self.strings[ofs:end].decode("latin-1")


def load(path: str | Path) -> Progs:
    data = Path(path).read_bytes()
    hdr = struct.unpack_from("<15i", data, 0)
    (version, crc, ofs_st, n_st, ofs_gd, n_gd, ofs_fd, n_fd, ofs_fn, n_fn, ofs_str, n_str, ofs_gl, n_gl,
     entityfields) = hdr
    if version != PROG_VERSION:
        raise ProgsError(f"{path} has wrong version number ({version} should be {PROG_VERSION})")
    if ofs_str + n_str > len(data):
        raise ProgsError(f"{path} strings go past end of file")
    strings = data[ofs_str:ofs_str + n_str]

    def s(ofs: int) -> str:
        end = strings.index(b"\0", ofs)
        return strings[ofs:end].decode("latin-1")

    functions = []
    for i in range(n_fn):
        fs, ps, loc, _prof, sn, sf, np_ = struct.unpack_from("<7i", data, ofs_fn + i * 36)
        psize = list(data[ofs_fn + i * 36 + 28: ofs_fn + i * 36 + 36])
        if fs >= n_st:
            raise ProgsError(f"out of bounds function statement (function {i})")
        functions.append(Function(i, fs, ps, loc, s(sn), s(sf), np_, psize))

    def defs(ofs: int, n: int, is_field: bool) -> list[Def]:
        out = []
        for i in range(n):
            t, o, sn = struct.unpack_from("<HHi", data, ofs + i * 8)
            if is_field and t & DEF_SAVEGLOBAL:
                raise ProgsError("fielddefs[i].type & DEF_SAVEGLOBAL")
            out.append(Def(t & ~DEF_SAVEGLOBAL, bool(t & DEF_SAVEGLOBAL), o, s(sn)))
        return out

    globaldefs = defs(ofs_gd, n_gd, False)
    fielddefs = defs(ofs_fd, n_fd, True)
    globals_raw = data[ofs_gl:ofs_gl + 4 * n_gl]

    statements, unknown = [], Counter()
    for i in range(n_st):
        op, a, b, c = struct.unpack_from("<HHHH", data, ofs_st + i * 8)
        st = Statement(op, a, b, c)
        name = OPS[op] if op < len(OPS) else None
        if name in ("IF", "IFNOT"):
            bs = b - 0x10000 if b >= 0x8000 else b
            if a >= n_gl or not 0 <= i + bs < n_st:
                raise ProgsError(f"out of bounds IF/IFNOT (statement {i})")
            st.jump = i + bs
        elif name == "GOTO":
            as_ = a - 0x10000 if a >= 0x8000 else a
            if not 0 <= i + as_ < n_st:
                raise ProgsError(f"out of bounds GOTO (statement {i})")
            st.jump = i + as_
        elif name is None:
            unknown[op] += 1  # C: Con_DPrintf, statement left zeroed (OP_DONE)
        statements.append(st)

    p = Progs(str(path), version, crc, statements, globaldefs, fielddefs, functions, strings, globals_raw,
              entityfields)
    p.stats = {"unknown_opcodes": dict(unknown)}
    return p


def summary(p: Progs) -> dict:
    ops = Counter(OPS[s.op] if s.op < len(OPS) else f"?{s.op}" for s in p.statements)
    builtins = sorted({f.builtin for f in p.functions if f.builtin is not None})
    qc = [f for f in p.functions if f.builtin is None and f.index > 0]
    sizes = []
    for f in qc:
        n = 0
        i = f.first_statement
        while i < len(p.statements):
            n += 1
            if p.statements[i].op == OP["DONE"]:
                break
            i += 1
        sizes.append(n)
    return {
        "file": p.path, "crc": p.crc, "statements": len(p.statements), "globals": p.numglobals,
        "globaldefs": len(p.globaldefs), "fielddefs": len(p.fielddefs), "entityfields": p.entityfields,
        "functions": len(p.functions), "qc_functions": len(qc), "builtin_defs": len(p.functions) - len(qc) - 1,
        "builtin_numbers": builtins, "max_locals": max((f.locals for f in qc), default=0),
        "largest_function_statements": max(sizes, default=0),
        "opcodes": dict(ops.most_common()), "unknown_opcodes": p.stats["unknown_opcodes"],
        "strings_bytes": len(p.strings),
    }


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("progs")
    ap.add_argument("--json")
    a = ap.parse_args()
    sm = summary(load(a.progs))
    if a.json:
        Path(a.json).write_text(json.dumps(sm, indent=1) + "\n")
    print(json.dumps({k: v for k, v in sm.items() if k not in ("opcodes", "builtin_numbers")}, indent=1))
    print("builtins used:", len(sm["builtin_numbers"]), "opcodes:", sm["opcodes"])
