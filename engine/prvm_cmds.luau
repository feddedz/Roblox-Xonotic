--!strict
--[[
	DarkPlaces prvm_cmds.c (common QuakeC builtins), GPLv2 or later (see engine/cvar.luau).
]]
--[[
	Port of prvm_cmds.c @xonotic-v0.8.6. PARTIAL: the cvar builtins and their helpers. Builtins are
	registered by C name in svvm_cmds.PORTED (server); csqc/menu tables later.
	Globals: OFS_RETURN = 1, OFS_PARM0 = 4, parameter i at 4 + 3*i (pr_comp.h), 4-byte slots.
	Also ported: the surface builtins (getsurface* #434-#439, #486, #628, #629 with getmodel, animatemodel for
	unanimated models, the applytransform helpers, clippointtosurface) and uri_get #513 (no-libcurl path).
	NOT YET PORTED: everything else in prvm_cmds.c (stubs in engine/svvm_cmds.luau log it).
]]
local cvar = require("./cvar")
local cmd = require("./cmd")
local console = require("./console")
local libc = require("./_port/libc")
local prvm_edict = require("./prvm_edict")
local utf8lib = require("./utf8lib")
local filematch = require("./filematch")
local common = require("./common")
local f32 = require("./_port/f32")
local libm = require("./_port/libm")
local fs = require("./fs")
local mdfour = require("./mdfour")
local sha256 = require("./_port/sha256")
local mathlib = require("./mathlib")
local host_cmd = require("./host_cmd")
local matrixlib = require("./matrixlib")

local prvm_cmds = {}

local OFS_RETURN, OFS_PARM0 = 1, 4
local VM_STRINGTEMP_LENGTH = 16384 -- prvm_cmds.h: MAX_INPUTLINE

local function G_STRING(prog: any, ofs: number): string
	return prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, ofs * 4))
end
local function SET_G_FLOAT(prog: any, ofs: number, v: number)
	buffer.writef32(prog.globals, ofs * 4, v)
end
local function SET_G_INT(prog: any, ofs: number, v: number)
	buffer.writei32(prog.globals, ofs * 4, v)
end

local function G_FLOAT(prog: any, ofs: number): number
	return buffer.readf32(prog.globals, ofs * 4)
end

-- VM_SAFEPARMCOUNT (prvm_cmds.h L207)
local function SAFEPARMCOUNT(prog: any, p: number, f: string)
	if prog.argc ~= p then
		prog.error_cmd(string.format("%s wrong parameter count %i (%d expected ) !", f, prog.argc, p))
	end
end

-- VM_SAFEPARMCOUNTRANGE (prvm_cmds.h L206)
local function SAFEPARMCOUNTRANGE(prog: any, p1: number, p2: number, f: string)
	if prog.argc < p1 or prog.argc > p2 then
		prog.error_cmd(string.format("%s wrong parameter count %i (%d to %d expected ) !", f, prog.argc, p1, p2))
	end
end

-- port: prvm_cmds.c VM_Warning L25-44 @xonotic-v0.8.6 (prvm_backtraceforwarnings state dump not ported)
function prvm_cmds.VM_Warning(_prog: any, fmt: string, ...: any)
	console.Con_Print(libc.snprintf(16384, fmt, ...))
end

-- port: prvm_cmds.c VM_CheckEmptyString L55-59 @xonotic-v0.8.6
function prvm_cmds.VM_CheckEmptyString(prog: any, s: string)
	local c = string.byte(s, 1) or 0
	if c == 0 or c == 32 or c == 9 or c == 13 or c == 10 then
		prog.error_cmd(string.format("%s: Bad string", prog.name))
	end
end

--[[
	Frame blends and edict skeletons (prvm_cmds.c L61-231). The per-edict private data they fill
	(ed->priv.server->framegroupblend[MAX_FRAMEGROUPBLENDS], frameblend[MAX_FRAMEBLENDS], skeleton) is held per prog:
	prog.ed_framegroupblend[e] = 4 x { frame, lerp, start } (C element i at [i + 1]), prog.ed_frameblend[e] = the
	frameblend_t array of engine/model_alias.luau (8 x { subframe, lerp }), prog.ed_skeleton[e] = skeleton_t
	{ model, relativetransforms } (relativetransforms nil = NULL). prvm_cmds.EdictFrameBlend returns the three of
	an edict (created zeroed on first use, as the zeroed priv memory). prog.skeletons[i] (0-based, nil = NULL) are
	the skeleton objects of the skel_* builtins.
]]
local MAX_FRAMEGROUPBLENDS = 4 -- protocol.h L349
local MAX_FRAMEBLENDS = MAX_FRAMEGROUPBLENDS * 2 -- client.h L480
local MAX_EDICTS = 32768 -- quakedef.h

-- port support: the priv.server frame blend data of edict e (see above)
function prvm_cmds.EdictFrameBlend(prog: any, e: number): (any, any, any)
	local fgbs = prog.ed_framegroupblend
	if not fgbs then
		fgbs = {}
		prog.ed_framegroupblend = fgbs
		prog.ed_frameblend = {}
		prog.ed_skeleton = {}
	end
	local fgb = fgbs[e]
	if not fgb then
		fgb = table.create(MAX_FRAMEGROUPBLENDS)
		for i = 1, MAX_FRAMEGROUPBLENDS do
			fgb[i] = { frame = 0, lerp = 0, start = 0 }
		end
		fgbs[e] = fgb
		local fb = table.create(MAX_FRAMEBLENDS)
		for i = 1, MAX_FRAMEBLENDS do
			fb[i] = { subframe = 0, lerp = 0 }
		end
		prog.ed_frameblend[e] = fb
		prog.ed_skeleton[e] = { model = nil, relativetransforms = nil }
	end
	return fgb, prog.ed_frameblend[e], prog.ed_skeleton[e]
end

-- PRVM_gameedictfloat(ed, name) (0 when the progs lack the field)
local function edfloat(prog: any, base: number, name: string): number
	local o = prvm_edict.FieldOfs(prog, name)
	if o < 0 then
		return 0
	end
	return buffer.readf32(prog.edictsfields, (base + o) * 4)
end

-- port: prvm_cmds.c VM_GenerateFrameGroupBlend L61-85 @xonotic-v0.8.6
function prvm_cmds.VM_GenerateFrameGroupBlend(prog: any, framegroupblend: any, ed: number)
	local R = f32.round
	local base = ed * prog.entityfields
	-- self.frame is the interpolation target (new frame)
	-- self.frame1time is the animation base time for the interpolation target
	-- self.frame2 is the interpolation start (previous frame)
	-- self.frame2time is the animation base time for the interpolation start
	-- self.lerpfrac is the interpolation strength for self.frame2
	-- self.lerpfrac3 is the interpolation strength for self.frame3
	-- self.lerpfrac4 is the interpolation strength for self.frame4
	-- pitch angle on a player model where the animator set up 5 sets of
	-- animations and the csqc simply lerps between sets)
	framegroupblend[1].frame = libc.toint(edfloat(prog, base, "frame"))
	framegroupblend[2].frame = libc.toint(edfloat(prog, base, "frame2"))
	framegroupblend[3].frame = libc.toint(edfloat(prog, base, "frame3"))
	framegroupblend[4].frame = libc.toint(edfloat(prog, base, "frame4"))
	framegroupblend[1].start = edfloat(prog, base, "frame1time") -- (double start = float field: exact)
	framegroupblend[2].start = edfloat(prog, base, "frame2time")
	framegroupblend[3].start = edfloat(prog, base, "frame3time")
	framegroupblend[4].start = edfloat(prog, base, "frame4time")
	framegroupblend[2].lerp = edfloat(prog, base, "lerpfrac")
	framegroupblend[3].lerp = edfloat(prog, base, "lerpfrac3")
	framegroupblend[4].lerp = edfloat(prog, base, "lerpfrac4")
	-- assume that the (missing) lerpfrac1 is whatever remains after lerpfrac2+lerpfrac3+lerpfrac4 are summed
	framegroupblend[1].lerp = R(R(R(1 - framegroupblend[2].lerp) - framegroupblend[3].lerp) - framegroupblend[4].lerp)
end

-- r_lerpmodels / r_lerpsprites (gl_rmain.c) are registered by the renderer only: on a dedicated server the
-- static cvar_t was never registered and its .integer is 0 (Cvar_RegisterVariable parses the default string),
-- so nolerp is true there. Engine behaviour kept: a dedicated server never blends between frames here.
local function cvar_integer_unregistered0(name: string): number
	local c = cvar.Cvar_FindVar(name)
	return if c then c.integer else 0
end

-- LordHavoc: quite tempting to break apart this function to reuse the
--            duplicated code, but I suspect it is better for performance
--            this way
-- port: prvm_cmds.c VM_FrameBlendFromFrameGroupBlend L90-189 @xonotic-v0.8.6
-- (curtime is a double; blend[i].lerp is a float: each += is rounded)
function prvm_cmds.VM_FrameBlendFromFrameGroupBlend(frameblend: any, framegroupblend: any, model: any, curtime: number)
	local R = f32.round
	local sub2, numframes, f
	local isfirstframegroup = true
	local nolerp
	local sublerp, lerp, d
	local scene
	local blend = frameblend

	for i = 1, MAX_FRAMEBLENDS do
		blend[i].subframe = 0
		blend[i].lerp = 0
	end

	-- rpolzer: Not testing isanimated here - a model might have
	-- "animations" that move no vertices (but only bones), thus rendering
	-- may assume it's not animated while processing can't.
	if not model then
		blend[1].lerp = 1
		return
	end

	nolerp = if model.type == "mod_sprite"
		then cvar_integer_unregistered0("r_lerpsprites") == 0
		else cvar_integer_unregistered0("r_lerpmodels") == 0
	numframes = model.numframes or 0
	for k = 1, MAX_FRAMEGROUPBLENDS do
		local g = framegroupblend[k]
		f = g.frame
		if f < 0 or f >= numframes then -- (unsigned int)f >= (unsigned int)numframes
			if cvar_integer_unregistered0("developer_extra") ~= 0 then
				console.Con_DPrintf("VM_FrameBlendFromFrameGroupBlend: no such frame %d in model %s\n", f, model.name)
			end
			f = 0
		end
		lerp = g.lerp
		d = lerp
		if lerp <= 0 then
			continue
		end
		if nolerp then
			if isfirstframegroup then
				lerp = 1
				d = 1
				isfirstframegroup = false
			else
				continue
			end
		end
		if model.animscenes then
			scene = model.animscenes[f + 1]
			f = scene.firstframe
			if scene.framecount > 1 then
				-- this code path is only used on .zym models and torches
				sublerp = scene.framerate * (curtime - g.start)
				f = libc.toint(math.floor(sublerp))
				sublerp -= f
				sub2 = f + 1
				if sublerp < (1.0 / 65536.0) then
					sublerp = 0
				end
				if sublerp > R(65535.0 / 65536.0) then
					sublerp = 1
				end
				if nolerp then
					sublerp = 0
				end
				if scene.loop then
					-- (C % truncates toward zero)
					f = math.sign(f) * (math.abs(f) % scene.framecount)
					sub2 = math.sign(sub2) * (math.abs(sub2) % scene.framecount)
				end
				-- bound(0, x, framecount - 1)
				f = (if f < 0 then 0 elseif f > scene.framecount - 1 then scene.framecount - 1 else f)
					+ scene.firstframe
				sub2 = (if sub2 < 0 then 0 elseif sub2 > scene.framecount - 1 then scene.framecount - 1 else sub2)
					+ scene.firstframe
				d = sublerp * lerp
				-- two framelerps produced from one animation
				if d > 0 then
					for i = 1, MAX_FRAMEBLENDS do
						if blend[i].lerp <= 0 or blend[i].subframe == sub2 then
							blend[i].subframe = sub2
							blend[i].lerp = R(blend[i].lerp + d)
							break
						end
					end
				end
				d = (1 - sublerp) * lerp
			end
		end
		if d > 0 then
			for i = 1, MAX_FRAMEBLENDS do
				if blend[i].lerp <= 0 or blend[i].subframe == f then
					blend[i].subframe = f
					blend[i].lerp = R(blend[i].lerp + d)
					break
				end
			end
		end
	end
end

-- port: prvm_cmds.c VM_UpdateEdictSkeleton L191-224 @xonotic-v0.8.6
function prvm_cmds.VM_UpdateEdictSkeleton(prog: any, ed: number, edmodel: any, _frameblend: any)
	local _, _, edskeleton = prvm_cmds.EdictFrameBlend(prog, ed)
	if edskeleton.model ~= edmodel then
		prvm_cmds.VM_RemoveEdictSkeleton(prog, ed)
		edskeleton.model = edmodel
	end
	if not edskeleton.model or (edskeleton.model.num_bones or 0) == 0 then
		-- Mem_Free(relativetransforms)
		edskeleton.relativetransforms = nil
		return
	end

	do
		local skeletonindex = -1
		local skeleton
		skeletonindex = libc.toint(edfloat(prog, ed * prog.entityfields, "skeletonindex")) - 1
		skeleton = if skeletonindex >= 0
				and skeletonindex < MAX_EDICTS
				and prog.skeletons
			then prog.skeletons[skeletonindex]
			else nil
		if skeleton and skeleton.model.num_bones == edskeleton.model.num_bones then
			-- custom skeleton controlled by the game (FTE_CSQC_SKELETONOBJECTS)
			if not edskeleton.relativetransforms then
				edskeleton.relativetransforms = table.create(edskeleton.model.num_bones)
				for i = 1, edskeleton.model.num_bones do
					edskeleton.relativetransforms[i] = matrixlib.new()
				end
			end
			-- memcpy(relativetransforms, skeleton->relativetransforms, num_bones * sizeof(matrix4x4_t))
			for i = 1, edskeleton.model.num_bones do
				local src, dst = skeleton.relativetransforms[i], edskeleton.relativetransforms[i]
				for k = 1, 4 do
					for j = 1, 4 do
						dst.m[k][j] = src.m[k][j]
					end
				end
			end
		else
			-- Mem_Free(relativetransforms)
			edskeleton.relativetransforms = nil
		end
	end
end

-- port: prvm_cmds.c VM_RemoveEdictSkeleton L226-231 @xonotic-v0.8.6
function prvm_cmds.VM_RemoveEdictSkeleton(prog: any, ed: number)
	local _, _, edskeleton = prvm_cmds.EdictFrameBlend(prog, ed)
	-- Mem_Free(relativetransforms); memset(&skeleton, 0, sizeof(skeleton))
	edskeleton.relativetransforms = nil
	edskeleton.model = nil
end

-- port: prvm_cmds.c VM_VarString L239-253 @xonotic-v0.8.6
function prvm_cmds.VM_VarString(prog: any, first: number, outlength: number): string
	local parts = {}
	local room = outlength - 1
	local i = first
	while i < prog.argc and room > 0 do
		local s = libc.cstr(G_STRING(prog, OFS_PARM0 + i * 3))
		if #s > room then
			s = string.sub(s, 1, room)
		end
		table.insert(parts, s)
		room -= #s
		i += 1
	end
	return table.concat(parts)
end

-- port: prvm_cmds.c PRVM_Cvar_ReadOk L623-628 @xonotic-v0.8.6
local function PRVM_Cvar_ReadOk(s: string): boolean
	local c = cvar.Cvar_FindVar(s)
	return c ~= nil and bit32.band(c.flags, cvar.CVAR_PRIVATE) == 0
end

-- port: prvm_cmds.c VM_cvar L637-644 @xonotic-v0.8.6
function prvm_cmds.VM_cvar(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_FLOAT(prog, OFS_RETURN, if PRVM_Cvar_ReadOk(s) then cvar.Cvar_VariableValue(s) else 0)
end

-- port: prvm_cmds.c VM_cvar_type L659-690 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_type(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	local c = cvar.Cvar_FindVar(s)
	if not c then
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return -- CVAR_TYPE_NONE
	end
	local ret = 1 -- CVAR_EXISTS
	if bit32.band(c.flags, cvar.CVAR_SAVE) ~= 0 then
		ret = bit32.bor(ret, 2) -- CVAR_TYPE_SAVED
	end
	if bit32.band(c.flags, cvar.CVAR_PRIVATE) ~= 0 then
		ret = bit32.bor(ret, 4) -- CVAR_TYPE_PRIVATE
	end
	if bit32.band(c.flags, cvar.CVAR_ALLOCATED) == 0 then
		ret = bit32.bor(ret, 8) -- CVAR_TYPE_ENGINE
	end
	if c.description ~= cvar.cvar_dummy_description then
		ret = bit32.bor(ret, 16) -- CVAR_TYPE_HASDESCRIPTION
	end
	if bit32.band(c.flags, cvar.CVAR_READONLY) ~= 0 then
		ret = bit32.bor(ret, 32) -- CVAR_TYPE_READONLY
	end
	SET_G_FLOAT(prog, OFS_RETURN, ret)
end

-- port: prvm_cmds.c VM_cvar_string L699-706 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_string(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar_string")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_INT(
		prog,
		OFS_RETURN,
		prvm_edict.PRVM_SetTempString(prog, if PRVM_Cvar_ReadOk(s) then cvar.Cvar_VariableString(s).str else "")
	)
end

-- port: prvm_cmds.c VM_cvar_defstring L716-723 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_defstring(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar_defstring")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, cvar.Cvar_VariableDefString(s).str))
end

-- port: prvm_cmds.c VM_cvar_description L732-739 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_description(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_cvar_description")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	prvm_cmds.VM_CheckEmptyString(prog, s)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, cvar.Cvar_VariableDescription(s).str))
end

-- port: prvm_cmds.c VM_cvar_set L747-756 @xonotic-v0.8.6
function prvm_cmds.VM_cvar_set(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_cvar_set")
	local s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	local name = G_STRING(prog, OFS_PARM0)
	prvm_cmds.VM_CheckEmptyString(prog, name)
	cvar.Cvar_Set(name, s)
end

-- port: prvm_cmds.c VM_registercvar L1642-1671 @xonotic-v0.8.6
function prvm_cmds.VM_registercvar(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_registercvar")
	local name = G_STRING(prog, OFS_PARM0)
	local value = G_STRING(prog, OFS_PARM0 + 3)
	local flags = if prog.argc >= 3 then libc.toint(buffer.readf32(prog.globals, (OFS_PARM0 + 6) * 4)) else 0
	SET_G_FLOAT(prog, OFS_RETURN, 0)
	if flags > cvar.CVAR_MAXFLAGSVAL then
		return
	end
	-- first check to see if it has already been defined
	if cvar.Cvar_FindVar(name) then
		return
	end
	-- check for overlap with a command
	if cmd.Cmd_Exists(name) then
		prvm_cmds.VM_Warning(prog, "VM_registercvar: %s is a command\n", name)
		return
	end
	cvar.Cvar_Get(name, value, flags, nil)
	SET_G_FLOAT(prog, OFS_RETURN, 1) -- success
end

-- port: prvm_cmds.c VM_print L373-379 @xonotic-v0.8.6
function prvm_cmds.VM_print(prog: any)
	console.Con_Print(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
end

-- port: prvm_cmds.c VM_ftos L785-799 @xonotic-v0.8.6
function prvm_cmds.VM_ftos(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_ftos")
	local v = G_FLOAT(prog, OFS_PARM0)
	local s
	if f32.round(libc.toint(v)) == v then
		s = string.format("%.0f", v)
	else
		s = string.format("%f", v)
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, libc.snprintf(128, "%s", s)))
end

-- port: prvm_cmds.c VM_stof L862-868 @xonotic-v0.8.6
function prvm_cmds.VM_stof(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_stof")
	SET_G_FLOAT(prog, OFS_RETURN, libc.atof(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)))
end

-- port: prvm_cmds.c VM_floor L1433-1438 @xonotic-v0.8.6
function prvm_cmds.VM_floor(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_floor")
	SET_G_FLOAT(prog, OFS_RETURN, math.floor(G_FLOAT(prog, OFS_PARM0)))
end

-- port: prvm_cmds.c VM_pow L1750-1754 @xonotic-v0.8.6
function prvm_cmds.VM_pow(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_pow")
	SET_G_FLOAT(prog, OFS_RETURN, libm.pow(G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3)))
end

-- port: prvm_cmds.c VM_strlen L2170-2176 @xonotic-v0.8.6
function prvm_cmds.VM_strlen(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strlen")
	SET_G_FLOAT(prog, OFS_RETURN, utf8lib.u8_strlen(G_STRING(prog, OFS_PARM0)))
end

-- port: prvm_cmds.c VM_strcat L2279-2286 @xonotic-v0.8.6
function prvm_cmds.VM_strcat(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_strcat")
	SET_G_INT(
		prog,
		OFS_RETURN,
		prvm_edict.PRVM_SetTempString(prog, prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
	)
end

-- port: prvm_cmds.c VM_substring L2297-2359 @xonotic-v0.8.6
function prvm_cmds.VM_substring(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_substring")
	local s = libc.cstr(G_STRING(prog, OFS_PARM0))
	local start = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local length = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local u_slength = 0
	if start < 0 then -- FTE_STRINGS feature
		u_slength = utf8lib.u8_strlen(s)
		start += u_slength
		start = math.clamp(start, 0, u_slength)
	end
	if length < 0 then -- FTE_STRINGS feature
		if u_slength == 0 then -- it's not calculated when it's not needed above
			u_slength = utf8lib.u8_strlen(s)
		end
		length += u_slength - start + 1
	end
	local u_start = utf8lib.u8_byteofs(s, start)
	if u_start < 0 then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, ""))
		return
	end
	local u_length = utf8lib.u8_bytelen(s, 1 + u_start, length)
	if u_length >= VM_STRINGTEMP_LENGTH - 1 then
		u_length = VM_STRINGTEMP_LENGTH - 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, string.sub(s, 1 + u_start, u_start + u_length)))
end

-- port: prvm_cmds.c VM_strzone L2521-2533 @xonotic-v0.8.6
function prvm_cmds.VM_strzone(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strzone")
	local s = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_AllocString(prog, #s + 1, s))
end

-- port: prvm_cmds.c VM_strunzone L2543-2547 @xonotic-v0.8.6
function prvm_cmds.VM_strunzone(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strunzone")
	prvm_edict.PRVM_FreeString(prog, buffer.readi32(prog.globals, OFS_PARM0 * 4))
end

-- port: prvm_cmds.c VM_str2chr L5671-5690 @xonotic-v0.8.6
function prvm_cmds.VM_str2chr(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_str2chr")
	local s = libc.cstr(G_STRING(prog, OFS_PARM0))
	local index = utf8lib.u8_bytelen(s, 1, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3)))
	index = libc.toint(index) -- (int) of the size_t result
	local uindex = if index < 0 then index + 4294967296 else index -- (unsigned)
	if uindex < #s then
		local ch
		if utf8lib.enabled() then
			ch = (utf8lib.u8_getchar_utf8_enabled(s, 1 + index))
		else
			ch = string.byte(s, 1 + index)
		end
		SET_G_FLOAT(prog, OFS_RETURN, ch)
	else
		SET_G_FLOAT(prog, OFS_RETURN, 0)
	end
end

-- strcmp / strncmp result as glibc returns it: difference of the first differing bytes (unsigned)
local function cmpbytes(a: string, b: string, n: number): number
	local i = 1
	while i <= n do
		local x, y = string.byte(a, i) or 0, string.byte(b, i) or 0
		if x ~= y then
			return x - y
		end
		if x == 0 then
			return 0
		end
		i += 1
	end
	return 0
end

-- port: prvm_cmds.c VM_strncmp L5898-5912 @xonotic-v0.8.6
function prvm_cmds.VM_strncmp(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_strncmp")
	local s1 = libc.cstr(G_STRING(prog, OFS_PARM0))
	local s2 = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	if prog.argc > 2 then
		local n = G_FLOAT(prog, OFS_PARM0 + 6)
		n = if n < 0 then math.huge else math.floor(n) -- (size_t) of a float
		SET_G_FLOAT(prog, OFS_RETURN, cmpbytes(s1, s2, n))
	else
		SET_G_FLOAT(prog, OFS_RETURN, cmpbytes(s1, s2, math.huge))
	end
end

local function RETURN_EDICT(prog: any, e: number)
	buffer.writei32(prog.globals, OFS_RETURN * 4, e)
end

-- port: prvm_cmds.c VM_spawn L969-976 @xonotic-v0.8.6 (builtinsprofile counters: profiling only)
function prvm_cmds.VM_spawn(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_spawn")
	RETURN_EDICT(prog, prvm_edict.PRVM_ED_Alloc(prog))
end

-- port: prvm_cmds.c VM_remove L986-1006 @xonotic-v0.8.6
function prvm_cmds.VM_remove(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_remove")
	local e = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local dev = cvar.Cvar_FindVar("developer")
	if e <= prog.reserved_edicts then
		if dev and dev.integer > 0 then
			prvm_cmds.VM_Warning(prog, "VM_remove: tried to remove the null entity or a reserved entity!\n")
		end
	elseif prog.ed_free[e] then
		if dev and dev.integer > 0 then
			prvm_cmds.VM_Warning(prog, "VM_remove: tried to remove an already freed entity!\n")
		end
	else
		prvm_edict.PRVM_ED_Free(prog, e)
	end
end

-- port: prvm_cmds.c VM_nextent L1462-1486 @xonotic-v0.8.6
function prvm_cmds.VM_nextent(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_nextent")
	local i = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	while true do
		i += 1
		if i == prog.num_edicts then
			RETURN_EDICT(prog, 0)
			return
		end
		if not prog.ed_free[i] then
			RETURN_EDICT(prog, i)
			return
		end
	end
end

-- port: prvm_cmds.c VM_ftoe L890-900 @xonotic-v0.8.6
function prvm_cmds.VM_ftoe(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_ftoe")
	local ent = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if ent < 0 or ent >= prog.max_edicts or prog.ed_free[ent] then
		ent = 0 -- return world instead of a free or invalid entity
	end
	SET_G_INT(prog, OFS_RETURN, ent)
end

-- port: prvm_cmds.c VM_etof L909-913 @xonotic-v0.8.6
function prvm_cmds.VM_etof(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_etof")
	SET_G_FLOAT(prog, OFS_RETURN, buffer.readi32(prog.globals, OFS_PARM0 * 4))
end

-- port: prvm_cmds.c VM_bound L1735-1739 @xonotic-v0.8.6 (mathlib.h bound macro)
function prvm_cmds.VM_bound(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_bound")
	local mn, num, mx = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3), G_FLOAT(prog, OFS_PARM0 + 6)
	SET_G_FLOAT(prog, OFS_RETURN, if num >= mn then (if num < mx then num else mx) else mn)
end

--[[ String buffers (prvm_stringbuffer_t in prog->stringbuffersarray). Mem_ExpandableArray hands out the
lowest free record index, which is the buffer number QC sees; a record is
{ strings = { [0..] = string|nil }, num_strings, max_strings, flags }. ]]
local STRINGBUFFER_QCFLAGS = 1 -- progsvm.h L517

local function buffers(prog: any): { [number]: any }
	prog.stringbuffersarray = prog.stringbuffersarray or {}
	return prog.stringbuffersarray
end
-- Mem_ExpandableArray_RecordAtIndex: nil for negative / unallocated indices
local function RecordAtIndex(prog: any, i: number): any
	if i < 0 then
		return nil
	end
	return buffers(prog)[i]
end

-- port: prvm_cmds.c BufStr_Expand L4593-4607 @xonotic-v0.8.6
local function BufStr_Expand(sb: any, strindex: number)
	if sb.max_strings <= strindex then
		sb.max_strings = math.max(sb.max_strings * 2, 128)
		while sb.max_strings <= strindex do
			sb.max_strings *= 2
		end
	end
end

-- port: prvm_cmds.c BufStr_Shrink L4609-4623 @xonotic-v0.8.6
local function BufStr_Shrink(sb: any)
	while sb.num_strings > 0 and sb.strings[sb.num_strings - 1] == nil do
		sb.num_strings -= 1
	end
	if sb.num_strings == 0 then
		sb.max_strings = 0
		sb.strings = {}
	end
end

-- port: prvm_cmds.c BufStr_Set L4680-4702 @xonotic-v0.8.6
local function BufStr_Set(sb: any, strindex: number, str: string?)
	if not sb or strindex < 0 then
		return
	end
	BufStr_Expand(sb, strindex)
	sb.num_strings = math.max(sb.num_strings, strindex + 1)
	sb.strings[strindex] = if str then libc.cstr(str :: string) else nil
	BufStr_Shrink(sb)
end
prvm_cmds.BufStr_Set = BufStr_Set

-- port: prvm_cmds.c VM_buf_create L4742-4762 @xonotic-v0.8.6
function prvm_cmds.VM_buf_create(prog: any)
	SAFEPARMCOUNTRANGE(prog, 0, 2, "VM_buf_create")
	if prog.argc >= 1 and G_STRING(prog, OFS_PARM0) ~= "string" then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		return
	end
	local arr = buffers(prog)
	local i = 0
	while arr[i] ~= nil do
		i += 1
	end
	local sb = { strings = {}, num_strings = 0, max_strings = 0, flags = 0 }
	arr[i] = sb
	if prog.argc >= 2 then
		sb.flags = bit32.band(libc.toint(G_FLOAT(prog, OFS_PARM0 + 3)), STRINGBUFFER_QCFLAGS)
	end
	SET_G_FLOAT(prog, OFS_RETURN, i)
end

-- port: prvm_cmds.c VM_buf_del L4773-4785 @xonotic-v0.8.6 (BufStr_Del L4704-4719)
function prvm_cmds.VM_buf_del(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_buf_del")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if RecordAtIndex(prog, n) then
		buffers(prog)[n] = nil
	else
		prvm_cmds.VM_Warning(prog, "VM_buf_del: invalid buffer %i used in %s\n", n, prog.name)
	end
end

-- port: prvm_cmds.c VM_buf_getsize L4794-4808 @xonotic-v0.8.6
function prvm_cmds.VM_buf_getsize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_buf_getsize")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		prvm_cmds.VM_Warning(prog, "VM_buf_getsize: invalid buffer %i used in %s\n", n, prog.name)
	else
		SET_G_FLOAT(prog, OFS_RETURN, sb.num_strings)
	end
end

-- port: prvm_cmds.c VM_bufstr_get L4947-4968 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_get(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_bufstr_get")
	SET_G_INT(prog, OFS_RETURN, 0) -- OFS_NULL
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_get: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local strindex = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if strindex < 0 then
		return
	end
	if strindex < sb.num_strings and sb.strings[strindex] then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, sb.strings[strindex]))
	end
end

-- port: prvm_cmds.c VM_bufstr_set L4977-5000 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_set(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_bufstr_set")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_set: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local strindex = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if strindex < 0 or strindex >= 1000000 then -- huge number of strings
		prvm_cmds.VM_Warning(prog, "VM_bufstr_set: invalid string index %i used in %s\n", strindex, prog.name)
		return
	end
	BufStr_Set(sb, strindex, G_STRING(prog, OFS_PARM0 + 6))
end

-- port: prvm_cmds.c VM_buf_cvarlist L5434-5508 @xonotic-v0.8.6
function prvm_cmds.VM_buf_cvarlist(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_buf_cvarlist")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_free: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local partial = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local len = #partial
	local antipartial = if prog.argc == 3 then libc.cstr(G_STRING(prog, OFS_PARM0 + 6)) else nil
	local antilen = if antipartial then #(antipartial :: string) else 0
	local ispattern = string.find(partial, "[%*%?]") ~= nil
	local antiispattern = antipartial ~= nil and string.find(antipartial :: string, "[%*%?]") ~= nil
	local list = {}
	local count = 0
	local v = cvar.cvar_vars
	while v do
		local skip = false
		if len > 0 then
			if ispattern then
				skip = not filematch.matchpattern_with_separator(v.name, partial, false, "", false)
			else
				skip = string.sub(v.name, 1, len) ~= partial
			end
		end
		if not skip and antilen > 0 then
			if antiispattern then
				skip = filematch.matchpattern_with_separator(v.name, antipartial :: string, false, "", false)
			else
				skip = string.sub(v.name, 1, antilen) == antipartial
			end
		end
		if not skip then
			list[count] = v.name -- 0-based like the C array
			count += 1
		end
		v = v.next
	end
	sb.strings = list
	sb.max_strings, sb.num_strings = count, count
end

-- port: prvm_cmds.c VM_localcmd L615-621 @xonotic-v0.8.6
function prvm_cmds.VM_localcmd(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_localcmd")
	cmd.Cbuf_AddText(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
end

-- port: prvm_cmds.c VM_min L1683-1698 @xonotic-v0.8.6
function prvm_cmds.VM_min(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_min")
	if prog.argc >= 3 then
		local f = G_FLOAT(prog, OFS_PARM0)
		for i = 1, prog.argc - 1 do
			local x = G_FLOAT(prog, OFS_PARM0 + i * 3)
			if f > x then
				f = x
			end
		end
		SET_G_FLOAT(prog, OFS_RETURN, f)
	else
		local a, b = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3)
		SET_G_FLOAT(prog, OFS_RETURN, if a < b then a else b)
	end
end

-- port: prvm_cmds.c VM_max L1709-1724 @xonotic-v0.8.6
function prvm_cmds.VM_max(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_max")
	if prog.argc >= 3 then
		local f = G_FLOAT(prog, OFS_PARM0)
		for i = 1, prog.argc - 1 do
			local x = G_FLOAT(prog, OFS_PARM0 + i * 3)
			if f < x then
				f = x
			end
		end
		SET_G_FLOAT(prog, OFS_RETURN, f)
	else
		local a, b = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3)
		SET_G_FLOAT(prog, OFS_RETURN, if a > b then a else b)
	end
end

-- port: prvm_cmds.c VM_strreplace L2369-2426 @xonotic-v0.8.6
function prvm_cmds.VM_strreplace(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_strreplace")
	local search = libc.cstr(G_STRING(prog, OFS_PARM0))
	local replace = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local subject = libc.cstr(G_STRING(prog, OFS_PARM0 + 6))
	local sl, rl, subl = #search, #replace, #subject
	local out = {}
	local si = 0
	local cap = VM_STRINGTEMP_LENGTH - 1
	local function put(ch: string)
		if si < cap then
			table.insert(out, ch)
			si += 1
		end
	end
	local i = 0
	while i <= subl - sl do
		local j = 0
		while j < sl and string.byte(subject, i + j + 1) == string.byte(search, j + 1) do
			j += 1
		end
		if j == sl then
			for k = 1, rl do
				if si >= cap then
					break
				end
				put(string.sub(replace, k, k))
			end
			if sl > 0 then
				i += sl - 1
			else
				put(string.sub(subject, i + 1, i + 1))
			end
		else
			put(string.sub(subject, i + 1, i + 1))
		end
		i += 1
	end
	while i < subl do
		put(string.sub(subject, i + 1, i + 1))
		i += 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_strstrofs L5647-5668 @xonotic-v0.8.6
function prvm_cmds.VM_strstrofs(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_strstrofs")
	local instr = libc.cstr(G_STRING(prog, OFS_PARM0))
	local match = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local firstofs = if prog.argc > 2 then libc.toint(G_FLOAT(prog, OFS_PARM0 + 6)) else 0
	firstofs = libc.toint(utf8lib.u8_bytelen(instr, 1, firstofs))
	if firstofs ~= 0 and (firstofs < 0 or firstofs > #instr) then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		return
	end
	local at = string.find(instr, match, firstofs + 1, true)
	if not at then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
	else
		SET_G_FLOAT(prog, OFS_RETURN, utf8lib.u8_strnlen(instr, 1, at - 1))
	end
end

-- port: prvm_cmds.c VM_crc16 L5933-5941 @xonotic-v0.8.6
function prvm_cmds.VM_crc16(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_crc16")
	local insensitive = G_FLOAT(prog, OFS_PARM0)
	local s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	SET_G_FLOAT(prog, OFS_RETURN, if insensitive ~= 0 then common.CRC_Block_CaseInsensitive(s) else common.CRC_Block(s))
end

-- port: prvm_cmds.c VM_uri_escape L6054-6083 @xonotic-v0.8.6
function prvm_cmds.VM_uri_escape(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_uri_escape")
	local src = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	local hex = "0123456789ABCDEF"
	local out = {}
	local q = 0
	for k = 1, #src do
		if q >= VM_STRINGTEMP_LENGTH - 3 then
			break
		end
		local c = string.sub(src, k, k)
		if string.find(c, "^[A-Za-z0-9%-_%.!~'()]$") then
			table.insert(out, c)
			q += 1
		else
			local b = string.byte(c)
			table.insert(
				out,
				"%" .. string.sub(hex, b // 16 + 1, b // 16 + 1) .. string.sub(hex, b % 16 + 1, b % 16 + 1)
			)
			q += 3
		end
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_uri_unescape L6087-6130 @xonotic-v0.8.6
function prvm_cmds.VM_uri_unescape(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_uri_unescape")
	local src = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	local function hexv(c: number?): number?
		if not c then
			return nil
		elseif c >= 48 and c <= 57 then
			return c - 48
		elseif c >= 97 and c <= 102 then
			return c - 87
		elseif c >= 65 and c <= 70 then
			return c - 55
		end
		return nil
	end
	local out = {}
	local p = 1
	while p <= #src do
		if string.byte(src, p) == 37 then -- '%'
			local hi, lo = hexv(string.byte(src, p + 1)), hexv(string.byte(src, p + 2))
			if hi and lo then
				if hi ~= 0 or lo ~= 0 then -- don't unescape NUL bytes
					table.insert(out, string.char(hi * 16 + lo))
				end
				p += 3
				continue
			end
		end
		table.insert(out, string.sub(src, p, p))
		p += 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_vlen L492-496 @xonotic-v0.8.6 (VectorLength: float DotProduct, sqrt in double)
function prvm_cmds.VM_vlen(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vlen")
	local x, y, z = G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 1), G_FLOAT(prog, OFS_PARM0 + 2)
	local d = f32.add(f32.add(f32.mul(x, x), f32.mul(y, y)), f32.mul(z, z))
	SET_G_FLOAT(prog, OFS_RETURN, math.sqrt(d))
end

-- port: prvm_cmds.c VM_rint L1414-1424 @xonotic-v0.8.6
function prvm_cmds.VM_rint(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_rint")
	local f = G_FLOAT(prog, OFS_PARM0)
	if f > 0 then
		SET_G_FLOAT(prog, OFS_RETURN, math.floor(f + 0.5))
	else
		SET_G_FLOAT(prog, OFS_RETURN, math.ceil(f - 0.5))
	end
end

-- port: prvm_cmds.c VM_numentityfields L2021-2024 @xonotic-v0.8.6
function prvm_cmds.VM_numentityfields(prog: any)
	SET_G_FLOAT(prog, OFS_RETURN, #prog.fielddefs)
end

-- glibc strcasecmp/strncasecmp result: difference of the first differing tolower()ed bytes
local function casecmp(a: string, b: string, n: number): number
	local i = 1
	while i <= n do
		local x, y = string.byte(a, i) or 0, string.byte(b, i) or 0
		if x >= 65 and x <= 90 then
			x += 32
		end
		if y >= 65 and y <= 90 then
			y += 32
		end
		if x ~= y then
			return x - y
		end
		if x == 0 then
			return 0
		end
		i += 1
	end
	return 0
end

-- port: prvm_cmds.c VM_strncasecmp L5916-5930 @xonotic-v0.8.6
function prvm_cmds.VM_strncasecmp(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_strncasecmp")
	local s1 = libc.cstr(G_STRING(prog, OFS_PARM0))
	local s2 = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	if prog.argc > 2 then
		local n = G_FLOAT(prog, OFS_PARM0 + 6)
		n = if n < 0 then math.huge else math.floor(n)
		SET_G_FLOAT(prog, OFS_RETURN, casecmp(s1, s2, n))
	else
		SET_G_FLOAT(prog, OFS_RETURN, casecmp(s1, s2, math.huge))
	end
end

-- Tokenizer state shared by tokenize* / argv* (prvm_cmds.c L2586-2593: static, shared by all VMs)
local MAXTOKENS = VM_STRINGTEMP_LENGTH // 2
local num_tokens = 0
local tokens: { [number]: number } = {}
local tokens_startpos: { [number]: number } = {}
local tokens_endpos: { [number]: number } = {}

-- strlcpy(tokenize_string, s, sizeof(tokenize_string))
local function tokenize_copy(s: string): string
	s = libc.cstr(s)
	if #s > VM_STRINGTEMP_LENGTH - 1 then
		s = string.sub(s, 1, VM_STRINGTEMP_LENGTH - 1)
	end
	return s
end

-- port: prvm_cmds.c VM_tokenize_console L2625-2653 @xonotic-v0.8.6
function prvm_cmds.VM_tokenize_console(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_tokenize")
	local str = tokenize_copy(G_STRING(prog, OFS_PARM0))
	local p: number? = 1
	num_tokens = 0
	while true do
		if num_tokens >= MAXTOKENS then
			break
		end
		local q = p :: number
		while (string.byte(str, q) or 0) ~= 0 and common.ISWHITESPACE(string.byte(str, q) or 0) do
			q += 1
		end
		tokens_startpos[num_tokens] = q - 1
		local ok
		ok, p = common.COM_ParseToken_Console(str, q)
		if not ok then
			break
		end
		tokens_endpos[num_tokens] = (p :: number) - 1
		tokens[num_tokens] = prvm_edict.PRVM_SetTempString(prog, common.com_token)
		num_tokens += 1
	end
	SET_G_FLOAT(prog, OFS_RETURN, num_tokens)
end

-- port: prvm_cmds.c VM_tokenizebyseparator L2669-2731 @xonotic-v0.8.6
function prvm_cmds.VM_tokenizebyseparator(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_tokenizebyseparator")
	local str = tokenize_copy(G_STRING(prog, OFS_PARM0))
	local separators = {}
	for j = 1, prog.argc - 1 do
		local sep = libc.cstr(G_STRING(prog, OFS_PARM0 + j * 3))
		if sep ~= "" then
			table.insert(separators, sep)
		end
	end
	num_tokens = 0
	local tokentextlen = 0 -- j: bytes used in tokentext[MAX_INPUTLINE]
	local p = 1
	local n = #str
	while num_tokens < MAXTOKENS do
		tokens_startpos[num_tokens] = p - 1
		local p0 = p
		local tok = {}
		while p <= n do
			local hit = nil
			for _, sep in separators do
				if string.sub(str, p, p + #sep - 1) == sep then
					hit = sep
					break
				end
			end
			if hit then
				p += #hit
				break
			end
			if tokentextlen < VM_STRINGTEMP_LENGTH - 1 then
				table.insert(tok, string.sub(str, p, p))
				tokentextlen += 1
			end
			p += 1
			p0 = p
		end
		tokens_endpos[num_tokens] = p0 - 1
		if tokentextlen >= VM_STRINGTEMP_LENGTH then
			break
		end
		tokentextlen += 1
		tokens[num_tokens] = prvm_edict.PRVM_SetTempString(prog, table.concat(tok))
		num_tokens += 1
		if p > n then
			break
		end
	end
	SET_G_FLOAT(prog, OFS_RETURN, num_tokens)
end

local function tokenindex(prog: any): number?
	SAFEPARMCOUNT(prog, 1, "VM_argv")
	local t = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if t < 0 then
		t += num_tokens
	end
	if t >= 0 and t < num_tokens then
		return t
	end
	return nil
end

-- port: prvm_cmds.c VM_argv L2735-2750 @xonotic-v0.8.6
function prvm_cmds.VM_argv(prog: any)
	local t = tokenindex(prog)
	SET_G_INT(prog, OFS_RETURN, if t then tokens[t] else 0)
end

-- port: prvm_cmds.c VM_argv_start_index L2753-2768 @xonotic-v0.8.6
function prvm_cmds.VM_argv_start_index(prog: any)
	local t = tokenindex(prog)
	SET_G_FLOAT(prog, OFS_RETURN, if t then tokens_startpos[t] else -1)
end

-- port: prvm_cmds.c VM_argv_end_index L2771-2786 @xonotic-v0.8.6
function prvm_cmds.VM_argv_end_index(prog: any)
	local t = tokenindex(prog)
	SET_G_FLOAT(prog, OFS_RETURN, if t then tokens_endpos[t] else -1)
end

-- port: prvm_cmds.c VM_infoadd L5861-5877 @xonotic-v0.8.6
function prvm_cmds.VM_infoadd(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_infoadd")
	local info = G_STRING(prog, OFS_PARM0)
	local key = G_STRING(prog, OFS_PARM0 + 3)
	local value = prvm_cmds.VM_VarString(prog, 2, VM_STRINGTEMP_LENGTH)
	local temp = tokenize_copy(info) -- strlcpy(temp, info, VM_STRINGTEMP_LENGTH)
	temp = common.InfoString_SetValue(temp, VM_STRINGTEMP_LENGTH, key, value)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, temp))
end

-- port: prvm_cmds.c VM_infoget L5881-5894 @xonotic-v0.8.6
function prvm_cmds.VM_infoget(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_infoget")
	local info = libc.cstr(G_STRING(prog, OFS_PARM0))
	local key = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local value = common.InfoString_GetValue(info, key, VM_STRINGTEMP_LENGTH) or ""
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, value))
end

-- C name -> builtin, for the vm_*_builtins tables
-- port: prvm_cmds.c VM_strtolower L2233-2245 @xonotic-v0.8.6
function prvm_cmds.VM_strtolower(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strtolower")
	local s = G_STRING(prog, OFS_PARM0)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, common.COM_ToLowerString(s, VM_STRINGTEMP_LENGTH)))
end

-- port: prvm_cmds.c VM_strtoupper L2255-2267 @xonotic-v0.8.6
function prvm_cmds.VM_strtoupper(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strtoupper")
	local s = G_STRING(prog, OFS_PARM0)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, common.COM_ToUpperString(s, VM_STRINGTEMP_LENGTH)))
end

local PRVM_MAX_OPENSEARCHES = 128 -- progsvm.h L272 (not DP_SMALLMEMORY)

local function opensearches(prog: any): { [number]: { string } }
	prog.opensearches = prog.opensearches or {}
	return prog.opensearches
end

-- port: prvm_cmds.c VM_search_begin L3088-3121 @xonotic-v0.8.6 (PRVM_AllocationOrigin: leak report not ported)
function prvm_cmds.VM_search_begin(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_search_begin")
	local pattern = G_STRING(prog, OFS_PARM0)
	prvm_cmds.VM_CheckEmptyString(prog, pattern)
	local caseinsens = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local quiet = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local os_ = opensearches(prog)
	local handle = 0
	while handle < PRVM_MAX_OPENSEARCHES do
		if not os_[handle] then
			break
		end
		handle += 1
	end
	if handle >= PRVM_MAX_OPENSEARCHES then
		SET_G_FLOAT(prog, OFS_RETURN, -2)
		prvm_cmds.VM_Warning(
			prog,
			"VM_search_begin: %s ran out of search handles (%i)\n",
			prog.name,
			PRVM_MAX_OPENSEARCHES
		)
		return
	end
	local r = fs.FS_Search(libc.cstr(pattern), caseinsens ~= 0, quiet ~= 0)
	os_[handle] = r :: any
	if not r then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
	else
		SET_G_FLOAT(prog, OFS_RETURN, handle)
	end
end

-- shared handle checks of VM_search_end / getsize / getfilename
local function searchHandle(prog: any, fname: string): { string }?
	local handle = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if handle < 0 or handle >= PRVM_MAX_OPENSEARCHES then
		prvm_cmds.VM_Warning(prog, "%s: invalid handle %i used in %s\n", fname, handle, prog.name)
		return nil
	end
	local r = opensearches(prog)[handle]
	if r == nil then
		prvm_cmds.VM_Warning(prog, "%s: no such handle %i in %s\n", fname, handle, prog.name)
		return nil
	end
	return r
end

-- port: prvm_cmds.c VM_search_end L3130-3152 @xonotic-v0.8.6
function prvm_cmds.VM_search_end(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_search_end")
	if searchHandle(prog, "VM_search_end") then
		opensearches(prog)[libc.toint(G_FLOAT(prog, OFS_PARM0))] = nil
	end
end

-- port: prvm_cmds.c VM_search_getsize L3161-3180 @xonotic-v0.8.6
function prvm_cmds.VM_search_getsize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_M_search_getsize")
	local r = searchHandle(prog, "VM_search_getsize")
	if r then
		SET_G_FLOAT(prog, OFS_RETURN, #r)
	end
end

-- port: prvm_cmds.c VM_search_getfilename L3189-3214 @xonotic-v0.8.6
function prvm_cmds.VM_search_getfilename(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_search_getfilename")
	local r = searchHandle(prog, "VM_search_getfilename")
	if not r then
		return
	end
	local filenum = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if filenum < 0 or filenum >= #r then
		prvm_cmds.VM_Warning(prog, "VM_search_getfilename: invalid filenum %i in %s\n", filenum, prog.name)
		return
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, r[filenum + 1]))
end

-- port: prvm_cmds.c VM_digest_hex L5944-5990 @xonotic-v0.8.6 (Crypto_Available: the release ships d0_blind_id)
function prvm_cmds.VM_digest_hex(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_digest_hex")
	local digest = libc.cstr(G_STRING(prog, OFS_PARM0))
	local s = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	local out: string? = nil
	if digest == "MD4" then
		out = mdfour.mdfour(s)
	elseif digest == "SHA256" then
		out = sha256(s)
	end
	-- no warning needed on mismatch - we return string_null to QC
	if out then
		local hex = string.gsub(out, ".", function(c: string): string
			return string.format("%02x", string.byte(c))
		end)
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, hex))
	else
		SET_G_INT(prog, OFS_RETURN, 0)
	end
end

local PRVM_MAX_OPENFILES = 256 -- progsvm.h L271 (not DP_SMALLMEMORY)

local function openfiles(prog: any): { [number]: any }
	prog.openfiles = prog.openfiles or {}
	return prog.openfiles
end

local function developer_extra(): boolean
	local v = cvar.Cvar_FindVar("developer_extra")
	return v ~= nil and v.integer ~= 0
end

-- port: prvm_cmds.c VM_fopen L1805-1859 @xonotic-v0.8.6 (PRVM_AllocationOrigin: leak report not ported)
function prvm_cmds.VM_fopen(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_fopen")
	local of = openfiles(prog)
	local filenum = 0
	while filenum < PRVM_MAX_OPENFILES do
		if of[filenum] == nil then
			break
		end
		filenum += 1
	end
	if filenum >= PRVM_MAX_OPENFILES then
		SET_G_FLOAT(prog, OFS_RETURN, -2)
		prvm_cmds.VM_Warning(prog, "VM_fopen: %s ran out of file handles (%i)\n", prog.name, PRVM_MAX_OPENFILES)
		return
	end
	local filename = libc.cstr(G_STRING(prog, OFS_PARM0))
	local mode = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local modestring
	if mode == 0 then -- FILE_READ
		modestring = "rb"
		of[filenum] = fs.FS_OpenVirtualFile(string.sub("data/" .. filename, 1, 1023), false)
		if of[filenum] == nil then
			of[filenum] = fs.FS_OpenVirtualFile(string.sub(filename, 1, 1023), false)
		end
	elseif mode == 1 then -- FILE_APPEND
		modestring = "a"
		of[filenum] = fs.FS_OpenRealFile(string.sub("data/" .. filename, 1, 1023), modestring, false)
	elseif mode == 2 then -- FILE_WRITE
		modestring = "w"
		of[filenum] = fs.FS_OpenRealFile(string.sub("data/" .. filename, 1, 1023), modestring, false)
	else
		SET_G_FLOAT(prog, OFS_RETURN, -3)
		prvm_cmds.VM_Warning(
			prog,
			"VM_fopen: %s: no such mode %i (valid: 0 = read, 1 = append, 2 = write)\n",
			prog.name,
			mode
		)
		return
	end
	if of[filenum] == nil then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
		if developer_extra() then
			prvm_cmds.VM_Warning(prog, "VM_fopen: %s: %s mode %s failed\n", prog.name, filename, modestring)
		end
	else
		SET_G_FLOAT(prog, OFS_RETURN, filenum)
		if developer_extra() then
			console.Con_DPrint(
				string.format("VM_fopen: %s: %s mode %s opened as #%i\n", prog.name, filename, modestring, filenum)
			)
		end
	end
end

-- handle checks shared by VM_fclose / VM_fgets / VM_fputs
local function fileHandle(prog: any, fname: string): (any, number)
	local filenum = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if filenum < 0 or filenum >= PRVM_MAX_OPENFILES then
		prvm_cmds.VM_Warning(prog, "%s: invalid file handle %i used in %s\n", fname, filenum, prog.name)
		return nil, filenum
	end
	local f = openfiles(prog)[filenum]
	if f == nil then
		prvm_cmds.VM_Warning(
			prog,
			"%s: no such file handle %i (or file has been closed) in %s\n",
			fname,
			filenum,
			prog.name
		)
	end
	return f, filenum
end

-- port: prvm_cmds.c VM_fclose L1869-1892 @xonotic-v0.8.6
function prvm_cmds.VM_fclose(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_fclose")
	local f, filenum = fileHandle(prog, "VM_fclose")
	if not f then
		return
	end
	fs.FS_Close(f)
	openfiles(prog)[filenum] = nil
	if developer_extra() then
		console.Con_DPrint(string.format("VM_fclose: %s: #%i closed\n", prog.name, filenum))
	end
end

-- port: prvm_cmds.c VM_fgets L1902-1945 @xonotic-v0.8.6
function prvm_cmds.VM_fgets(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_fgets")
	-- set the return value regardless of any possible errors
	SET_G_INT(prog, OFS_RETURN, 0) -- OFS_NULL
	local f = fileHandle(prog, "VM_fgets")
	if not f then
		return
	end
	local out = {}
	local c
	while true do
		c = fs.FS_Getc(f)
		if c == 13 or c == 10 or c < 0 then
			break
		end
		if #out < VM_STRINGTEMP_LENGTH - 1 then
			table.insert(out, string.char(c))
		end
	end
	local str = table.concat(out)
	-- remove \n following \r
	if c == 13 then
		c = fs.FS_Getc(f)
		if c ~= 10 then
			fs.FS_UnGetc(f, c % 256) -- (unsigned char)c: EOF becomes 255, as in C
		end
	end
	if developer_extra() then
		console.Con_DPrint(string.format("fgets: %s: %s\n", prog.name, libc.cstr(str)))
	end
	if c >= 0 or #out > 0 then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, str))
	end
end

-- port: prvm_cmds.c VM_fputs L1955-1979 @xonotic-v0.8.6
function prvm_cmds.VM_fputs(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_fputs")
	local f = fileHandle(prog, "VM_fputs")
	if not f then
		return
	end
	local str = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	if #str > 0 then
		fs.FS_Write(f, str)
	end
	if developer_extra() then
		console.Con_DPrint(string.format("fputs: %s: %s\n", prog.name, str))
	end
end

-- port: prvm_cmds.c checkextension L266-309 @xonotic-v0.8.6 (no USEODE in the release's server; Crypto_Available
-- true: the release ships d0_blind_id)
local function checkextension(prog: any, name: string): boolean
	local ext = prog.extensionstring or ""
	local len = #name
	for word in string.gmatch(ext, "[^ ]+") do
		if #word == len and libc.strcasecmp(word, name) == 0 then
			return true
		end
	end
	return false
end
prvm_cmds.checkextension = checkextension

-- port: prvm_cmds.c VM_checkextension L311-316 @xonotic-v0.8.6
function prvm_cmds.VM_checkextension(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_checkextension")
	SET_G_FLOAT(prog, OFS_RETURN, if checkextension(prog, libc.cstr(G_STRING(prog, OFS_PARM0))) then 1 else 0)
end

-- port: mathlib.h lhrandom L65 @xonotic-v0.8.6 (double arithmetic, glibc rand)
function prvm_cmds.lhrandom(min: number, max: number): number
	return ((libc.rand() + 0.5) / (libc.RAND_MAX + 1)) * (max - min) + min
end

-- port: prvm_cmds.c VM_random L559-564 @xonotic-v0.8.6
function prvm_cmds.VM_random(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_random")
	SET_G_FLOAT(prog, OFS_RETURN, prvm_cmds.lhrandom(0, 1))
end

-- time(NULL) (port support: a replaceable hook like Sys_DirtyTime; tests pin the wall clock with it)
prvm_cmds.time = function(): number
	return os.time()
end

-- port: prvm_cmds.c VM_strftime L922-959 @xonotic-v0.8.6
function prvm_cmds.VM_strftime(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 8, "VM_strftime")
	local fmt = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	local t = prvm_cmds.time()
	local tm = if G_FLOAT(prog, OFS_PARM0) ~= 0 then libc.localtime(t) else libc.gmtime(t)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, libc.strftime(fmt, tm, VM_STRINGTEMP_LENGTH)))
end

-- port: prvm_cmds.c VM_entityfieldname L2035-2049 @xonotic-v0.8.6
function prvm_cmds.VM_entityfieldname(prog: any)
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if i < 0 or i >= #prog.fielddefs then
		prvm_cmds.VM_Warning(prog, "VM_entityfieldname: %s: field index out of bounds\n", prog.name)
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, ""))
		return
	end
	SET_G_INT(prog, OFS_RETURN, prog.fielddefs[i + 1].s_name) -- presuming that s_name points to a string already
end

-- port: prvm_cmds.c VM_whichpack L6134-6143 @xonotic-v0.8.6
function prvm_cmds.VM_whichpack(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_whichpack")
	local pack = fs.FS_WhichPack(libc.cstr(G_STRING(prog, OFS_PARM0)))
	SET_G_INT(prog, OFS_RETURN, if pack then prvm_edict.PRVM_SetTempString(prog, pack) else 0)
end

-- port: prvm_cmds.c VM_sprintf L6506-6827 @xonotic-v0.8.6
-- outbuf is a byte buffer with C pointer o; dpsnprintf returns -1 on truncation and o moves back by one,
-- as in C. INT_LOSSLESS_FORMAT_SIZE "j": integers are intmax_t (64-bit).
local MAX_INPUTLINE = 16384
local PRINTF_ALTERNATE, PRINTF_ZEROPAD, PRINTF_LEFT, PRINTF_SPACEPOSITIVE, PRINTF_SIGNPOSITIVE = 1, 2, 4, 8, 16
function prvm_cmds.VM_sprintf(prog: any)
	local s = libc.cstr(G_STRING(prog, OFS_PARM0))
	local outbuf = buffer.create(MAX_INPUTLINE)
	local o, e = 0, MAX_INPUTLINE
	local argpos = 1
	local function ch(i: number): number
		return string.byte(s, i) or 0
	end
	local function isdig(c: number): boolean
		return c >= 48 and c <= 57
	end
	-- dpsnprintf(o, end - o, ...) of an already formatted string
	local function dp(str: string): number
		local room = e - o
		if #str >= room then
			buffer.writestring(outbuf, o, str, room - 1)
			buffer.writeu8(outbuf, o + room - 1, 0)
			return -1
		end
		buffer.writestring(outbuf, o, str)
		if o + #str < e then
			buffer.writeu8(outbuf, o + #str, 0)
		end
		return #str
	end
	local function inargs(a: number): boolean
		return a >= 1 and a < prog.argc
	end
	local function GETARG_FLOAT(a: number): number
		return if inargs(a) then G_FLOAT(prog, OFS_PARM0 + 3 * a) else 0
	end
	local function GETARG_INT(a: number): number
		return if inargs(a) then buffer.readi32(prog.globals, (OFS_PARM0 + 3 * a) * 4) else 0
	end
	local function GETARG_VEC(a: number, k: number, isfloat: boolean): number
		if not inargs(a) then
			return 0
		end
		local off = (OFS_PARM0 + 3 * a + k) * 4
		return if isfloat then buffer.readf32(prog.globals, off) else buffer.readi32(prog.globals, off)
	end
	local function GETARG_STRING(a: number): string
		return if inargs(a) then libc.cstr(G_STRING(prog, OFS_PARM0 + 3 * a)) else ""
	end
	-- strtol(s, &err, 10) on a digit run, cast to int
	local function strtol_int(i: number): (number, number)
		local _, j = libc.strtol10(s, i)
		return libc.atoi(string.sub(s, i, j - 1)), j
	end
	local function invalid(s0: number)
		prvm_cmds.VM_Warning(prog, "VM_sprintf: invalid directive in %s: %s\n", prog.name, string.sub(s, s0))
	end

	local i = 1
	while true do
		local s0 = i
		local c = ch(i)
		if c == 0 then
			break -- finished
		end
		local verbatim = c ~= 37
		if c == 37 then
			i += 1
			if ch(i) == 37 then
				verbatim = true
			end
		end
		if verbatim then
			if o < e - 1 then
				buffer.writeu8(outbuf, o, ch(i))
				o += 1
			end
			i += 1
			continue
		end
		-- complete directive format: %3$*1$.*2$ld
		local width, precision, thisarg, flags, isfloat = -1, -1, -1, 0, -1
		local stop = false
		-- is number following?
		if isdig(ch(i)) then
			local err
			width, err = strtol_int(i)
			if ch(err) == 36 then -- '$'
				thisarg = width
				width = -1
				i = err + 1
			else
				if ch(i) == 48 then
					flags = bit32.bor(flags, PRINTF_ZEROPAD)
					if width == 0 then
						width = -1 -- it was just a flag
					end
				end
				i = err
			end
		end
		if width < 0 then
			while true do
				local f = ch(i)
				if f == 35 then
					flags = bit32.bor(flags, PRINTF_ALTERNATE)
				elseif f == 48 then
					flags = bit32.bor(flags, PRINTF_ZEROPAD)
				elseif f == 45 then
					flags = bit32.bor(flags, PRINTF_LEFT)
				elseif f == 32 then
					flags = bit32.bor(flags, PRINTF_SPACEPOSITIVE)
				elseif f == 43 then
					flags = bit32.bor(flags, PRINTF_SIGNPOSITIVE)
				else
					break -- noflags
				end
				i += 1
			end
			if ch(i) == 42 then -- '*'
				i += 1
				if isdig(ch(i)) then
					local err
					width, err = strtol_int(i)
					if ch(err) ~= 36 then
						invalid(s0)
						break
					end
					i = err + 1
				else
					width = argpos
					argpos += 1
				end
				width = libc.toint(GETARG_FLOAT(width))
				if width < 0 then
					flags = bit32.bor(flags, PRINTF_LEFT)
					width = if width == -2147483648 then width else -width
				end
			elseif isdig(ch(i)) then
				local err
				width, err = strtol_int(i)
				i = err
				if width < 0 then
					flags = bit32.bor(flags, PRINTF_LEFT)
					width = if width == -2147483648 then width else -width
				end
			end
			-- otherwise width stays -1
		end
		if ch(i) == 46 then -- '.'
			i += 1
			if ch(i) == 42 then
				i += 1
				if isdig(ch(i)) then
					local err
					precision, err = strtol_int(i)
					if ch(err) ~= 36 then
						invalid(s0)
						break
					end
					i = err + 1
				else
					precision = argpos
					argpos += 1
				end
				precision = libc.toint(GETARG_FLOAT(precision))
			elseif isdig(ch(i)) then
				local err
				precision, err = strtol_int(i)
				i = err
			else
				invalid(s0)
				break
			end
		end
		while true do
			local l = ch(i)
			if l == 104 then -- h
				isfloat = 1
			elseif l == 108 or l == 76 then -- l L
				isfloat = 0
			elseif l ~= 106 and l ~= 122 and l ~= 116 then -- j z t: no effect
				break -- nolength
			end
			i += 1
		end
		-- now s points to the final directive char and is no longer changed
		local d = string.char(ch(i))
		if isfloat < 0 then
			isfloat = if d == "i" then 0 else 1
		end
		local fl = isfloat == 1
		if thisarg < 0 then
			thisarg = argpos
			argpos += 1
		end
		if o < e - 1 then
			local fs_ = ""
			if d ~= "s" and d ~= "c" and bit32.band(flags, PRINTF_ALTERNATE) ~= 0 then
				fs_ ..= "#"
			end
			if bit32.band(flags, PRINTF_ZEROPAD) ~= 0 then
				fs_ ..= "0"
			end
			if bit32.band(flags, PRINTF_LEFT) ~= 0 then
				fs_ ..= "-"
			end
			if bit32.band(flags, PRINTF_SPACEPOSITIVE) ~= 0 then
				fs_ ..= " "
			end
			if bit32.band(flags, PRINTF_SIGNPOSITIVE) ~= 0 then
				fs_ ..= "+"
			end
			if width < 0 then -- not set
				width = 0
			end
			-- "%*d" with a negative int width means left-aligned |width| (INT_MIN: C's own UB, treated so too)
			local w, ff = width, fs_
			if w < 0 then
				w = -w
				if not string.find(ff, "-", 1, true) then
					ff ..= "-"
				end
			end
			local p = if precision >= 0 then precision else -1
			if d == "d" or d == "i" then
				o += dp(
					libc.format1(ff, w, p, "d", if fl then libc.toint64(GETARG_FLOAT(thisarg)) else GETARG_INT(thisarg))
				)
			elseif d == "o" or d == "u" or d == "x" or d == "X" then
				local v = if fl then libc.touint64bits(GETARG_FLOAT(thisarg)) else GETARG_INT(thisarg)
				o += dp(libc.format1(ff, w, p, d, v))
			elseif d == "e" or d == "E" or d == "f" or d == "F" or d == "g" or d == "G" then
				o += dp(libc.format1(ff, w, p, d, if fl then GETARG_FLOAT(thisarg) else GETARG_INT(thisarg)))
			elseif d == "v" or d == "V" then
				local g = if d == "v" then "g" else "G"
				local parts = {}
				for k = 0, 2 do
					parts[k + 1] = libc.format1(ff, w, p, g, GETARG_VEC(thisarg, k, fl))
				end
				o += dp(table.concat(parts, " "))
			elseif d == "c" then
				local u = (if fl then libc.toint64(GETARG_FLOAT(thisarg)) else GETARG_INT(thisarg)) % 4294967296
				if bit32.band(flags, PRINTF_ALTERNATE) ~= 0 then
					o += dp(libc.format1(ff, w, -1, "c", u % 256))
				else
					local buf = utf8lib.u8_encodech(if u >= 2147483648 then u - 4294967296 else u) or ""
					if precision < 0 then -- not set
						precision = e - o - 1
					end
					o += dp(utf8lib.u8_strpad(buf, bit32.band(flags, PRINTF_LEFT) ~= 0, width, precision))
				end
			elseif d == "s" then
				if bit32.band(flags, PRINTF_ALTERNATE) ~= 0 then
					o += dp(libc.format1(ff, w, p, "s", GETARG_STRING(thisarg)))
				else
					if precision < 0 then -- not set
						precision = e - o - 1
					end
					local left = bit32.band(flags, PRINTF_LEFT) ~= 0
					if bit32.band(flags, PRINTF_SIGNPOSITIVE) ~= 0 then
						o += dp(utf8lib.u8_strpad(GETARG_STRING(thisarg), left, width, precision))
					else
						o += dp(utf8lib.u8_strpad_colorcodes(GETARG_STRING(thisarg), left, width, precision))
					end
				end
			else
				invalid(s0)
				stop = true
			end
		end
		if stop then
			break
		end
		i += 1
	end
	-- finished:
	buffer.writeu8(outbuf, o, 0)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, libc.cstr(buffer.readstring(outbuf, 0, o + 1))))
end

-- port: prvm_cmds.c VM_strdecolorize L2187-2197 @xonotic-v0.8.6
function prvm_cmds.VM_strdecolorize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strdecolorize")
	local _, out = common.COM_StringDecolorize(G_STRING(prog, OFS_PARM0), 0, VM_STRINGTEMP_LENGTH, true)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, out))
end

-- vectors and fields
local R = f32.round
local M_PI = 3.14159265358979323846
local function G_VECTOR(prog: any, ofs: number): { number }
	local g = prog.globals
	return { buffer.readf32(g, ofs * 4), buffer.readf32(g, ofs * 4 + 4), buffer.readf32(g, ofs * 4 + 8) }
end
local function SET_G_VECTOR(prog: any, ofs: number, v: { number })
	local g = prog.globals
	buffer.writef32(g, ofs * 4, v[1])
	buffer.writef32(g, ofs * 4 + 4, v[2])
	buffer.writef32(g, ofs * 4 + 8, v[3])
end
-- PRVM_gameglobal* by name (PRVM_FindOffsets: globaloffsets)
local function GlobalOfs(prog: any, name: string): number
	prog.globalofs_cache = prog.globalofs_cache or {}
	local o = prog.globalofs_cache[name]
	if o == nil then
		local d = prvm_edict.PRVM_ED_FindGlobal(prog, name)
		o = if d then (d :: any).ofs else -1
		prog.globalofs_cache[name] = o
	end
	return o
end
prvm_cmds.GlobalOfs = GlobalOfs
local function E_OFS(prog: any, ed: number, f: number): number
	return (ed * prog.entityfields + f) * 4
end
local function E_FLOAT(prog: any, ed: number, f: number): number
	return buffer.readf32(prog.edictsfields, E_OFS(prog, ed, f))
end
local function SET_E_FLOAT(prog: any, ed: number, f: number, v: number)
	buffer.writef32(prog.edictsfields, E_OFS(prog, ed, f), v)
end
local function E_INT(prog: any, ed: number, f: number): number
	return buffer.readi32(prog.edictsfields, E_OFS(prog, ed, f))
end
local function SET_E_INT(prog: any, ed: number, f: number, v: number)
	buffer.writei32(prog.edictsfields, E_OFS(prog, ed, f), v)
end
local function G_EDICTNUM(prog: any, ofs: number): number
	return buffer.readi32(prog.globals, ofs * 4)
end
local function setGameVectors(prog: any, forward: { number }, right: { number }, up: { number })
	SET_G_VECTOR(prog, GlobalOfs(prog, "v_forward"), forward)
	SET_G_VECTOR(prog, GlobalOfs(prog, "v_right"), right)
	SET_G_VECTOR(prog, GlobalOfs(prog, "v_up"), up)
end

-- port: prvm_cmds.c VM_makevectors L4318-4327 @xonotic-v0.8.6
function prvm_cmds.VM_makevectors(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_makevectors")
	local f, r, u = {}, {}, {}
	mathlib.AngleVectors(G_VECTOR(prog, OFS_PARM0), f, r, u)
	setGameVectors(prog, f, r, u)
end

-- port: prvm_cmds.c VM_vectorvectors L4337-4346 @xonotic-v0.8.6
function prvm_cmds.VM_vectorvectors(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vectorvectors")
	local f, r, u = {}, {}, {}
	mathlib.VectorNormalize2(G_VECTOR(prog, OFS_PARM0), f)
	mathlib.VectorVectors(f, r, u)
	setGameVectors(prog, f, r, u)
end

-- port: prvm_cmds.c VM_normalize L463-483 @xonotic-v0.8.6
function prvm_cmds.VM_normalize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_normalize")
	local v = G_VECTOR(prog, OFS_PARM0)
	local f = mathlib.DotProduct(v, v)
	local nv = { 0, 0, 0 }
	if f ~= 0 then
		f = 1.0 / math.sqrt(f)
		nv = { R(v[1] * f), R(v[2] * f), R(v[3] * f) }
	end
	SET_G_VECTOR(prog, OFS_RETURN, nv)
end

-- port: prvm_cmds.c VM_vectoyaw L505-524 @xonotic-v0.8.6
function prvm_cmds.VM_vectoyaw(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vectoyaw")
	local v = G_VECTOR(prog, OFS_PARM0)
	local yaw = 0
	if not (v[2] == 0 and v[1] == 0) then
		yaw = libc.toint(libm.atan2(v[2], v[1]) * 180 / M_PI)
		if yaw < 0 then
			yaw += 360
		end
	end
	SET_G_FLOAT(prog, OFS_RETURN, yaw)
end

-- port: prvm_cmds.c VM_vectoangles L534-548 @xonotic-v0.8.6
function prvm_cmds.VM_vectoangles(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 2, "VM_vectoangles")
	local result = {}
	if prog.argc >= 2 then
		mathlib.AnglesFromVectors(result, G_VECTOR(prog, OFS_PARM0), G_VECTOR(prog, OFS_PARM0 + 3), true)
	else
		mathlib.AnglesFromVectors(result, G_VECTOR(prog, OFS_PARM0), nil, true)
	end
	SET_G_VECTOR(prog, OFS_RETURN, result)
end

-- one-argument math builtins: PRVM_G_FLOAT(OFS_RETURN) = fn(PRVM_G_FLOAT(OFS_PARM0)) in double
local function math1(name: string, fn: (number) -> number): (any) -> ()
	return function(prog: any)
		SAFEPARMCOUNT(prog, 1, name)
		SET_G_FLOAT(prog, OFS_RETURN, fn(G_FLOAT(prog, OFS_PARM0)))
	end
end
-- port: prvm_cmds.c VM_ceil L1447-1452 @xonotic-v0.8.6
prvm_cmds.VM_ceil = math1("VM_ceil", math.ceil)
-- port: prvm_cmds.c VM_fabs L809-817 @xonotic-v0.8.6
prvm_cmds.VM_fabs = math1("VM_fabs", math.abs)
-- port: prvm_cmds.c VM_sin L1524-1528 @xonotic-v0.8.6
prvm_cmds.VM_sin = math1("VM_sin", libm.sin)
-- port: prvm_cmds.c VM_cos L1536-1540 @xonotic-v0.8.6
prvm_cmds.VM_cos = math1("VM_cos", libm.cos)
-- port: prvm_cmds.c VM_sqrt L1549-1553 @xonotic-v0.8.6
prvm_cmds.VM_sqrt = math1("VM_sqrt", math.sqrt)
-- port: prvm_cmds.c VM_asin L1562-1566 @xonotic-v0.8.6
prvm_cmds.VM_asin = math1("VM_asin", libm.asin)
-- port: prvm_cmds.c VM_acos L1574-1578 @xonotic-v0.8.6
prvm_cmds.VM_acos = math1("VM_acos", libm.acos)
-- port: prvm_cmds.c VM_atan L1586-1590 @xonotic-v0.8.6
prvm_cmds.VM_atan = math1("VM_atan", libm.atan)
-- port: prvm_cmds.c VM_tan L1610-1614 @xonotic-v0.8.6
prvm_cmds.VM_tan = math1("VM_tan", libm.tan)
-- port: prvm_cmds.c VM_log L1756-1760 @xonotic-v0.8.6
prvm_cmds.VM_log = math1("VM_log", libm.log)

-- port: prvm_cmds.c VM_atan2 L1598-1602 @xonotic-v0.8.6
function prvm_cmds.VM_atan2(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_atan2")
	SET_G_FLOAT(prog, OFS_RETURN, libm.atan2(G_FLOAT(prog, OFS_PARM0), G_FLOAT(prog, OFS_PARM0 + 3)))
end

-- port: prvm_cmds.c VM_randomvec L1625-1631 @xonotic-v0.8.6 (VectorRandom, mathlib.h L133)
function prvm_cmds.VM_randomvec(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_randomvec")
	local v = { 0, 0, 0 }
	repeat
		v[1] = R(prvm_cmds.lhrandom(-1, 1))
		v[2] = R(prvm_cmds.lhrandom(-1, 1))
		v[3] = R(prvm_cmds.lhrandom(-1, 1))
	until not (mathlib.DotProduct(v, v) > 1)
	SET_G_VECTOR(prog, OFS_RETURN, v)
end

-- port: prvm_cmds.c VM_bitshift L4372-4386 @xonotic-v0.8.6 (x86 masks the shift count to 5 bits)
function prvm_cmds.VM_bitshift(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_bitshift")
	local n1 = libc.toint(math.abs(R(libc.toint(G_FLOAT(prog, OFS_PARM0)))))
	local n2 = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local r
	if n1 == 0 then
		r = n1
	elseif n2 < 0 then
		r = bit32.arshift(n1, -n2 % 32)
		r = if r >= 2147483648 then r - 4294967296 else r
	else
		r = bit32.lshift(n1, n2 % 32)
		r = if r >= 2147483648 then r - 4294967296 else r
	end
	SET_G_FLOAT(prog, OFS_RETURN, r)
end

-- VM_changeyaw / VM_changepitch body (float arithmetic)
local function changeangle(prog: any, ent: number, idx: number, idealf: string, speedf: string, who: string)
	if ent == 0 then
		prvm_cmds.VM_Warning(prog, "%s: can not modify world entity\n", who)
		return
	end
	if prog.ed_free[ent] then
		prvm_cmds.VM_Warning(prog, "%s: can not modify free entity\n", who)
		return
	end
	local ang = prvm_edict.FieldOfs(prog, "angles") + idx
	local current = R(mathlib.ANGLEMOD(E_FLOAT(prog, ent, ang)))
	local ideal = E_FLOAT(prog, ent, prvm_edict.FieldOfs(prog, idealf))
	local speed = E_FLOAT(prog, ent, prvm_edict.FieldOfs(prog, speedf))
	if current == ideal then
		return
	end
	local move = R(ideal - current)
	if ideal > current then
		if move >= 180 then
			move = R(move - 360)
		end
	else
		if move <= -180 then
			move = R(move + 360)
		end
	end
	if move > 0 then
		if move > speed then
			move = speed
		end
	else
		if move < -speed then
			move = -speed
		end
	end
	current = R(current + move)
	SET_E_FLOAT(prog, ent, ang, R(mathlib.ANGLEMOD(current)))
end

-- port: prvm_cmds.c VM_changeyaw L5522-5573 @xonotic-v0.8.6
function prvm_cmds.VM_changeyaw(prog: any)
	-- this is called (VERY HACKISHLY) by VM_SV_MoveToGoal, so it can not use any parameters
	local self = buffer.readi32(prog.globals, GlobalOfs(prog, "self") * 4)
	changeangle(prog, self, 1, "ideal_yaw", "yaw_speed", "changeyaw")
end

-- port: prvm_cmds.c VM_changepitch L5580-5629 @xonotic-v0.8.6
function prvm_cmds.VM_changepitch(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_changepitch")
	changeangle(prog, G_EDICTNUM(prog, OFS_PARM0), 0, "idealpitch", "pitch_speed", "changepitch")
end

-- port: prvm_cmds.c VM_vtos L827-835 @xonotic-v0.8.6
function prvm_cmds.VM_vtos(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_vtos")
	local v = G_VECTOR(prog, OFS_PARM0)
	local str = libc.snprintf(512, "'%5.1f %5.1f %5.1f'", v[1], v[2], v[3])
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, str))
end

-- port: prvm_cmds.c VM_etos L845-853 @xonotic-v0.8.6
function prvm_cmds.VM_etos(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_etos")
	SET_G_INT(
		prog,
		OFS_RETURN,
		prvm_edict.PRVM_SetTempString(prog, string.format("entity %i", G_EDICTNUM(prog, OFS_PARM0)))
	)
end

-- port: mathlib.c Math_atov L863-882 @xonotic-v0.8.6 (out: prvm_vec3_t, float)
local function Math_atov(str: string, out: { number }): number
	out[1], out[2], out[3] = 0, 0, 0
	local p = 1
	local function c(): number
		return string.byte(str, p) or 0
	end
	if c() == 39 then
		p += 1
	end
	local i = 0
	while i < 3 do
		while c() == 32 or c() == 9 do
			p += 1
		end
		out[i + 1] = R(libc.atof(string.sub(str, p)))
		local ch = c()
		if out[i + 1] == 0 and ch ~= 45 and ch ~= 43 and (ch < 48 or ch > 57) then
			break -- not a number
		end
		while c() ~= 0 and c() ~= 32 and c() ~= 9 and c() ~= 39 do
			p += 1
		end
		if c() == 39 then
			break
		end
		i += 1
	end
	return i
end
prvm_cmds.Math_atov = Math_atov

-- port: prvm_cmds.c VM_stov L2503-2511 @xonotic-v0.8.6
function prvm_cmds.VM_stov(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_stov")
	local v = {}
	Math_atov(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH), v)
	SET_G_VECTOR(prog, OFS_RETURN, v)
end

-- port: prvm_cmds.c VM_chr2str L5693-5712 @xonotic-v0.8.6
function prvm_cmds.VM_chr2str(prog: any)
	SAFEPARMCOUNTRANGE(prog, 0, 8, "VM_chr2str")
	local parts = {}
	local len = 0
	local i = 0
	while i < prog.argc and len < 36 do
		local n, bytes = utf8lib.u8_fromchar(libc.toint(G_FLOAT(prog, OFS_PARM0 + i * 3)), 36)
		if n > 0 then
			table.insert(parts, bytes)
		end
		len += n
		i += 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(parts)))
end

-- port: prvm_cmds.c VM_strlennocol L2209-2222 @xonotic-v0.8.6
function prvm_cmds.VM_strlennocol(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_strlennocol")
	local n = utf8lib.u8_COM_StringLengthNoColors(libc.cstr(G_STRING(prog, OFS_PARM0)), 0)
	SET_G_FLOAT(prog, OFS_RETURN, n)
end

-- port: prvm_cmds.c VM_isserver L2795-2800 @xonotic-v0.8.6
function prvm_cmds.VM_isserver(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_serverstate")
	SET_G_FLOAT(prog, OFS_RETURN, if host_cmd.sv_active then 1 else 0)
end

-- port: prvm_cmds.c VM_wasfreed L5992-5996 @xonotic-v0.8.6
function prvm_cmds.VM_wasfreed(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_wasfreed")
	SET_G_FLOAT(prog, OFS_RETURN, if prog.ed_free[G_EDICTNUM(prog, OFS_PARM0)] then 1 else 0)
end

-- port: prvm_cmds.c VM_dprint L765-775 @xonotic-v0.8.6
function prvm_cmds.VM_dprint(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_dprint")
	console.Con_DPrint(prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH))
end

local function E_STRING(prog: any, ed: number, f: number): string
	local t = E_INT(prog, ed, f)
	if t == 0 then
		return "" -- if (!t) t = "";
	end
	return libc.cstr(prvm_edict.PRVM_GetString(prog, t))
end

-- port: prvm_cmds.c VM_find L1016-1050 @xonotic-v0.8.6 (builtinsprofile: profiler counter, not ported)
function prvm_cmds.VM_find(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_find")
	local e = G_EDICTNUM(prog, OFS_PARM0)
	local f = buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4)
	local str = libc.cstr(G_STRING(prog, OFS_PARM0 + 6))
	e += 1
	while e < prog.num_edicts do
		if not prog.ed_free[e] and E_STRING(prog, e, f) == str then
			RETURN_EDICT(prog, e)
			return
		end
		e += 1
	end
	RETURN_EDICT(prog, 0)
end

-- port: prvm_cmds.c VM_findfloat L1061-1088 @xonotic-v0.8.6
function prvm_cmds.VM_findfloat(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_findfloat")
	local e = G_EDICTNUM(prog, OFS_PARM0)
	local f = buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4)
	local v = G_FLOAT(prog, OFS_PARM0 + 6)
	e += 1
	while e < prog.num_edicts do
		if not prog.ed_free[e] and E_FLOAT(prog, e, f) == v then
			RETURN_EDICT(prog, e)
			return
		end
		e += 1
	end
	RETURN_EDICT(prog, 0)
end

-- (prvm_int_t)float
local function toi(x: number): number
	return libc.toint(x)
end

-- port: prvm_cmds.c VM_findflags L1200-1230 @xonotic-v0.8.6
function prvm_cmds.VM_findflags(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_findflags")
	local e = G_EDICTNUM(prog, OFS_PARM0)
	local f = buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4)
	local v = toi(G_FLOAT(prog, OFS_PARM0 + 6))
	e += 1
	while e < prog.num_edicts do
		if not prog.ed_free[e] then
			local x = E_FLOAT(prog, e, f)
			if x ~= 0 and bit32.band(toi(x), v) ~= 0 then
				RETURN_EDICT(prog, e)
				return
			end
		end
		e += 1
	end
	RETURN_EDICT(prog, 0)
end

local function chainfield(prog: any, name: string): number
	local cf = if prog.argc == 3
		then buffer.readi32(prog.globals, (OFS_PARM0 + 6) * 4)
		else prvm_edict.FieldOfs(prog, "chain")
	if cf < 0 then
		prog.error_cmd(string.format("%s: %s doesnt have the specified chain field !", name, prog.name))
	end
	return cf
end

-- shared loop of VM_findchain / VM_findchainfloat / VM_findchainflags
local function findchain(prog: any, cf: number, match: (number) -> boolean)
	local chain = 0
	for i = 1, prog.num_edicts - 1 do
		if not prog.ed_free[i] and match(i) then
			SET_E_INT(prog, i, cf, chain)
			chain = i
		end
	end
	RETURN_EDICT(prog, chain)
end

-- port: prvm_cmds.c VM_findchain L1099-1142 @xonotic-v0.8.6
function prvm_cmds.VM_findchain(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_findchain")
	local cf = chainfield(prog, "VM_findchain")
	local f = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local str = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	findchain(prog, cf, function(i: number): boolean
		return E_STRING(prog, i, f) == str
	end)
end

-- port: prvm_cmds.c VM_findchainfloat L1154-1190 @xonotic-v0.8.6
function prvm_cmds.VM_findchainfloat(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_findchainfloat")
	local cf = chainfield(prog, "VM_findchain")
	local f = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local v = G_FLOAT(prog, OFS_PARM0 + 3)
	findchain(prog, cf, function(i: number): boolean
		return E_FLOAT(prog, i, f) == v
	end)
end

-- port: prvm_cmds.c VM_findchainflags L1240-1278 @xonotic-v0.8.6
function prvm_cmds.VM_findchainflags(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 3, "VM_findchainflags")
	local cf = chainfield(prog, "VM_findchain")
	local f = buffer.readi32(prog.globals, OFS_PARM0 * 4)
	local v = toi(G_FLOAT(prog, OFS_PARM0 + 3))
	findchain(prog, cf, function(i: number): boolean
		local x = E_FLOAT(prog, i, f)
		return x ~= 0 and bit32.band(toi(x), v) ~= 0
	end)
end

-- port: prvm_cmds.c VM_buf_copy L4817-4861 @xonotic-v0.8.6
-- The C fetches the destination with PARM0 (the source), so dst == src: the strings are freed, the record
-- is assigned to itself, a new zeroed strings array is allocated and the copy loop reads it (all NULL).
-- Net effect, reproduced here: the source keeps num_strings/max_strings but loses every string.
function prvm_cmds.VM_buf_copy(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_buf_copy")
	local n0 = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local src = RecordAtIndex(prog, n0)
	if not src then
		prvm_cmds.VM_Warning(prog, "VM_buf_copy: invalid source buffer %i used in %s\n", n0, prog.name)
		return
	end
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if i == n0 then
		prvm_cmds.VM_Warning(prog, "VM_buf_copy: source == destination (%i) in %s\n", i, prog.name)
		return
	end
	src.strings = {}
end

-- glibc msort (stdlib/msort.c msort_with_tmp): top-down merge sort, n1 = n / 2, the left element wins
-- when cmp <= 0. The comparators below are not consistent for NULL/empty strings, so the algorithm matters.
local function msort(a: { any }, lo: number, n: number, cmp: (any, any) -> number)
	if n <= 1 then
		return
	end
	local n1 = n // 2
	local n2 = n - n1
	msort(a, lo, n1, cmp)
	msort(a, lo + n1, n2, cmp)
	local tmp = table.create(n)
	local i, j = lo, lo + n1
	local ie, je = lo + n1, lo + n
	while i < ie and j < je do
		if cmp(a[i], a[j]) <= 0 then
			table.insert(tmp, a[i])
			i += 1
		else
			table.insert(tmp, a[j])
			j += 1
		end
	end
	while i < ie do
		table.insert(tmp, a[i])
		i += 1
	end
	-- the rest of the right half is already in place
	for k, v in tmp do
		a[lo + k - 1] = v
	end
end

-- port: prvm_cmds.c VM_buf_sort L4871-4897 @xonotic-v0.8.6 (BufStr_SortStringsUP/DOWN L4625-4643)
function prvm_cmds.VM_buf_sort(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_buf_sort")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_buf_sort: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	if sb.num_strings <= 0 then
		prvm_cmds.VM_Warning(prog, "VM_buf_sort: tried to sort empty buffer %i in %s\n", n, prog.name)
		return
	end
	local sortlength = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if sortlength <= 0 then
		sortlength = 0x7FFFFFFF
	end
	local function strncmp(a: string, b: string): number
		return libc.strcmp(string.sub(a, 1, sortlength), string.sub(b, 1, sortlength))
	end
	local up = G_FLOAT(prog, OFS_PARM0 + 6) == 0
	local cmp = function(a: string?, b: string?): number
		if not a or a == "" then
			return 1
		end
		if not b or b == "" then
			return -1
		end
		return if up then strncmp(a, b) else strncmp(b, a)
	end
	local arr: { any } = table.create(sb.num_strings)
	for k = 0, sb.num_strings - 1 do
		arr[k] = sb.strings[k] or false
	end
	local wrapped = function(a: any, b: any): number
		return cmp(if a == false then nil else a, if b == false then nil else b)
	end
	msort(arr, 0, sb.num_strings, wrapped)
	for k = 0, sb.num_strings - 1 do
		sb.strings[k] = if arr[k] == false then nil else arr[k]
	end
	BufStr_Shrink(sb)
end

-- port: prvm_cmds.c VM_buf_implode L4906-4938 @xonotic-v0.8.6 (the separator is strlcat'ed before every
-- string, the first included; l does not count it for i == 0)
function prvm_cmds.VM_buf_implode(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_buf_implode")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	SET_G_INT(prog, OFS_RETURN, 0) -- OFS_NULL
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_buf_implode: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	if sb.num_strings == 0 then
		return
	end
	local sep = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local k = ""
	local l = 0
	local cap = VM_STRINGTEMP_LENGTH - 1
	for i = 0, sb.num_strings - 1 do
		local str = sb.strings[i]
		if str then
			l += (if i > 0 then #sep else 0) + #str
			if l >= cap then
				break
			end
			k = string.sub(k .. sep, 1, cap) -- strlcat(k, sep, sizeof(k))
			k = string.sub(k .. str, 1, cap)
		end
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, k))
end

-- port: prvm_cmds.c VM_bufstr_add L5010-5048 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_add(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_bufstr_add")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	SET_G_FLOAT(prog, OFS_RETURN, -1)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_add: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	if buffer.readi32(prog.globals, (OFS_PARM0 + 3) * 4) == 0 then -- NULL string
		prvm_cmds.VM_Warning(prog, "VM_bufstr_add: can not add an empty string to buffer %i in %s\n", n, prog.name)
		return
	end
	local str = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local order = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local strindex
	if order ~= 0 then
		strindex = sb.num_strings
	else
		strindex = 0
		while strindex < sb.num_strings do
			if sb.strings[strindex] == nil then
				break
			end
			strindex += 1
		end
	end
	BufStr_Expand(sb, strindex)
	sb.num_strings = math.max(sb.num_strings, strindex + 1)
	sb.strings[strindex] = str
	SET_G_FLOAT(prog, OFS_RETURN, strindex)
end

-- port: prvm_cmds.c VM_bufstr_free L5057-5084 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_free(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_bufstr_free")
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_free: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	if i < 0 then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_free: invalid string index %i used in %s\n", i, prog.name)
		return
	end
	if i < sb.num_strings then
		sb.strings[i] = nil
	end
	BufStr_Shrink(sb)
end

local MATCH_WHOLE, MATCH_LEFT, MATCH_RIGHT, MATCH_MIDDLE, MATCH_PATTERN = 1, 2, 3, 4, 5

-- port: prvm_cmds.c detect_match_rule L5257-5309 @xonotic-v0.8.6 (ppos - pattern == patternlength never
-- holds, so "*x*" and "x*" are MATCH_PATTERN, as in C)
local function detect_match_rule(pattern: string): (string, number)
	local patternlength = #pattern
	local ppos = string.find(pattern, "*", 1, true)
	local qpos = string.find(pattern, "?", 1, true)
	-- has ? - pattern
	if qpos then
		return pattern, MATCH_PATTERN
	end
	-- has * - left, mid, right or pattern
	if ppos then
		-- starts with * - may be right/mid or pattern
		if ppos - 1 == 0 then
			ppos = string.find(pattern, "*", 2, true)
			-- *something
			if not ppos then
				return string.sub(pattern, 2), MATCH_RIGHT
			end
			-- *something*
			if ppos - 1 == patternlength then
				return string.sub(pattern, 2, ppos - 1), MATCH_MIDDLE
			end
			-- *som*thing
			return pattern, MATCH_PATTERN
		end
		-- end with * - left
		if ppos - 1 == patternlength then
			return string.sub(pattern, 1, ppos - 1), MATCH_LEFT
		end
		-- som*thing
		return pattern, MATCH_PATTERN
	end
	-- have no wildcards - whole string
	return pattern, MATCH_WHOLE
end

-- port: prvm_cmds.c match_rule L5312-5329 @xonotic-v0.8.6
local function match_rule(
	str: string,
	max_string: number,
	pattern: string,
	patternlength: number,
	rule: number
): boolean
	if rule == 1 then
		return string.sub(str, 1, max_string) == string.sub(pattern, 1, max_string)
	end
	if rule == 2 then
		return string.sub(str, 1, patternlength) == string.sub(pattern, 1, patternlength)
	end
	if rule == 3 then
		local mid = string.find(str, pattern, 1, true)
		return mid ~= nil and mid + patternlength - 1 == #str
	end
	if rule == 4 then
		return string.find(str, pattern, 1, true) ~= nil
	end
	-- pattern
	return filematch.matchpattern_with_separator(str, pattern, false, "", false)
end

-- port: prvm_cmds.c VM_bufstr_find L5339-5386 @xonotic-v0.8.6
function prvm_cmds.VM_bufstr_find(prog: any)
	SAFEPARMCOUNTRANGE(prog, 3, 5, "VM_bufstr_find")
	SET_G_FLOAT(prog, OFS_RETURN, -1)
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_bufstr_find: invalid buffer %i used in %s\n", n, prog.name)
		return
	end
	local matchrule = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local match
	if matchrule ~= 0 then
		match = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	else
		match, matchrule =
			detect_match_rule(string.sub(libc.cstr(G_STRING(prog, OFS_PARM0 + 3)), 1, VM_STRINGTEMP_LENGTH - 1))
	end
	local matchlen = #match
	local i = if prog.argc > 3 then libc.toint(G_FLOAT(prog, OFS_PARM0 + 9)) else 0
	local step = if prog.argc > 4 then libc.toint(G_FLOAT(prog, OFS_PARM0 + 12)) else 1
	while i < sb.num_strings do
		local str = sb.strings[i]
		if str and match_rule(str, VM_STRINGTEMP_LENGTH, match, matchlen, matchrule) then
			SET_G_FLOAT(prog, OFS_RETURN, i)
			break
		end
		i += step
	end
end

-- port: prvm_cmds.c VM_matchpattern L5394-5426 @xonotic-v0.8.6
function prvm_cmds.VM_matchpattern(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 4, "VM_matchpattern")
	local str = libc.cstr(G_STRING(prog, OFS_PARM0))
	local matchrule = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local match
	if matchrule ~= 0 then
		match = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	else
		match, matchrule =
			detect_match_rule(string.sub(libc.cstr(G_STRING(prog, OFS_PARM0 + 3)), 1, VM_STRINGTEMP_LENGTH - 1))
	end
	local l = #match
	if prog.argc > 3 then
		-- s += max(0, min((unsigned int)PARM3, strlen(s) - 1)) in size_t
		local u = libc.toint64(G_FLOAT(prog, OFS_PARM0 + 9)) % 4294967296
		local lim = if #str == 0 then 2 ^ 64 - 1 else #str - 1
		local off = math.min(u, lim)
		str = string.sub(str, off + 1)
	end
	SET_G_FLOAT(prog, OFS_RETURN, if match_rule(str, VM_STRINGTEMP_LENGTH, match, l, matchrule) then 1 else 0)
end

-- port: prvm_cmds.c VM_tokenize L2594-2622 @xonotic-v0.8.6
function prvm_cmds.VM_tokenize(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_tokenize")
	local str = tokenize_copy(G_STRING(prog, OFS_PARM0))
	local p: number? = 1
	num_tokens = 0
	while true do
		if num_tokens >= MAXTOKENS then
			break
		end
		-- skip whitespace here to find token start pos
		local q = p :: number
		while (string.byte(str, q) or 0) ~= 0 and common.ISWHITESPACE(string.byte(str, q) or 0) do
			q += 1
		end
		tokens_startpos[num_tokens] = q - 1
		local ok
		ok, p = common.COM_ParseToken_VM_Tokenize(str, q, false)
		if not ok then
			break
		end
		tokens_endpos[num_tokens] = (p :: number) - 1
		tokens[num_tokens] = prvm_edict.PRVM_SetTempString(prog, common.com_token)
		num_tokens += 1
	end
	SET_G_FLOAT(prog, OFS_RETURN, num_tokens)
end

-- port: prvm_cmds.c VM_strpad L5843-5857 @xonotic-v0.8.6 ("%*s" with -pad: < 0 = left padding)
function prvm_cmds.VM_strpad(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_strpad")
	local pad = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local src = prvm_cmds.VM_VarString(prog, 1, VM_STRINGTEMP_LENGTH)
	local w = -pad
	local out
	if w < 0 then
		out = libc.format1("-", if w == -2147483648 then 2147483648 else -w, -1, "s", src)
	else
		out = libc.format1("", w, -1, "s", src)
	end
	if #out > VM_STRINGTEMP_LENGTH - 1 then
		out = string.sub(out, 1, VM_STRINGTEMP_LENGTH - 1)
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, out))
end

-- port: prvm_cmds.c chrconv_number L5714-5738 @xonotic-v0.8.6
local function chrconv_number(i: number, base: number, conv: number): number
	i -= base
	if conv == 1 then
		base = 48
	elseif conv == 2 then
		base = 48 + 128
	elseif conv == 3 then
		base = 48 - 30
	elseif conv == 4 then
		base = 48 + 128 - 30
	end
	return i + base
end
-- port: prvm_cmds.c chrconv_punct L5739-5755 @xonotic-v0.8.6
local function chrconv_punct(i: number, base: number, conv: number): number
	i -= base
	if conv == 1 then
		base = 0
	elseif conv == 2 then
		base = 128
	end
	return i + base
end
-- port: prvm_cmds.c chrchar_alpha L5757-5793 @xonotic-v0.8.6
local function chrchar_alpha(
	i: number,
	basec: number,
	baset: number,
	convc: number,
	convt: number,
	charnum: number
): number
	-- convert case and colour seperatly...
	i -= baset + basec
	if convt == 1 then
		baset = 0
	elseif convt == 2 then
		baset = 128
	elseif convt == 5 or convt == 6 then
		baset = if bit32.band(charnum, 1) == convt - 5 then 128 else 0
	end
	if convc == 1 then
		basec = 97
	elseif convc == 2 then
		basec = 65
	end
	return i + basec + baset
end

-- port: prvm_cmds.c VM_strconv L5796-5840 @xonotic-v0.8.6 (results stored in unsigned char)
function prvm_cmds.VM_strconv(prog: any)
	SAFEPARMCOUNTRANGE(prog, 3, 8, "VM_strconv")
	local ccase = libc.toint(G_FLOAT(prog, OFS_PARM0)) -- 0 same, 1 lower, 2 upper
	local redalpha = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local rednum = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	local res = prvm_cmds.VM_VarString(prog, 3, VM_STRINGTEMP_LENGTH)
	local out = table.create(#res)
	for i = 1, #res do
		local r = string.byte(res, i)
		local ci = i - 1
		local v
		if r >= 48 and r <= 57 then -- normal numbers...
			v = chrconv_number(r, 48, rednum)
		elseif r >= 48 + 128 and r <= 57 + 128 then
			v = chrconv_number(r, 48 + 128, rednum)
		elseif r >= 48 + 128 - 30 and r <= 57 + 128 - 30 then
			v = chrconv_number(r, 48 + 128 - 30, rednum)
		elseif r >= 48 - 30 and r <= 57 - 30 then
			v = chrconv_number(r, 48 - 30, rednum)
		elseif r >= 97 and r <= 122 then
			v = chrchar_alpha(r, 97, 0, ccase, redalpha, ci)
		elseif r >= 65 and r <= 90 then
			v = chrchar_alpha(r, 65, 0, ccase, redalpha, ci)
		elseif r >= 97 + 128 and r <= 122 + 128 then
			v = chrchar_alpha(r, 97, 128, ccase, redalpha, ci)
		elseif r >= 65 + 128 and r <= 90 + 128 then
			v = chrchar_alpha(r, 65, 128, ccase, redalpha, ci)
		elseif bit32.band(r, 127) < 16 or redalpha == 0 then -- special chars..
			v = r
		elseif r < 128 then
			v = chrconv_punct(r, 0, redalpha)
		else
			v = chrconv_punct(r, 128, redalpha)
		end
		out[i] = string.char(v % 256)
	end
	-- a converted byte can be 0: the C string ends there
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_strireplace L2436-2493 @xonotic-v0.8.6 (tolower: C locale)
function prvm_cmds.VM_strireplace(prog: any)
	SAFEPARMCOUNT(prog, 3, "VM_strreplace")
	local search = libc.cstr(G_STRING(prog, OFS_PARM0))
	local replace = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	local subject = libc.cstr(G_STRING(prog, OFS_PARM0 + 6))
	local sl, rl, subl = #search, #replace, #subject
	local lsearch, lsubject = string.lower(search), string.lower(subject)
	local out = {}
	local si = 0
	local cap = VM_STRINGTEMP_LENGTH - 1
	local function put(ch: string)
		if si < cap then
			table.insert(out, ch)
			si += 1
		end
	end
	local i = 0
	while i <= subl - sl do
		local j = 0
		while j < sl and string.byte(lsubject, i + j + 1) == string.byte(lsearch, j + 1) do
			j += 1
		end
		if j == sl then
			for k = 1, rl do
				if si >= cap then
					break
				end
				put(string.sub(replace, k, k))
			end
			if sl > 0 then
				i += sl - 1
			else
				put(string.sub(subject, i + 1, i + 1))
			end
		else
			put(string.sub(subject, i + 1, i + 1))
		end
		i += 1
	end
	while i < subl do
		put(string.sub(subject, i + 1, i + 1))
		i += 1
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, table.concat(out)))
end

-- port: prvm_cmds.c VM_isfunction L6479-6496 @xonotic-v0.8.6
function prvm_cmds.VM_isfunction(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_isfunction")
	local str = G_STRING(prog, OFS_PARM0)
	prvm_cmds.VM_CheckEmptyString(prog, str)
	SET_G_FLOAT(prog, OFS_RETURN, if prvm_edict.PRVM_ED_FindFunction(prog, libc.cstr(str)) then 1 else 0)
end

-- port: prvm_cmds.c VM_callfunction L6439-6470 @xonotic-v0.8.6
function prvm_cmds.VM_callfunction(prog: any)
	SAFEPARMCOUNTRANGE(prog, 1, 8, "VM_callfunction")
	local str = libc.cstr(G_STRING(prog, OFS_PARM0 + (prog.argc - 1) * 3))
	prvm_cmds.VM_CheckEmptyString(prog, str)
	local func, fnum = prvm_edict.PRVM_ED_FindFunction(prog, str)
	if not func then
		prog.error_cmd(string.format("VM_callfunciton: function %s not found !", str))
	elseif (func :: any).first_statement < 0 then
		-- negative statements are built in functions
		local builtinnumber = -(func :: any).first_statement
		local b = if builtinnumber < prog.numbuiltins then prog.builtins[builtinnumber] else nil
		if b then
			b(prog)
		else
			prog.error_cmd(
				string.format(
					"No such builtin #%i in %s; most likely cause: outdated engine build. Try updating!",
					builtinnumber,
					prog.name
				)
			)
		end
	elseif (fnum :: number) > 0 then
		prog.argc -= 1
		local exec = prog.ExecuteProgram
		if not exec then
			-- prvm_edict.ExecuteProgram dispatches like this (and keeps the two modules)
			exec = prvm_edict.ExecuteProgram
		end
		exec(prog, fnum, "")
		prog.argc += 1
	end
end

-- port: prvm_cmds.c VM_gettime L2881-2919 @xonotic-v0.8.6 (no CONFIG_CD on the dedicated server)
function prvm_cmds.VM_gettime(prog: any)
	SAFEPARMCOUNTRANGE(prog, 0, 1, "VM_gettime")
	local realtime = prvm_edict.realtime
	if prog.argc == 0 then
		SET_G_FLOAT(prog, OFS_RETURN, R(realtime))
		return
	end
	local timer_index = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if timer_index == 0 or timer_index == 3 then -- GETTIME_FRAMESTART, GETTIME_UPTIME
		SET_G_FLOAT(prog, OFS_RETURN, realtime)
	elseif timer_index == 1 then -- GETTIME_REALTIME
		SET_G_FLOAT(prog, OFS_RETURN, prvm_cmds.Sys_DirtyTime())
	elseif timer_index == 2 then -- GETTIME_HIRES
		SET_G_FLOAT(prog, OFS_RETURN, prvm_cmds.Sys_DirtyTime() - (prvm_cmds.host_dirtytime or 0))
	else
		prvm_cmds.VM_Warning(prog, "VM_gettime: %s: unsupported timer specified, returning realtime\n", prog.name)
		SET_G_FLOAT(prog, OFS_RETURN, realtime)
	end
end

-- sys_shared.c Sys_DirtyTime: seconds since an arbitrary start (os.clock is the monotonic clock in Luau;
-- host.luau replaces this with the platform clock when it exists)
prvm_cmds.Sys_DirtyTime = function(): number
	return os.clock()
end

local function xfunction_name(prog: any): string
	local f = prog.functions[(prog.xfunction or 0) + 1]
	return prvm_edict.PRVM_GetString(prog, if f then f.s_name else 0)
end

-- port: prvm_cmds.c VM_error L328-339 @xonotic-v0.8.6
function prvm_cmds.VM_error(prog: any)
	local str = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	console.Con_Print(string.format("======%s ERROR in %s:\n%s\n", prog.name, xfunction_name(prog), str))
	local ed = buffer.readi32(prog.globals, GlobalOfs(prog, "self") * 4)
	prvm_edict.PRVM_ED_Print(prog, ed, nil)
	prog.error_cmd(
		string.format(
			"%s: Program error in function %s:\n%s\nTip: read above for entity information\n",
			prog.name,
			xfunction_name(prog),
			str
		)
	)
end

-- port: prvm_cmds.c VM_objerror L351-362 @xonotic-v0.8.6
function prvm_cmds.VM_objerror(prog: any)
	local str = prvm_cmds.VM_VarString(prog, 0, VM_STRINGTEMP_LENGTH)
	console.Con_Print("======OBJECT ERROR======\n")
	local ed = buffer.readi32(prog.globals, GlobalOfs(prog, "self") * 4)
	prvm_edict.PRVM_ED_Print(prog, ed, nil)
	prvm_edict.PRVM_ED_Free(prog, ed)
	console.Con_Print(
		string.format(
			"%s OBJECT ERROR in %s:\n%s\nTip: read above for entity information\n",
			prog.name,
			xfunction_name(prog),
			str
		)
	)
end

-- port: prvm_cmds.c VM_eprint L1400-1405 @xonotic-v0.8.6
function prvm_cmds.VM_eprint(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_eprint")
	prvm_edict.PRVM_ED_PrintNum(prog, G_EDICTNUM(prog, OFS_PARM0), nil)
end

-- port: prvm_cmds.c VM_coredump L1327-1334 @xonotic-v0.8.6
function prvm_cmds.VM_coredump(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_coredump")
	cmd.Cbuf_AddText("prvm_edicts ")
	cmd.Cbuf_AddText(prog.name)
	cmd.Cbuf_AddText("\n")
end

-- port: prvm_cmds.c VM_traceon L1372-1377 @xonotic-v0.8.6
function prvm_cmds.VM_traceon(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_traceon")
	prog.trace = true
end

-- port: prvm_cmds.c VM_traceoff L1386-1391 @xonotic-v0.8.6
function prvm_cmds.VM_traceoff(prog: any)
	SAFEPARMCOUNT(prog, 0, "VM_traceoff")
	prog.trace = false
end

-- port: prvm_cmds.c VM_break L598-601 @xonotic-v0.8.6
function prvm_cmds.VM_break(prog: any)
	prog.error_cmd(string.format("%s: break statement", prog.name))
end

-- port: prvm_cmds.c VM_precache_file L1313-1318 @xonotic-v0.8.6
function prvm_cmds.VM_precache_file(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_precache_file")
	-- precache_file is only used to copy files with qcc, it does nothing
	SET_G_INT(prog, OFS_RETURN, buffer.readi32(prog.globals, OFS_PARM0 * 4))
end

-- port: prvm_cmds.c VM_entityfieldtype L2059-2073 @xonotic-v0.8.6
function prvm_cmds.VM_entityfieldtype(prog: any)
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if i < 0 or i >= #prog.fielddefs then
		prvm_cmds.VM_Warning(prog, "VM_entityfieldtype: %s: field index out of bounds\n", prog.name)
		SET_G_FLOAT(prog, OFS_RETURN, -1.0)
		return
	end
	SET_G_FLOAT(prog, OFS_RETURN, prog.fielddefs[i + 1].type)
end

-- port: prvm_cmds.c VM_getentityfieldstring L2083-2124 @xonotic-v0.8.6
function prvm_cmds.VM_getentityfieldstring(prog: any)
	-- put the data into a string
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if i < 0 or i >= #prog.fielddefs then
		prvm_cmds.VM_Warning(prog, "VM_entityfielddata: %s: field index out of bounds\n", prog.name)
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, ""))
		return
	end
	local d = prog.fielddefs[i + 1]
	local ent = G_EDICTNUM(prog, OFS_PARM0 + 3)
	if prog.ed_free[ent] then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, ""))
		prvm_cmds.VM_Warning(prog, "VM_entityfielddata: %s: entity %i is free !\n", prog.name, ent)
		return
	end
	local o = E_OFS(prog, ent, d.ofs)
	-- if it's 0 or blank, return an empty string
	local t = bit32.band(d.type, 0x7FFF)
	local size = ({ 1, 1, 1, 3, 1, 1, 1, 2 })[t + 1] or 1
	local nonzero = false
	for j = 0, size - 1 do
		if o + j * 4 + 4 <= buffer.len(prog.edictsfields) and buffer.readi32(prog.edictsfields, o + j * 4) ~= 0 then
			nonzero = true
			break
		end
	end
	if not nonzero then
		SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, ""))
		return
	end
	local str = prvm_edict.PRVM_UglyValueString(prog, d.type, prog.edictsfields, o, 16384)
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, str))
end

-- port: prvm_cmds.c VM_putentityfieldstring L2134-2160 @xonotic-v0.8.6
function prvm_cmds.VM_putentityfieldstring(prog: any)
	local i = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if i < 0 or i >= #prog.fielddefs then
		prvm_cmds.VM_Warning(prog, "VM_entityfielddata: %s: field index out of bounds\n", prog.name)
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end
	local d = prog.fielddefs[i + 1]
	local ent = G_EDICTNUM(prog, OFS_PARM0 + 3)
	if prog.ed_free[ent] then
		prvm_cmds.VM_Warning(prog, "VM_entityfielddata: %s: entity %i is free !\n", prog.name, ent)
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end
	-- parse the string into the value
	local ok = prvm_edict.PRVM_ED_ParseEpair(prog, ent, d, G_STRING(prog, OFS_PARM0 + 6), false)
	SET_G_FLOAT(prog, OFS_RETURN, if ok then 1 else 0)
end

-- port: prvm_cmds.c VM_writetofile L1988-2010 @xonotic-v0.8.6 (VM_GetFileHandle L1779-1792)
function prvm_cmds.VM_writetofile(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_writetofile")
	local index = libc.toint(G_FLOAT(prog, OFS_PARM0))
	local file = nil
	if index < 0 or index >= PRVM_MAX_OPENFILES then
		console.Con_Print(string.format("VM_GetFileHandle: invalid file handle %i used in %s\n", index, prog.name))
	elseif openfiles(prog)[index] == nil then
		console.Con_Print(
			string.format(
				"VM_GetFileHandle: no such file handle %i (or file has been closed) in %s\n",
				index,
				prog.name
			)
		)
	else
		file = openfiles(prog)[index]
	end
	if not file then
		prvm_cmds.VM_Warning(prog, "VM_writetofile: invalid or closed file handle\n")
		return
	end
	local ent = G_EDICTNUM(prog, OFS_PARM0 + 3)
	if prog.ed_free[ent] then
		prvm_cmds.VM_Warning(prog, "VM_writetofile: %s: entity %i is free !\n", prog.name, ent)
		return
	end
	prvm_edict.PRVM_ED_Write(prog, file, ent)
end

-- port: prvm_cmds.c VM_parseentitydata L2989-3008 @xonotic-v0.8.6
function prvm_cmds.VM_parseentitydata(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_parseentitydata")
	-- get edict and test it
	local ent = G_EDICTNUM(prog, OFS_PARM0)
	if prog.ed_free[ent] then
		prog.error_cmd(
			string.format(
				"VM_parseentitydata: %s: Can only set already spawned entities (entity %i is free)!",
				prog.name,
				ent
			)
		)
	end
	local data = libc.cstr(G_STRING(prog, OFS_PARM0 + 3))
	-- parse the opening brace
	local ok, pos = common.COM_ParseToken_Simple(data, 1, false, false, true)
	if not ok or string.sub(common.com_token, 1, 1) ~= "{" then
		prog.error_cmd(
			string.format(
				"VM_parseentitydata: %s: Couldn't parse entity data:\n%s",
				prog.name,
				if pos then string.sub(data, pos) else ""
			)
		)
	end
	prvm_edict.PRVM_ED_ParseEdict(prog, data, pos, ent)
end

-- port: prvm_cmds.c VM_loadfromdata L2975-2980 @xonotic-v0.8.6
function prvm_cmds.VM_loadfromdata(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_loadentsfromfile")
	prvm_edict.PRVM_ED_LoadFromFile(prog, libc.cstr(G_STRING(prog, OFS_PARM0)))
end

-- port: prvm_cmds.c VM_loadfromfile L3017-3041 @xonotic-v0.8.6
function prvm_cmds.VM_loadfromfile(prog: any)
	SAFEPARMCOUNT(prog, 1, "VM_loadfromfile")
	local filename = libc.cstr(G_STRING(prog, OFS_PARM0))
	if fs.FS_CheckNastyPath(filename, false) ~= 0 then
		SET_G_FLOAT(prog, OFS_RETURN, -4)
		prvm_cmds.VM_Warning(
			prog,
			'VM_loadfromfile: %s dangerous or non-portable filename "%s" not allowed. (contains : or \\ or begins with .. or /)\n',
			prog.name,
			filename
		)
		return
	end
	-- not conform with VM_fopen
	local data = fs.FS_LoadFile(filename, false)
	if data == nil then
		SET_G_FLOAT(prog, OFS_RETURN, -1)
	end
	-- PRVM_ED_LoadFromFile(prog, NULL) parses nothing
	prvm_edict.PRVM_ED_LoadFromFile(prog, libc.cstr(data or ""))
end

-- port: prvm_cmds.c VM_buf_loadfile L5093-5166 @xonotic-v0.8.6
function prvm_cmds.VM_buf_loadfile(prog: any)
	SAFEPARMCOUNT(prog, 2, "VM_buf_loadfile")
	-- get file
	local filename = libc.cstr(G_STRING(prog, OFS_PARM0))
	local file = fs.FS_OpenVirtualFile(string.sub("data/" .. filename, 1, 1023), false)
	if file == nil then
		file = fs.FS_OpenVirtualFile(string.sub(filename, 1, 1023), false)
	end
	if file == nil then
		if developer_extra() then
			prvm_cmds.VM_Warning(prog, "VM_buf_loadfile: failed to open file %s in %s\n", filename, prog.name)
		end
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end
	-- get string buffer
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_buf_loadfile: invalid buffer %i used in %s\n", n, prog.name)
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end
	-- read file (append to the end of buffer)
	local strindex = sb.num_strings
	while true do
		-- read line
		local out = {}
		local c
		while true do
			c = fs.FS_Getc(file)
			if c == 13 or c == 10 or c < 0 then
				break
			end
			if #out < VM_STRINGTEMP_LENGTH - 1 then
				table.insert(out, string.char(c))
			end
		end
		-- remove \n following \r
		if c == 13 then
			c = fs.FS_Getc(file)
			if c ~= 10 then
				fs.FS_UnGetc(file, c % 256)
			end
		end
		-- add and continue
		if c >= 0 or #out > 0 then
			BufStr_Expand(sb, strindex)
			sb.num_strings = math.max(sb.num_strings, strindex + 1)
			sb.strings[strindex] = libc.cstr(table.concat(out))
			strindex = sb.num_strings
		else
			break
		end
	end
	-- close file
	fs.FS_Close(file)
	SET_G_FLOAT(prog, OFS_RETURN, 1)
end

-- port: prvm_cmds.c VM_buf_writefile L5176-5248 @xonotic-v0.8.6
function prvm_cmds.VM_buf_writefile(prog: any)
	SAFEPARMCOUNTRANGE(prog, 2, 4, "VM_buf_writefile")
	-- get file
	local filenum = libc.toint(G_FLOAT(prog, OFS_PARM0))
	if filenum < 0 or filenum >= PRVM_MAX_OPENFILES then
		prvm_cmds.VM_Warning(prog, "VM_buf_writefile: invalid file handle %i used in %s\n", filenum, prog.name)
		return
	end
	local file = openfiles(prog)[filenum]
	if file == nil then
		prvm_cmds.VM_Warning(
			prog,
			"VM_buf_writefile: no such file handle %i (or file has been closed) in %s\n",
			filenum,
			prog.name
		)
		return
	end
	-- get string buffer
	local n = libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))
	local sb = RecordAtIndex(prog, n)
	if not sb then
		prvm_cmds.VM_Warning(prog, "VM_buf_writefile: invalid buffer %i used in %s\n", n, prog.name)
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end
	-- get start and end parms
	local strindex, strnum
	if prog.argc > 3 then
		strindex = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
		strnum = libc.toint(G_FLOAT(prog, OFS_PARM0 + 9))
	elseif prog.argc > 2 then
		strindex = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
		strnum = sb.num_strings - strindex
	else
		strindex = 0
		strnum = sb.num_strings
	end
	if strindex < 0 or strindex >= sb.num_strings then
		prvm_cmds.VM_Warning(prog, "VM_buf_writefile: wrong start string index %i used in %s\n", strindex, prog.name)
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end
	if strnum < 0 then
		prvm_cmds.VM_Warning(prog, "VM_buf_writefile: wrong strings count %i used in %s\n", strnum, prog.name)
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end
	-- write
	while strindex < sb.num_strings and strnum ~= 0 do
		local str = sb.strings[strindex]
		if str then
			if #str > 0 then
				fs.FS_Write(file, str)
			end
			fs.FS_Write(file, "\n")
		end
		strindex += 1
		strnum -= 1
	end
	SET_G_FLOAT(prog, OFS_RETURN, 1)
end

-- port: prvm_cmds.c VM_SetTraceGlobals L5998-6013 @xonotic-v0.8.6 (trace: collision.trace_t; trace.ent is an
-- edict number or nil = NULL; the qboolean fields are stored as 1 / 0, the double fraction / endpos as float)
function prvm_cmds.VM_SetTraceGlobals(prog: any, trace: any)
	local function b(x: boolean): number
		return if x then 1 else 0
	end
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_allsolid"), b(trace.allsolid))
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_startsolid"), b(trace.startsolid))
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_fraction"), trace.fraction)
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_inwater"), b(trace.inwater))
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_inopen"), b(trace.inopen))
	SET_G_VECTOR(prog, GlobalOfs(prog, "trace_endpos"), trace.endpos)
	SET_G_VECTOR(prog, GlobalOfs(prog, "trace_plane_normal"), trace.plane.normal)
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_plane_dist"), trace.plane.dist)
	SET_G_INT(prog, GlobalOfs(prog, "trace_ent"), if trace.ent ~= nil then trace.ent else 0)
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_dpstartcontents"), trace.startsupercontents)
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_dphitcontents"), trace.hitsupercontents)
	SET_G_FLOAT(prog, GlobalOfs(prog, "trace_dphitq3surfaceflags"), trace.hitq3surfaceflags)
	SET_G_INT(
		prog,
		GlobalOfs(prog, "trace_dphittexturename"),
		if trace.hittexture then prvm_edict.PRVM_SetTempString(prog, trace.hittexture.name) else 0
	)
end

--[[
	surface querying (prvm_cmds.c L6830-7260)

	Models are the dp_model_t tables of engine/model_brush.luau: data_surfaces is 1-based (C surface i at
	[i + 1]); surfmesh float arrays are f32 buffers (float k at byte 4 * k), data_element3i an i32 buffer.
	A `float *` into such an array (animatemodel_cache->data_vertex3f, ...) is the buffer. Edicts are numbers
	(0 = the world). vec_t is float: every float operation is rounded (D-004); int -> float conversions too.
	prog->animatemodel_cache is prog.animatemodel_cache (nil = NULL). VM_Cmd_Reset (which calls
	animatemodel_reset) is not ported; a new prog table starts without a cache, as the memset prog does in C.
]]
local readf32, readi32 = buffer.readf32, buffer.readi32

local notported_surface: { [string]: boolean } = {}
local function NOT_YET_PORTED(what: string)
	if not notported_surface[what] then
		notported_surface[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- float[3] at element `i` (C: array + 3 * i) of an f32 buffer, as a new vec3
local function vec3at(b: buffer, i: number): { number }
	return { readf32(b, 12 * i), readf32(b, 12 * i + 4), readf32(b, 12 * i + 8) }
end

local lazy_sv_main: any, lazy_svvm_cmds: any = nil, nil

-- port: prvm_cmds.c getmodel L6832-6840 @xonotic-v0.8.6
local function getmodel(prog: any, ed: number): any
	if prog == cvar.prvm_prog_list[0] then -- SVVM_prog
		if not lazy_sv_main then
			lazy_sv_main = require("./sv_main") -- sv_main -> svvm_cmds -> this module (kept: require() is slow)
		end
		return lazy_sv_main.SV_GetModelFromEdict(ed)
	elseif prog == cvar.prvm_prog_list[1] then -- CLVM_prog
		NOT_YET_PORTED("CL_GetModelFromEdict (cl_main.c) in prvm_cmds.c getmodel")
		return nil
	else
		return nil
	end
end

-- struct animatemodel_cache (prvm_cmds.c L6842-6857): model, frameblend[MAX_FRAMEBLENDS], skeleton_p, skeleton,
-- data_vertex3f / svector3f / tvector3f / normal3f, max_vertices, buf_vertex3f / svector3f / tvector3f / normal3f
local function new_animatemodel_cache(): any
	return {
		model = nil,
		frameblend = nil,
		skeleton_p = nil,
		skeleton = nil,
		data_vertex3f = nil,
		data_svector3f = nil,
		data_tvector3f = nil,
		data_normal3f = nil,
		max_vertices = 0,
		buf_vertex3f = nil,
		buf_svector3f = nil,
		buf_tvector3f = nil,
		buf_normal3f = nil,
	}
end

-- port: prvm_cmds.c animatemodel_reset L6859-6868 @xonotic-v0.8.6
-- (C frees the cache without setting prog->animatemodel_cache to NULL: its only caller, VM_Cmd_Reset, runs in
-- PRVM_Prog_Reset just before memset(prog, 0); the nil here is that memset)
function prvm_cmds.animatemodel_reset(prog: any)
	if not prog.animatemodel_cache then
		return
	end
	-- Mem_Free of the four buffers and of the cache
	prog.animatemodel_cache = nil
end

-- port: prvm_cmds.c animatemodel L6870-6925 @xonotic-v0.8.6
-- Ported: the cache allocation and the path of models without vertex animation (brush models: the cache points
-- at the model's own arrays). NOT YET PORTED: the animated path (alias models with surfmesh.isanimated and
-- AnimateVertices: VM_GenerateFrameGroupBlend, VM_FrameBlendFromFrameGroupBlend, the skeleton check,
-- VM_UpdateEdictSkeleton and model->AnimateVertices into the cache buffers, model_alias.c). Until it is ported it
-- logs once and leaves the cache on the model's unanimated base arrays (the C would fill the buffers with the
-- vertices of the entity's current frame blend).
local function animatemodel(prog: any, model: any, _ed: number)
	local animatemodel_cache
	if not prog.animatemodel_cache then
		prog.animatemodel_cache = new_animatemodel_cache() -- Mem_Alloc + memset 0
	end
	animatemodel_cache = prog.animatemodel_cache
	if not (model.surfmesh.isanimated and model.AnimateVertices) then
		animatemodel_cache.data_vertex3f = model.surfmesh.data_vertex3f
		animatemodel_cache.data_svector3f = model.surfmesh.data_svector3f
		animatemodel_cache.data_tvector3f = model.surfmesh.data_tvector3f
		animatemodel_cache.data_normal3f = model.surfmesh.data_normal3f
		return
	end
	NOT_YET_PORTED(
		"prvm_cmds.c animatemodel L6890-6924 (animated models: frame blend, skeleton, AnimateVertices); the unanimated base vertices are used"
	)
	animatemodel_cache.data_vertex3f = model.surfmesh.data_vertex3f
	animatemodel_cache.data_svector3f = model.surfmesh.data_svector3f
	animatemodel_cache.data_tvector3f = model.surfmesh.data_tvector3f
	animatemodel_cache.data_normal3f = model.surfmesh.data_normal3f
end

-- port: prvm_cmds.c getmatrix L6927-6935 @xonotic-v0.8.6
local function getmatrix(prog: any, ed: number, out: any)
	if prog == cvar.prvm_prog_list[0] then -- SVVM_prog
		if not lazy_svvm_cmds then
			lazy_svvm_cmds = require("./svvm_cmds") -- svvm_cmds requires this module (kept: require() is slow)
		end
		lazy_svvm_cmds.SV_GetEntityMatrix(prog, ed, out, false)
	elseif prog == cvar.prvm_prog_list[1] then -- CLVM_prog
		NOT_YET_PORTED("CL_GetEntityMatrix (csprogs.c) in prvm_cmds.c getmatrix")
		matrixlib.Matrix4x4_CreateIdentity(out) -- (port support: the C would fill it from the client entity)
	else
		matrixlib.Matrix4x4_CreateIdentity(out) -- *out = identitymatrix
	end
end

--[[
	matrixlib.c helpers the surface builtins need that engine/matrixlib.luau does not have yet. They belong in
	that module (one module per C file); they are here only because engine/matrixlib.luau is being extended by
	the alias-model work at the same time. Move them to matrixlib.luau when that lands.
]]
-- Adapted from code contributed to Mesa by David Moore (Mesa 7.6 under SGI Free License B - which is MIT/X11-type)
-- added helper for common subexpression elimination by eihrul, and other optimizations by div0
-- port: matrixlib.c Matrix4x4_Invert_Full L147-197 @xonotic-v0.8.6 (the `#if 1` version; out must not alias in1)
local function Matrix4x4_Invert_Full(out: any, in1: any): number
	local det
	local a, o = in1.m, out.m

	-- note: orientation does not matter, as transpose(invert(transpose(m))) == invert(m), proof:
	--   transpose(invert(transpose(m))) * m
	-- = transpose(invert(transpose(m))) * transpose(transpose(m))
	-- = transpose(transpose(m) * invert(transpose(m)))
	-- = transpose(identity)
	-- = identity

	-- this seems to help gcc's common subexpression elimination, and also makes the code look nicer
	local m00, m01, m02, m03 = a[1][1], a[1][2], a[1][3], a[1][4]
	local m10, m11, m12, m13 = a[2][1], a[2][2], a[2][3], a[2][4]
	local m20, m21, m22, m23 = a[3][1], a[3][2], a[3][3], a[3][4]
	local m30, m31, m32, m33 = a[4][1], a[4][2], a[4][3], a[4][4]

	-- (x*(p*q - r*s)): every product and difference is a float operation
	local function d(p: number, q: number, r: number, s: number): number
		return R(R(p * q) - R(r * s))
	end
	-- (x*X - y*Y + z*Z), evaluated left to right
	local function t3(x: number, xx: number, y: number, yy: number, z: number, zz: number): number
		return R(R(R(x * xx) - R(y * yy)) + R(z * zz))
	end

	-- calculate the adjoint
	o[1][1] = t3(m11, d(m22, m33, m23, m32), m21, d(m12, m33, m13, m32), m31, d(m12, m23, m13, m22))
	o[1][2] = -t3(m01, d(m22, m33, m23, m32), m21, d(m02, m33, m03, m32), m31, d(m02, m23, m03, m22))
	o[1][3] = t3(m01, d(m12, m33, m13, m32), m11, d(m02, m33, m03, m32), m31, d(m02, m13, m03, m12))
	o[1][4] = -t3(m01, d(m12, m23, m13, m22), m11, d(m02, m23, m03, m22), m21, d(m02, m13, m03, m12))
	o[2][1] = -t3(m10, d(m22, m33, m23, m32), m20, d(m12, m33, m13, m32), m30, d(m12, m23, m13, m22))
	o[2][2] = t3(m00, d(m22, m33, m23, m32), m20, d(m02, m33, m03, m32), m30, d(m02, m23, m03, m22))
	o[2][3] = -t3(m00, d(m12, m33, m13, m32), m10, d(m02, m33, m03, m32), m30, d(m02, m13, m03, m12))
	o[2][4] = t3(m00, d(m12, m23, m13, m22), m10, d(m02, m23, m03, m22), m20, d(m02, m13, m03, m12))
	o[3][1] = t3(m10, d(m21, m33, m23, m31), m20, d(m11, m33, m13, m31), m30, d(m11, m23, m13, m21))
	o[3][2] = -t3(m00, d(m21, m33, m23, m31), m20, d(m01, m33, m03, m31), m30, d(m01, m23, m03, m21))
	o[3][3] = t3(m00, d(m11, m33, m13, m31), m10, d(m01, m33, m03, m31), m30, d(m01, m13, m03, m11))
	o[3][4] = -t3(m00, d(m11, m23, m13, m21), m10, d(m01, m23, m03, m21), m20, d(m01, m13, m03, m11))
	o[4][1] = -t3(m10, d(m21, m32, m22, m31), m20, d(m11, m32, m12, m31), m30, d(m11, m22, m12, m21))
	o[4][2] = t3(m00, d(m21, m32, m22, m31), m20, d(m01, m32, m02, m31), m30, d(m01, m22, m02, m21))
	o[4][3] = -t3(m00, d(m11, m32, m12, m31), m10, d(m01, m32, m02, m31), m30, d(m01, m12, m02, m11))
	o[4][4] = t3(m00, d(m11, m22, m12, m21), m10, d(m01, m22, m02, m21), m20, d(m01, m12, m02, m11))

	-- calculate the determinant (as inverse == 1/det * adjoint, adjoint * m == identity * det, so this calculates the det)
	det = R(R(R(R(m00 * o[1][1]) + R(m10 * o[1][2])) + R(m20 * o[1][3])) + R(m30 * o[1][4]))
	if det == 0.0 then
		return 0
	end

	-- multiplications are faster than divisions, usually
	det = R(1.0 / det)

	-- manually unrolled loop to multiply all matrix elements by 1/det
	for r = 1, 4 do
		local row = o[r]
		row[1] = R(row[1] * det)
		row[2] = R(row[2] * det)
		row[3] = R(row[3] * det)
		row[4] = R(row[4] * det)
	end

	return 1
end

-- port: matrixlib.c Matrix4x4_Transform3x3 L1687-1698 @xonotic-v0.8.6 (#else branch; out must not alias v)
local function Matrix4x4_Transform3x3(in_: any, v: { number }, out: { number })
	local m = in_.m
	local v1, v2, v3 = v[1], v[2], v[3]
	out[1] = R(R(R(v1 * m[1][1]) + R(v2 * m[1][2])) + R(v3 * m[1][3]))
	out[2] = R(R(R(v1 * m[2][1]) + R(v2 * m[2][2])) + R(v3 * m[2][3]))
	out[3] = R(R(R(v1 * m[3][1]) + R(v2 * m[3][2])) + R(v3 * m[3][3]))
end

-- port: prvm_cmds.c applytransform_forward L6937-6942 @xonotic-v0.8.6
local function applytransform_forward(prog: any, in_: { number }, ed: number, out: { number })
	local m = matrixlib.new()
	getmatrix(prog, ed, m)
	matrixlib.Matrix4x4_Transform(m, in_, out)
end

-- port: prvm_cmds.c applytransform_forward_direction L6944-6949 @xonotic-v0.8.6
local function applytransform_forward_direction(prog: any, in_: { number }, ed: number, out: { number })
	local m = matrixlib.new()
	getmatrix(prog, ed, m)
	Matrix4x4_Transform3x3(m, in_, out)
end

-- port: prvm_cmds.c applytransform_inverted L6951-6957 @xonotic-v0.8.6
-- (engine quirk kept: the inverted matrix goes through Matrix4x4_Transform3x3, so its translation is dropped;
-- the point is only rotated / scaled back, never moved by -origin. getsurfaceclippedpoint adds the origin back
-- afterwards, getsurfacenearpoint does not. If the inverse does not exist, n keeps the unscaled adjoint
-- Matrix4x4_Invert_Full wrote before it returned 0, as in C.)
local function applytransform_inverted(prog: any, in_: { number }, ed: number, out: { number })
	local m, n = matrixlib.new(), matrixlib.new()
	getmatrix(prog, ed, m)
	Matrix4x4_Invert_Full(n, m)
	Matrix4x4_Transform3x3(n, in_, out)
end

-- port: prvm_cmds.c applytransform_forward_normal L6959-6966 @xonotic-v0.8.6
local function applytransform_forward_normal(prog: any, in_: { number }, ed: number, out: { number })
	local m = matrixlib.new()
	getmatrix(prog, ed, m)
	local p1, p2, p3 = matrixlib.Matrix4x4_TransformPositivePlane(m, in_[1], in_[2], in_[3], 0)
	out[1], out[2], out[3] = p1, p2, p3 -- VectorCopy(p, out)
end

-- TriangleNormal (mathlib.h L140-144) on float vectors: each difference, product and sum is a float op
local function TriangleNormal(a: { number }, b: { number }, c: { number }, n: { number })
	n[1] = R(R(R(a[2] - b[2]) * R(c[3] - b[3])) - R(R(a[3] - b[3]) * R(c[2] - b[2])))
	n[2] = R(R(R(a[3] - b[3]) * R(c[1] - b[1])) - R(R(a[1] - b[1]) * R(c[3] - b[3])))
	n[3] = R(R(R(a[1] - b[1]) * R(c[2] - b[2])) - R(R(a[2] - b[2]) * R(c[1] - b[1])))
end

local DotProduct = mathlib.DotProduct
local VectorNormalize = mathlib.VectorNormalize

-- port: prvm_cmds.c clippointtosurface L6968-7003 @xonotic-v0.8.6
local function clippointtosurface(prog: any, ed: number, model: any, surface: any, p: { number }, out: { number })
	local v: { { number } } = {}
	local facenormal, edgenormal, sidenormal, temp = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
	local offsetdist, dist, bestdist
	animatemodel(prog, model, ed)
	bestdist = 1000000000
	out[1], out[2], out[3] = p[1], p[2], p[3]
	local element3i: buffer = model.surfmesh.data_element3i
	local vertex3f: buffer = prog.animatemodel_cache.data_vertex3f
	local e = 12 * surface.num_firsttriangle -- byte offset of (data_element3i + 3 * num_firsttriangle)
	for _ = 0, surface.num_triangles - 1 do
		-- clip original point to each triangle of the surface and find the
		-- triangle that is closest
		v[1] = vec3at(vertex3f, readi32(element3i, e))
		v[2] = vec3at(vertex3f, readi32(element3i, e + 4))
		v[3] = vec3at(vertex3f, readi32(element3i, e + 8))
		TriangleNormal(v[1], v[2], v[3], facenormal)
		VectorNormalize(facenormal)
		offsetdist = R(DotProduct(v[1], facenormal) - DotProduct(p, facenormal))
		-- VectorMA(p, offsetdist, facenormal, temp)
		temp[1] = R(p[1] + R(offsetdist * facenormal[1]))
		temp[2] = R(p[2] + R(offsetdist * facenormal[2]))
		temp[3] = R(p[3] + R(offsetdist * facenormal[3]))
		local j, k = 0, 2
		while j < 3 do
			local vk, vj = v[k + 1], v[j + 1]
			-- VectorSubtract(v[k], v[j], edgenormal)
			edgenormal[1] = R(vk[1] - vj[1])
			edgenormal[2] = R(vk[2] - vj[2])
			edgenormal[3] = R(vk[3] - vj[3])
			-- CrossProduct(edgenormal, facenormal, sidenormal)
			sidenormal[1] = R(R(edgenormal[2] * facenormal[3]) - R(edgenormal[3] * facenormal[2]))
			sidenormal[2] = R(R(edgenormal[3] * facenormal[1]) - R(edgenormal[1] * facenormal[3]))
			sidenormal[3] = R(R(edgenormal[1] * facenormal[2]) - R(edgenormal[2] * facenormal[1]))
			VectorNormalize(sidenormal)
			offsetdist = R(DotProduct(vk, sidenormal) - DotProduct(temp, sidenormal))
			if offsetdist < 0 then
				-- VectorMA(temp, offsetdist, sidenormal, temp)
				temp[1] = R(temp[1] + R(offsetdist * sidenormal[1]))
				temp[2] = R(temp[2] + R(offsetdist * sidenormal[2]))
				temp[3] = R(temp[3] + R(offsetdist * sidenormal[3]))
			end
			k = j
			j += 1
		end
		-- VectorDistance2(temp, p)
		local d1, d2, d3 = R(temp[1] - p[1]), R(temp[2] - p[2]), R(temp[3] - p[3])
		dist = R(R(R(d1 * d1) + R(d2 * d2)) + R(d3 * d3))
		if bestdist > dist then
			bestdist = dist
			out[1], out[2], out[3] = temp[1], temp[2], temp[3]
		end
		e += 12
	end
end

-- port: prvm_cmds.c getsurface L7005-7010 @xonotic-v0.8.6
local function getsurface(model: any, surfacenum: number): any
	if surfacenum < 0 or surfacenum >= model.nummodelsurfaces then
		return nil
	end
	return model.data_surfaces[surfacenum + model.firstmodelsurface + 1]
end

--PF_getsurfacenumpoints, // #434 float(entity e, float s) getsurfacenumpoints = #434;
-- port: prvm_cmds.c VM_getsurfacenumpoints L7014-7028 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacenumpoints(prog: any)
	local model, surface
	SAFEPARMCOUNT(prog, 2, "VM_getsurfacenumpoints")
	-- return 0 if no such surface
	model = getmodel(prog, G_EDICTNUM(prog, OFS_PARM0))
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end

	-- note: this (incorrectly) assumes it is a simple polygon
	SET_G_FLOAT(prog, OFS_RETURN, surface.num_vertices)
end

--PF_getsurfacepoint,     // #435 vector(entity e, float s, float n) getsurfacepoint = #435;
-- port: prvm_cmds.c VM_getsurfacepoint L7030-7049 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacepoint(prog: any)
	local ed, model, surface, pointnum
	local result = { 0, 0, 0 }
	SAFEPARMCOUNT(prog, 3, "VM_getsurfacepoint")
	SET_G_VECTOR(prog, OFS_RETURN, { 0, 0, 0 })
	ed = G_EDICTNUM(prog, OFS_PARM0)
	model = getmodel(prog, ed)
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		return
	end
	-- note: this (incorrectly) assumes it is a simple polygon
	pointnum = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	if pointnum < 0 or pointnum >= surface.num_vertices then
		return
	end
	animatemodel(prog, model, ed)
	applytransform_forward(
		prog,
		vec3at(prog.animatemodel_cache.data_vertex3f, surface.num_firstvertex + pointnum),
		ed,
		result
	)
	SET_G_VECTOR(prog, OFS_RETURN, result)
end

--PF_getsurfacepointattribute,     // #486 vector(entity e, float s, float n, float a) getsurfacepointattribute = #486;
-- float SPA_POSITION = 0;
-- float SPA_S_AXIS = 1;
-- float SPA_T_AXIS = 2;
-- float SPA_R_AXIS = 3; // same as SPA_NORMAL
-- float SPA_TEXCOORDS0 = 4;
-- float SPA_LIGHTMAP0_TEXCOORDS = 5;
-- float SPA_LIGHTMAP0_COLOR = 6;
-- port: prvm_cmds.c VM_getsurfacepointattribute L7058-7127 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacepointattribute(prog: any)
	local ed, model, surface, pointnum, attributetype
	local result = { 0, 0, 0 }

	SAFEPARMCOUNT(prog, 4, "VM_getsurfacepoint")
	SET_G_VECTOR(prog, OFS_RETURN, { 0, 0, 0 })
	ed = G_EDICTNUM(prog, OFS_PARM0)
	model = getmodel(prog, ed)
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		return
	end
	pointnum = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	if pointnum < 0 or pointnum >= surface.num_vertices then
		return
	end
	attributetype = libc.toint(G_FLOAT(prog, OFS_PARM0 + 9))

	animatemodel(prog, model, ed)

	local cache = prog.animatemodel_cache
	local k = surface.num_firstvertex + pointnum
	-- float SPA_POSITION = 0;
	if attributetype == 0 then
		applytransform_forward(prog, vec3at(cache.data_vertex3f, k), ed, result)
		SET_G_VECTOR(prog, OFS_RETURN, result)
	-- float SPA_S_AXIS = 1;
	elseif attributetype == 1 then
		applytransform_forward_direction(prog, vec3at(cache.data_svector3f, k), ed, result)
		SET_G_VECTOR(prog, OFS_RETURN, result)
	-- float SPA_T_AXIS = 2;
	elseif attributetype == 2 then
		applytransform_forward_direction(prog, vec3at(cache.data_tvector3f, k), ed, result)
		SET_G_VECTOR(prog, OFS_RETURN, result)
	-- float SPA_R_AXIS = 3; // same as SPA_NORMAL
	elseif attributetype == 3 then
		applytransform_forward_direction(prog, vec3at(cache.data_normal3f, k), ed, result)
		SET_G_VECTOR(prog, OFS_RETURN, result)
	-- float SPA_TEXCOORDS0 = 4;
	elseif attributetype == 4 then
		local texcoord: buffer = model.surfmesh.data_texcoordtexture2f
		result[1] = readf32(texcoord, 8 * k)
		result[2] = readf32(texcoord, 8 * k + 4)
		result[3] = 0.0
		SET_G_VECTOR(prog, OFS_RETURN, result)
	-- float SPA_LIGHTMAP0_TEXCOORDS = 5;
	elseif attributetype == 5 then
		local texcoord: buffer = model.surfmesh.data_texcoordlightmap2f
		result[1] = readf32(texcoord, 8 * k)
		result[2] = readf32(texcoord, 8 * k + 4)
		result[3] = 0.0
		SET_G_VECTOR(prog, OFS_RETURN, result)
	-- float SPA_LIGHTMAP0_COLOR = 6;
	elseif attributetype == 6 then
		-- ignore alpha for now..
		local color: buffer = model.surfmesh.data_lightmapcolor4f
		SET_G_VECTOR(
			prog,
			OFS_RETURN,
			{ readf32(color, 16 * k), readf32(color, 16 * k + 4), readf32(color, 16 * k + 8) }
		)
	else
		SET_G_VECTOR(prog, OFS_RETURN, { 0.0, 0.0, 0.0 })
	end
end

--PF_getsurfacenormal,    // #436 vector(entity e, float s) getsurfacenormal = #436;
-- port: prvm_cmds.c VM_getsurfacenormal L7129-7146 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacenormal(prog: any)
	local model, surface
	local normal, result = { 0, 0, 0 }, { 0, 0, 0 }
	SAFEPARMCOUNT(prog, 2, "VM_getsurfacenormal")
	SET_G_VECTOR(prog, OFS_RETURN, { 0, 0, 0 })
	model = getmodel(prog, G_EDICTNUM(prog, OFS_PARM0))
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		return
	end
	-- note: this only returns the first triangle, so it doesn't work very
	-- well for curved surfaces or arbitrary meshes
	-- (engine quirk kept: "the first triangle" is the first three vertices of the surface, not its first
	-- element triple)
	animatemodel(prog, model, G_EDICTNUM(prog, OFS_PARM0))
	local vertex3f: buffer = prog.animatemodel_cache.data_vertex3f
	local fv = surface.num_firstvertex
	TriangleNormal(vec3at(vertex3f, fv), vec3at(vertex3f, fv + 1), vec3at(vertex3f, fv + 2), normal)
	applytransform_forward_normal(prog, normal, G_EDICTNUM(prog, OFS_PARM0), result)
	VectorNormalize(result)
	SET_G_VECTOR(prog, OFS_RETURN, result)
end

--PF_getsurfacetexture,   // #437 string(entity e, float s) getsurfacetexture = #437;
-- port: prvm_cmds.c VM_getsurfacetexture L7148-7157 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacetexture(prog: any)
	local model, surface
	SAFEPARMCOUNT(prog, 2, "VM_getsurfacetexture")
	SET_G_INT(prog, OFS_RETURN, 0) -- OFS_NULL
	model = getmodel(prog, G_EDICTNUM(prog, OFS_PARM0))
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		return
	end
	SET_G_INT(prog, OFS_RETURN, prvm_edict.PRVM_SetTempString(prog, surface.texture.name))
end

--PF_getsurfacenearpoint, // #438 float(entity e, vector p) getsurfacenearpoint = #438;
-- port: prvm_cmds.c VM_getsurfacenearpoint L7159-7207 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacenearpoint(prog: any)
	local surfacenum, best
	local clipped, p = { 0, 0, 0 }, { 0, 0, 0 }
	local dist, bestdist
	local ed, model, surface
	local point
	SAFEPARMCOUNT(prog, 2, "VM_getsurfacenearpoint")
	SET_G_FLOAT(prog, OFS_RETURN, -1)
	ed = G_EDICTNUM(prog, OFS_PARM0)
	point = G_VECTOR(prog, OFS_PARM0 + 3)

	-- (!ed: PRVM_G_EDICT is never NULL)
	if prog.ed_free[ed] then
		return
	end
	model = getmodel(prog, ed)
	if not model or model.num_surfaces == 0 then
		return
	end

	animatemodel(prog, model, ed)

	applytransform_inverted(prog, point, ed, p)
	best = -1
	bestdist = 1000000000
	surfacenum = 0
	while surfacenum < model.nummodelsurfaces do
		surface = model.data_surfaces[surfacenum + model.firstmodelsurface + 1]
		-- first see if the nearest point on the surface's box is closer than the previous match
		for i = 1, 3 do
			-- bound(surface->mins[i], p[i], surface->maxs[i]) - p[i]
			local mn, mx = surface.mins[i], surface.maxs[i]
			local b = if p[i] >= mn then (if p[i] < mx then p[i] else mx) else mn
			clipped[i] = R(b - p[i])
		end
		dist = DotProduct(clipped, clipped) -- VectorLength2
		if dist < bestdist then
			-- it is, check the nearest point on the actual geometry
			clippointtosurface(prog, ed, model, surface, p, clipped)
			-- VectorSubtract(clipped, p, clipped)
			clipped[1] = R(clipped[1] - p[1])
			clipped[2] = R(clipped[2] - p[2])
			clipped[3] = R(clipped[3] - p[3])
			dist = R(dist + DotProduct(clipped, clipped))
			if dist < bestdist then
				-- that's closer too, store it as the best match
				best = surfacenum
				bestdist = dist
			end
		end
		surfacenum += 1
	end
	SET_G_FLOAT(prog, OFS_RETURN, best)
end

--PF_getsurfaceclippedpoint, // #439 vector(entity e, float s, vector p) getsurfaceclippedpoint = #439;
-- port: prvm_cmds.c VM_getsurfaceclippedpoint L7209-7225 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfaceclippedpoint(prog: any)
	local ed, model, surface
	local p, out, inp = { 0, 0, 0 }, { 0, 0, 0 }, nil
	SAFEPARMCOUNT(prog, 3, "VM_te_getsurfaceclippedpoint")
	SET_G_VECTOR(prog, OFS_RETURN, { 0, 0, 0 })
	ed = G_EDICTNUM(prog, OFS_PARM0)
	model = getmodel(prog, ed)
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		return
	end
	animatemodel(prog, model, ed)
	inp = G_VECTOR(prog, OFS_PARM0 + 6)
	applytransform_inverted(prog, inp, ed, p)
	clippointtosurface(prog, ed, model, surface, p, out)
	-- VectorAdd(out, PRVM_serveredictvector(ed, origin), PRVM_G_VECTOR(OFS_RETURN))
	local o = prvm_edict.FieldOfs(prog, "origin")
	SET_G_VECTOR(prog, OFS_RETURN, {
		R(out[1] + E_FLOAT(prog, ed, o)),
		R(out[2] + E_FLOAT(prog, ed, o + 1)),
		R(out[3] + E_FLOAT(prog, ed, o + 2)),
	})
end

--PF_getsurfacenumtriangles, // #??? float(entity e, float s) getsurfacenumtriangles = #???;
-- port: prvm_cmds.c VM_getsurfacenumtriangles L7228-7241 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacenumtriangles(prog: any)
	local model, surface
	SAFEPARMCOUNT(prog, 2, "VM_SV_getsurfacenumtriangles")
	-- return 0 if no such surface
	model = getmodel(prog, G_EDICTNUM(prog, OFS_PARM0))
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		SET_G_FLOAT(prog, OFS_RETURN, 0)
		return
	end

	SET_G_FLOAT(prog, OFS_RETURN, surface.num_triangles)
end

--PF_getsurfacetriangle,     // #??? vector(entity e, float s, float n) getsurfacetriangle = #???;
-- port: prvm_cmds.c VM_getsurfacetriangle L7243-7260 @xonotic-v0.8.6
function prvm_cmds.VM_getsurfacetriangle(prog: any)
	local d = { -1, -1, -1 }
	local ed, model, surface, trinum
	SAFEPARMCOUNT(prog, 3, "VM_SV_getsurfacetriangle")
	SET_G_VECTOR(prog, OFS_RETURN, { 0, 0, 0 })
	ed = G_EDICTNUM(prog, OFS_PARM0)
	model = getmodel(prog, ed)
	surface = if model then getsurface(model, libc.toint(G_FLOAT(prog, OFS_PARM0 + 3))) else nil
	if not model or not surface then
		return
	end
	trinum = libc.toint(G_FLOAT(prog, OFS_PARM0 + 6))
	if trinum < 0 or trinum >= surface.num_triangles then
		return
	end
	-- FIXME: implement rotation/scaling
	-- VectorMA(&(data_element3i + 3 * num_firsttriangle)[trinum * 3], num_firstvertex, d, out): each int element
	-- and the int num_firstvertex convert to float, the product and the sum are float ops (the result is the
	-- element's vertex numbers relative to the surface's first vertex)
	local element3i: buffer = model.surfmesh.data_element3i
	local e = 12 * (surface.num_firsttriangle + trinum)
	local fv = R(surface.num_firstvertex)
	SET_G_VECTOR(prog, OFS_RETURN, {
		R(R(readi32(element3i, e)) + R(fv * d[1])),
		R(R(readi32(element3i, e + 4)) + R(fv * d[2])),
		R(R(readi32(element3i, e + 8)) + R(fv * d[3])),
	})
end

--[[
	uri_get (prvm_cmds.c L6145-6358). This port has no libcurl (Roblox servers make no outgoing HTTP for the
	engine; the transport is Roblox only) and no d0_blind_id keys, so both external calls take the path the C
	takes when the library is missing:
	  * Curl_Begin_ToMemory_POST -> Curl_Begin (libcurl.c L878-887): `if(!curl_dll || !cl_curl_enabled.integer)
	    return false;` -- curl_dll is NULL when libcurl could not be loaded.
	  * Crypto_SignDataDetached (crypto.c L2619-2628): pubkeys_havepriv[keyid] is false without a loaded private
	    key, so it returns 0 (the `goto out` paths, no signature header).
	The callback uri_to_string_callback (L6159-6193) is therefore never called.
]]
-- uri_to_prog_t (prvm_cmds.c L6145-6157): prog, starttime, id, buffer[MAX_INPUTLINE], posttype[128], postdata,
-- postlen, sigdata, siglen

-- port: prvm_cmds.c VM_uri_get L6197-6358 @xonotic-v0.8.6
-- uri_get() gets content from an URL and calls a callback "uri_get_callback" with it set as string; an unique ID of the transfer is returned
-- returns 1 on success, and then calls the callback with the ID, 0 or the HTTP status code, and the received data in a string
function prvm_cmds.VM_uri_get(prog: any)
	local url
	local id
	local ret
	local handle
	local posttype = nil
	local postseparator = nil
	local poststringbuffer = -1
	local postkeyid = -1
	local query_string = nil
	local lq

	local _, URI_Get_Callback = prvm_edict.PRVM_ED_FindFunction(prog, "URI_Get_Callback") -- PRVM_allfunction
	if not URI_Get_Callback or URI_Get_Callback == 0 then
		prog.error_cmd(string.format("uri_get called by %s without URI_Get_Callback defined", prog.name))
	end

	SAFEPARMCOUNTRANGE(prog, 2, 6, "VM_uri_get")

	url = libc.cstr(G_STRING(prog, OFS_PARM0))
	id = G_FLOAT(prog, OFS_PARM0 + 3)
	if prog.argc >= 3 then
		posttype = libc.cstr(G_STRING(prog, OFS_PARM0 + 6))
	end
	if prog.argc >= 4 then
		postseparator = libc.cstr(G_STRING(prog, OFS_PARM0 + 9))
	end
	if prog.argc >= 5 then
		poststringbuffer = libc.toint(G_FLOAT(prog, OFS_PARM0 + 12))
	end
	if prog.argc >= 6 then
		postkeyid = libc.toint(G_FLOAT(prog, OFS_PARM0 + 15))
	end
	-- this can't be the prog's mem pool, as curl may call the callback later!
	handle = { prog = prog, starttime = 0, id = 0, buffer = "", posttype = "", postdata = nil, postlen = 0 } :: any
	handle.sigdata = nil :: string?
	handle.siglen = 0

	local q = string.find(url, "?", 1, true) -- strchr(url, '?')
	if q then
		query_string = string.sub(url, q + 1) -- ++query_string
	end
	lq = if query_string then #query_string else 0

	handle.prog = prog
	handle.starttime = prog.starttime
	handle.id = id
	if postseparator and posttype and posttype ~= "" then
		local l = #postseparator
		if poststringbuffer >= 0 then
			local ltotal
			-- "implode"
			local stringbuffer = RecordAtIndex(prog, poststringbuffer)
			if not stringbuffer then
				prvm_cmds.VM_Warning(
					prog,
					"uri_get: invalid buffer %i used in %s\n",
					libc.toint(G_FLOAT(prog, OFS_PARM0)),
					prog.name
				)
				return
			end
			ltotal = 0
			for i = 0, stringbuffer.num_strings - 1 do
				if i > 0 then
					ltotal += l
				end
				if stringbuffer.strings[i] then
					ltotal += #libc.cstr(stringbuffer.strings[i])
				end
			end
			local parts = {}
			handle.postlen = ltotal
			ltotal = 0
			for i = 0, stringbuffer.num_strings - 1 do
				if i > 0 then
					table.insert(parts, postseparator)
					ltotal += l
				end
				if stringbuffer.strings[i] then
					local s = libc.cstr(stringbuffer.strings[i])
					table.insert(parts, s)
					ltotal += #s
				end
			end
			handle.postdata = table.concat(parts)
			if ltotal ~= handle.postlen then
				prog.error_cmd(string.format("%s: string buffer content size mismatch, possible overrun", prog.name))
			end
		else
			handle.postlen = l
			handle.postdata = postseparator
		end
		-- handle->postdata[handle->postlen] = 0, then the query string after it
		-- (memcpy(handle->postdata + handle->postlen + 1, query_string, lq))
		handle.postdata = handle.postdata .. "\0" .. string.sub(query_string or "", 1, lq)
		if postkeyid >= 0 then
			-- POST: we sign postdata \0 query string
			-- Crypto_SignDataDetached returns 0 (no private key loaded): sigdata stays NULL (goto out1)
			handle.siglen = 0
			handle.sigdata = nil
		end
		-- out1:
		handle.posttype = string.sub(posttype, 1, 127) -- strlcpy(handle->posttype, posttype, sizeof(handle->posttype))
		ret = false -- Curl_Begin_ToMemory_POST(url, handle->sigdata, 0, handle->posttype, ...): no libcurl
	else
		if postkeyid >= 0 and query_string then
			-- GET: we sign JUST the query string
			-- Crypto_SignDataDetached returns 0 (no private key loaded): sigdata stays NULL (goto out2)
			handle.siglen = 0
			handle.sigdata = nil
		end
		-- out2:
		handle.postdata = nil
		handle.postlen = 0
		ret = false -- Curl_Begin_ToMemory_POST(url, handle->sigdata, 0, NULL, NULL, 0, ...): no libcurl
	end
	if ret then
		SET_G_INT(prog, OFS_RETURN, 1)
	else
		-- Z_Free of postdata, sigdata and the handle
		handle = nil
		SET_G_INT(prog, OFS_RETURN, 0)
	end
end

prvm_cmds.BUILTINS = {
	VM_cvar = prvm_cmds.VM_cvar,
	VM_cvar_type = prvm_cmds.VM_cvar_type,
	VM_cvar_string = prvm_cmds.VM_cvar_string,
	VM_cvar_defstring = prvm_cmds.VM_cvar_defstring,
	VM_cvar_description = prvm_cmds.VM_cvar_description,
	VM_cvar_set = prvm_cmds.VM_cvar_set,
	VM_registercvar = prvm_cmds.VM_registercvar,
	VM_print = prvm_cmds.VM_print,
	VM_ftos = prvm_cmds.VM_ftos,
	VM_stof = prvm_cmds.VM_stof,
	VM_floor = prvm_cmds.VM_floor,
	VM_pow = prvm_cmds.VM_pow,
	VM_strlen = prvm_cmds.VM_strlen,
	VM_strcat = prvm_cmds.VM_strcat,
	VM_substring = prvm_cmds.VM_substring,
	VM_strzone = prvm_cmds.VM_strzone,
	VM_strunzone = prvm_cmds.VM_strunzone,
	VM_str2chr = prvm_cmds.VM_str2chr,
	VM_strncmp = prvm_cmds.VM_strncmp,
	VM_spawn = prvm_cmds.VM_spawn,
	VM_remove = prvm_cmds.VM_remove,
	VM_nextent = prvm_cmds.VM_nextent,
	VM_ftoe = prvm_cmds.VM_ftoe,
	VM_etof = prvm_cmds.VM_etof,
	VM_bound = prvm_cmds.VM_bound,
	VM_localcmd = prvm_cmds.VM_localcmd,
	VM_vlen = prvm_cmds.VM_vlen,
	VM_tokenize_console = prvm_cmds.VM_tokenize_console,
	VM_tokenizebyseparator = prvm_cmds.VM_tokenizebyseparator,
	VM_argv = prvm_cmds.VM_argv,
	VM_infoadd = prvm_cmds.VM_infoadd,
	VM_infoget = prvm_cmds.VM_infoget,
	VM_argv_start_index = prvm_cmds.VM_argv_start_index,
	VM_argv_end_index = prvm_cmds.VM_argv_end_index,
	VM_rint = prvm_cmds.VM_rint,
	VM_numentityfields = prvm_cmds.VM_numentityfields,
	VM_strncasecmp = prvm_cmds.VM_strncasecmp,
	VM_min = prvm_cmds.VM_min,
	VM_max = prvm_cmds.VM_max,
	VM_strreplace = prvm_cmds.VM_strreplace,
	VM_strstrofs = prvm_cmds.VM_strstrofs,
	VM_crc16 = prvm_cmds.VM_crc16,
	VM_uri_escape = prvm_cmds.VM_uri_escape,
	VM_uri_unescape = prvm_cmds.VM_uri_unescape,
	VM_buf_create = prvm_cmds.VM_buf_create,
	VM_buf_del = prvm_cmds.VM_buf_del,
	VM_buf_getsize = prvm_cmds.VM_buf_getsize,
	VM_bufstr_get = prvm_cmds.VM_bufstr_get,
	VM_bufstr_set = prvm_cmds.VM_bufstr_set,
	VM_buf_cvarlist = prvm_cmds.VM_buf_cvarlist,
	VM_strtolower = prvm_cmds.VM_strtolower,
	VM_buf_loadfile = prvm_cmds.VM_buf_loadfile,
	VM_buf_writefile = prvm_cmds.VM_buf_writefile,
	VM_error = prvm_cmds.VM_error,
	VM_objerror = prvm_cmds.VM_objerror,
	VM_eprint = prvm_cmds.VM_eprint,
	VM_coredump = prvm_cmds.VM_coredump,
	VM_traceon = prvm_cmds.VM_traceon,
	VM_traceoff = prvm_cmds.VM_traceoff,
	VM_break = prvm_cmds.VM_break,
	VM_precache_file = prvm_cmds.VM_precache_file,
	VM_entityfieldtype = prvm_cmds.VM_entityfieldtype,
	VM_getentityfieldstring = prvm_cmds.VM_getentityfieldstring,
	VM_putentityfieldstring = prvm_cmds.VM_putentityfieldstring,
	VM_writetofile = prvm_cmds.VM_writetofile,
	VM_parseentitydata = prvm_cmds.VM_parseentitydata,
	VM_loadfromdata = prvm_cmds.VM_loadfromdata,
	VM_loadfromfile = prvm_cmds.VM_loadfromfile,
	VM_tokenize = prvm_cmds.VM_tokenize,
	VM_strpad = prvm_cmds.VM_strpad,
	VM_strconv = prvm_cmds.VM_strconv,
	VM_strireplace = prvm_cmds.VM_strireplace,
	VM_isfunction = prvm_cmds.VM_isfunction,
	VM_callfunction = prvm_cmds.VM_callfunction,
	VM_gettime = prvm_cmds.VM_gettime,
	VM_buf_copy = prvm_cmds.VM_buf_copy,
	VM_buf_sort = prvm_cmds.VM_buf_sort,
	VM_buf_implode = prvm_cmds.VM_buf_implode,
	VM_bufstr_add = prvm_cmds.VM_bufstr_add,
	VM_bufstr_free = prvm_cmds.VM_bufstr_free,
	VM_bufstr_find = prvm_cmds.VM_bufstr_find,
	VM_matchpattern = prvm_cmds.VM_matchpattern,
	VM_makevectors = prvm_cmds.VM_makevectors,
	VM_vectorvectors = prvm_cmds.VM_vectorvectors,
	VM_normalize = prvm_cmds.VM_normalize,
	VM_vectoyaw = prvm_cmds.VM_vectoyaw,
	VM_vectoangles = prvm_cmds.VM_vectoangles,
	VM_ceil = prvm_cmds.VM_ceil,
	VM_fabs = prvm_cmds.VM_fabs,
	VM_sin = prvm_cmds.VM_sin,
	VM_cos = prvm_cmds.VM_cos,
	VM_sqrt = prvm_cmds.VM_sqrt,
	VM_asin = prvm_cmds.VM_asin,
	VM_acos = prvm_cmds.VM_acos,
	VM_atan = prvm_cmds.VM_atan,
	VM_tan = prvm_cmds.VM_tan,
	VM_log = prvm_cmds.VM_log,
	VM_atan2 = prvm_cmds.VM_atan2,
	VM_randomvec = prvm_cmds.VM_randomvec,
	VM_bitshift = prvm_cmds.VM_bitshift,
	VM_changeyaw = prvm_cmds.VM_changeyaw,
	VM_changepitch = prvm_cmds.VM_changepitch,
	VM_vtos = prvm_cmds.VM_vtos,
	VM_etos = prvm_cmds.VM_etos,
	VM_stov = prvm_cmds.VM_stov,
	VM_chr2str = prvm_cmds.VM_chr2str,
	VM_strlennocol = prvm_cmds.VM_strlennocol,
	VM_isserver = prvm_cmds.VM_isserver,
	VM_wasfreed = prvm_cmds.VM_wasfreed,
	VM_dprint = prvm_cmds.VM_dprint,
	VM_find = prvm_cmds.VM_find,
	VM_findfloat = prvm_cmds.VM_findfloat,
	VM_findflags = prvm_cmds.VM_findflags,
	VM_findchain = prvm_cmds.VM_findchain,
	VM_findchainfloat = prvm_cmds.VM_findchainfloat,
	VM_findchainflags = prvm_cmds.VM_findchainflags,
	VM_strdecolorize = prvm_cmds.VM_strdecolorize,
	VM_sprintf = prvm_cmds.VM_sprintf,
	VM_checkextension = prvm_cmds.VM_checkextension,
	VM_random = prvm_cmds.VM_random,
	VM_strftime = prvm_cmds.VM_strftime,
	VM_entityfieldname = prvm_cmds.VM_entityfieldname,
	VM_whichpack = prvm_cmds.VM_whichpack,
	VM_fopen = prvm_cmds.VM_fopen,
	VM_fclose = prvm_cmds.VM_fclose,
	VM_fgets = prvm_cmds.VM_fgets,
	VM_fputs = prvm_cmds.VM_fputs,
	VM_digest_hex = prvm_cmds.VM_digest_hex,
	VM_strtoupper = prvm_cmds.VM_strtoupper,
	VM_search_begin = prvm_cmds.VM_search_begin,
	VM_search_end = prvm_cmds.VM_search_end,
	VM_search_getsize = prvm_cmds.VM_search_getsize,
	VM_search_getfilename = prvm_cmds.VM_search_getfilename,
	VM_getsurfacenumpoints = prvm_cmds.VM_getsurfacenumpoints,
	VM_getsurfacepoint = prvm_cmds.VM_getsurfacepoint,
	VM_getsurfacepointattribute = prvm_cmds.VM_getsurfacepointattribute,
	VM_getsurfacenormal = prvm_cmds.VM_getsurfacenormal,
	VM_getsurfacetexture = prvm_cmds.VM_getsurfacetexture,
	VM_getsurfacenearpoint = prvm_cmds.VM_getsurfacenearpoint,
	VM_getsurfaceclippedpoint = prvm_cmds.VM_getsurfaceclippedpoint,
	VM_getsurfacenumtriangles = prvm_cmds.VM_getsurfacenumtriangles,
	VM_getsurfacetriangle = prvm_cmds.VM_getsurfacetriangle,
	VM_uri_get = prvm_cmds.VM_uri_get,
} :: { [string]: (prog: any) -> () }

return prvm_cmds
