import struct, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from progs import OP, ProgsError, load  # noqa: E402
from cfg import build_cfg  # noqa: E402


def assemble(statements, functions, strings=b"\0main\0foo.qc\0bi\0", globals_=(0,) * 32, version=6):
    """statements: [(op, a, b, c)] with signed values allowed; functions: [(first_statement, s_name)]."""
    st = b"".join(struct.pack("<Hhhh", OP[o] if isinstance(o, str) else o, a, b, c) for o, a, b, c in statements)
    fn = b"".join(struct.pack("<7i8B", fs, 28, 0, 0, sn, 6, 0, *([0] * 8)) for fs, sn in functions)
    gd = struct.pack("<HHi", 2, 1, 1)
    fd = struct.pack("<HHi", 2, 0, 1)
    gl = struct.pack(f"<{len(globals_)}i", *globals_)
    ofs = 60
    parts, hdr = [], [version, 1234]
    for blob, count in ((st, len(statements)), (gd, 1), (fd, 1), (fn, len(functions)), (strings, len(strings)),
                        (gl, len(globals_))):
        hdr += [ofs, count]
        parts.append(blob)
        ofs += len(blob)
    hdr.append(1)  # entityfields
    return struct.pack("<15i", *hdr) + b"".join(parts)


def write(blob):
    f = tempfile.NamedTemporaryFile(suffix=".dat", delete=False)
    f.write(blob)
    f.close()
    return f.name


class ProgsTest(unittest.TestCase):
    def test_loop_and_signed_jumps(self):
        # 0: DONE (statement 0 is an error stub)  1: IFNOT g10 -> +3 (4)  2: ADD_F  3: GOTO -2 (1)  4: DONE
        sts = [("DONE", 0, 0, 0), ("IFNOT", 10, 3, 0), ("ADD_F", 10, 11, 10), ("GOTO", -2, 0, 0), ("DONE", 0, 0, 0)]
        p = load(write(assemble(sts, [(0, 0), (1, 1), (-5, 13)])))
        self.assertEqual(p.statements[1].jump, 4)
        self.assertEqual(p.statements[3].jump, 1)
        self.assertEqual(p.functions[1].name, "main")
        self.assertEqual(p.functions[2].builtin, 5)
        c = build_cfg(p, p.functions[1])
        self.assertTrue(c.reducible)
        self.assertEqual(len(c.back_edges), 1)

    def test_irreducible(self):
        # two entries into a cycle: 1: IF g10 -> 3 ; 2: GOTO +2 (4)... build blocks B(2)<->B(3) entered from both
        sts = [("DONE", 0, 0, 0),
               ("IF", 10, 2, 0),        # 1 -> 3 or 2
               ("IF", 11, 2, 0),        # 2 -> 4 or 3   (block A)
               ("IF", 12, -1, 0),       # 3 -> 2 or 4   (block B)
               ("DONE", 0, 0, 0)]
        p = load(write(assemble(sts, [(0, 0), (1, 1)])))
        self.assertFalse(build_cfg(p, p.functions[1]).reducible)

    def test_wrong_version(self):
        with self.assertRaises(ProgsError):
            load(write(assemble([("DONE", 0, 0, 0)], [(0, 0)], version=7)))

    def test_out_of_bounds_goto(self):
        with self.assertRaises(ProgsError):
            load(write(assemble([("DONE", 0, 0, 0), ("GOTO", 50, 0, 0)], [(0, 0)])))


if __name__ == "__main__":
    unittest.main()
