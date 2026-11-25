--!strict
--!native
--[[
	DarkPlaces polygon.c / polygon.h: "this code is in the public domain" (Forest Hale, polygon.c L2-4).
]]
--[[
	Port of polygon.c @xonotic-v0.8.6. PARTIAL: the double-precision PolygonD_QuadForPlane and PolygonD_Divide
	(users so far: collision.c Collision_NewBrushFromPlanes). C double = Luau number, so nothing is rounded;
	the order of the operations is the C order.
	Point lists (double[3 * n]) are 1-based Luau arrays: C element k is at [k + 1].
	NOT YET PORTED: the float versions (PolygonF_*) and PolygonD/F_Clip, added with their users.
]]
local polygon = {}

-- port: polygon.c PolygonD_QuadForPlane L54-97 @xonotic-v0.8.6
function polygon.PolygonD_QuadForPlane(
	outpoints: { number },
	planenormalx: number,
	planenormaly: number,
	planenormalz: number,
	planedist: number,
	quadsize: number
)
	local d: number
	local quadright = { 0, 0, 0 }
	local quadup = { 0, 0, 0 }
	if math.abs(planenormalz) > math.abs(planenormalx) and math.abs(planenormalz) > math.abs(planenormaly) then
		quadup[1] = 1
		quadup[2] = 0
		quadup[3] = 0
	else
		quadup[1] = 0
		quadup[2] = 0
		quadup[3] = 1
	end
	-- d = -DotProduct(quadup, planenormal);
	d = -(quadup[1] * planenormalx + quadup[2] * planenormaly + quadup[3] * planenormalz)
	-- VectorMA(quadup, d, planenormal, quadup);
	quadup[1] += d * planenormalx
	quadup[2] += d * planenormaly
	quadup[3] += d * planenormalz
	-- VectorNormalize(quadup);
	d = 1.0 / math.sqrt(quadup[1] * quadup[1] + quadup[2] * quadup[2] + quadup[3] * quadup[3])
	quadup[1] *= d
	quadup[2] *= d
	quadup[3] *= d
	-- CrossProduct(quadup,planenormal,quadright);
	quadright[1] = quadup[2] * planenormalz - quadup[3] * planenormaly
	quadright[2] = quadup[3] * planenormalx - quadup[1] * planenormalz
	quadright[3] = quadup[1] * planenormaly - quadup[2] * planenormalx
	-- make the points
	outpoints[1] = planedist * planenormalx - quadsize * quadright[1] + quadsize * quadup[1]
	outpoints[2] = planedist * planenormaly - quadsize * quadright[2] + quadsize * quadup[2]
	outpoints[3] = planedist * planenormalz - quadsize * quadright[3] + quadsize * quadup[3]
	outpoints[4] = planedist * planenormalx + quadsize * quadright[1] + quadsize * quadup[1]
	outpoints[5] = planedist * planenormaly + quadsize * quadright[2] + quadsize * quadup[2]
	outpoints[6] = planedist * planenormalz + quadsize * quadright[3] + quadsize * quadup[3]
	outpoints[7] = planedist * planenormalx + quadsize * quadright[1] - quadsize * quadup[1]
	outpoints[8] = planedist * planenormaly + quadsize * quadright[2] - quadsize * quadup[2]
	outpoints[9] = planedist * planenormalz + quadsize * quadright[3] - quadsize * quadup[3]
	outpoints[10] = planedist * planenormalx - quadsize * quadright[1] - quadsize * quadup[1]
	outpoints[11] = planedist * planenormaly - quadsize * quadright[2] - quadsize * quadup[2]
	outpoints[12] = planedist * planenormalz - quadsize * quadright[3] - quadsize * quadup[3]
end

-- port: polygon.c PolygonD_Divide L245-309 @xonotic-v0.8.6
-- outfrontpoints / outbackpoints may be nil (C: NULL with a max of 0). Returns neededfrontpoints,
-- neededbackpoints, oncount (C: out pointers).
function polygon.PolygonD_Divide(
	innumpoints: number,
	inpoints: { number },
	planenormalx: number,
	planenormaly: number,
	planenormalz: number,
	planedist: number,
	epsilon: number,
	outfrontmaxpoints: number,
	outfrontpoints: { number }?,
	outbackmaxpoints: number,
	outbackpoints: { number }?
): (number, number, number)
	local frontcount, backcount, oncount = 0, 0, 0
	local frac: number, pdist: number, ndist: number
	local fo, bo = 0, 0 -- write positions of *outfrontpoints++ / *outbackpoints++
	if innumpoints ~= 0 then
		local n = 0 -- 0-based offset of point n in inpoints
		local p: number
		ndist = inpoints[n + 1] * planenormalx
			+ inpoints[n + 2] * planenormaly
			+ inpoints[n + 3] * planenormalz
			- planedist
		for i = 0, innumpoints - 1 do
			p = n
			pdist = ndist
			n = (if (i + 1) < innumpoints then (i + 1) else 0) * 3
			ndist = inpoints[n + 1] * planenormalx
				+ inpoints[n + 2] * planenormaly
				+ inpoints[n + 3] * planenormalz
				- planedist
			if pdist >= -epsilon then
				if pdist <= epsilon then
					oncount += 1
				end
				if frontcount < outfrontmaxpoints then
					local o = outfrontpoints :: { number }
					o[fo + 1] = inpoints[p + 1]
					o[fo + 2] = inpoints[p + 2]
					o[fo + 3] = inpoints[p + 3]
					fo += 3
				end
				frontcount += 1
			end
			if pdist <= epsilon then
				if backcount < outbackmaxpoints then
					local o = outbackpoints :: { number }
					o[bo + 1] = inpoints[p + 1]
					o[bo + 2] = inpoints[p + 2]
					o[bo + 3] = inpoints[p + 3]
					bo += 3
				end
				backcount += 1
			end
			if (pdist > epsilon and ndist < -epsilon) or (pdist < -epsilon and ndist > epsilon) then
				oncount += 1
				frac = pdist / (pdist - ndist)
				if frontcount < outfrontmaxpoints then
					local o = outfrontpoints :: { number }
					o[fo + 1] = inpoints[p + 1] + frac * (inpoints[n + 1] - inpoints[p + 1])
					o[fo + 2] = inpoints[p + 2] + frac * (inpoints[n + 2] - inpoints[p + 2])
					o[fo + 3] = inpoints[p + 3] + frac * (inpoints[n + 3] - inpoints[p + 3])
					fo += 3
				end
				frontcount += 1
				if backcount < outbackmaxpoints then
					local o = outbackpoints :: { number }
					o[bo + 1] = inpoints[p + 1] + frac * (inpoints[n + 1] - inpoints[p + 1])
					o[bo + 2] = inpoints[p + 2] + frac * (inpoints[n + 2] - inpoints[p + 2])
					o[bo + 3] = inpoints[p + 3] + frac * (inpoints[n + 3] - inpoints[p + 3])
					bo += 3
				end
				backcount += 1
			end
		end
	end
	return frontcount, backcount, oncount
end

return polygon
