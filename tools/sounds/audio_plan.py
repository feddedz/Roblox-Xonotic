#!/usr/bin/env python3
"""AUDIO-PLAN: decide how every sound of the pinned release becomes Roblox audio assets.

  python3 tools/sounds/audio_plan.py [--build high] [--quota N | --query-quota --user-id ID]
                                     [--build-packs] [--test-pack]

Rules (owner, 2026-11-21; docs/subsystems/audio.md):
  1. Identical files (same sha256) are uploaded once; every vpath maps to that one upload.
  2. Each sound is its own asset, as long as the account's 30-day audio upload quota allows it.
  3. Only if the unique uploads exceed the quota, short one-shot sounds of the packable groups
     (one weapon, one announcer set, one voice set, pickups) are packed into one file per group,
     with 0.5 s of silence between sounds; the manifest records pack, start and end of each slice.
  4. Never packed: music (sound/cdtracks), looping sounds, long sounds (> LONG_S), anything outside
     the packable groups.
Packs are built as 16-bit FLAC from the decoded PCM: DarkPlaces decodes Ogg Vorbis to 16-bit PCM
(snd_ogg.c), so a 16-bit lossless pack holds exactly the samples DarkPlaces plays (no second lossy
encode). Members of one pack share sample rate and channel count (nothing is resampled); a group whose
members differ gets one pack per (rate, channels).

Output: assets/manifest/audio-plan.tsv (one row per sound vpath) and, with --build-packs,
work/audio/packs/*.flac. The Roblox asset id column stays empty until the uploader (M1-SOUNDS) fills it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GAP_S = 0.5  # silence between packed sounds (owner spec)
LONG_S = 10.0  # sounds longer than this are never packed
MAX_LEN_S = 7 * 60  # Roblox audio asset: up to 7 minutes (G-030)
MAX_BYTES = 20 * 1000 * 1000  # Roblox upload: up to 20 MB per file (G-030); MB taken as 10^6 to be safe
SOUND_EXT = (".ogg", ".wav", ".mp3")
QUOTA_URL = "https://apis.roblox.com/cloud/v2/users/{uid}/asset-quotas"

PICKUP_RE = re.compile(
    r"^sound/(misc/(armor\d|armor17_5|armor25|itempickup|itemrespawn|itemrespawncountdown|mediumhealth"
    r"|megahealth|minihealth|powerup|powerup_shield|shield_respawn|strength_respawn)"
    r"|weapons/(weaponpickup|weaponpickup_new_toys))\.(ogg|wav)$"
)
# Weapon sound file prefix -> weapon (sound/weapons/<prefix>...). Unlisted files go to "weapons/misc".
WEAPON_PREFIX = [
    ("arc_", "arc"), ("campingrifle_", "rifle"), ("crylink_", "crylink"), ("electro_", "electro"),
    ("fireball_", "fireball"), ("flac", "hlac"), ("gauntlet", "gauntlet"), ("grenade_", "mortar"),
    ("hagar_", "hagar"), ("hagexp", "hagar"), ("hookbomb_", "hook"), ("hook_", "hook"),
    ("lasergun_", "blaster"), ("laserimpact", "blaster"), ("lgbeam_", "electro_beam"),
    ("mine_", "minelayer"), ("minstanex", "vaporizer"), ("nex", "vortex"), ("neximpact", "vortex"),
    ("rocket_", "devastator"), ("seeker", "seeker"), ("shotgun_", "shotgun"), ("tag", "tag"),
    ("uzi_", "machinegun"), ("tuba", "tuba"),
]


@dataclass
class Sound:
    vpath: str
    sha256: str
    size: int
    duration: float = 0.0
    rate: int = 0
    channels: int = 0
    codec: str = ""
    loop_start: int | None = None  # sample frame, from the file's own loop marker
    group: str = ""
    packable: bool = False
    reason: str = ""  # why it is not packable
    dup_of: str = ""  # vpath of the first file with the same sha256
    pack: str = ""
    start: float = 0.0
    end: float = 0.0
    notes: list[str] = field(default_factory=list)


def group_of(vpath: str) -> tuple[str, bool, str]:
    """(group, packable group?, reason if not)"""
    parts = vpath.split("/")
    if vpath.startswith("sound/cdtracks/"):
        return "music", False, "music"
    if PICKUP_RE.match(vpath):
        return "pickups", True, ""
    if parts[1] == "announcer" and len(parts) > 3:
        return f"announcer/{parts[2]}", True, ""
    if parts[1] == "player" and len(parts) > 3:
        return f"voice/{parts[2]}", True, ""
    if parts[1] == "weapons" and len(parts) == 3:
        name = parts[2]
        for pre, weapon in WEAPON_PREFIX:
            if name.startswith(pre):
                return f"weapon/{weapon}", True, ""
        return "weapon/misc", True, ""
    return "/".join(parts[1:-1]) or "sound", False, "not a packable group"


def wav_loop_start(data: bytes) -> int | None:
    """snd_wav.c GetWavinfo: loop start from the first 'cue ' chunk (dwSampleOffset at +24)."""
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return None
    i = 12
    while i + 8 <= len(data):
        cid, ln = data[i : i + 4], struct.unpack_from("<I", data, i + 4)[0]
        if cid == b"cue " and i + 8 + 28 <= len(data):
            return struct.unpack_from("<I", data, i + 8 + 24)[0]
        i += 8 + ln + (ln & 1)
    return None


def probe(path: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out)


def analyse(vfs_dir: Path, rows: list[tuple[str, int, str]]) -> list[Sound]:
    sounds: list[Sound] = []
    first: dict[str, str] = {}
    for vpath, size, sha in rows:
        s = Sound(vpath, sha, size)
        s.group, s.packable, s.reason = group_of(vpath)
        p = vfs_dir / vpath
        info = probe(p)
        st = next(x for x in info["streams"] if x["codec_type"] == "audio")
        s.rate, s.channels, s.codec = int(st["sample_rate"]), int(st["channels"]), st["codec_name"]
        s.duration = float(st.get("duration") or info["format"]["duration"])
        tags = {k.upper(): v for k, v in {**info["format"].get("tags", {}), **st.get("tags", {})}.items()}
        for k in ("LOOP_START", "LOOPSTART"):  # snd_ogg.c reads the LOOP_START comment
            if k in tags:
                s.loop_start = int(float(tags[k]))
        if vpath.endswith(".wav"):
            s.loop_start = wav_loop_start(p.read_bytes())
        if vpath.endswith(".mp3"):
            s.notes.append("mp3: DarkPlaces 0.8.6 has no mp3 decoder, so the game never plays this file")
        if s.packable:
            if s.loop_start is not None:
                s.packable, s.reason = False, "has loop marker"
            elif "loop" in vpath.rsplit("/", 1)[1] or vpath.endswith("_fly.ogg"):
                s.packable, s.reason = False, "looping (name: loop/_fly)"
            elif s.duration > LONG_S:
                s.packable, s.reason = False, f"long (> {LONG_S:g} s)"
        if s.duration > MAX_LEN_S:
            s.notes.append(f"longer than {MAX_LEN_S // 60} min: must be split into parts (docs/subsystems/audio.md)")
        if size > MAX_BYTES:
            s.notes.append("file > 20 MB: must be split (docs/subsystems/audio.md)")
        if sha in first:
            s.dup_of = first[sha]
        else:
            first[sha] = vpath
        sounds.append(s)
    return sounds


def plan_packs(sounds: list[Sound], quota: int | None) -> tuple[list[str], int]:
    """Pack whole groups, biggest saving first, only until the unique uploads fit the quota."""
    uniques = [s for s in sounds if not s.dup_of]
    need = len(uniques)
    packed: list[str] = []
    if quota is None or need <= quota:
        return packed, need
    by_key: dict[tuple[str, int, int], list[Sound]] = {}
    for s in uniques:
        if s.packable:
            by_key.setdefault((s.group, s.rate, s.channels), []).append(s)
    for key in sorted(by_key, key=lambda k: (-len(by_key[k]), k)):
        if need <= quota:
            break
        members = sorted(by_key[key], key=lambda s: s.vpath)
        chunks, cur, t = [], [], 0.0
        for s in members:  # split a pack before it would exceed 7 minutes
            if cur and t + GAP_S + s.duration > MAX_LEN_S:
                chunks.append(cur)
                cur, t = [], 0.0
            t += (GAP_S if cur else 0.0) + s.duration
            cur.append(s)
        if cur:
            chunks.append(cur)
        if len(members) - len(chunks) <= 0:
            continue
        group, rate, ch = key
        for n, chunk in enumerate(chunks):
            name = f"{group.replace('/', '_')}_{rate}_{ch}ch" + (f"_{n + 1}" if len(chunks) > 1 else "")
            t, frames = 0.0, 0
            for i, s in enumerate(chunk):
                if i:
                    frames += round(GAP_S * rate)
                s.pack = name
                s.start = frames / rate
                frames += round(s.duration * rate)
                s.end = frames / rate
            packed.append(name)
        need -= len(members) - len(chunks)
    return packed, need


def query_quota(user_id: str) -> tuple[int, dict]:
    """Open Cloud v2 List Asset Quotas (scope asset:read; G-030). Key from $ROBLOX_API_KEY."""
    key = os.environ.get("ROBLOX_API_KEY", "")
    filt = urllib.parse.quote("quotaType == RateLimitUpload && assetType == Audio")
    req = urllib.request.Request(QUOTA_URL.format(uid=user_id) + f"?filter={filt}", headers={"x-api-key": key})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    q = body["assetQuotas"][0]
    return int(q["capacity"]) - int(q.get("usage", 0)), q


def build_packs(vfs_dir: Path, sounds: list[Sound], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    packs: dict[str, list[Sound]] = {}
    for s in sounds:
        if s.pack and not s.dup_of:
            packs.setdefault(s.pack, []).append(s)
    for name, members in packs.items():
        members.sort(key=lambda s: s.start)
        rate, ch = members[0].rate, members[0].channels
        pcm = bytearray()
        for i, s in enumerate(members):
            frames_before = round(s.start * rate)
            pcm += bytes(2 * ch * (frames_before - len(pcm) // (2 * ch)))  # gap of silence
            raw = subprocess.run(
                ["ffmpeg", "-v", "error", "-i", str(vfs_dir / s.vpath), "-f", "s16le", "-acodec", "pcm_s16le", "-"],
                capture_output=True, check=True,
            ).stdout
            want = round(s.end * rate) - frames_before
            raw = raw[: want * 2 * ch].ljust(want * 2 * ch, b"\0")
            pcm += raw
        dst = out_dir / f"{name}.flac"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(rate), "-ac", str(ch), "-i", "-",
             "-sample_fmt", "s16", str(dst)],
            input=bytes(pcm), check=True,
        )
        if dst.stat().st_size > MAX_BYTES:
            sys.exit(f"{dst} is over 20 MB; split the group")


def test_pack(out: Path) -> None:
    """Pack for the [needs Studio] slice test (P-AUDIOSLICE): 8 clicks of 0.1 s, 0.5 s apart, 44.1 kHz mono."""
    rate, n, click = 44100, 8, 4410
    pcm = bytearray()
    for i in range(n):
        if i:
            pcm += bytes(2 * round(GAP_S * rate))
        for j in range(click):  # 1 kHz tone burst at full scale, amplitude rising with the index
            v = int(32767 * (0.3 + 0.7 * i / (n - 1)) * (1 if (j * 1000 * 2 // rate) % 2 == 0 else -1))
            pcm += struct.pack("<h", v)
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(rate), "-ac", "1", "-i", "-", str(out)],
                   input=bytes(pcm), check=True)
    print(f"wrote {out}: slice i = [{0.6:g}*i, {0.6:g}*i + 0.1] s, i = 0..{n - 1}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", default="high", choices=["standard", "high"])
    ap.add_argument("--quota", type=int, help="remaining 30-day audio uploads (overrides --query-quota)")
    ap.add_argument("--query-quota", action="store_true", help="read it from Open Cloud ($ROBLOX_API_KEY)")
    ap.add_argument("--user-id")
    ap.add_argument("--build-packs", action="store_true")
    ap.add_argument("--test-pack", action="store_true")
    a = ap.parse_args()
    if a.test_pack:
        test_pack(ROOT / "work/audio/p-audioslice.flac")
        return
    quota, qinfo = a.quota, None
    if quota is None and a.query_quota:
        if not a.user_id:
            sys.exit("--query-quota needs --user-id")
        quota, qinfo = query_quota(a.user_id)
    vfs_dir = ROOT / f"work/vfs-{a.build}"
    rows = []
    for line in (ROOT / f"assets/manifest/vfs-{a.build}.tsv").read_text().splitlines():
        if line.startswith("#"):
            continue
        vpath, _kind, _pk3, size, sha = line.split("\t")[:5]
        if vpath.startswith("sound/") and vpath.lower().endswith(SOUND_EXT):
            rows.append((vpath, int(size), sha))
    if not (vfs_dir / rows[0][0]).exists():
        sys.exit(f"{vfs_dir} missing: python3 tools/pk3/manifest.py --build {a.build} --extract")
    sounds = analyse(vfs_dir, rows)
    packs, uploads = plan_packs(sounds, quota)
    out = ROOT / "assets/manifest/audio-plan.tsv"
    with open(out, "w") as f:
        f.write("# vpath\tsha256\tupload(file uploaded for it)\tdup_of\tgroup\tpack\tstart_s\tend_s\tduration_s"
                "\trate\tchannels\tcodec\tloop_start\tpackable\treason\tnotes\tasset_id\n")
        for s in sounds:
            src = s.dup_of or s.vpath
            upload = next((x.pack for x in sounds if x.vpath == src), "") or src
            if upload != src:
                upload = f"work/audio/packs/{upload}.flac"
            f.write("\t".join([
                s.vpath, s.sha256, upload, s.dup_of, s.group, s.pack,
                f"{s.start:.6f}" if s.pack else "", f"{s.end:.6f}" if s.pack else "", f"{s.duration:.6f}",
                str(s.rate), str(s.channels), s.codec, "" if s.loop_start is None else str(s.loop_start),
                "yes" if s.packable else "no", s.reason, "; ".join(s.notes), "",
            ]) + "\n")
    dups = sum(1 for s in sounds if s.dup_of)
    total = sum(s.duration for s in sounds if not s.dup_of)
    print(f"{len(sounds)} sound files, {dups} duplicates by sha256 -> {len(sounds) - dups} unique, "
          f"{total / 60:.1f} min of audio")
    print(f"quota: {quota if quota is not None else 'not given (plan = all individual)'}"
          + (f" ({qinfo})" if qinfo else ""))
    print(f"uploads needed: {uploads}; packs: {len(packs)} ({', '.join(packs) or 'none'})")
    for s in sounds:
        if s.notes:
            print(f"note: {s.vpath}: {'; '.join(s.notes)}")
    if quota is not None and uploads > quota:
        print(f"STILL OVER QUOTA by {uploads - quota}: upload the rest after usageResetTime (staged)")
    if a.build_packs:
        build_packs(vfs_dir, sounds, ROOT / "work/audio/packs")
    print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
