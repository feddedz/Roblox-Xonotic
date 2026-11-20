#!/usr/bin/env python3
"""Control-flow graphs of QuakeC functions (basis for structuring AOT output; Luau has no goto).

build_cfg(progs, function) -> Cfg with basic blocks, successors, dominators, back edges and a
reducibility flag. A CFG is reducible iff removing the back edges (u->v where v dominates u) leaves it
acyclic. Reducible functions compile to structured `while`/`if`; irreducible ones need a dispatch loop.
gmqcc ends every function with OP_DONE and never jumps outside the function (verified for 0.8.6).

CLI: python3 tools/qcaot/cfg.py work/vfs-high/progs.dat   -> stats + names of irreducible functions
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from progs import OP, Function, Progs, load  # noqa: E402

TERMINATORS = {OP["DONE"], OP["RETURN"]}


@dataclass
class Cfg:
    start: int          # first statement
    end: int            # index of the function's final OP_DONE
    blocks: list[int]   # leader statement of each block, ascending
    succ: list[list[int]]
    reachable: set[int]
    dom: list[set[int]]
    back_edges: list[tuple[int, int]]
    reducible: bool
    leaves_function: int  # jumps whose target is outside [start, end] (expected 0)

    def block_end(self, k: int) -> int:
        return (self.blocks[k + 1] - 1) if k + 1 < len(self.blocks) else self.end


def build_cfg(p: Progs, f: Function) -> Cfg:
    st = p.statements
    fs = f.first_statement
    e = fs
    while st[e].op != OP["DONE"]:
        e += 1
    leaders, leaving = {fs}, 0
    for i in range(fs, e + 1):
        s = st[i]
        if s.jump >= 0:
            if not fs <= s.jump <= e:
                leaving += 1
            leaders.add(s.jump)
            leaders.add(i + 1)
        if s.op in TERMINATORS:
            leaders.add(i + 1)
    blocks = sorted(x for x in leaders if fs <= x <= e)
    idx = {b: k for k, b in enumerate(blocks)}
    n = len(blocks)
    succ: list[list[int]] = [[] for _ in range(n)]
    for k in range(n):
        last = (blocks[k + 1] - 1) if k + 1 < n else e
        s = st[last]
        if s.op in TERMINATORS:
            continue
        if s.op == OP["GOTO"]:
            succ[k].append(idx[s.jump])
            continue
        if s.jump >= 0:
            succ[k].append(idx[s.jump])
        if k + 1 < n:
            succ[k].append(k + 1)
    reach, stack = {0}, [0]
    while stack:
        u = stack.pop()
        for v in succ[u]:
            if v not in reach:
                reach.add(v)
                stack.append(v)
    preds: list[list[int]] = [[] for _ in range(n)]
    for u in range(n):
        for v in succ[u]:
            preds[v].append(u)
    every = set(range(n))
    dom = [every.copy() for _ in range(n)]
    dom[0] = {0}
    changed = True
    while changed:
        changed = False
        for v in range(1, n):
            if v not in reach:
                continue
            ps = [dom[u] for u in preds[v] if u in reach]
            nd = (set.intersection(*ps) if ps else set()) | {v}
            if nd != dom[v]:
                dom[v] = nd
                changed = True
    back = [(u, v) for u in sorted(reach) for v in succ[u] if v in dom[u]]
    bs = set(back)
    color = [0] * n
    cyclic = False
    stack2 = [(0, iter(succ[0]))]
    color[0] = 1
    while stack2:  # iterative DFS on the graph without back edges
        u, it = stack2[-1]
        for v in it:
            if (u, v) in bs:
                continue
            if color[v] == 1:
                cyclic = True
            elif color[v] == 0:
                color[v] = 1
                stack2.append((v, iter(succ[v])))
                break
        else:
            color[u] = 2
            stack2.pop()
    return Cfg(fs, e, blocks, succ, reach, dom, back, not cyclic, leaving)


def main():
    p = load(sys.argv[1])
    qc = [f for f in p.functions if f.builtin is None and f.index > 0]
    irr, loops, maxb, leaving = [], 0, 0, 0
    for f in qc:
        c = build_cfg(p, f)
        loops += len(c.back_edges)
        maxb = max(maxb, len(c.blocks))
        leaving += c.leaves_function
        if not c.reducible:
            irr.append(f.name)
    print(f"{sys.argv[1]}: {len(qc)} functions, {len(irr)} irreducible {irr}, {loops} loop back-edges, "
          f"max {maxb} blocks, {leaving} jumps leaving a function")


if __name__ == "__main__":
    main()
