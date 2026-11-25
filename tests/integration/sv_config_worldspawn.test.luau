--!strict
-- M2-RUNNER: dedicated Host_Init + quake.rc config chain, then SV_VM_Setup on the real progs.dat.
-- 1. every autocvar_* global holds its cvar's value (PRVM_Prog_Load autocvar pass);
-- 2. spawnfunc_worldspawn runs on a fresh engine with the interpreter and with AOT, and both leave
--    identical globals, builtin sequences and cvars. Needs game data (skips in CI).
local t = require("../_lib/t")
local lfs = require("@lune/fs")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local sv_main = require("../../engine/sv_main")
local prvm_edict = require("../../engine/prvm_edict")
local prvm_exec = require("../../engine/prvm_exec")
local qcrt = require("../../engine/_port/qcrt")
local f32 = require("../../engine/_port/f32")
local libc = require("../../engine/_port/libc")
local provider = require("../_lib/vfs_provider")

local function cvardump(): string
	local out = {}
	local v = cvar.cvar_vars
	while v do
		table.insert(out, v.name .. "=" .. v.string.str)
		v = v.next
	end
	return table.concat(out, "\n")
end

return function(ctx: t.Ctx)
	local dat, gen = "work/vfs-high/progs.dat", "game/generated/progs/init.luau"
	local p = provider("high")
	if not (p and lfs.isFile(dat) and lfs.isFile(gen)) then
		t.skip(ctx, "needs work/vfs-high and tools/build.sh output")
		return
	end
	local data = buffer.fromstring(lfs.readFile(dat))
	local results = {}
	for k = 1, 2 do
		local lines: { string } = {}
		console.sink = function(l: string)
			table.insert(lines, l)
		end
		fs.SetProvider(p)
		host.Host_Init_Dedicated()
		local log: { string } = {}
		local prog = sv_main.SV_VM_Setup(data, {
			onStub = function(n: number, cname: string, _p: any)
				table.insert(log, string.format("#%d %s", n, cname))
			end,
		})
		prog.warning = function(_m: string) end
		if k == 1 then
			-- autocvar globals == cvar values
			local n, bad, firstbad = 0, 0, nil
			for _, def in prog.globaldefs do
				local name = prvm_edict.PRVM_GetString(prog, def.s_name)
				local typ = bit32.band(def.type, 0x7fff)
				if string.sub(name, 1, 9) == "autocvar_" and string.match(name, "_[xyz]$") == nil then
					local c = cvar.Cvar_FindVar(string.sub(name, 10)) :: any
					n += 1
					local ok = c ~= nil
					if ok and typ == 2 then
						ok = buffer.readf32(prog.globals, def.ofs * 4) == f32.round(libc.atof(c.string.str))
					elseif ok and typ == 1 then
						ok = prvm_edict.PRVM_GetString(prog, buffer.readi32(prog.globals, def.ofs * 4)) == c.string.str
					end
					if not ok then
						bad += 1
						firstbad = firstbad or name
					end
				end
			end
			print(
				string.format(
					"  autocvars: %d globals, %d mismatches%s",
					n,
					bad,
					if firstbad then " (first " .. firstbad .. ")" else ""
				)
			)
			t.ok(ctx, n > 1000, "autocvar globals found")
			t.eq(ctx, bad, 0, "autocvar globals equal their cvars")
			local g = cvar.Cvar_FindVar("g_balance_blaster_primary_damage")
			t.ok(ctx, g ~= nil and g.string.str ~= "0", "balance cvar from config")
		else
			(require :: any)("../../game/generated/progs").install(prog, { qcrt = qcrt, f32 = f32 })
		end
		local _, fnum = prvm_edict.PRVM_ED_FindFunction(prog, "spawnfunc_worldspawn")
		local selfdef = prvm_edict.PRVM_ED_FindGlobal(prog, "self")
		buffer.writei32(prog.globals, (selfdef :: any).ofs * 4, 0)
		local ok, err
		if k == 1 then
			ok, err = pcall(prvm_exec.PRVM_ExecuteProgram, prog, fnum, "worldspawn")
		else
			ok, err = pcall(qcrt.ExecuteProgram, prog, fnum, "worldspawn")
		end
		fs.SetProvider(nil)
		results[k] = {
			ok = ok,
			err = tostring(err),
			globals = buffer.tostring(prog.globals),
			log = log,
			cvars = cvardump(),
			lines = lines,
		}
	end
	console.sink = function(l: string)
		print(l)
	end
	local a, b = results[1], results[2]
	t.eq(ctx, b.ok, a.ok, "worldspawn: same outcome")
	t.eq(ctx, b.err, a.err, "worldspawn: same error")
	t.ok(ctx, a.globals == b.globals, "worldspawn: same globals")
	t.eq(ctx, table.concat(b.log, "|"), table.concat(a.log, "|"), "worldspawn: same builtin sequence")
	t.ok(ctx, a.cvars == b.cvars, "worldspawn: same cvars afterwards")
	local seen, order = {}, {}
	for _, l in a.log do
		if not seen[l] then
			seen[l] = true
			table.insert(order, l)
		end
	end
	print(
		string.format(
			"  worldspawn with real cvars: ok=%s, %d stub calls, %d distinct stubs; result: %s",
			tostring(a.ok),
			#a.log,
			#order,
			if a.ok then "completed" else a.err
		)
	)
	print("  first stubs: " .. table.concat(order, ", ", 1, math.min(#order, 30)))
end
