# QuakeC VM and the AOT compiler (M2)

Engine side: `prvm_edict.c`, `prvm_exec.c` + `prvm_execprogram.h`, `prvm_cmds.c`, `svvm_cmds.c` (server
builtins), `clvm_cmds.c` (CSQC), `mvm_cmds.c` (menu). Tools: `tools/qcaot/` (`progs.py` reader,
`cfg.py` control-flow graphs; compiler next). Output: `game/generated/` (never hand-edited).

## The three programs (0.8.6, identical in both builds)
| | progs.dat (server) | csprogs.dat (client) | menu.dat |
|---|---:|---:|---:|
| statements | 577,559 | 319,361 | 135,793 |
| QC functions / builtin defs | 13,042 / 319 | 8,988 / 332 | 3,479 / 234 |
| distinct builtin numbers | 254 | 291 | 203 |
| globals (4-byte slots) | 49,450 | 35,857 | 17,095 |
| entity fields (slots, before engine-required ones) | 4,905 | 2,582 | 2,286 |
| largest function (statements / basic blocks) | 3,921 / 693 | 2,336 / 570 | 2,581 / 570 |
| irreducible functions | `_entcs_send` | `HUD_ItemsTime`, `ItemSetModel` | none |

Format: PROG_VERSION 6, 66 standard opcodes (OP_DONE…OP_BITOR), no unknown opcodes, OP_STATE unused,
no jump leaves its function. `s_file` is sometimes garbage (gmqcc quirk): don't rely on it.

## Facts from the pinned engine source (must be mirrored)
- **Storage:** `PRVM_64` is off (qtypes.h L43): every global and field slot is 4 bytes, `float` or `int`
  in a union. Use one `buffer` for globals and one for all edict fields
  (`edictsfields[edictnum * entityfields + ofs]`, as in DarkPlaces) with `readf32/writef32/readi32/writei32`
  at `ofs * 4`. f32 rounding then happens on every store (D-004).
- **Initial globals** (PRVM_Prog_Load): with PRVM_64 off, both branches of the int/float heuristic store the
  same 32 bits (x86-64 `movss` keeps NaN payloads), so copying `globals_raw` into the buffer is exact.
- **Engine-required globals and fields** are appended after the file's (`numrequiredglobals`,
  `numrequiredfields` per VM, lists in `prvm_offsets.h` + svvm/clvm/mvm init). The AOT layout must append
  the same ones in the same order.
- **Operands:** loaded as unsigned 16-bit global indices; IF/IFNOT `b` and GOTO `a` are signed, relative.
- **Semantics to copy exactly** (`prvm_execprogram.h`):
  `DIV_F` by 0 gives **0** (warning only with `developer`); truthiness of IF/IFNOT/NOT_F/AND/OR is
  `FLOAT_IS_TRUE_FOR_INT(bits) = bits & 0x7FFFFFFF` (so -0.0 is false, NaN is true); `MUL_V` is a dot
  product `a0*b0 + a1*b1 + a2*b2` in float with per-op rounding, left to right; `BITAND/BITOR` truncate
  both floats to int, operate, convert back to float; `EQ_S` compares string contents (strcmp);
  `NOT_S` is true for string 0 or empty; `ADDRESS` bounds-checks edict and field (error = QC crash).
- **Runaway check:** after 10,000,000 jumps in one execution, error "runaway loop" (if prvm_runawaycheck).
- **Calls:** `PRVM_EnterFunction` saves the callee's `locals` slots (from `parm_start`) to a local stack
  (16,384 ints; depth 1,024, both non-DP_SMALLMEMORY values), copies params from OFS_PARM0+i*3 into
  `parm_start…`, and `PRVM_LeaveFunction` restores them. QC locals live in **global slots**, so recursion
  and builtins that read globals observe this. Generated code must keep locals in the globals buffer and
  save/restore exactly like this (any register-promotion optimisation must be proven equivalent).
- **Strings:** a string value is an int offset: ≥0 into the progs string table; negative = engine strings,
  tempstrings, zone strings (`PRVM_SetEngineString`, `PRVM_SetTempString`, `PRVM_AllocString`). Mirror the
  numbering so values stored in fields/globals match the reference bit for bit.

## Compiler plan (M2-AOT)
1. Per QC function: CFG (`tools/qcaot/cfg.py`) → structured Luau (`while true do … end` loops with
   `break`/`continue`, nested `if`s). Luau has no goto and no labelled break: use the reducible-CFG
   structuring of Ramsey's "Beyond Relooper" (dominator tree + loop nesting), with a flag variable where
   an exit skips several loop levels. Irreducible functions (3 total) → dispatch loop over blocks.
2. Emit one Luau function per QC function, named after the QC name (mangled, unique), with a
   `-- qc: <name> s<first>-<last>` comment. Builtins dispatch through the engine table by number.
3. Statement-to-Luau mapping is mechanical and must preserve f32 semantics: operands read from the buffer
   (already f32), each result written back to the buffer (rounds). Vector ops = 3 slot ops in C order.
4. Size: ~1M statements. Check Luau limits before choosing chunking (constants per function, registers
   255, upvalues, Roblox script size: verify in docs, record in §GOTCHAS). Split output into many modules.
5. Verification: a reference interpreter (`engine/prvm_exec.luau`, a straight port of the C loop) runs the
   same programs; differential-test AOT vs interpreter on recorded call sequences, and both vs real DP
   (REF-DP). The interpreter is also the fallback while the AOT is incomplete.
6. Debug symbols: M2-DEBUG rebuilds progs.dat from `source/qcsrc` with the pinned gmqcc; if byte-identical,
   gmqcc's `.lno` output maps statements to source lines for comments and error messages.

## Implementation status (2026-11-20, session 017gQiyN)
- **Reference interpreter** `engine/prvm_exec.luau`: PRVM_EnterFunction, PRVM_LeaveFunction,
  PRVM_ExecuteProgram + every opcode of prvm_execprogram.h, same checks and error text. Loader
  `engine/prvm_edict.luau`: PRVM_Prog_Load up to the statement checks, PRVM_GetString. Not ported yet:
  profiling/coverage/trace/watchpoints (no effect on results), OP_STATE body (unused by 0.8.6),
  the rest of Prog_Load (required functions, field lookup, PRVM_Init_Exec), edict and string allocation.
- **Compiler** `tools/qcaot/compile.py` → `game/generated/<prog>/` (init.luau + c###.luau chunks,
  ~20k statements each): menu 8.3 MB, csprogs 20.0 MB, progs 37.2 MB of Luau; ~1 s / 10 s to generate.
  Control flow v1: block dispatch loop (`pc`, binary if-tree); straight-line code for jump-free functions.
  Runtime `engine/_port/qcrt.luau` shares code paths and error text with the interpreter.
- **Proof so far:**
  - `tests/unit/prvm_exec.test.luau` (29 checks): interpreter vs C semantics on hand-assembled programs
    (f32 rounding, DIV by 0/-0, -0.0/NaN truthiness, (int) truncation incl. NaN→INT_MIN, strcmp
    difference, recursion with locals restore, builtins/argc, edict bounds, runaway at exactly 10M jumps,
    loader checks).
  - `tests/unit/qcaot_synth.test.luau` (CI): compiled == interpreted on synthetic programs (found and fixed
    a self-looping single-block bug).
  - `tests/integration/qcaot_diff.test.luau` (needs game data): **all 25,509 QC functions of progs,
    csprogs and menu give identical globals, edict fields, builtin call sequences and error text** under
    random parameters and deterministic builtin stubs (two seeds; ~58% of calls complete, the rest end in
    QC errors that also match). A planted one-character bug is detected.
  - Not yet proven: interpreter == real DarkPlaces on recorded data (needs REF-DP).
- Speed (Lune, no native codegen, dominated by logging stubs, not a benchmark): AOT ≈ 1.5× interpreter.
