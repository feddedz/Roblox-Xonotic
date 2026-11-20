# engine/

Hand-ported DarkPlaces (tag `xonotic-v0.8.6`, commit `f244ef2525c9c018f1b077d49959df3c77ebc7b1`),
one `.luau` per C source file with the same name (`sv_phys.c` → `sv_phys.luau`), same function and
variable names, same order of operations. Every ported function carries:

    -- port: sv_phys.c SV_FlyMove L1234-1310 @xonotic-v0.8.6

Keep original copyright notices at the top of each ported file.

`_port/` holds port-support helpers that have no C counterpart (float32 rounding, C-struct storage).
Nothing OS-facing lives here: that is `platform/`.
