--!strict
-- P-AUDIOSLICE [needs Studio] (docs/subsystems/audio.md): can one packed audio asset be played as
-- independent slices? Must pass before any gameplay sound is packed (AUDIO-PLAN rule 8).
-- Asset: `python3 tools/sounds/audio_plan.py --test-pack` -> work/audio/p-audioslice.flac, uploaded by the
-- owner; put its id in the attribute `AudioSliceAssetId` of StarterPlayerScripts.StudioTestsClient.
-- Slice i (0..7) = [0.6*i, 0.6*i + 0.1] s: a 0.1 s 1 kHz burst, louder with i, 0.5 s of silence between.
-- Listen too: part 1 = 8 separate clean beeps getting louder (no click, no late start, no bleed),
-- part 2 = all 8 at once (one loud burst), part 3 = the loudest beep twice, 20 ms apart.
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Report = require("./Report")

local AudioSlice = {}

local N, STEP, LEN = 8, 0.6, 0.1

local function region(i: number): NumberRange
	return NumberRange.new(STEP * i, STEP * i + LEN)
end

local function newSound(id: string, i: number): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.PlaybackRegionsEnabled = true
	s.PlaybackRegion = region(i)
	s.Volume = 1
	s.Parent = SoundService
	return s
end

-- Play s and measure: delay until IsPlaying, TimePosition on the first frames, time until Ended.
local function measure(s: Sound): string
	local t0 = os.clock()
	local ended: number? = nil
	local conn = s.Ended:Connect(function()
		ended = os.clock() - t0
	end)
	s:Play()
	local firstPos = s.TimePosition
	RunService.Heartbeat:Wait()
	local playingAfter = s.IsPlaying
	local pos1 = s.TimePosition
	local dt1 = os.clock() - t0
	local deadline = os.clock() + 2
	while ended == nil and os.clock() < deadline do
		RunService.Heartbeat:Wait()
	end
	conn:Disconnect()
	return string.format(
		"pos@Play=%.4f playing@frame1=%s pos@frame1=%.4f (dt %.4f) ended_after=%s",
		firstPos,
		tostring(playingAfter),
		pos1,
		dt1,
		if ended then string.format("%.4f s", ended) else "no Ended in 2 s"
	)
end

function AudioSlice.run()
	local script = (game:GetService("Players").LocalPlayer :: any).PlayerScripts:FindFirstChild("StudioTestsClient")
	local idNum = if script then script:GetAttribute("AudioSliceAssetId") else nil
	if typeof(idNum) ~= "number" or idNum <= 0 then
		Report.add("P-AUDIOSLICE", "SKIPPED: set attribute AudioSliceAssetId (number) on StudioTestsClient")
		return
	end
	local id = "rbxassetid://" .. tostring(idNum)

	-- 1: each slice alone, measured.
	local sounds: { Sound } = {}
	for i = 0, N - 1 do
		sounds[i + 1] = newSound(id, i)
	end
	ContentProvider:PreloadAsync(sounds :: any)
	Report.add(
		"P-AUDIOSLICE-LEN",
		string.format("TimeLength=%.4f (expect %.1f)", sounds[1].TimeLength, STEP * (N - 1) + LEN)
	)
	for i = 0, N - 1 do
		Report.add(string.format("P-AUDIOSLICE-%d", i), measure(sounds[i + 1]))
		task.wait(0.4)
	end

	-- 2: all slices at once (overlap of different regions of one asset).
	task.wait(1)
	for _, s in sounds do
		s:Play()
	end
	RunService.Heartbeat:Wait()
	local playing = 0
	for _, s in sounds do
		if s.IsPlaying then
			playing += 1
		end
	end
	Report.add("P-AUDIOSLICE-OVERLAP", string.format("%d of %d slices IsPlaying together on frame 1", playing, N))

	-- 3: same region twice, 20 ms apart (rapid fire on one sound).
	task.wait(1)
	local a, b = newSound(id, N - 1), newSound(id, N - 1)
	ContentProvider:PreloadAsync({ a, b } :: any)
	a:Play()
	task.wait(0.02)
	b:Play()
	RunService.Heartbeat:Wait()
	Report.add(
		"P-AUDIOSLICE-SAME",
		string.format("a.IsPlaying=%s b.IsPlaying=%s", tostring(a.IsPlaying), tostring(b.IsPlaying))
	)

	-- 4: AudioPlayer route (M8-SOUND may use the audio API instead of Sound).
	task.wait(1)
	local ok, res = pcall(function()
		local p = Instance.new("AudioPlayer") :: any
		p.Asset = id
		p.PlaybackRegion = region(3)
		local out = Instance.new("AudioDeviceOutput")
		local w = Instance.new("Wire") :: any
		w.SourceInstance = p
		w.TargetInstance = out
		p.Parent, out.Parent, w.Parent = SoundService, SoundService, SoundService
		local deadline = os.clock() + 10
		while not p.IsReady and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end
		local t0 = os.clock()
		local ended: number? = nil
		p.Ended:Connect(function()
			ended = os.clock() - t0
		end)
		p:Play()
		local pos0 = p.TimePosition
		local dl = os.clock() + 2
		while ended == nil and os.clock() < dl do
			RunService.Heartbeat:Wait()
		end
		return string.format(
			"IsReady=%s pos@Play=%.4f ended_after=%s",
			tostring(p.IsReady),
			pos0,
			if ended then string.format("%.4f s", ended) else "no Ended in 2 s"
		)
	end)
	Report.add("P-AUDIOSLICE-AUDIOPLAYER", if ok then res else "ERROR " .. tostring(res))
	Report.add(
		"P-AUDIOSLICE-LISTEN",
		"owner: did you hear 8 clean separate beeps, then one burst, then a double beep? (yes/no + notes)"
	)
end

return AudioSlice
