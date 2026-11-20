--!strict
-- The content-policy switch (D-016): mode semantics. Gameplay-identity tests across modes are
-- GORE-MODE-TESTS (need the headless server, M4).
local t = require("../_lib/t")
local CP = require("../../platform/contentpolicy")

return function(ctx: t.Ctx)
	t.eq(ctx, CP.mode(), "player-choice", "default mode is Xonotic behaviour while Q-007 is deferred")

	CP._setModeForTest("player-choice")
	t.eq(ctx, next(CP.lockedCvars()), nil, "player-choice locks nothing")
	t.eq(ctx, CP.goreAssetsEnabled(), true, "player-choice loads gore assets")
	t.eq(ctx, CP.resolve(true), "normal", "player-choice serves gore assets")

	CP._setModeForTest("forced-gentle")
	t.eq(ctx, CP.lockedCvars().cl_gentle, "1", "forced-gentle locks cl_gentle 1")
	t.eq(ctx, CP.goreAssetsEnabled(), true, "forced-gentle keeps the gore group")
	t.eq(ctx, CP.resolve(true), "normal", "forced-gentle serves real files")

	CP._setModeForTest("removed")
	t.eq(ctx, CP.lockedCvars().cl_gentle, "1", "removed locks cl_gentle 1")
	t.eq(ctx, CP.goreAssetsEnabled(), false, "removed never loads the gore group")
	t.eq(ctx, CP.resolve(true), "placeholder", "removed serves placeholders for gore paths")
	t.eq(ctx, CP.resolve(false), "normal", "removed never touches non-gore paths")

	t.ok(ctx, not pcall(CP._setModeForTest, "bogus" :: any), "unknown modes are rejected")
	CP._setModeForTest("player-choice")
end
