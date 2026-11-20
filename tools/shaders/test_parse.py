import sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parse import Tokenizer, parse_file, fs_search  # noqa: E402


def toks(data: bytes, nl=False):
    t, out = Tokenizer(data), []
    while (x := t.next(nl)) is not None:
        out.append(x)
    return out


class TokenizerTest(unittest.TestCase):
    def test_comments_quotes_single_chars(self):
        self.assertEqual(toks(b'a //c\n b /* x\n y */ "q \\n r" {c:d}'),
                         [b"a", b"b", b"q \n r", b"{", b"c", b":", b"d", b"}"])
        # '//' starts a comment only at the start of a token (DarkPlaces quirk)
        self.assertEqual(toks(b"a//c"), [b"a//c"])

    def test_newlines_returned_only_when_asked(self):
        self.assertEqual(toks(b"a\r\nb\rc", nl=True), [b"a", b"\n", b"b", b"\n", b"c"])
        self.assertEqual(toks(b"a\r\nb\rc", nl=False), [b"a", b"b", b"c"])


class ParseTest(unittest.TestCase):
    def test_layer_closing_brace_on_directive_line(self):
        (s,) = parse_file(b"s\n{\n{\nmap $lightmap }\ncull none\n}\n", 1)
        self.assertEqual(s["layers"], [[[b"map", b"$lightmap"]]])
        self.assertEqual(s["directives"], [[b"cull", b"none"]])

    def test_shader_level_brace_quirk_first_file_only(self):
        src = b"a\n{\ncull none }\nb\n{\n}\n"
        first = list(parse_file(src, 0))
        self.assertEqual([x["name"] for x in first], [b"a", b"b"])
        # in later files the '}' is swallowed: "b" and "{" become a directive of shader a
        later = list(parse_file(src, 1))
        self.assertEqual([x["name"] for x in later], [b"a"])
        self.assertEqual(later[0]["directives"], [[b"cull", b"none"], [b"b"]])

    def test_dp_prefix_and_truncation(self):
        (s,) = parse_file(b"s { dp_water 1 }", 0)  # first-file quirk ends the shader at '}'
        self.assertEqual(s["directives"], [])
        (s,) = parse_file(b"s {\ndp_water " + b"x" * 80 + b"\n}", 1)
        self.assertEqual(s["directives"], [[b"dpwater", b"x" * 63]])

    def test_extra_layers_dropped(self):
        (s,) = parse_file(b"s {\n" + b"{\nmap a\n}\n" * 10 + b"}", 1)
        self.assertEqual((len(s["layers"]), s["dropped_layers"]), (8, 2))

    def test_fs_search_order(self):
        self.assertEqual(fs_search(["scripts/rocket.shader", "scripts/RL.shader", "scripts/sub/x.shader",
                                    "scripts/a.SHADER", "scripts/notes.txt"]),
                         ["scripts/a.SHADER", "scripts/RL.shader", "scripts/rocket.shader"])


if __name__ == "__main__":
    unittest.main()
