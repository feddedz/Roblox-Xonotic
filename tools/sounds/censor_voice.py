#!/usr/bin/env python3
"""Owner decision D-022: bleep the profanity in the voice lines Roblox moderation rejected (Q-013).

  python3 tools/sounds/censor_voice.py      (needs work/vfs-high; writes work/audio/censored/*.flac)

Word timings come from Whisper medium.en (word timestamps), stored in assets/manifest/audio-censor-whisper.json
(regenerate: openai-whisper, `transcribe(word_timestamps=True)` on each file). Each bad word is replaced by a
1 kHz tone at the word's loudness (5 ms fades): from 80 ms before the word (not before the middle of the
previous word) to where the word's energy fades (not past the next word). Same length, rate and channels;
16-bit lossless FLAC of the decoded samples, so the rest of the line is untouched. Upload with
upload_audio.upload(); the asset replaces the rejected one for that sha256 in roblox-audio.tsv (DIFF-005).
"""
import json, subprocess, math, struct, re, os
import pathlib
ROOT = pathlib.Path(__file__).resolve().parents[2]
os.chdir(ROOT)
d = json.load(open("assets/manifest/audio-censor-whisper.json"))
BAD = re.compile(r"^(bitch|retard|pussy|ass)\b", re.I)
plan = {}
for f, v in d.items():
    words = v["words"]
    spans = [(a, b) for w, a, b in words if BAD.match(w.lower().strip("!,.?"))]
    if f == "player_specop_coms_teamshoot2.ogg":  # Whisper split "retard" into "reached hard" (0.36-1.04)
        spans = [(words[1][1], words[2][2])]
    plan[f] = spans
for f, spans in plan.items():
    src = "work/vfs-high/sound/" + "/".join(f[:-4].split("_", 3)) + ".ogg"
    info = json.loads(subprocess.run(["ffprobe","-v","error","-print_format","json","-show_streams",src],capture_output=True,check=True).stdout)["streams"][0]
    rate, ch = int(info["sample_rate"]), int(info["channels"])
    raw = subprocess.run(["ffmpeg","-v","error","-i",src,"-f","s16le","-acodec","pcm_s16le","-"],capture_output=True,check=True).stdout
    n = len(raw) // (2 * ch)
    s = list(struct.unpack("<%dh" % (n * ch), raw))
    words = d[f]["words"]
    for a, b in spans:
        # neighbours: previous word end / next word start bound the bleep
        prevs = [w for w in words if w[2] <= a + 1e-6]
        prev_end = (prevs[-1][1] + prevs[-1][2]) / 2 if prevs else 0.0  # no earlier than mid previous word
        next_start = min([w[1] for w in words if w[1] >= b - 1e-6] + [n / rate])
        win = int(0.01 * rate)
        def frms(k):
            seg = s[k * ch:(k + win) * ch]
            return math.sqrt(sum(x * x for x in seg) / max(1, len(seg)))
        i0 = max(int(prev_end * rate), int((a - 0.08) * rate), 0)
        i1 = min(int(next_start * rate), n)
        peak = max(frms(k) for k in range(int(a * rate), max(int(a * rate) + 1, int(b * rate) - win), win))
        k = int(b * rate)
        while k + win < i1 and frms(k) > 0.08 * peak:   # extend over the word's tail until it fades
            k += win
        i1 = min(i1, k + int(0.04 * rate))
        seg = s[i0 * ch:i1 * ch]
        rms = math.sqrt(sum(x * x for x in seg) / max(1, len(seg)))
        amp = min(20000, max(3000, rms * 1.2))
        fade = int(0.005 * rate)
        for k in range(i0, i1):
            env = min(1, (k - i0) / fade, (i1 - 1 - k) / fade)
            v = int(amp * env * math.sin(2 * math.pi * 1000 * (k - i0) / rate))
            for c in range(ch):
                s[k * ch + c] = v
    os.makedirs("work/audio/censored", exist_ok=True)
    out = "work/audio/censored/" + f[:-4] + ".flac"
    subprocess.run(["ffmpeg","-v","error","-y","-f","s16le","-ar",str(rate),"-ac",str(ch),"-i","-","-sample_fmt","s16",out],input=struct.pack("<%dh" % len(s), *s),check=True)
    # same length check
    m = int(subprocess.run(["ffprobe","-v","error","-count_packets","-show_entries","stream=duration_ts","-of","csv=p=0",out],capture_output=True,text=True).stdout.strip() or 0)
    print(f, "spans", [(round(a,2),round(b,2)) for a,b in spans], "samples", n, "->", m)

