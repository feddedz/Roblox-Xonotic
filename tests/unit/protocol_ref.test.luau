--!strict
-- engine/protocol.luau against the release's protocol.c compiled unchanged (tests/vectors/protocol.tsv,
-- tools/testgen/protocol_vectors.sh): the protocol table, EntityState5_DeltaBits / EntityState5_WriteUpdate of
-- state pairs, EntityFrameCSQC_WriteFrame / LostFrame sequences with the generator's fake QuakeC SendEntity
-- (mirrored here), EntityFrame5_WriteFrame / AckFrame / LostFrame sequences with stats, and
-- Protocol_WriteStatsReliable. Every message must be byte-identical and every database digest equal.
local t = require("../_lib/t")
local common = require("../../engine/common")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local f32 = require("../../engine/_port/f32")
local libc = require("../../engine/_port/libc")
local host_cmd = require("../../engine/host_cmd")
local server = require("../../engine/server")
local protocol = require("../../engine/protocol")

local band, bxor, lshift, rshift = bit32.band, bit32.bxor, bit32.lshift, bit32.rshift

return function(ctx: t.Ctx)
	local NED, NF, NG, GSELF = 2048, 4, 64, 28

	-- ---- helpers
	local function num(s: string): number
		return tonumber(s) :: number
	end
	local function fb(h: string): number
		return f32.frombits(tonumber(h, 16) :: number)
	end
	local dbuf = buffer.create(8)
	local function db(h: string): number
		buffer.writeu32(dbuf, 4, tonumber(string.sub(h, 1, 8), 16) :: number)
		buffer.writeu32(dbuf, 0, tonumber(string.sub(h, 9, 16), 16) :: number)
		return buffer.readf64(dbuf, 0)
	end
	local function hexs(b: buffer, n: number): string
		if n <= 0 then
			return "-"
		end
		local s = buffer.readstring(b, 0, n)
		return (
			string.gsub(s, ".", function(ch: string): string
				return string.format("%02x", string.byte(ch))
			end)
		)
	end
	local function hext(tb: { [number]: number }, n: number): string
		local parts = table.create(n)
		for i = 0, n - 1 do
			parts[i + 1] = string.format("%02x", tb[i])
		end
		return table.concat(parts)
	end
	local function mix(h: number, v: number): number
		h = bxor(h, v % 4294967296)
		h = bxor(h, lshift(h, 13))
		h = bxor(h, rshift(h, 17))
		h = bxor(h, lshift(h, 5))
		return h
	end

	-- ---- the saved engine state
	local svs = host_cmd.svs :: any
	local sv = server.sv :: any
	local saved = {
		prog = cvar.prvm_prog_list[0],
		sink = console.sink,
		clients = svs.clients,
		maxclients = svs.maxclients,
		host_client = server.host_client,
		protocol = sv.protocol,
		time = sv.time,
		models = sv.models,
		msg = sv.writeentitiestoclient_msg,
		cn = sv.writeentitiestoclient_clientnumber,
		cen = sv.writeentitiestoclient_cliententitynumber,
	}
	console.sink = function(_line: string) end

	-- ---- the prog and the fake SendEntity
	local salt = 0
	local prog: any = {
		globals = buffer.create(NG * 4),
		edictsfields = buffer.create(NED * NF * 4),
		entityfields = NF,
		num_edicts = NED,
		max_edicts = NED,
		fieldofs_cache = { SendEntity = 0, classname = 1 },
		globalofs_cache = { self = GSELF },
	}
	prog.ExecuteProgram = function(p: any, fnum: number, _errormessage: string)
		local g = p.globals
		local self = buffer.readi32(g, GSELF * 4)
		local cl = buffer.readi32(g, 4 * 4)
		local sf = libc.toint(buffer.readf32(g, 7 * 4))
		local h = 2166136261
		h = mix(h, fnum)
		h = mix(h, self)
		h = mix(h, cl)
		h = mix(h, sf)
		h = mix(h, salt)
		local len = h % 23
		if rshift(h, 8) % 37 == 0 then
			len = 200 + h % 300
		end
		for i = 0, len - 1 do
			common.MSG_WriteByte(server.sv.writeentitiestoclient_msg :: any, band(rshift(h, i % 24) + i, 255))
		end
		buffer.writef32(g, 1 * 4, if rshift(h, 12) % 7 == 0 then 0 else 1)
	end
	cvar.prvm_prog_list[0] = prog
	svs.clients = { [0] = {}, [1] = {} }
	sv.models = {}

	-- ---- skeletons and states
	local skelmodels = { [0] = { num_bones = 1 }, [1] = { num_bones = 3 } }
	local bones: { [number]: any } = {}
	local function parseState(c: { string }, i: number): protocol.entity_state_t
		local s = protocol.EntityState_New()
		s.number = num(c[i])
		s.active = num(c[i + 1])
		s.modelindex = num(c[i + 2])
		s.frame = num(c[i + 3])
		s.skin = num(c[i + 4])
		s.effects = num(c[i + 5])
		s.flags = num(c[i + 6])
		s.alpha = num(c[i + 7])
		s.scale = num(c[i + 8])
		s.colormap = num(c[i + 9])
		s.tagentity = num(c[i + 10])
		s.tagindex = num(c[i + 11])
		s.viewmodelforclient = num(c[i + 12])
		s.exteriormodelforclient = num(c[i + 13])
		s.traileffectnum = num(c[i + 14])
		for k = 1, 4 do
			s.light[k] = num(c[i + 14 + k])
		end
		s.lightstyle = num(c[i + 19])
		s.lightpflags = num(c[i + 20])
		s.glowsize = num(c[i + 21])
		s.glowcolor = num(c[i + 22])
		for k = 1, 3 do
			s.colormod[k] = num(c[i + 22 + k])
			s.glowmod[k] = num(c[i + 25 + k])
			s.origin[k] = fb(c[i + 28 + k])
			s.angles[k] = fb(c[i + 31 + k])
			s.netcenter[k] = fb(c[i + 34 + k])
		end
		for k = 1, 4 do
			local o = i + 38 + (k - 1) * 3
			s.framegroupblend[k].frame = num(c[o])
			s.framegroupblend[k].lerp = fb(c[o + 1])
			s.framegroupblend[k].start = db(c[o + 2])
		end
		local skel = num(c[i + 50])
		if skel >= 0 then
			s.skeletonobject.model = skelmodels[skel % 2]
			s.skeletonobject.relativetransforms = bones[skel]
		end
		return s
	end
	local STATEFIELDS = 51

	-- ---- CSQC
	local function csqcDigest(c: number): string
		local client = svs.clients[c]
		local scope, csf = client.csqcentityscope, client.csqcentitysendflags
		local n = client.csqcnumedicts
		local sc = table.create(n)
		local sfl = table.create(n)
		for i = 0, n - 1 do
			sc[i + 1] = string.format("%02x", buffer.readu8(scope, i))
			sfl[i + 1] = string.format("%x", buffer.readu32(csf, i * 4))
		end
		local h = 2166136261
		for i = 1, protocol.NUM_CSQCENTITYDB_FRAMES do
			local d = client.csqcentityframehistory[i]
			h = mix(h, d.framenum)
			h = mix(h, d.num)
			for j = 0, d.num - 1 do
				h = mix(h, buffer.readu16(d.entno, j * 2))
				h = mix(h, buffer.readi32(d.sendflags, j * 4))
			end
		end
		return `\t{n}\t{client.csqcentityframehistory_next}\t{client.csqcentityframe_lastreset}\t{table.concat(sc)}\t{table.concat(
			sfl,
			","
		)}\t{string.format("%08x", h)}`
	end

	-- ---- EntityFrame5
	local d: any = nil
	local stats: { [number]: number } = {}
	local pop: { [number]: protocol.entity_state_t } = {}
	local function resetStats(hc: any)
		hc.stats, hc.statsdeltabits = nil, nil
		protocol.Stats_ClientFields(hc)
		for i = 0, protocol.MAX_CL_STATS - 1 do
			stats[i] = 0
		end
	end
	local function e5Digest(): string
		local parts = {}
		for i = 0, d.maxedicts - 1 do
			local bits, pr = buffer.readu32(d.deltabits, i * 4), buffer.readu8(d.priorities, i)
			if bits ~= 0 or pr ~= 0 then
				table.insert(parts, string.format("%d:%x:%d", i, bits, pr))
			end
		end
		local h = 2166136261
		for i = 0, d.maxedicts - 1 do
			h = mix(h, buffer.readu32(d.updateframenum, i * 4))
		end
		local hv = 2166136261
		for i = 0, (d.maxedicts + 7) // 8 - 1 do
			hv = mix(hv, buffer.readu8(d.visiblebits, i))
		end
		local logs = {}
		for i = 0, protocol.ENTITYFRAME5_MAXPACKETLOGS - 1 do
			local p = d.packetlog[i + 1]
			if p.packetnumber ~= 0 then
				local hp = 2166136261
				for k = 0, p.numstates - 1 do
					hp = mix(hp, buffer.readu32(p.states, k * 8))
					hp = mix(hp, buffer.readu32(p.states, k * 8 + 4))
				end
				for k = 0, 31 do
					hp = mix(hp, buffer.readu8(p.statsdeltabits, k))
				end
				table.insert(logs, string.format("%d:%d:%d:%08x", i, p.packetnumber, p.numstates, hp))
			end
		end
		local counts = table.create(protocol.ENTITYFRAME5_PRIORITYLEVELS)
		for i = 0, protocol.ENTITYFRAME5_PRIORITYLEVELS - 1 do
			counts[i + 1] = tostring(buffer.readi32(d.prioritychaincounts, i * 4))
		end
		return table.concat({
			"DG",
			tostring(d.latestframenum),
			tostring(d.maxedicts),
			tostring(d.viewentnum),
			if #parts > 0 then table.concat(parts, ",") else "-",
			string.format("%08x", h),
			string.format("%08x", hv),
			if #logs > 0 then table.concat(logs, ",") else "-",
			hext(server.host_client.statsdeltabits, 32),
			table.concat(counts, ","),
		}, "\t")
	end

	-- ---- replay
	local pending: string? = nil -- the expected result line the previous call is compared with
	local pendingmsg = ""
	local function expect(got: string)
		pending = got
	end
	local counts = { DR = 0, CR = 0, R5 = 0, DG = 0, WR = 0, P = 0 }
	local lineno = 0
	local reachedEnd = false
	local msg: common.SizeBuf = common.SZ_New(1)
	local wsmsg: common.SizeBuf? = nil

	for line in string.gmatch(t.read("tests/vectors/protocol.tsv"), "[^\r\n]+") do
		lineno += 1
		local c = string.split(line, "\t")
		local kind = c[1]
		if kind == "DR" or kind == "CR" or kind == "R5" or kind == "DG" or kind == "WR" then
			counts[kind] += 1
			t.eq(ctx, pending, line, `line {lineno}: {kind} {pendingmsg}`)
			pending = nil
		elseif kind == "MAXCL" then
			svs.maxclients = num(c[2])
		elseif kind == "TIME" then
			sv.time = db(c[2])
		elseif kind == "MD" then
			local m: any = { numframes = num(c[3]), animscenes = {} }
			for j = 0, m.numframes - 1 do
				m.animscenes[j + 1] = { framecount = num(c[4 + j * 2]), framerate = fb(c[5 + j * 2]) }
			end
			sv.models[num(c[2])] = m
		elseif kind == "SK" then
			local k = num(c[2])
			local b = bones[k]
			if not b then
				b = {}
				for i = 1, 3 do
					b[i] = { m = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } } }
				end
				bones[k] = b
			end
			local o = 3
			for i = 1, 3 do
				for r = 1, 4 do
					for col = 1, 4 do
						b[i].m[r][col] = fb(c[o])
						o += 1
					end
				end
			end
		elseif kind == "SE" then
			buffer.writei32(prog.edictsfields, (num(c[2]) * NF + 0) * 4, num(c[3]))
		elseif kind == "PE" then
			counts.P += 1
			t.eq(ctx, protocol.Protocol_EnumForName(c[2] or ""), num(c[3]), `line {lineno}: Protocol_EnumForName`)
		elseif kind == "PF" then
			counts.P += 1
			local p = num(c[2])
			t.eq(ctx, protocol.Protocol_NameForEnum(p), c[3], `line {lineno}: Protocol_NameForEnum`)
			t.eq(ctx, protocol.Protocol_NumberForEnum(p), num(c[4]), `line {lineno}: Protocol_NumberForEnum`)
		elseif kind == "PN" then
			counts.P += 1
			t.eq(ctx, protocol.Protocol_EnumForNumber(num(c[2])), num(c[3]), `line {lineno}: Protocol_EnumForNumber`)
		elseif kind == "PS" then
			counts.P += 1
			t.eq(ctx, protocol.Protocol_Names(num(c[2])) or "untouched", c[3] or "", `line {lineno}: Protocol_Names`)
		elseif kind == "DW" then
			local o = parseState(c, 2)
			local n = parseState(c, 2 + STATEFIELDS)
			local number, changedbits = num(c[2 + 2 * STATEFIELDS]), num(c[3 + 2 * STATEFIELDS])
			local bits = protocol.EntityState5_DeltaBits(o, n)
			local buf = common.SZ_New(256)
			protocol.EntityState5_WriteUpdate(number, n, changedbits, buf)
			pendingmsg = "DeltaBits / WriteUpdate"
			expect(`DR\t{bits}\t{hexs(buf.data, buf.cursize)}`)
		elseif kind == "CI" then
			local cn = num(c[2])
			local client = svs.clients[cn]
			protocol.CSQC_ClientFields(client)
			-- SV_ConnectClient (sv_main.c L922-934)
			for i = 0, protocol.MAX_EDICTS - 1 do
				buffer.writeu8(client.csqcentityscope, i, 0)
				buffer.writeu32(client.csqcentitysendflags, i * 4, 0xFFFFFF)
			end
			for i = 1, protocol.NUM_CSQCENTITYDB_FRAMES do
				client.csqcentityframehistory[i].num = 0
				client.csqcentityframehistory[i].framenum = -1
			end
			client.csqcnumedicts = 0
			client.csqcentityframehistory_next = 0
			sv.writeentitiestoclient_clientnumber = cn
			sv.writeentitiestoclient_cliententitynumber = cn + 1
		elseif kind == "NE" then
			prog.num_edicts = num(c[2])
		elseif kind == "CF" then
			local client = svs.clients[num(c[2])]
			local e = num(c[3])
			buffer.writeu32(
				client.csqcentitysendflags,
				e * 4,
				bit32.bor(buffer.readu32(client.csqcentitysendflags, e * 4), num(c[4]))
			)
		elseif kind == "SALT" then
			salt = num(c[2])
		elseif kind == "CW" then
			local cn, maxsize, msgmax, pre, framenum, nn =
				num(c[2]), num(c[3]), num(c[4]), num(c[5]), num(c[6]), num(c[7])
			local numbers = table.create(nn)
			for i = 1, nn do
				numbers[i] = num(c[7 + i])
			end
			msg = common.SZ_New(msgmax)
			for i = 0, pre - 1 do
				common.MSG_WriteByte(msg, i)
			end
			sv.writeentitiestoclient_msg = msg
			local ret = protocol.EntityFrameCSQC_WriteFrame(msg, maxsize, nn, numbers, framenum)
			pendingmsg = "EntityFrameCSQC_WriteFrame"
			expect(
				`CR\t{if ret then 1 else 0}\t{if msg.overflowed then 1 else 0}\t{hexs(msg.data, msg.cursize)}{csqcDigest(
					cn
				)}`
			)
		elseif kind == "CL" then
			local cn = num(c[2])
			protocol.EntityFrameCSQC_LostFrame(svs.clients[cn], num(c[3]))
			pendingmsg = "EntityFrameCSQC_LostFrame"
			expect(`CR\t-1\t0\t-{csqcDigest(cn)}`)
		elseif kind == "E5" then
			server.host_client = svs.clients[0]
			resetStats(server.host_client)
			d = protocol.EntityFrame5_AllocDatabase(nil)
			table.clear(pop)
		elseif kind == "PROTO" then
			sv.protocol = protocol.Protocol_EnumForName(c[2])
		elseif kind == "ME" then
			prog.max_edicts = num(c[2])
		elseif kind == "ES" then
			local s = parseState(c, 2)
			pop[s.number] = s
		elseif kind == "EK" then
			pop[num(c[2])] = nil
		elseif kind == "US" then
			for i = 2, #c do
				local kv = string.split(c[i], ":")
				stats[num(kv[1])] = num(kv[2])
			end
			protocol.Protocol_UpdateClientStats(stats)
		elseif kind == "W5" then
			local maxsize, pre, viewent, moveseq, need_empty, ns =
				num(c[2]), num(c[3]), num(c[4]), num(c[5]), num(c[6]), num(c[7])
			local states = table.create(ns)
			for i = 1, ns do
				states[i] = pop[num(c[7 + i])]
			end
			msg = common.SZ_New(1450)
			for i = 0, pre - 1 do
				common.MSG_WriteByte(msg, i)
			end
			local ret = protocol.EntityFrame5_WriteFrame(msg, maxsize, d, ns, states, viewent, moveseq, need_empty ~= 0)
			pendingmsg = "EntityFrame5_WriteFrame"
			expect(`R5\t{if ret then 1 else 0}\t{hexs(msg.data, msg.cursize)}`)
		elseif kind == "A5" then
			protocol.EntityFrame5_AckFrame(d, num(c[2]))
		elseif kind == "L5" then
			protocol.EntityFrame5_LostFrame(d, num(c[2]))
		elseif kind == "WI" then
			server.host_client = svs.clients[1]
			resetStats(server.host_client)
		elseif kind == "WS" then
			local hc = server.host_client
			if num(c[2]) ~= 0 then
				wsmsg = common.SZ_New(4096)
				hc.netconnection = { message = wsmsg }
			else
				wsmsg = nil
				hc.netconnection = nil
			end
			protocol.Protocol_WriteStatsReliable()
			local m = wsmsg
			pendingmsg = "Protocol_WriteStatsReliable"
			expect(`WR\t{if m then hexs(m.data, m.cursize) else "-"}\t{hext(hc.statsdeltabits, 32)}`)
		elseif kind == "END" then
			reachedEnd = true
		elseif kind == "HOSTERROR" then
			t.ok(ctx, false, `line {lineno}: the C reference hit Host_Error`)
		end
		-- the digest follows every database call
		if kind == "R5" or kind == "A5" or kind == "L5" then
			pendingmsg = "EntityFrame5 database digest"
			expect(e5Digest())
		end
	end
	t.ok(ctx, reachedEnd, "reached the end of the vector file")
	t.ok(ctx, counts.DR >= 5000 and counts.CR >= 300 and counts.R5 >= 500 and counts.WR >= 100, "vector counts")
	print(
		string.format(
			"protocol_ref: %d DR, %d CR, %d R5, %d DG, %d WR, %d table checks",
			counts.DR,
			counts.CR,
			counts.R5,
			counts.DG,
			counts.WR,
			counts.P
		)
	)

	-- ---- restore
	cvar.prvm_prog_list[0] = saved.prog
	console.sink = saved.sink
	svs.clients = saved.clients
	svs.maxclients = saved.maxclients
	server.host_client = saved.host_client
	sv.protocol = saved.protocol
	sv.time = saved.time
	sv.models = saved.models
	sv.writeentitiestoclient_msg = saved.msg
	sv.writeentitiestoclient_clientnumber = saved.cn
	sv.writeentitiestoclient_cliententitynumber = saved.cen
end
