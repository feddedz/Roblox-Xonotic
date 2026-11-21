-- Measures Luau bytecode size and load memory of generated QC chunks (M2-AOT-SHIP). Not a test.
-- Usage: lune run tests/_tools/bytecode_size.luau <prog>
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local name = process.args[1]
local dir = "game/generated/" .. name
local src, bc, maxsrc, n = 0, 0, 0, 0
for _, f in fs.readDir(dir) do
	if string.sub(f, -5) == ".luau" then
		local s = fs.readFile(dir .. "/" .. f)
		local b = luau.compile(s, { optimizationLevel = 1 })
		src += #s
		bc += #b
		maxsrc = math.max(maxsrc, #s)
		n += 1
	end
end
local before = collectgarbage("count")
local gen = (require :: any)("../../game/generated/" .. name)
local prog = { aot = {} }
gen.install(prog, { qcrt = {}, f32 = {
	round = function(x)
		return x
	end,
} })
local after = collectgarbage("count")
print(
	string.format(
		"%s: %d modules, source %.1f MB (largest %.2f MB), bytecode %.1f MB, Lua heap after require +%.1f MB",
		name,
		n,
		src / 1e6,
		maxsrc / 1e6,
		bc / 1e6,
		(after - before) / 1024
	)
)
