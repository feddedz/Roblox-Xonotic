--!strict
--[[
	Debug tool (not part of the port): runs a bot match on the ported server inside Roblox Studio and shows it.
	Place: studio-botmatch.project.json (rojo build, open the .rbxl). In Studio, edit mode is enough:
	    require(game.ReplicatedStorage.BotMatch.Run).start()
	    require(game.ReplicatedStorage.BotMatch.Run).stop()
	BotMatch.luau boots the server (config chain, compiled QuakeC, `map`, bots) and steps it; ServerView.luau draws
	the map and the entities. Progress and numbers are attributes of Workspace.ServerView (Status, Error, Frames,
	FrameMs, World, Players, Shown, Edicts).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Run = {}

local conn: RBXScriptConnection? = nil
Run.running = false

local function req(inst: Instance?): any
	return (require :: any)(inst)
end

function Run.stop()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	Run.running = false
end

-- chase camera behind the first player box (viewer convenience; Run.follow = false gives the camera back)
Run.follow = true
local target: BasePart? = nil
local lastpos: Vector3? = nil
local heading = Vector3.new(1, 0, 0)
local function chase(entities: Instance?)
	if not entities then
		return
	end
	if not target or not target.Parent then
		target, lastpos = nil, nil
		for _, p in entities:GetChildren() do
			if p:IsA("BasePart") and string.find(p.Name, " player$") then
				target = p
				break
			end
		end
	end
	local t = target
	if not t then
		return
	end
	local pos = t.Position
	if lastpos then
		local d = (pos - lastpos) * Vector3.new(1, 0, 1)
		if d.Magnitude > 0.02 and d.Magnitude < 5 then -- (a respawn / teleport is not a heading)
			heading = heading:Lerp(d.Unit, 0.08)
		end
	end
	lastpos = pos
	local back = if heading.Magnitude > 0.01 then heading.Unit else Vector3.new(1, 0, 0)
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(pos - back * 13 + Vector3.new(0, 6, 0), pos + Vector3.new(0, 1.5, 0))
end

function Run.start(opts: { map: string?, bots: number? }?)
	if Run.running then
		return
	end
	Run.running = true
	local root = script.Parent :: Instance
	local xonotic = ReplicatedStorage:FindFirstChild("Xonotic") :: Instance
	local engine = xonotic:FindFirstChild("engine") :: Instance
	local gamedata = ServerStorage:FindFirstChild("XonoticGame") :: Instance
	local function eng(name: string): any
		local inst: Instance? = engine
		for seg in string.gmatch(name, "[^/]+") do
			inst = (inst :: Instance):FindFirstChild(seg)
		end
		return req(inst)
	end
	local BotMatch = req(root:FindFirstChild("BotMatch"))
	local ServerView = req(root:FindFirstChild("ServerView"))
	local folder: Folder = ServerView.setup({
		prvm_edict = eng("prvm_edict"),
		model_shared = eng("model_shared"),
		textures = req((xonotic:FindFirstChild("platform") :: any).render.texture_assets),
	})

	task.spawn(function()
		local ok, err = xpcall(function()
			local t0 = os.clock()
			BotMatch.onStatus = function(text: string)
				folder:SetAttribute("Status", text)
			end
			folder:SetAttribute("Status", "loading game data")
			task.wait()
			local vfs = req(gamedata:FindFirstChild("vfs"))
			task.wait()
			local progs = req(gamedata:FindFirstChild("progs"))
			task.wait()
			BotMatch.boot({
				engine = eng,
				progs = progs,
				vfs = vfs,
				yield = task.wait,
				clock = os.clock,
				map = if opts and opts.map then opts.map else "stormkeep",
				bots = if opts and opts.bots then opts.bots else 4,
			})
			folder:SetAttribute("BootSeconds", os.clock() - t0)
			ServerView.drawWorld(BotMatch.sv)
			-- the map's own light is in its lightmaps, which this view does not draw: flat light instead
			local Lighting = game:GetService("Lighting")
			Lighting.Ambient = Color3.fromRGB(200, 200, 200)
			Lighting.OutdoorAmbient = Color3.fromRGB(200, 200, 200)
			Lighting.GlobalShadows = false
			folder:SetAttribute("Status", "running")
			local busy = false
			local total, n = 0, 0
			conn = RunService.Heartbeat:Connect(function(dt: number)
				if busy or not Run.running then
					return
				end
				busy = true
				local t1 = os.clock()
				local okf, e = xpcall(function()
					BotMatch.frame(math.min(dt, 0.1))
					ServerView.update(BotMatch.sv, BotMatch.prog)
					if Run.follow then
						chase(folder:FindFirstChild("Entities"))
					end
				end, debug.traceback)
				total += os.clock() - t1
				n += 1
				if n == 30 then
					folder:SetAttribute("FrameMs", total / n * 1000)
					folder:SetAttribute("Frames", BotMatch.frames)
					total, n = 0, 0
				end
				busy = false
				if not okf then
					folder:SetAttribute("Error", string.sub(tostring(e), 1, 1500))
					folder:SetAttribute("Status", "stopped on an error")
					Run.stop()
				end
			end)
		end, debug.traceback)
		if not ok then
			folder:SetAttribute("Error", string.sub(tostring(err), 1, 1500))
			folder:SetAttribute("Status", "stopped on an error")
			Run.running = false
		end
	end)
end

return Run
