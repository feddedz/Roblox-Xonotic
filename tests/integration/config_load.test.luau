--!strict
-- M2-RUNNER: a dedicated server's Host_Init + quake.rc config chain on the real 0.8.6 data.
local t = require("../_lib/t")
local console = require("../../engine/console")
local cvar = require("../../engine/cvar")
local fs = require("../../engine/fs")
local host = require("../../engine/host")
local provider = require("../_lib/vfs_provider")

return function(ctx: t.Ctx)
	local p = provider("high")
	if not p then
		t.skip(ctx, "needs work/vfs-high (tools/pk3/manifest.py --build high --extract)")
		return
	end
	local out: { string } = {}
	console.sink = function(l: string)
		table.insert(out, l)
	end
	fs.SetProvider(p)
	local t0 = os.clock()
	host.Host_Init_Dedicated()
	local dt = os.clock() - t0
	fs.SetProvider(nil)
	console.sink = function(l: string)
		print(l)
	end
	local n = 0
	local v = cvar.cvar_vars
	while v do
		n += 1
		v = v.next
	end
	local execs = 0
	for _, l in out do
		if string.sub(l, 1, 7) == "execing" then
			execs += 1
		end
	end
	print(string.format("config chain: %d cvars, %d files exec'd, %d console lines, %.2f s", n, execs, #out, dt))
	t.ok(ctx, execs > 20, "config files executed")
	t.ok(ctx, n > 3000, "cvars defined")
	local function val(name: string): string?
		local c = cvar.Cvar_FindVar(name)
		return c and c.string.str
	end
	-- engine defaults untouched by configs, configs overriding engine defaults, pure config cvars
	t.eq(ctx, val("sv_public"), "1", "Host_ServerOptions sv_public")
	t.eq(ctx, val("deathmatch"), "1", "Host_ServerOptions deathmatch")
	t.eq(ctx, val("fs_gamedir"), "data")
	t.ok(ctx, val("g_balance_blaster_primary_damage") ~= nil, "balance config loaded")
	t.ok(ctx, val("sv_gravity") ~= nil, "sv_gravity")
end
