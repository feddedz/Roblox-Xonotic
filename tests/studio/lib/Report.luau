--!strict
-- Collects probe results and prints them as one block to copy from the Output window.
local Report = {}

local lines: { string } = {}

function Report.add(id: string, result: string)
	table.insert(lines, `{id}\t{result}`)
	print(`[StudioTests] {id}: {result}`)
end

function Report.dump(title: string)
	print(`===== BEGIN {title} (copy everything until END into HANDOFF §GOTCHAS / the session) =====`)
	for _, l in lines do
		print(l)
	end
	print(`===== END {title} =====`)
end

return Report
