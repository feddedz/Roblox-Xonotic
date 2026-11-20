import sys, tempfile, unittest, zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vfs import Vfs, kind_of, strcasecmp_key  # noqa: E402


def mk(d: Path, name: str, files: dict) -> Path:
    p = d / name
    with zipfile.ZipFile(p, "w") as z:
        for k, v in files.items():
            z.writestr(k, v)
    return p


class VfsTest(unittest.TestCase):
    def test_last_sorted_pk3_wins(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            a = mk(d, "a.pk3", {"x.cfg": "A", "only_a": "1"})
            b = mk(d, "B.pk3", {"x.cfg": "B"})   # strcasecmp: "B" sorts after "a"
            c = mk(d, "_c.pk3", {"x.cfg": "C"})  # '_' (0x5f) sorts before 'a' (0x61)
            v = Vfs([b, c, a])
            self.assertEqual(v.read("x.cfg"), b"B")
            self.assertEqual(v.entries["x.cfg"].shadowed, ["_c.pk3", "a.pk3"])
            self.assertEqual(v.read("only_a"), b"1")

    def test_case_sensitive_lookup(self):
        with tempfile.TemporaryDirectory() as t:
            v = Vfs([mk(Path(t), "a.pk3", {"Textures/X.tga": "1"})])
            with self.assertRaises(KeyError):
                v.read("textures/x.tga")

    def test_strcasecmp_key_ascii_only(self):
        self.assertEqual(strcasecmp_key("AbC_"), b"abc_")
        self.assertLess(strcasecmp_key("data/_x"), strcasecmp_key("data/a"))

    def test_kinds(self):
        self.assertEqual(kind_of("dds/textures/a.dds"), "texture")
        self.assertEqual(kind_of("sound/cdtracks/track01.ogg"), "music")
        self.assertEqual(kind_of("maps/a.map"), "mapsource")
        self.assertEqual(kind_of("progs.dat"), "progs")


if __name__ == "__main__":
    unittest.main()
