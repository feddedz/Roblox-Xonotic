--!strict
-- engine/cvar.luau + engine/cmd.luau: console script semantics of cvar.c / cmd.c @xonotic-v0.8.6.
local t = require("../_lib/t")
local cvar = require("../../engine/cvar")
local cmd = require("../../engine/cmd")
local console = require("../../engine/console")
local fs = require("../../engine/fs")

return function(ctx: t.Ctx)
	local out: { string } = {}
	console.sink = function(l: string)
		table.insert(out, l)
	end
	cvar.reset()
	cmd.reset()
	cmd.Cmd_Init()
	cmd.Cmd_Init_Commands()
	local function run(text: string)
		cmd.Cbuf_AddText(text)
		cmd.Cbuf_Execute()
	end
	local function val(name: string): string?
		local v = cvar.Cvar_FindVar(name)
		return v and v.string.str
	end

	-- set / seta / flags / value / integer
	run('set a 1.5\nseta b "x y" "desc"\n')
	t.eq(ctx, val("a"), "1.5")
	t.eq(ctx, (cvar.Cvar_FindVar("a") :: any).value, 1.5)
	t.eq(ctx, (cvar.Cvar_FindVar("a") :: any).integer, 1)
	t.eq(ctx, bit32.band((cvar.Cvar_FindVar("b") :: any).flags, cvar.CVAR_SAVE), cvar.CVAR_SAVE, "seta saves")
	t.eq(ctx, (cvar.Cvar_FindVar("b") :: any).description.str, "desc")
	t.eq(ctx, (cvar.Cvar_FindVar("a") :: any).description, cvar.cvar_dummy_description, "dummy description pointer")
	-- "<name> <value>" sets through Cvar_Command; same-length value keeps the C buffer (pointer)
	local ref = (cvar.Cvar_FindVar("a") :: any).string
	run("a 2.5\n")
	t.eq(ctx, (cvar.Cvar_FindVar("a") :: any).string, ref, "same length reuses buffer")
	run("a 10\n")
	t.ok(ctx, (cvar.Cvar_FindVar("a") :: any).string ~= ref, "new length reallocates")
	-- ; splits, quotes protect ; and //, comments need whitespace before //
	run('set c "1;2" ; set d 4 // set e 5\nset f http://x\n')
	t.eq(ctx, val("c"), "1;2")
	t.eq(ctx, val("d"), "4")
	t.eq(ctx, val("e"), nil, "comment")
	t.eq(ctx, val("f"), "http://x", "// inside a word is not a comment")
	-- $ expansion, quoting, ${x ?}, ${x !}, $$, indirection
	run('set g "q\\"uote"\nset h "$g"\nset h2 $g\nset i "${nosuch ?}"\nset j $$g\nset k g\nset l "${$k}"\n')
	t.eq(ctx, val("h"), 'q"uote', "quoted form inside quotes")
	t.eq(ctx, val("h2"), 'q\\"uote', "unquoted: the escape stays (only quoted tokens unescape)")
	t.eq(ctx, val("i"), "")
	t.eq(ctx, val("j"), "$g")
	t.eq(ctx, val("l"), 'q"uote', "indirection")
	run("set m ${nosuch !}\n")
	t.eq(ctx, val("m"), nil, "! aborts the line")
	-- aliases: parameters, $*, $2-, $#, alias lines are not preprocessed
	run('alias setboth "set $1 $2; set ${1}_copy $2; set $1_x $2"\nsetboth n 7\n')
	t.eq(ctx, val("n"), "7")
	t.eq(ctx, val("n_copy"), "7")
	t.eq(ctx, val("n_x"), nil, "$1_x is the (unknown) variable 1_x")
	run('set o OLD\nalias showo "set p $o"\nset o NEW\nshowo\n')
	t.eq(ctx, val("p"), "NEW", "alias expands cvars at call time")
	run('alias cnt "set q $#; set r \\"$2-\\""\ncnt a b c d\n')
	t.eq(ctx, val("q"), "5")
	t.eq(ctx, val("r"), "b c d")
	-- toggle
	run("set s 0\ntoggle s\n")
	t.eq(ctx, val("s"), "1")
	run("toggle s a b c\n")
	t.eq(ctx, val("s"), "a", "value not found -> first")
	run("toggle s a b c\n")
	t.eq(ctx, val("s"), "b")
	-- unset / read-only / static
	run("unset s\n")
	t.eq(ctx, val("s"), nil)
	local ro = cvar.static(cvar.CVAR_READONLY, "ro", "1", "read only")
	cvar.Cvar_RegisterVariable(ro)
	run("ro 2\nset ro 3\nunset ro\n")
	t.eq(ctx, val("ro"), "1")
	-- defaults locking, alphabetical list
	run("set zz 1\ncvar_lockdefaults\nset zz 2\ncvar_resettodefaults_all\n")
	t.eq(ctx, val("zz"), "1")
	local names = {}
	local v = cvar.cvar_vars
	while v do
		table.insert(names, v.name)
		v = v.next
	end
	local sorted = table.clone(names)
	table.sort(sorted)
	t.eq(ctx, table.concat(names, ","), table.concat(sorted, ","), "cvar_vars alphabetical")
	-- exec via the fs provider, default.cfg prelude + lockdefaults, wildcard order
	local files: { [string]: string } = {
		["default.cfg"] = "set fromdefault 1\nexec sub/*.cfg\n",
		["sub/b.cfg"] = "set order b\n",
		["sub/A.cfg"] = "set order2 $order\n",
	}
	local list = {}
	for k in files do
		table.insert(list, k)
	end
	fs.SetProvider({
		files = list,
		load = function(p: string)
			return files[p]
		end,
	})
	cvar.Cvar_RegisterVariable(cvar.static(0, "sys_ticrate", "0.0138889", "how long a server frame is"))
	run("exec default.cfg\n")
	t.eq(ctx, val("fromdefault"), "1")
	t.eq(ctx, val("sys_ticrate"), "0.01388889", "default.cfg prelude (Xonotic branch)")
	-- FS_Search sorts A.cfg before b.cfg, but each Cmd_Exec inserts at the buffer front: b.cfg runs first
	t.eq(ctx, val("order2"), "b", "wildcard exec runs in reverse sorted order")
	t.eq(ctx, (cvar.Cvar_FindVar("fromdefault") :: any).defstring.str, "1", "cvar_lockdefaults after default.cfg")
	run("exec nosuch.cfg\n")
	t.ok(ctx, table.find(out, "couldn't exec nosuch.cfg") ~= nil, "missing exec message")
	fs.SetProvider(nil)
end
