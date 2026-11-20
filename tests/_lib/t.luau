--!strict
-- Minimal test helpers for the Lune runner (tests/run.luau).
local t = {}

export type Ctx = { name: string, failures: { string }, checks: number, skipped: string? }

function t.eq(ctx: Ctx, got: any, want: any, msg: string?)
	ctx.checks += 1
	if got ~= want and not (got ~= got and want ~= want) then
		if #ctx.failures < 25 then
			table.insert(ctx.failures, `{msg or "eq"}: got {tostring(got)}, want {tostring(want)}`)
		end
	end
end

function t.ok(ctx: Ctx, cond: any, msg: string?)
	ctx.checks += 1
	if not cond and #ctx.failures < 25 then
		table.insert(ctx.failures, msg or "assertion failed")
	end
end

-- Mark the test as skipped (e.g. game data in work/ not present, as in CI).
function t.skip(ctx: Ctx, reason: string)
	ctx.skipped = reason
end

-- Read a repo-relative file (tests run with the repo root as cwd).
function t.read(path: string): string
	local fs = require("@lune/fs")
	return fs.readFile(path)
end

return t
