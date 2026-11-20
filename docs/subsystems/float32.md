# Float32 exactness (D-004)

DarkPlaces (`vec_t`, `prvm_vec_t`, `float`) computes in IEEE single precision; Luau numbers are doubles.
Drift between the two changes gameplay over time (movement, traces, timers), so the port reproduces
float results bit for bit.

## Rules
1. **Per operation.** For one `+ - * /` or `sqrt` on float operands, computing in double then rounding
   once to float gives exactly the float result (binary64 has p=53 ≥ 2·24+2, so double rounding is
   innocuous: Figueroa, "When is double rounding innocuous?", 1995). So `c = a*b + d` in C becomes
   `f32.round(f32.round(a*b) + d)`. Keep C's evaluation order (left to right for same precedence).
2. **Per store.** Assigning to a float variable, struct field, QC global or entity field rounds. QC
   globals/fields are stored in `buffer` f32 slots, which round on write automatically.
3. **Promotions.** Mixed `float`/`double` C expressions are evaluated in double (usual arithmetic
   conversions) and round only when stored to float. Literals like `0.5` are double in C, `0.5f` float.
   `sqrt()`/`sin()`/`atan2()` are double functions in C: argument promoted, result rounded only on store.
   Read the C types carefully at each site.
4. **No FMA.** The reference binary targets generic x86-64 (SSE2, no FMA contraction). Never fuse.
5. **Double stays double.** `realtime`, `host.realtime`, `sv.time`, `cl.time` etc. are `double`.
6. **Integers.** C `int` arithmetic wraps at 32 bits; use `bit32` or explicit wrap where overflow is
   possible. `(int)f` truncates toward zero (`math.modf`-style, not `math.floor`).
7. **Libm.** `sin`, `cos`, `atan2`, `pow`, `exp`, `log` results may differ by 1 ulp between glibc and
   Luau's C runtime on some inputs. Differential tests on recorded data decide whether a site needs a
   bit-exact reimplementation. Record findings in §GOTCHAS.

## Helper
`engine/_port/f32.luau`: `round`, `add`, `sub`, `mul`, `div`, `sqrt`, `tobits`, `frombits`.
Equivalent route: `vector.create(x, 0, 0).x` (Luau `vector` components are float32 and vector `+ - *`
are computed in float). Both verified against numpy float32 (`tools/testgen/f32_vectors.py` →
`tests/vectors/f32.txt`, 12,025 cases: conversions, exact ties, subnormals, overflow, ops, sqrt).

## Open points
- Vector ops via Luau `vector`: `vector * number` converts the number to float first (matches C only if
  the C scalar is float). `vector.dot` order/precision not yet verified: verify before using in ports.
- Performance: 5M `f32.round` calls ≈ 0.08 s in Lune (interpreted); measure under `--!native` in Studio.
