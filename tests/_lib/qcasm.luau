--!strict
-- Minimal assembler that builds a PROG_VERSION 6 progs.dat image in a buffer (pr_comp.h layout),
-- for unit tests of the QC VM. Not part of the game.
local qcasm = {}

export type Func = { name: string, first: number, parm_start: number, locals: number, parms: { number }? }

-- statements: { {op, a, b, c} } (signed values allowed for jumps); functions: list of Func
-- (function 0 is added automatically); globals: { [ofs] = number } as float, globalsInt: { [ofs] = int };
-- strings: { string } appended after the leading "\0"; returns buffer and a map string -> offset.
function qcasm.build(spec: {
	statements: { { number } },
	functions: { Func },
	numglobals: number,
	globals: { [number]: number }?,
	globalsInt: { [number]: number }?,
	strings: { string }?,
	entityfields: number?,
}): (buffer, { [string]: number })
	local strtab = "\0"
	local stroff: { [string]: number } = {}
	for _, s in spec.strings or {} do
		stroff[s] = #strtab
		strtab ..= s .. "\0"
	end
	for _, f in spec.functions do
		if stroff[f.name] == nil then
			stroff[f.name] = #strtab
			strtab ..= f.name .. "\0"
		end
	end
	local nst, nfn = #spec.statements, #spec.functions + 1
	local hdr = 60
	local ofs_st = hdr
	local ofs_gd = ofs_st + nst * 8
	local ofs_fd = ofs_gd
	local ofs_fn = ofs_fd
	local ofs_str = ofs_fn + nfn * 36
	local ofs_gl = ofs_str + #strtab
	local size = ofs_gl + spec.numglobals * 4
	local b = buffer.create(size)
	local function I(o: number, v: number)
		buffer.writei32(b, o, v)
	end
	I(0, 6)
	I(4, 0)
	I(8, ofs_st)
	I(12, nst)
	I(16, ofs_gd)
	I(20, 0)
	I(24, ofs_fd)
	I(28, 0)
	I(32, ofs_fn)
	I(36, nfn)
	I(40, ofs_str)
	I(44, #strtab)
	I(48, ofs_gl)
	I(52, spec.numglobals)
	I(56, spec.entityfields or 0)
	for i, s in spec.statements do
		local o = ofs_st + (i - 1) * 8
		buffer.writeu16(b, o, s[1])
		for k = 2, 4 do
			local v = s[k] or 0
			buffer.writeu16(b, o + (k - 1) * 2, if v < 0 then v + 0x10000 else v)
		end
	end
	for i, f in spec.functions do
		local o = ofs_fn + i * 36
		I(o, f.first)
		I(o + 4, f.parm_start)
		I(o + 8, f.locals)
		I(o + 16, stroff[f.name])
		I(o + 20, 0)
		local parms = f.parms or {}
		I(o + 24, #parms)
		for j, ps in parms do
			buffer.writeu8(b, o + 28 + j - 1, ps)
		end
	end
	buffer.writestring(b, ofs_str, strtab)
	for ofs, v in spec.globals or {} do
		buffer.writef32(b, ofs_gl + ofs * 4, v)
	end
	for ofs, v in spec.globalsInt or {} do
		buffer.writei32(b, ofs_gl + ofs * 4, v)
	end
	return b, stroff
end

return qcasm
