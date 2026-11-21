#!/usr/bin/env python3
"""Generate engine/_port/sv_init_defs.luau: every cvar and console command a DarkPlaces 0.8.6 *dedicated
server* (Linux `sv-release`) registers during Host_Init, in execution order.

  python3 tools/engine/gen_cvars.py            (needs work/source: tools/release/fetch.sh source)

How: the files of OBJ_SV (makefile.inc) are preprocessed for that build (USEODE defined, CONFIG_MENU /
CONFIG_CD not, __linux__), function bodies are extracted, and the calls of Host_Init's dedicated path
(host.c L1213-1262, the `cls.state == ca_dedicated` branch) are followed depth-first in source order.
Each `Cvar_RegisterVariable(&x)` resolves `cvar_t x = {flags, "name", "default", "description"};`.
Each `Cmd_AddCommand[_WithClientCommand]("name", ...)` is recorded (stubs until the command is ported).
Calls inside `if`/`switch` bodies are followed too: the report (stdout) lists every registration that
sits under a condition with the condition text, so a person can check it (docs/subsystems/server-runner.md).
The authority is REF-DP: `cvarlist` / `cmdlist` of the real dedicated server (task REF-CVARLIST).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "work/source/Xonotic/source/darkplaces"
OUT = ROOT / "engine/_port/sv_init_defs.luau"
DEFINED = {"USEODE", "__linux__", "__unix__", "__GNUC__", "SSE_POSSIBLE", "LINK_TO_ZLIB"}
DEFINED -= {"LINK_TO_ZLIB"}  # zlib is dlopen'ed by default (makefile: DP_LINK_ZLIB?=shared only on some targets)

ROOTS = [
    "Memory_Init", "Cmd_Init", "Memory_Init_Commands", "Con_Init", "u8_Init", "Curl_Init_Commands",
    "Cmd_Init_Commands", "Sys_Init_Commands", "COM_Init_Commands", "FS_Init_Commands", "Sys_InitConsole",
    "FS_Init_SelfPack", "COM_InitGameType", "Sys_InitProcessNice", "Mathlib_Init", "FS_Init",
    "Host_InitSession", "Crypto_Init", "Crypto_Init_Commands", "NetConn_Init", "Curl_Init", "PRVM_Init",
    "Mod_Init", "World_Init", "SV_Init", "V_Init", "Host_InitCommands", "Host_InitLocal",
    "Host_ServerOptions", "Thread_Init",
]
EXTRA_COMMANDS = [("disconnect", "disconnect from server (or disconnect all clients if running a server)")]
FLAGS = {
    "CVAR_SAVE": 1, "CVAR_NOTIFY": 2, "CVAR_READONLY": 4, "CVAR_SERVERINFO": 8, "CVAR_USERINFO": 16,
    "CVAR_PRIVATE": 32, "CVAR_NQUSERINFOHACK": 64, "CVAR_NORESETTODEFAULTS": 128,
}


def obj_sv_files() -> list[Path]:
    mk = (SRC / "makefile.inc").read_text()
    def var(name):
        m = re.search(rf"^{name}\s*=((?:.*\\\n)*.*)$", mk, re.M)
        return m.group(1).replace("\\\n", " ") if m else ""
    words = var("OBJ_SV").split()
    out = []
    for w in words:
        if w.startswith("$("):
            words += var(w[2:-1]).split()
            continue
        p = SRC / re.sub(r"\.o$", ".c", w)
        if p.suffix == ".c" and p.exists():
            out.append(p)
    return sorted(set(out))


def strip_comments(t: str) -> str:
    # keep strings and line structure; drop // and /* */ comments
    out, i, n = [], 0, len(t)
    while i < n:
        c = t[i]
        if c in "\"'":
            j = i + 1
            while j < n and t[j] != c:
                j += 2 if t[j] == "\\" else 1
            out.append(t[i : j + 1])
            i = j + 1
        elif t.startswith("//", i):
            j = t.find("\n", i)
            i = n if j < 0 else j
        elif t.startswith("/*", i):
            j = t.find("*/", i + 2)
            out.append("\n" * t.count("\n", i, j))
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def eval_if(expr: str) -> bool:
    e = re.sub(r"defined\s*\(\s*(\w+)\s*\)", lambda m: "1" if m.group(1) in DEFINED else "0", expr)
    e = re.sub(r"defined\s+(\w+)", lambda m: "1" if m.group(1) in DEFINED else "0", e)
    e = e.replace("&&", " and ").replace("||", " or ").replace("!", " not ")
    e = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: m.group(0) if m.group(0) in ("and", "or", "not") else "0", e)
    try:
        return bool(eval(e, {}, {}))
    except Exception:
        print(f"warning: cannot evaluate #if {expr!r}; taken as false", file=sys.stderr)
        return False


def preprocess(t: str) -> str:
    lines = t.split("\n")
    out, stack = [], []  # stack of (active, taken)
    for line in lines:
        s = line.strip()
        m = re.match(r"#\s*(ifdef|ifndef|if|elif|else|endif)\b(.*)", s)
        active = all(a for a, _ in stack)
        if m:
            d, rest = m.group(1), m.group(2).strip()
            if d == "ifdef":
                v = rest.split()[0] in DEFINED
                stack.append((v, v))
            elif d == "ifndef":
                v = rest.split()[0] not in DEFINED
                stack.append((v, v))
            elif d == "if":
                v = eval_if(rest)
                stack.append((v, v))
            elif d == "elif":
                a, taken = stack.pop()
                v = (not taken) and eval_if(rest)
                stack.append((v, taken or v))
            elif d == "else":
                a, taken = stack.pop()
                stack.append((not taken, True))
            elif d == "endif":
                stack.pop()
            out.append("")
        else:
            out.append(line if active else "")
    return "\n".join(out)


def c_strings(s: str) -> list[str]:
    """Adjacent C string literals in s, concatenated per group, unescaped."""
    groups, cur, i = [], None, 0
    while i < len(s):
        if s[i] == '"':
            j, buf = i + 1, []
            while s[j] != '"':
                if s[j] == "\\":
                    esc = s[j + 1]
                    buf.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "r": "\r"}.get(esc, esc))
                    j += 2
                else:
                    buf.append(s[j])
                    j += 1
            cur = (cur or "") + "".join(buf)
            i = j + 1
        elif s[i] == ",":
            if cur is not None:
                groups.append(cur)
            cur = None
            i += 1
        else:
            i += 1
    if cur is not None:
        groups.append(cur)
    return groups


def main() -> None:
    if not SRC.exists():
        sys.exit("work/source missing: tools/release/fetch.sh source")
    files = obj_sv_files()
    cvars: dict[str, tuple[int, str, str, str | None, str]] = {}
    funcs: dict[str, tuple[str, str]] = {}  # name -> (file, body)
    for p in files:
        t = preprocess(strip_comments(p.read_text(errors="replace")))
        for m in re.finditer(r"\bcvar_t\s+(\w+)\s*=\s*\{(.*?)\}\s*;", t, re.S):
            var, inner = m.group(1), m.group(2)
            flagexpr = inner.split(",", 1)[0]
            flags = 0
            for tok in re.findall(r"\w+", flagexpr):
                flags |= FLAGS.get(tok, int(tok, 0) if tok[0].isdigit() else 0)
            strs = c_strings(inner.split(",", 1)[1])
            cvars[var] = (flags, strs[0], strs[1], strs[2] if len(strs) > 2 else None, p.name)
        # arrays: `cvar_t name [] = { {flags, "n", "d", "desc"}, ..., {0, NULL, NULL, NULL} };`
        for m in re.finditer(r"\bcvar_t\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\}\s*;", t, re.S):
            k = 0
            for em in re.finditer(r"\{([^{}]*)\}", m.group(2)):
                inner = em.group(1)
                if "NULL" in inner.split(",", 2)[1]:
                    break
                flags = 0
                for tok in re.findall(r"\w+", inner.split(",", 1)[0]):
                    flags |= FLAGS.get(tok, int(tok, 0) if tok[0].isdigit() else 0)
                strs = c_strings(inner.split(",", 1)[1])
                cvars[f"{m.group(1)}[{k}]"] = (flags, strs[0], strs[1], strs[2] if len(strs) > 2 else None, p.name)
                k += 1
        for m in re.finditer(r"^[A-Za-z_][\w \t\*]*?\b(\w+)\s*\(([^;{)]*)\)\s*\{", t, re.M):
            name = m.group(1)
            if name in ("if", "while", "for", "switch", "return"):
                continue
            i, depth = m.end() - 1, 0
            while i < len(t):
                c = t[i]
                if c in "\"'":
                    j = i + 1
                    while t[j] != c:
                        j += 2 if t[j] == "\\" else 1
                    i = j
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            funcs.setdefault(name, (p.name, t[m.end() : i]))
    events: list[tuple] = []
    seen_f: set[str] = set()
    seen_c: set[str] = set()
    conditional: list[str] = []

    def walk(fn: str, chain: list[str]) -> None:
        if fn in seen_f or fn not in funcs:
            return
        seen_f.add(fn)
        fname, body = funcs[fn]
        for m in re.finditer(r"\b(\w+)\s*\(", body):
            callee = m.group(1)
            before = body[: m.start()]
            cond = None
            # nearest enclosing if (...) whose block is still open: rough indentation heuristic
            line_start = before.rfind("\n") + 1
            indent = len(before[line_start:]) - len(before[line_start:].lstrip("\t "))
            if indent > 1:
                ifs = re.findall(r"\n[\t ]*(if|else if|switch|case)\b([^\n]*)", before)
                if ifs:
                    cond = (ifs[-1][0] + ifs[-1][1]).strip()
            if callee == "Cvar_RegisterVariable":
                arr = re.match(r"\s*&\s*(\w+)\[i\]\s*\)", body[m.end() :])
                if arr:  # for (i = 0;name[i].name;i++) Cvar_RegisterVariable(&name[i]);
                    k = 0
                    while f"{arr.group(1)}[{k}]" in cvars:
                        var = f"{arr.group(1)}[{k}]"
                        if cvars[var][1] not in seen_c:
                            seen_c.add(cvars[var][1])
                            events.append(("cvar", var, *cvars[var], fn))
                        k += 1
                    continue
                a = re.match(r"\s*&\s*(\w+)\s*\)", body[m.end() :])
                if not a:
                    print(f"warning: {fname} {fn}: non-simple Cvar_RegisterVariable{body[m.end():m.end()+40]!r}")
                    continue
                var = a.group(1)
                if var not in cvars:
                    print(f"warning: {fname} {fn}: cvar_t {var} not found")
                    continue
                name = cvars[var][1]
                if name not in seen_c:
                    seen_c.add(name)
                    events.append(("cvar", var, *cvars[var], fn))
                    if cond:
                        conditional.append(f"{name}: {fname} {fn}: {cond}")
            elif callee in ("Cmd_AddCommand", "Cmd_AddCommand_WithClientCommand"):
                args = body[m.end() :]
                close, depth = 0, 1
                while depth:
                    ch = args[close]
                    depth += {"(": 1, ")": -1}.get(ch, 0)
                    close += 1
                strs = c_strings(args[: close - 1])
                if strs:
                    events.append(("cmd", strs[0], strs[-1] if len(strs) > 1 else "", fname, fn))
                    if cond:
                        conditional.append(f"command {strs[0]}: {fname} {fn}: {cond}")
            elif callee in funcs:
                walk(callee, chain + [fn])

    for r in ROOTS:
        walk(r, [])
    for name, desc in EXTRA_COMMANDS:
        events.append(("cmd", name, desc, "host.c", "Host_Init"))

    def lq(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"'

    lines = [
        "--!strict",
        "-- GENERATED by tools/engine/gen_cvars.py from DarkPlaces @xonotic-v0.8.6 (GPLv2 or later). Do not edit.",
        "-- Cvars and commands a Linux dedicated server registers in Host_Init, in execution order.",
        "-- cvar: { kind, var, flags, name, default, description|nil, file, func }; cmd: { kind, name, description, file, func }",
        "return {",
    ]
    for e in events:
        if e[0] == "cvar":
            _, var, flags, name, dflt, desc, fname, fn = e
            lines.append(f"\t{{ \"cvar\", {lq(var)}, {flags}, {lq(name)}, {lq(dflt)}, {lq(desc) if desc is not None else 'nil'}, {lq(fname)}, {lq(fn)} }},")
        else:
            _, name, desc, fname, fn = e
            lines.append(f"\t{{ \"cmd\", {lq(name)}, {lq(desc)}, {lq(fname)}, {lq(fn)} }},")
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n")
    nc = sum(1 for e in events if e[0] == "cvar")
    print(f"{len(files)} files, {len(funcs)} functions; {nc} cvars, {len(events) - nc} commands -> {OUT.relative_to(ROOT)}")
    print(f"{len(conditional)} registrations under a condition (check):")
    for c in conditional:
        print("  " + c)


if __name__ == "__main__":
    main()
