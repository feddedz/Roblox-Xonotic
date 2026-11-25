import sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audio_plan import GAP_S, Sound, group_of, plan_packs, wav_loop_start  # noqa: E402


def snd(vpath, dur=1.0, rate=44100, ch=1, sha=None):
    s = Sound(vpath, sha or vpath, 100, duration=dur, rate=rate, channels=ch)
    s.group, s.packable, s.reason = group_of(vpath)
    return s


class AudioPlanTest(unittest.TestCase):
    def test_groups(self):
        self.assertEqual(group_of("sound/cdtracks/neon.ogg")[:2], ("music", False))
        self.assertEqual(group_of("sound/weapons/rocket_fire.ogg")[:2], ("weapon/devastator", True))
        self.assertEqual(group_of("sound/weapons/weaponpickup.ogg")[:2], ("pickups", True))
        self.assertEqual(group_of("sound/misc/megahealth.ogg")[:2], ("pickups", True))
        self.assertEqual(group_of("sound/player/robot/death.ogg")[:2], ("voice/robot", True))
        self.assertEqual(group_of("sound/announcer/default/1.ogg")[:2], ("announcer/default", True))
        self.assertFalse(group_of("sound/ambient/a.ogg")[1])

    def test_no_packing_when_quota_fits(self):
        s = [snd(f"sound/player/robot/{i}.ogg") for i in range(5)]
        self.assertEqual(plan_packs(s, 5), ([], 5))
        self.assertEqual(plan_packs(s, None), ([], 5))

    def test_pack_layout_and_dedupe(self):
        s = [snd(f"sound/player/robot/{i}.ogg", dur=0.5 + i) for i in range(3)]
        d = snd("sound/player/robot/dup.ogg", sha=s[0].sha256)
        d.dup_of = s[0].vpath
        other = snd("sound/ambient/x.ogg")
        packs, need = plan_packs(s + [d, other], 2)
        self.assertEqual(packs, ["voice_robot_44100_1ch"])
        self.assertEqual(need, 2)  # one pack + the ambient sound; the duplicate costs nothing
        self.assertEqual(s[0].start, 0.0)
        self.assertAlmostEqual(s[1].start, s[0].end + GAP_S, places=4)
        self.assertAlmostEqual(s[2].end - s[2].start, 2.5, places=4)
        self.assertEqual(d.pack, "")  # duplicates follow their original via dup_of
        self.assertEqual(other.pack, "")

    def test_mixed_rates_split_packs(self):
        s = [snd("sound/player/robot/a.ogg", rate=44100), snd("sound/player/robot/b.ogg", rate=48000),
             snd("sound/player/robot/c.ogg", rate=48000)]
        packs, need = plan_packs(s, 2)
        self.assertEqual(packs, ["voice_robot_48000_1ch"])
        self.assertEqual(need, 2)

    def test_wav_cue(self):
        fmt = b"fmt " + (16).to_bytes(4, "little") + bytes(16)
        cue = b"cue " + (28).to_bytes(4, "little") + bytes(24) + (1234).to_bytes(4, "little")
        body = b"WAVE" + fmt + cue
        self.assertEqual(wav_loop_start(b"RIFF" + len(body).to_bytes(4, "little") + body), 1234)


if __name__ == "__main__":
    unittest.main()
