--!strict
--[[
	Headless test runner (Lune). Run from the repo root:
	    lune run tests/run.luau            -- all tests
	    lune run tests/run.luau f32 trace  -- only tests whose path contains a filter
	Discovers tests/**/*.test.luau. Each returns function(ctx) that records checks via tests/_lib/t.
	Exit code 1 if any test fails, so CI and sessions can rely on it.
]]
local fs = require("@lune/fs")
local process = require("@lune/process")

local filters = process.args
local files: { string } = {}
local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			if name ~= "reference" then
				walk(p)
			end
		elseif string.sub(name, -10) == ".test.luau" then
			local keep = #filters == 0
			for _, f in filters do
				if string.find(p, f, 1, true) then
					keep = true
				end
			end
			if keep then
				table.insert(files, p)
			end
		end
	end
end
walk("tests")
table.sort(files)

local failed = 0
for _, p in files do
	local ctx = { name = p, failures = {}, checks = 0 }
	local t0 = os.clock()
	local ok, err = pcall(function()
		local fn = require("../" .. string.sub(p, 1, -6)) :: any
		fn(ctx)
	end)
	if not ok then
		table.insert(ctx.failures, "error: " .. tostring(err))
	end
	local dt = os.clock() - t0
	if #ctx.failures == 0 then
		print(string.format("PASS %-50s %7d checks %6.2fs", p, ctx.checks, dt))
	else
		failed += 1
		print(string.format("FAIL %-50s %7d checks %6.2fs", p, ctx.checks, dt))
		for _, f in ctx.failures do
			print("    " .. f)
		end
	end
end
print(string.format("%d test files, %d failed", #files, failed))
process.exit(if failed > 0 then 1 else 0)
