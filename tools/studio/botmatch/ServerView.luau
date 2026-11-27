--!strict
--[[
	Debug view of a RUNNING SERVER (NOT the game's renderer, not part of the port): shows what the ported server
	holds while a match runs, in Workspace.ServerView:
	  * World: the surfaces of sv.worldmodel as engine/model_brush.luau loaded them (textured MeshParts),
	  * Entities: every edict that has a model. Brush models (doors, plats, "*N") are drawn as their surfaces at
	    the entity's origin and angles; everything else is drawn as its bounding box (mins .. maxs), players with
	    their name. Positions are read from the edict fields after every server frame.
	It exists to look at the server in Roblox Studio while the real client and renderer (M5, M6) do not exist
	yet. What it does NOT do, all of it the renderer's job later: player / item / weapon models, Q3 shaders (the
	first image a shader names is used), lightmaps, sky, fog, particles, transparency, sound, the exact scale.
	Quake axes (x east, y north, z up) become Roblox (x, z, -y); SCALE studs per Quake unit is a viewer choice.
]]
local AssetService = game:GetService("AssetService")

local ServerView = {}

local SCALE = 0.1
local MAX_TRIANGLES = 20000 -- EditableMesh limits (G-002)
local MAX_VERTICES = 60000
local Q3SURFACEFLAG_SKY = 4
local Q3SURFACEFLAG_NODRAW = 128
local EF_NODRAW = 16

type Deps = {
	prvm_edict: any,
	model_shared: any,
	textures: { [string]: number },
}
type Piece = { part: BasePart, offset: CFrame }
type Ent = { key: string, pieces: { Piece }, label: TextLabel?, x: number, y: number, z: number, a: number }

local deps: Deps? = nil
local folder: Folder? = nil
local entfolder: Folder? = nil
local ents: { [number]: Ent } = {}
local texcache: { [string]: number | boolean } = {}

local function toR(x: number, y: number, z: number): Vector3
	return Vector3.new(x * SCALE, z * SCALE, -y * SCALE)
end

local function hashcolor(name: string, s: number, v: number): Color3
	local h = 0
	for c = 1, #name do
		h = (h * 31 + string.byte(name, c)) % 360
	end
	return Color3.fromHSV(h / 360, s, v)
end

-- image of a texture: the image with the shader's own name, else the first image its shader script names
local function textureId(tex: any): number?
	local d = deps :: Deps
	local hit = texcache[tex.name]
	if hit ~= nil then
		return if hit == false then nil else hit :: number
	end
	local names = { tex.name }
	local ok, shader = pcall(d.model_shared.Mod_LookupQ3Shader, tex.name)
	if ok and shader and shader.layers then
		for _, layer in shader.layers do
			local tn = layer.texturename
			if tn and type(tn[1]) == "string" and string.sub(tn[1], 1, 1) ~= "$" then
				table.insert(names, tn[1])
			end
		end
	end
	local found: number? = nil
	for _, n in names do
		local base = string.gsub(n, "%.%a%a%a$", "")
		for _, ext in { ".tga", ".png", ".jpg" } do
			local id = d.textures[base .. ext]
			if id then
				found = id
				break
			end
		end
		if found then
			break
		end
	end
	texcache[tex.name] = found or false
	return found
end

-- surfaces [first, first + count) of a brush model as MeshParts (one or more per texture). Vertex positions are
-- in the model's own space; each piece comes back with its offset from the model origin.
local function meshSurfaces(mod: any, parent: Instance, yield: boolean): ({ Piece }, number, number)
	local sm = mod.surfmesh
	local vertex3f: buffer, normal3f: buffer, tc2f: buffer, element3i: buffer =
		sm.data_vertex3f, sm.data_normal3f, sm.data_texcoordtexture2f, sm.data_element3i
	local bytex: { [any]: { any } } = {}
	local order: { any } = {}
	local triangles = 0
	for i = 0, mod.nummodelsurfaces - 1 do
		local s = mod.data_surfaces[mod.firstmodelsurface + i + 1]
		local tex = s.texture
		if not tex or s.num_triangles == 0 then
			continue
		end
		if bit32.band(tex.surfaceflags, Q3SURFACEFLAG_NODRAW + Q3SURFACEFLAG_SKY) ~= 0 then
			continue
		end
		if string.sub(tex.name, 1, 16) == "textures/common/" then
			continue -- caulk, clip, trigger, ...: tool shaders that are never drawn
		end
		if not bytex[tex] then
			bytex[tex] = {}
			table.insert(order, tex)
		end
		table.insert(bytex[tex], s)
		triangles += s.num_triangles
	end

	local pieces: { Piece } = {}
	local textured = 0
	local function flush(tex: any, tris: { number })
		local minx, miny, minz = math.huge, math.huge, math.huge
		local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
		for _, v in tris do
			local x = buffer.readf32(vertex3f, v * 12) * SCALE
			local y = buffer.readf32(vertex3f, v * 12 + 8) * SCALE
			local z = -buffer.readf32(vertex3f, v * 12 + 4) * SCALE
			minx, miny, minz = math.min(minx, x), math.min(miny, y), math.min(minz, z)
			maxx, maxy, maxz = math.max(maxx, x), math.max(maxy, y), math.max(maxz, z)
		end
		local center = Vector3.new((minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2)
		local em = AssetService:CreateEditableMesh()
		local vid: { [number]: number } = {}
		local uid: { [number]: number } = {}
		local nid: { [number]: number } = {}
		for i = 1, #tris, 3 do
			local ids, uvs, nrm = table.create(3), table.create(3), table.create(3)
			for k = 0, 2 do
				local v = tris[i + k]
				if not vid[v] then
					vid[v] = em:AddVertex(
						toR(
							buffer.readf32(vertex3f, v * 12),
							buffer.readf32(vertex3f, v * 12 + 4),
							buffer.readf32(vertex3f, v * 12 + 8)
						) - center
					)
					uid[v] = em:AddUV(Vector2.new(buffer.readf32(tc2f, v * 8), buffer.readf32(tc2f, v * 8 + 4)))
					nid[v] = em:AddNormal(
						Vector3.new(
							buffer.readf32(normal3f, v * 12),
							buffer.readf32(normal3f, v * 12 + 8),
							-buffer.readf32(normal3f, v * 12 + 4)
						)
					)
				end
				ids[k + 1], uvs[k + 1], nrm[k + 1] = vid[v], uid[v], nid[v]
			end
			local f = em:AddTriangle(ids[1], ids[2], ids[3])
			em:SetFaceUVs(f, uvs)
			em:SetFaceNormals(f, nrm)
		end
		local part = AssetService:CreateMeshPartAsync(Content.fromObject(em))
		part.Name = tex.name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.DoubleSided = true
		part.Material = Enum.Material.SmoothPlastic
		local id = textureId(tex)
		if id then
			part.TextureID = "rbxassetid://" .. tostring(id)
			textured += 1
		else
			part.Color = hashcolor(tex.name, 0.35, 0.75)
		end
		part.CFrame = CFrame.new(center)
		part.Parent = parent
		table.insert(pieces, { part = part, offset = CFrame.new(center) })
	end

	for done, tex in order do
		local tris: { number } = {}
		local seen: { [number]: boolean } = {}
		local nverts = 0
		for _, s in bytex[tex] do
			if #tris // 3 + s.num_triangles > MAX_TRIANGLES or nverts + s.num_vertices > MAX_VERTICES then
				if #tris > 0 then
					flush(tex, tris)
				end
				tris, seen, nverts = {}, {}, 0
			end
			for j = 0, s.num_triangles * 3 - 1 do
				local v = buffer.readi32(element3i, (s.num_firsttriangle * 3 + j) * 4)
				if not seen[v] then
					seen[v] = true
					nverts += 1
				end
				table.insert(tris, v)
			end
			while #tris // 3 > MAX_TRIANGLES do -- one surface alone over the limit: split it by triangles
				local head = table.move(tris, 1, MAX_TRIANGLES * 3, 1, {})
				flush(tex, head)
				tris = table.move(tris, MAX_TRIANGLES * 3 + 1, #tris, 1, {})
			end
		end
		if #tris > 0 then
			flush(tex, tris)
		end
		if yield then
			(folder :: Folder):SetAttribute("Status", string.format("drawing the map: %d / %d textures", done, #order))
			task.wait()
		end
	end
	return pieces, triangles, textured
end

function ServerView.setup(d: Deps): Folder
	deps = d
	local old = workspace:FindFirstChild("ServerView")
	if old then
		old:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "ServerView"
	f:SetAttribute("Status", "starting")
	f.Parent = workspace
	folder = f
	ents = {}
	table.clear(texcache)
	return f
end

function ServerView.status(text: string)
	if folder then
		folder:SetAttribute("Status", text)
	end
end

-- the map itself (yields between textures)
function ServerView.drawWorld(sv: any): string
	local f = folder :: Folder
	local world = Instance.new("Folder")
	world.Name = "World"
	world.Parent = f
	local pieces, triangles, textured = meshSurfaces(sv.worldmodel, world, true)
	local e = Instance.new("Folder")
	e.Name = "Entities"
	e.Parent = f
	entfolder = e
	local msg = string.format("map: %d triangles in %d parts (%d with a texture)", triangles, #pieces, textured)
	f:SetAttribute("World", msg)
	return msg
end

local function stripcolors(s: string): string
	s = string.gsub(s, "%^x%x%x%x", "")
	s = string.gsub(s, "%^%d", "")
	return s
end

local function drop(e: number)
	local ent = ents[e]
	if ent then
		for _, p in ent.pieces do
			p.part:Destroy()
		end
		ents[e] = nil
	end
end

-- every edict with a model, after a server frame
function ServerView.update(sv: any, prog: any)
	local d = deps :: Deps
	local parent = entfolder
	if not parent then
		return
	end
	local FO = d.prvm_edict.FieldOfs
	local o_modelindex, o_origin, o_angles = FO(prog, "modelindex"), FO(prog, "origin"), FO(prog, "angles")
	local o_mins, o_maxs, o_classname = FO(prog, "mins"), FO(prog, "maxs"), FO(prog, "classname")
	local o_netname, o_effects, o_health = FO(prog, "netname"), FO(prog, "effects"), FO(prog, "health")
	local okt, o_tag = pcall(FO, prog, "tag_entity")
	local b: buffer = prog.edictsfields
	local stride: number = prog.entityfields
	local num: number = prog.num_edicts
	local players, shown = 0, 0
	local botline: { string } = {}
	for e = 1, num - 1 do
		local base = e * stride
		local mi = 0
		if not prog.ed_free[e] then
			mi = buffer.readf32(b, (base + o_modelindex) * 4)
			-- hidden (EF_NODRAW: picked-up items), or attached to another entity (weapon models and the like)
			local hidden = bit32.band(buffer.readf32(b, (base + o_effects) * 4), EF_NODRAW) ~= 0
			local attached = okt and o_tag >= 0 and buffer.readi32(b, (base + o_tag) * 4) ~= 0
			if hidden or attached then
				mi = 0
			end
		end
		local mod = if mi > 0 then sv.models[mi] else nil
		if not mod then
			if ents[e] then
				drop(e)
			end
			continue
		end
		local classname: string = d.prvm_edict.PRVM_GetString(prog, buffer.readi32(b, (base + o_classname) * 4))
		local a = (base + o_mins) * 4
		local nx, ny, nz = buffer.readf32(b, a), buffer.readf32(b, a + 4), buffer.readf32(b, a + 8)
		a = (base + o_maxs) * 4
		local xx, xy, xz = buffer.readf32(b, a), buffer.readf32(b, a + 4), buffer.readf32(b, a + 8)
		local isbrush = string.sub(mod.name, 1, 1) == "*"
		local key = if isbrush
			then mod.name
			else string.format("%s %g %g %g %g %g %g", classname, nx, ny, nz, xx, xy, xz)
		local ent = ents[e]
		if ent and ent.key ~= key then
			drop(e)
			ent = nil
		end
		if not ent then
			local pieces: { Piece } = {}
			local label: TextLabel? = nil
			if isbrush then
				local holder = Instance.new("Folder")
				holder.Name = string.format("%d %s %s", e, classname, mod.name)
				holder.Parent = parent
				pieces = meshSurfaces(mod, holder, false)
			else
				local part = Instance.new("Part")
				part.Name = string.format("%d %s", e, classname)
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
				local sx, sy, sz = xx - nx, xy - ny, xz - nz
				if sx <= 0 or sy <= 0 or sz <= 0 then
					nx, ny, nz, xx, xy, xz = -4, -4, -4, 4, 4, 4 -- point entity (projectiles): a small ball
					sx, sy, sz = 8, 8, 8
					part.Shape = Enum.PartType.Ball
					part.Material = Enum.Material.Neon
				else
					part.Material = Enum.Material.SmoothPlastic
				end
				part.Size = Vector3.new(sx * SCALE, sz * SCALE, sy * SCALE)
				if classname == "player" then
					part.Color = Color3.fromHSV((e * 0.19) % 1, 0.9, 1)
					part.Material = Enum.Material.Neon
					local bb = Instance.new("BillboardGui")
					bb.Size = UDim2.fromOffset(220, 28)
					bb.StudsOffset = Vector3.new(0, sz * SCALE / 2 + 1.2, 0)
					bb.AlwaysOnTop = true
					local tl = Instance.new("TextLabel")
					tl.Size = UDim2.fromScale(1, 1)
					tl.BackgroundTransparency = 1
					tl.TextColor3 = Color3.new(1, 1, 1)
					tl.TextStrokeTransparency = 0
					tl.TextSize = 18
					tl.Font = Enum.Font.GothamBold
					tl.Parent = bb
					bb.Parent = part
					label = tl
				else
					part.Color = hashcolor(classname, 0.7, 0.9)
					part.Transparency = 0.25
				end
				part.Parent = parent
				local c = toR((nx + xx) / 2, (ny + xy) / 2, (nz + xz) / 2)
				pieces = { { part = part, offset = CFrame.new(c) } }
			end
			ent = { key = key, pieces = pieces, label = label, x = math.huge, y = 0, z = 0, a = 0 }
			ents[e] = ent
		end
		shown += 1
		a = (base + o_origin) * 4
		local ox, oy, oz = buffer.readf32(b, a), buffer.readf32(b, a + 4), buffer.readf32(b, a + 8)
		a = (base + o_angles) * 4
		local pitch, yaw, roll = buffer.readf32(b, a), buffer.readf32(b, a + 4), buffer.readf32(b, a + 8)
		local asum = if isbrush then pitch * 7 + yaw * 13 + roll * 17 else 0
		if ent.x ~= ox or ent.y ~= oy or ent.z ~= oz or ent.a ~= asum then
			ent.x, ent.y, ent.z, ent.a = ox, oy, oz, asum
			local cf = CFrame.new(toR(ox, oy, oz))
			if isbrush and asum ~= 0 then
				-- matrixlib.c Matrix4x4_CreateFromQuakeEntity, columns mapped to Roblox axes
				local sp, cp = math.sin(math.rad(pitch)), math.cos(math.rad(pitch))
				local sy, cy = math.sin(math.rad(yaw)), math.cos(math.rad(yaw))
				local sr, cr = math.sin(math.rad(roll)), math.cos(math.rad(roll))
				local c0 = toR(cp * cy, cp * sy, -sp)
				local c1 = toR(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, sr * cp)
				local c2 = toR(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp)
				cf = CFrame.fromMatrix(cf.Position, c0.Unit, c2.Unit, -c1.Unit)
			end
			for _, p in ent.pieces do
				p.part.CFrame = cf * p.offset
			end
		end
		if classname == "player" then
			players += 1
			local name = stripcolors(d.prvm_edict.PRVM_GetString(prog, buffer.readi32(b, (base + o_netname) * 4)))
			local health = buffer.readf32(b, (base + o_health) * 4)
			if ent.label then
				ent.label.Text = string.format("%s  %d", name, health)
			end
			local p = toR(ox, oy, oz)
			table.insert(botline, string.format("%s|%.1f|%.1f|%.1f|%d", name, p.X, p.Y, p.Z, health))
		end
	end
	for e in ents do
		if e >= num then
			drop(e)
		end
	end
	local f = folder :: Folder
	f:SetAttribute("Players", table.concat(botline, ";"))
	f:SetAttribute("Shown", shown)
	f:SetAttribute("Edicts", num)
end

return ServerView
