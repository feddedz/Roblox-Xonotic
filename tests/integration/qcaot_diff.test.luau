--!strict
--[[
	Differential test: AOT-compiled QuakeC (game/generated/<prog>) vs the reference interpreter
	(engine/prvm_exec.luau) on the real 0.8.6 programs. Every QC function is called with random
	parameters on two identically prepared progs; builtins are deterministic stubs shared by both.
	Required equal: error text (or success), globals buffer, edict fields, builtin call log.
	Needs work/vfs-high/*.dat (tools/release/fetch.sh + tools/pk3/manifest.py) and
	game/generated/* (tools/qcaot/compile.py); skips otherwise (CI).
	Env: QCAOT_DIFF_PROGS (default "menu,csprogs,progs"), QCAOT_DIFF_SEED, QCAOT_DIFF_LIMIT (functions per prog).
]]
local t = require("../_lib/t")
local fs = require("@lune/fs")
local process = require("@lune/process")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_exec = require("../../engine/prvm_exec")
local qcrt = require("../../engine/_port/qcrt")

local MAX_EDICTS = 32

local function makeProg(name: string, data: buffer, log: { string })
	local prog: any = prvm_edict.NewProg(name)
	prog.warning = function(_msg: string) end
	prvm_edict.PRVM_Prog_Load(prog, name .. ".dat", data)
	prvm_edict.SetMaxEdicts(prog, MAX_EDICTS)
	prog.runaway_limit = 20000
	prog.numbuiltins = 2048
	local calls = 0
	setmetatable(prog.builtins, {
		__index = function(_, n: number)
			return function(p: any)
				calls += 1
				local G = p.globals
				local parms = {}
				for i = 0, p.argc * 3 - 1 do
					parms[i + 1] = buffer.readi32(G, (4 + i) * 4)
				end
				table.insert(log, string.format("#%d argc=%d %s", n, p.argc, table.concat(parms, ",")))
				-- deterministic return: alternate small ints (valid edicts/strings 0..3) and floats
				local v = (n * 7 + calls) % 4
				if calls % 2 == 0 then
					buffer.writei32(G, 4, v)
				else
					buffer.writef32(G, 4, v - 1.5)
				end
				buffer.writei32(G, 8, 0)
				buffer.writei32(G, 12, 0)
			end
		end,
	})
	return prog
end

-- deterministic PRNG (splitmix-style on 32-bit halves; Lune has no Roblox Random)
local function newRng(seed: number)
	local state = seed % 4294967296
	local function nextU32(): number
		state = (state * 1664525 + 1013904223) % 4294967296
		local x = state
		x = bit32.bxor(x, bit32.rshift(x, 16))
		x = (x * 0x45d9f3b) % 4294967296
		x = bit32.bxor(x, bit32.rshift(x, 16))
		return x
	end
	return {
		number = function(lo: number?, hi: number?): number
			local u = nextU32() / 4294967296
			if lo and hi then
				return lo + (hi - lo) * u
			end
			return u
		end,
		int = function(lo: number, hi: number): number
			return lo + nextU32() % (hi - lo + 1)
		end,
	}
end

local function reset(prog: any)
	-- what PRVM_Crash does to the VM state after an error
	prog.depth = 0
	prog.localstack_used = 0
	prog.xfunction = -1
	prog.jc = 0
	prog.tempstringsbuf.cursize = 0
end

return function(ctx: t.Ctx)
	local names = string.split(process.env.QCAOT_DIFF_PROGS or "menu,csprogs,progs", ",")
	local seed = tonumber(process.env.QCAOT_DIFF_SEED or "20261120") :: number
	local limit = tonumber(process.env.QCAOT_DIFF_LIMIT or "1000000") :: number
	local ran = 0
	for _, name in names do
		local datPath = "work/vfs-high/" .. name .. ".dat"
		local genPath = "game/generated/" .. name .. "/init.luau"
		if not (fs.isFile(datPath) and fs.isFile(genPath)) then
			continue
		end
		ran += 1
		local data = buffer.fromstring(fs.readFile(datPath))
		local logI, logA = {}, {}
		local pI, pA = makeProg(name, data, logI), makeProg(name, data, logA)
		local gen = (require :: any)("../../game/generated/" .. name)
		gen.install(pA)
		local rng = newRng(seed)
		local tested, mismatches, completed = 0, 0, 0
		local timeI, timeA = 0, 0
		for fnum = 1, pI.numfunctions - 1 do
			if tested >= limit then
				break
			end
			local f = pI.functions[fnum + 1]
			if f.first_statement < 0 then
				continue
			end
			tested += 1
			-- identical random parameters for both
			for i = 0, 23 do
				local r = rng.number()
				local bits = if r < 0.3
					then rng.int(0, 3)
					elseif r < 0.6 then buffer.readi32(
						buffer.fromstring(string.pack("<f", rng.number(-1000, 1000))),
						0
					)
					else rng.int(0, 4294967295) - 2147483648
				buffer.writei32(pI.globals, (4 + i) * 4, bits)
				buffer.writei32(pA.globals, (4 + i) * 4, bits)
			end
			local nI, nA = #logI, #logA
			local c0 = os.clock()
			local okI, errI = pcall(prvm_exec.PRVM_ExecuteProgram, pI, fnum, "diff")
			local c1 = os.clock()
			local okA, errA = pcall(qcrt.ExecuteProgram, pA, fnum, "diff")
			timeI += c1 - c0
			timeA += os.clock() - c1
			if okI then
				completed += 1
			else
				reset(pI)
			end
			if not okA then
				reset(pA)
			end
			local same = okI == okA
				and (okI or tostring(errI) == tostring(errA))
				and buffer.tostring(pI.globals) == buffer.tostring(pA.globals)
				and buffer.tostring(pI.edictsfields) == buffer.tostring(pA.edictsfields)
				and #logI - nI == #logA - nA
			if same then
				for k = nI + 1, #logI do
					if logI[k] ~= logA[k] then
						same = false
						break
					end
				end
			end
			t.ok(
				ctx,
				same,
				string.format(
					"%s fn %d %s: interp ok=%s %s | aot ok=%s %s",
					name,
					fnum,
					prvm_edict.PRVM_GetString(pI, f.s_name),
					tostring(okI),
					tostring(errI),
					tostring(okA),
					tostring(errA)
				)
			)
			if not same then
				mismatches += 1
				-- resynchronise so one mismatch does not cascade
				buffer.copy(pA.globals, 0, pI.globals, 0)
				buffer.copy(pA.edictsfields, 0, pI.edictsfields, 0)
			end
		end
		print(
			string.format(
				"  qcaot_diff %s: %d functions, %d mismatches, %d ran to completion, %d ended in a QC error, %d builtin calls; interpreter %.2fs, AOT %.2fs",
				name,
				tested,
				mismatches,
				completed,
				tested - completed,
				#logI,
				timeI,
				timeA
			)
		)
	end
	if ran == 0 then
		t.skip(ctx, "no work/vfs-high/*.dat + game/generated/* (run tools/qcaot/compile.py)")
	end
end
