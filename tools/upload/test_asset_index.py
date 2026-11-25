"""The texture lookup the game uses must match the manifests: complete, current versions only, not stale.
Runs on the committed files (no release data needed). If it fails after an upload: asset_index.py --write."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asset_index as A  # noqa: E402


class AssetIndex(unittest.TestCase):
    def setUp(self):
        self.res = A.resolve()

    def test_every_texture_has_a_current_asset(self):
        self.assertEqual([r[0] for r in self.res if not r[1]], [])

    def test_no_superseded_upload_is_used(self):
        # an original that has a fixed version must never be handed to the game
        up = {c[0]: c[2] for c in A.rows("roblox-images.tsv") if len(c) > 4 and c[4] == "ok"}
        old = {up[c[3]] for c in A.rows("upload-ready.tsv") if c[1] != "original" and c[3] in up}
        used = {r[1] for r in self.res}
        self.assertEqual(sorted(old & used), [])

    def test_tsv_is_current(self):
        got = [(c[0], c[1]) for c in A.rows(A.TSV.name)]
        self.assertEqual(got, [(r[0], r[1]) for r in self.res])

    def test_luau_table_is_current(self):
        pairs = {}
        parts = sorted(A.LUA.parent.glob("texture_assets_*.luau"))
        for p in parts:
            text = p.read_text(encoding="utf-8")
            self.assertLess(len(text), 190_000, p.name)  # G-024
            pairs.update(re.findall(r'\["([^"]+)"\] = (\d+),', text))
        self.assertEqual(pairs, {r[0]: r[1] for r in self.res})
        main = A.LUA.read_text(encoding="utf-8")
        self.assertEqual(main.count("add(require("), len(parts))


if __name__ == "__main__":
    unittest.main()
