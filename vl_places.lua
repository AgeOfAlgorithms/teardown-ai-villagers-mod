-- Villagers: places on any map. The host scans the map round the village centre once (spread over frames): sheltered
-- floors grouped into buildings (walls round them, not a tree's crown or a bridge), the loose props that are beds,
-- chairs and tables, open ground, water's edge. Then each household gets a house with beds, each job a workplace, and
-- the village a tavern, a chapel and a square. A map can declare its places instead (villagers.place.<n>).
-- (no #version line: included by main.lua)

VlPlaces = {
	ready = false,          -- the scan and the assignment are done
	list = {},              -- every named place: {id, kind, name, pos, indoor, building, spots = {}, owner}
	byId = {},
	buildings = {},
	beds = {}, chairs = {}, tables = {},
	center = nil,
	stats = {rays = 0, frames = 0, columns = 0},
}

local VP = VlPlaces
local job = nil                                   -- the scan's coroutine
local budget = 0
local LAYER_OURS = 32                             -- villagers' client models and anchors: never part of the map

-- ---------------------------------------------------------------- small helpers
local function ray(o, d, dist)
	VP.stats.rays = VP.stats.rays + 1
	budget = budget - 1
	QueryRequire("physical static")
	QueryCollisionMask(255 - LAYER_OURS - 64)
	return QueryRaycast(o, d, dist)
end

local function spend()                            -- inside the coroutine: yield when this frame's rays are spent
	if budget <= 0 then coroutine.yield() end
end

local function hdist(a, b) local dx, dz = a[1] - b[1], a[3] - b[3]; return math.sqrt(dx * dx + dz * dz) end

-- surfaces of one column, top down (y values), at most 6; the material under the first one
local function column(x, z, top, depth)
	local out, mats = {}, {}
	local y = top
	for k = 1, 6 do
		local hit, d, _, shape = ray(Vec(x, y, z), Vec(0, -1, 0), depth)
		if not hit then break end
		local hy = y - d
		out[#out + 1] = hy
		if shape and shape ~= 0 then
			local ok, m = pcall(GetShapeMaterialAtPosition, shape, Vec(x, hy - 0.05, z))
			mats[#out] = ok and m or ""
		else
			mats[#out] = ""
		end
		y = hy - 0.35
	end
	return out, mats
end

-- ---------------------------------------------------------------- phase 1: where is the village?
local function findCenter(spawn)
	local step, half = VL_CFG.placeCoarseStep, VL_CFG.placeCoarseHalf
	local n = math.floor(2 * half / step) + 1
	local pts = {}
	for iz = 0, n - 1 do
		for ix = 0, n - 1 do
			local x, z = spawn[1] - half + ix * step, spawn[3] - half + iz * step
			local s, mats = column(x, z, spawn[2] + 80, 160)
			for k = 2, #s do
				local gap = s[k - 1] - s[k]
				if gap >= 2.0 and gap <= 14 and mats[k - 1] ~= "foliage" then pts[#pts + 1] = Vec(x, s[k], z); break end
			end
			spend()
		end
	end
	-- the 45 m disc with the most shelter, drawn a little toward the spawn
	local best, bestScore = spawn, -1
	for i = 1, #pts, 2 do
		local c = pts[i]
		local cnt = 0
		for j = 1, #pts do if hdist(c, pts[j]) < 45 then cnt = cnt + 1 end end
		local score = cnt - hdist(c, spawn) / 25
		if score > bestScore then best, bestScore = c, score end
	end
	VP.stats.coarseShelter = #pts
	return Vec(best[1], spawn[2], best[3])
end

-- ---------------------------------------------------------------- phase 2: the fine grid
local G = nil                -- {n, step, x0, z0, top = {}, water = {}, indoor = {[key] = {y...}}}

local function key(ix, iz) return iz * 100000 + ix end

local function fineScan(center)
	local step, half = VL_CFG.placeStep, VL_CFG.placeRadius
	local n = math.floor(2 * half / step) + 1
	G = {n = n, step = step, x0 = center[1] - half, z0 = center[3] - half, top = {}, water = {}, mat = {}, indoor = {}, under = {}}
	for iz = 0, n - 1 do
		for ix = 0, n - 1 do
			local x, z = G.x0 + ix * step, G.z0 + iz * step
			local s, mats = column(x, z, center[2] + 60, 140)
			VP.stats.columns = VP.stats.columns + 1
			local k = key(ix, iz)
			if #s > 0 then
				local low = s[#s]
				G.top[k] = s[1]
				G.mat[k] = mats[1]
				-- (any surface well under the top: a tree crown's ground, a roof's floor - successive hits inside a crown
				--  are close together, so look at all of them)
				for j = 2, #s do
					if s[1] - s[j] > 0.6 and s[1] - s[j] < 14 then G.under[k] = s[j]; break end
				end
				if IsPointInWater(Vec(x, s[1] + 0.2, z)) then G.water[k] = true end
				-- floors with room to stand and a roof (not leaves) within 14 m over them
				local floors = nil
				for j = 2, #s do
					local gap = s[j - 1] - s[j]
					if gap >= 1.9 and gap <= 14 and mats[j - 1] ~= "foliage" and not IsPointInWater(Vec(x, s[j] + 0.2, z)) then
						floors = floors or {}
						floors[#floors + 1] = s[j]
					end
				end
				if floors then G.indoor[k] = floors end
			end
			spend()
		end
	end
end

-- ---------------------------------------------------------------- buildings: connected sheltered floors with walls
local function cellPos(ix, iz, y) return Vec(G.x0 + ix * G.step, y, G.z0 + iz * G.step) end

local function groupBuildings()
	-- union-find over (column, floor index)
	local parent, nodes = {}, {}
	local function id(ix, iz, f) return key(ix, iz) * 8 + f end
	local function find(a) while parent[a] ~= a do parent[a] = parent[parent[a]]; a = parent[a] end return a end
	local function union(a, b) a, b = find(a), find(b); if a ~= b then parent[a] = b end end
	for k, floors in pairs(G.indoor) do
		local iz, ix = math.floor(k / 100000), k % 100000
		for f = 1, #floors do local a = id(ix, iz, f); parent[a] = a; nodes[#nodes + 1] = {a, ix, iz, f, floors[f]} end
	end
	for _, nd in ipairs(nodes) do
		local a, ix, iz, f, y = nd[1], nd[2], nd[3], nd[4], nd[5]
		for dz = -1, 1 do
			for dx = -1, 1 do
				if dx ~= 0 or dz ~= 0 then
					local fl = G.indoor[key(ix + dx, iz + dz)]
					if fl then
						for g = 1, #fl do
							if math.abs(fl[g] - y) <= 0.6 then union(a, id(ix + dx, iz + dz, g)) end
						end
					end
				end
			end
		end
		-- floors stacked in one column belong to one building (storeys)
		local fl = G.indoor[key(ix, iz)]
		if #fl > 1 and f > 1 then union(a, id(ix, iz, 1)) end
	end
	local groups = {}
	for _, nd in ipairs(nodes) do
		local r = find(nd[1])
		local g = groups[r]
		if not g then g = {cells = {}, cols = {}, ncols = 0}; groups[r] = g end
		g.cells[#g.cells + 1] = nd
		local k = key(nd[2], nd[3])
		if not g.cols[k] then g.cols[k] = true; g.ncols = g.ncols + 1 end
	end
	return groups
end

-- the share of a group's edge that has a wall: rays at 1 m from edge cells outward
local function enclosure(g)
	local tried, walls = 0, 0
	for _, nd in ipairs(g.cells) do
		local ix, iz, y = nd[2], nd[3], nd[5]
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			if not g.cols[key(ix + d[1], iz + d[2])] then
				tried = tried + 1
				local o = cellPos(ix, iz, y + 1.0)
				local hit = ray(o, Vec(d[1], 0, d[2]), G.step * 1.5)
				if hit then walls = walls + 1 end
				spend()
			end
		end
		if tried > 160 then break end
	end
	return tried > 0 and walls / tried or 0, tried
end

-- outside cells next to the ground floor's edge where no wall stands: the doors
local function doors(g)
	local out = {}
	local lowest = math.huge
	for _, nd in ipairs(g.cells) do if nd[5] < lowest then lowest = nd[5] end end
	for _, nd in ipairs(g.cells) do
		local ix, iz, y = nd[2], nd[3], nd[5]
		if y < lowest + 0.8 then
			for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				local k2 = key(ix + d[1], iz + d[2])
				local top = G.top[k2]
				if not g.cols[k2] and top and not G.water[k2] and math.abs(top - y) < 0.7 then
					local hit = ray(cellPos(ix, iz, y + 1.0), Vec(d[1], 0, d[2]), G.step * 1.5)
					if not hit then out[#out + 1] = cellPos(ix + d[1], iz + d[2], top) end
					spend()
				end
			end
		end
	end
	return out
end

local function makeBuildings()
	local groups = groupBuildings()
	local list = {}
	for _, g in pairs(groups) do
		local area = g.ncols * G.step * G.step
		if area >= VL_CFG.minHouseArea then
			local enc = enclosure(g)
			if enc >= VL_CFG.minEnclosure then
				local sx, sz, sy, lowest, floors = 0, 0, 0, math.huge, {}
				for _, nd in ipairs(g.cells) do
					local p = cellPos(nd[2], nd[3], nd[5])
					sx, sz = sx + p[1], sz + p[3]
					if nd[5] < lowest then lowest = nd[5] end
				end
				local c = Vec(sx / #g.cells, lowest, sz / #g.cells)
				local b = {id = #list + 1, cells = g.cells, cols = g.cols, area = area, center = c, enclosure = enc,
					floorY = lowest, beds = {}, chairs = {}, tables = {}, doors = doors(g)}
				for _, nd in ipairs(g.cells) do if nd[5] > lowest + 1.5 then b.storeys = 2 end end
				list[#list + 1] = b
			end
		end
	end
	VP.buildings = list
end

-- strictly inside: the point's own cell has a sheltered floor within `below` m under it (beds, sleeping on the floor)
function VlPlaces.indoorAt(p, below)
	if not G then return false end
	local ix = math.floor((p[1] - G.x0) / G.step + 0.5)
	local iz = math.floor((p[3] - G.z0) / G.step + 0.5)
	local fl = G.indoor[key(ix, iz)]
	if not fl then return false end
	for _, y in ipairs(fl) do if p[2] - y >= -0.3 and p[2] - y <= (below or 1.2) then return true end end
	return false
end

-- which building a point is in (its column, a floor within 2.5 m below)
function VlPlaces.buildingAt(p)
	if not G then return nil end
	local ix = math.floor((p[1] - G.x0) / G.step + 0.5)
	local iz = math.floor((p[3] - G.z0) / G.step + 0.5)
	for dz = -1, 1 do
		for dx = -1, 1 do
			local k = key(ix + dx, iz + dz)
			for _, b in ipairs(VP.buildings) do
				if b.cols[k] then return b end
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------- furniture: loose props by their shape
local function propShape(b)
	local best, bestVol = nil, 0
	for _, s in ipairs(GetBodyShapes(b) or {}) do
		local sx, sy, sz = GetShapeSize(s)
		local vol = sx * sy * sz
		if vol > bestVol then best, bestVol = s, vol end
	end
	if not best then return nil end
	local sx, sy, sz, vs = GetShapeSize(best)
	local t = GetShapeWorldTransform(best)
	local axes = {QuatRotateVec(t.rot, Vec(1, 0, 0)), QuatRotateVec(t.rot, Vec(0, 1, 0)), QuatRotateVec(t.rot, Vec(0, 0, 1))}
	local dims = {sx * vs, sy * vs, sz * vs}
	local up, upv = 1, 0
	for i = 1, 3 do if math.abs(axes[i][2]) > upv then up, upv = i, math.abs(axes[i][2]) end end
	local long, other = nil, nil
	for i = 1, 3 do
		if i ~= up then
			if not long or dims[i] > dims[long] then other = long; long = i else other = i end
		end
	end
	return dims[up], dims[long], dims[other], Vec(axes[long][1], 0, axes[long][3])
end

-- a prop's kind: "bed" | "chair" | "table" | nil (VERIFY in game: built-in beds are props of the bedroom sets)
function VlPlaces.classify(h, L, W)
	-- (the game's beds, headboards and bunks included: 1.9-2.1 x 1.0-2.1 x 0.8-2.0 m)
	if L >= 1.8 and L <= 2.4 and W >= 0.85 and W <= 2.3 and h >= 0.6 and h <= 2.1 then return "bed" end
	if h >= 0.65 and h <= 1.25 and L >= 0.3 and L <= 0.75 and W >= 0.3 then return "chair" end
	if h >= 0.6 and h <= 0.95 and L >= 0.8 and L <= 2.5 and W >= 0.55 and W <= 1.5 then return "table" end
	return nil
end

-- ---------------------------------------------------------------- beds by what they are made of
-- (seen in game, Frustrum 2026-11-14: a villager stood next to a real bed that no prop-size rule had found) A bed is a
-- soft (plastic: every game mattress is palette 153-158) surface 0.25-1.0 m over a house's floor, at least ~1.2 m2 and
-- 1.5 m long. Short rays down on a 1/3 m grid over each building's floor cells, loose props included; the soft hits
-- grouped; a sofa counts too (somewhere to sleep).
local function findSoft(b)
	local sub = 3
	local d = G.step / sub
	local soft, cells = {}, {}
	for _, nd in ipairs(b.cells) do
		local ix, iz, fy = nd[2], nd[3], nd[5]
		for sz = 0, sub - 1 do
			for sx = 0, sub - 1 do
				local x = G.x0 + (ix - 0.5) * G.step + (sx + 0.5) * d
				local z = G.z0 + (iz - 0.5) * G.step + (sz + 0.5) * d
				VP.stats.rays = VP.stats.rays + 1
				budget = budget - 1
				QueryRequire("physical")                         -- (loose props too: beds are props)
				QueryCollisionMask(255 - LAYER_OURS - 64)
				local hit, dist, _, sh = QueryRaycast(Vec(x, fy + 1.4, z), Vec(0, -1, 0), 1.3)
				if hit and sh and sh ~= 0 then
					local h = 1.4 - dist
					if h >= 0.25 and h <= 1.0 then
						local ok, m = pcall(GetShapeMaterialAtPosition, sh, Vec(x, fy + h - 0.04, z))
						if ok and m == "plastic" then
							local gx, gz = ix * sub + sx, iz * sub + sz
							local k = gz * 1000000 + gx
							soft[k] = {x = x, z = z, y = fy + h, gx = gx, gz = gz, floor = fy}
							cells[#cells + 1] = k
						end
					end
				end
				spend()
			end
		end
	end
	-- group the soft hits (8 neighbours)
	local seen, out = {}, {}
	for _, k0 in ipairs(cells) do
		if not seen[k0] then
			local stack, grp = {k0}, {}
			seen[k0] = true
			while #stack > 0 do
				local k = table.remove(stack)
				local c = soft[k]
				grp[#grp + 1] = c
				for dz = -1, 1 do
					for dx = -1, 1 do
						local k2 = (c.gz + dz) * 1000000 + (c.gx + dx)
						if soft[k2] and not seen[k2] and math.abs(soft[k2].y - c.y) < 0.35 then seen[k2] = true; stack[#stack + 1] = k2 end
					end
				end
			end
			local area = #grp * d * d
			local x0, x1, z0, z1, sx, sy, sz = 1e9, -1e9, 1e9, -1e9, 0, 0, 0
			for _, c in ipairs(grp) do
				x0, x1 = math.min(x0, c.x), math.max(x1, c.x); z0, z1 = math.min(z0, c.z), math.max(z1, c.z)
				sx, sy, sz = sx + c.x, sy + c.y, sz + c.z
			end
			local ex, ez = x1 - x0 + d, z1 - z0 + d
			local L, W = math.max(ex, ez), math.min(ex, ez)
			-- (seen in game, Frustrum 2026-11-14: a sleeper on the pavement under the bar's awning) a bed stands in a
			-- room: walls within 5 m on at least three of four sides, just over the mattress
			local walls = 0
			if area >= VL_CFG.bedMinArea then
				local o = Vec(sx / #grp, sy / #grp + 0.5, sz / #grp)
				for _, dv in ipairs({Vec(1, 0, 0), Vec(-1, 0, 0), Vec(0, 0, 1), Vec(0, 0, -1)}) do
					VP.stats.rays = VP.stats.rays + 1
					QueryRequire("physical static")
					QueryCollisionMask(255 - LAYER_OURS - 64)
					if QueryRaycast(o, dv, 5) then walls = walls + 1 end
				end
			end
			if area >= VL_CFG.bedMinArea and L >= 1.5 and L <= 3.2 and W >= 0.6 and walls >= 3 then
				out[#out + 1] = {kind = "bed", pos = Vec(sx / #grp, grp[1].floor, sz / #grp), top = sy / #grp, L = L, W = W, area = area,
					axis = ex >= ez and Vec(1, 0, 0) or Vec(0, 0, 1), double = W >= 1.3, building = b, soft = true}
			end
		end
	end
	return out
end

local function findBeds()
	VP.beds = {}
	for _, b in ipairs(VP.buildings) do
		b.beds = findSoft(b)
		for _, f in ipairs(b.beds) do VP.beds[#VP.beds + 1] = f end
	end
end

local function findFurniture(center)
	local half = VL_CFG.placeRadius
	local lo = VecSub(center, Vec(half, 30, half))
	local hi = VecAdd(center, Vec(half, 40, half))
	local list = QueryAabbBodies(lo, hi) or {}
	VP.beds, VP.chairs, VP.tables = {}, {}, {}
	for i, b in ipairs(list) do
		if IsBodyDynamic(b) and not HasTag(b, "vlanchor") then
			local h, L, W, ax = propShape(b)
			local kind = h and VlPlaces.classify(h, L, W)
			local blo, bhi = GetBodyBounds(b)
			local mid = VecScale(VecAdd(blo, bhi), 0.5)
			if kind == "bed" or kind == "table" then
				-- The top's material decides (measured from the game's own furniture models, 2026-11-14: every bed's
				-- mattress is plastic - palette 153-158 - while tables, desks and drawers are wood 57-61). Seen in
				-- game before that rule: 768 kg benches, a dumpster, dining tables and a desk all passed on size.
				local mass = GetBodyMass(b)
				local mat = ""
				QueryRequire("physical dynamic")
				local hit, d, _, sh = QueryRaycast(Vec(mid[1], bhi[2] + 0.3, mid[3]), Vec(0, -1, 0), bhi[2] - blo[2] + 0.3)
				if hit and sh and sh ~= 0 then
					local okm, m = pcall(GetShapeMaterialAtPosition, sh, Vec(mid[1], bhi[2] + 0.3 - d - 0.05, mid[3]))
					mat = okm and tostring(m) or ""
				end
				if kind == "bed" then
					if mat ~= "plastic" or mass > VL_CFG.bedMaxMass or not VlPlaces.indoorAt(Vec(mid[1], blo[2] + 0.05, mid[3]), 0.6) then
						kind = (mat ~= "plastic" and h >= 0.6 and h <= 0.95) and "table" or nil
					end
				elseif mat == "plastic" then
					kind = nil                                      -- (a sofa or a soft thing: no table)
				end
			end
			if kind then
				local f = {body = b, kind = kind, pos = mid, L = L, W = W, h = h, axis = ax, top = bhi[2],
					double = kind == "bed" and W >= 1.3}
				f.building = VlPlaces.buildingAt(mid)
				if kind == "bed" then VP.beds[#VP.beds + 1] = f
				elseif kind == "chair" then VP.chairs[#VP.chairs + 1] = f
				else VP.tables[#VP.tables + 1] = f end
				if f.building then
					local t = f.building[kind == "bed" and "beds" or (kind == "chair" and "chairs" or "tables")]
					t[#t + 1] = f
				end
			end
		end
		if i % 40 == 0 then budget = budget - 40; spend() end
	end
end

-- ---------------------------------------------------------------- open ground
local function openCells(filter, maxN)
	local out = {}
	for k, top in pairs(G.top) do
		-- (open ground: nothing under it either - seen in game, Frustrum 2026-11-14: the field was on tree crowns)
		if not G.indoor[k] and not G.water[k] and not G.under[k] then
			local iz, ix = math.floor(k / 100000), k % 100000
			if not filter or filter(ix, iz, top, k) then out[#out + 1] = cellPos(ix, iz, top) end
		end
	end
	-- a stable order (pairs is not), then thinned to maxN
	table.sort(out, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[3] < b[3] end)
	if maxN and #out > maxN then
		local t = {}
		for i = 1, maxN do t[i] = out[math.floor((i - 1) * #out / maxN) + 1] end
		out = t
	end
	return out
end

local function nearWater(ix, iz)
	for dz = -2, 2 do for dx = -2, 2 do if G.water[key(ix + dx, iz + dz)] then return true end end end
	return false
end

-- ---------------------------------------------------------------- places and assignment
local function addPlace(p)
	p.id = p.id or (p.kind .. #VP.list + 1)
	p.spots = p.spots or {}
	VP.list[#VP.list + 1] = p
	VP.byId[p.id] = p
	return p
end

-- walls within 6 m on at least three of four sides, at chest height: really in a room (seen in game, Frustrum
-- 2026-11-14: a house's sheltered floor ran out under the bar's awning onto the pavement, and a villager slept there)
function VlPlaces.enclosedAt(p)
	local walls = 0
	local o = VecAdd(p, Vec(0, 1.0, 0))
	for _, dv in ipairs({Vec(1, 0, 0), Vec(-1, 0, 0), Vec(0, 0, 1), Vec(0, 0, -1)}) do
		VP.stats.rays = VP.stats.rays + 1
		QueryRequire("physical static")
		QueryCollisionMask(255 - LAYER_OURS - 64)
		if QueryRaycast(o, dv, 6) then walls = walls + 1 end
	end
	return walls >= 3
end

local function standSpots(b, n)
	local out = {}
	local cells = b.cells
	local tries = math.min(#cells, n * 4)
	for i = 1, tries do
		if #out >= n then break end
		local nd = cells[math.floor((i - 1) * #cells / tries) + 1]
		local p = cellPos(nd[2], nd[3], nd[5])
		if VlPlaces.enclosedAt(p) then out[#out + 1] = {pos = p, posture = "stand"} end
	end
	if #out == 0 and #cells > 0 then out[1] = {pos = cellPos(cells[1][2], cells[1][3], cells[1][5]), posture = "stand"} end
	return out
end

local function seatSpots(b)
	local out = {}
	for _, c in ipairs(b.chairs) do out[#out + 1] = {pos = VecCopy(c.pos), posture = "sit", body = c.body} end
	return out
end

-- households from VL_PEOPLE: home ids shared by family members
local function households()
	local hs, order = {}, {}
	for _, p in ipairs(VL_PEOPLE or {}) do
		local h = p.home or p.id
		if not hs[h] then hs[h] = {id = h, members = {}}; order[#order + 1] = hs[h] end
		table.insert(hs[h].members, p)
	end
	return order
end

local function bedSlots(b)
	local n = 0
	for _, f in ipairs(b.beds) do n = n + (f.double and 2 or 1) end
	return n
end

local function assign()
	local bs = {}
	for _, b in ipairs(VP.buildings) do bs[#bs + 1] = b end
	local c = VP.center
	-- homes: buildings with beds first, the nearest to the centre first
	table.sort(bs, function(a, b)
		local sa, sb = bedSlots(a), bedSlots(b)
		if (sa > 0) ~= (sb > 0) then return sa > 0 end
		return hdist(a.center, c) < hdist(b.center, c)
	end)
	local used = {}
	VP.homes = {}
	local hh = households()
	-- the biggest households pick first
	table.sort(hh, function(a, b) if #a.members ~= #b.members then return #a.members > #b.members end return a.id < b.id end)
	for _, h in ipairs(hh) do
		local pick = nil
		for _, b in ipairs(bs) do
			if not used[b] and (bedSlots(b) >= #h.members or (not pick and bedSlots(b) > 0)) then pick = b; break end
		end
		if not pick then for _, b in ipairs(bs) do if not used[b] then pick = b; break end end end
		local owner = h.members[1]
		local fam = h.id:sub(1, 1):upper() .. h.id:sub(2)
		local name = #h.members > 1 and ("the " .. fam .. " house") or (owner.name .. "'s house")
		if pick then
			used[pick] = true
			local pl = addPlace({kind = "house", name = name, pos = pick.doors[1] or pick.center, inside = pick.center,
				indoor = true, building = pick, household = h.id, spots = standSpots(pick, 6)})
			for _, s in ipairs(seatSpots(pick)) do pl.spots[#pl.spots + 1] = s end
			pl.beds = pick.beds
			VP.homes[h.id] = pl
		else
			-- (seen in game, Frustrum 2026-11-14: Odette slept in the street) no building left: they lodge with the
			-- household that has the most room; camping only where the map has no buildings at all
			local best, room = nil, -1e9
			for hid, pl in pairs(VP.homes) do
				if pl.building then
					local r = bedSlots(pl.building) * 10 + pl.building.area - (pl.lodgers or 0) * 30
					if r > room then best, room = pl, r end
				end
			end
			if best then
				VP.homes[h.id] = best
				best.lodgers = (best.lodgers or 0) + #h.members
			else
				VP.homes[h.id] = {camp = true, household = h.id}
			end
		end
	end
	-- the rest: the tavern has the most seats, the chapel is the biggest left, workshops the small ones
	local left = {}
	for _, b in ipairs(bs) do if not used[b] then left[#left + 1] = b end end
	local function take(score)
		local best, bs2 = nil, -math.huge
		for i, b in ipairs(left) do
			local s = score(b)
			if s > bs2 then best, bs2 = i, s end
		end
		if not best then return nil end
		return table.remove(left, best)
	end
	local tav = take(function(b) return #b.chairs * 3 + #b.tables * 4 + b.area / 30 - hdist(b.center, c) / 30 end)
	if tav then
		local pl = addPlace({kind = "tavern", name = "the tavern", pos = tav.doors[1] or tav.center, inside = tav.center,
			indoor = true, building = tav, spots = seatSpots(tav)})
		for _, s in ipairs(standSpots(tav, 8)) do pl.spots[#pl.spots + 1] = s end
	end
	local chap = take(function(b) return b.area - hdist(b.center, c) / 4 end)
	if chap then
		local pl = addPlace({kind = "chapel", name = "the chapel", pos = chap.doors[1] or chap.center, inside = chap.center,
			indoor = true, building = chap, spots = seatSpots(chap)})
		for _, s in ipairs(standSpots(chap, 8)) do pl.spots[#pl.spots + 1] = s end
	end
	local WORK_NAMES = {smithy = "the smithy", shop = "the shop", workshop = "the workshop"}
	for _, p in ipairs(VL_PEOPLE or {}) do
		local wk = p.workKind
		if WORK_NAMES[wk] and not VP.byId[wk] then
			local b = take(function(b) return -math.abs(b.area - 50) - hdist(b.center, c) / 3 end)
			if b then
				addPlace({id = wk, kind = wk, name = WORK_NAMES[wk], pos = b.doors[1] or b.center, inside = b.center,
					indoor = true, building = b, spots = standSpots(b, 4)})
			end
		end
	end
	-- outdoors: the square (open ground near the centre), the field, the water's edge, the patrol round
	local nearC = openCells(function(ix, iz, top) return hdist(cellPos(ix, iz, top), c) < 18 end, 24)
	if #nearC > 0 then
		local sq = addPlace({id = "square", kind = "square", name = "the square", pos = nearC[1], indoor = false})
		for _, p in ipairs(nearC) do sq.spots[#sq.spots + 1] = {pos = p, posture = "stand"} end
	end
	local field = openCells(function(ix, iz, top, k) local m = G.mat[k]; return m == "dirt" or m == "grass" or m == "foliage" end, 40)
	if #field > 4 then
		local f = addPlace({id = "field", kind = "field", name = "the field", pos = field[math.floor(#field / 2) + 1], indoor = false})
		for _, p in ipairs(field) do f.spots[#f.spots + 1] = {pos = p, posture = "stand"} end
	end
	local shore = openCells(function(ix, iz) return nearWater(ix, iz) end, 20)
	if #shore > 0 then
		local w = addPlace({id = "water", kind = "water", name = "the water's edge", pos = shore[1], indoor = false})
		for _, p in ipairs(shore) do w.spots[#w.spots + 1] = {pos = p, posture = "stand"} end
	end
	local ring = openCells(function(ix, iz, top) local d = hdist(cellPos(ix, iz, top), c); return d > 25 and d < 45 end, 400)
	if #ring > 0 then
		-- six points round the centre, one per sector
		local pts = {}
		for s = 0, 5 do
			local a0 = s * math.pi / 3
			local best, bd = nil, math.huge
			for _, p in ipairs(ring) do
				local a = math.atan2(p[3] - c[3], p[1] - c[1]) % (2 * math.pi)
				local da = math.abs(a - a0 - math.pi / 6)
				if da < bd then best, bd = p, da end
			end
			if best then pts[#pts + 1] = best end
		end
		local pr = addPlace({id = "patrol", kind = "patrol", name = "the village edge", pos = pts[1], indoor = false})
		for _, p in ipairs(pts) do pr.spots[#pr.spots + 1] = {pos = p, posture = "stand"} end
	end
	-- a home for campers: the square
	for hid, h in pairs(VP.homes) do
		if h.camp then
			local sq = VP.byId.square
			VP.homes[hid] = addPlace({kind = "camp", name = "the camp by the square", pos = sq and sq.pos or c, indoor = false,
				household = hid, spots = sq and sq.spots or {{pos = c, posture = "stand"}}})
		end
	end
end

-- ---------------------------------------------------------------- the map's own places
-- villagers.place.<n> = "kind|name|x,y,z" (kinds: house, bed, chair, tavern, chapel, smithy, shop, workshop, field,
-- water, square, patrol). A bed or chair goes to the house / place nearest to it. Read once when the scan starts.
local function mapPlaces()
	local ok, keys = pcall(ListKeys, "villagers.place")
	if not ok or not keys or #keys == 0 then return false end
	local houses = {}
	local pending = {}
	for _, k in ipairs(keys) do
		local s = GetString("villagers.place." .. k)
		local kind, name, x, y, z = s:match("^([%w_]+)|([^|]*)|([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)")
		if kind then
			local pos = Vec(tonumber(x), tonumber(y), tonumber(z))
			if kind == "bed" or kind == "chair" then pending[#pending + 1] = {kind = kind, pos = pos}
			else
				local pl = addPlace({kind = kind, name = name ~= "" and name or ("the " .. kind), pos = pos, inside = pos,
					indoor = kind ~= "field" and kind ~= "water" and kind ~= "square" and kind ~= "patrol",
					spots = {{pos = pos, posture = "stand"}}, beds = {}})
				if kind == "house" then houses[#houses + 1] = pl end
			end
		end
	end
	for _, f in ipairs(pending) do
		local best, bd = nil, math.huge
		for _, pl in ipairs(VP.list) do
			local d = VecLength(VecSub(pl.pos, f.pos))
			if d < bd then best, bd = pl, d end
		end
		if best then
			if f.kind == "bed" then
				best.beds = best.beds or {}
				best.beds[#best.beds + 1] = {pos = f.pos, axis = Vec(1, 0, 0), top = f.pos[2] + 0.5, L = 2, W = 1}
			else
				best.spots[#best.spots + 1] = {pos = f.pos, posture = "sit"}
			end
		end
	end
	VP.homes = {}
	local hh = households()
	for i, h in ipairs(hh) do
		local pl = houses[(i - 1) % math.max(1, #houses) + 1]
		if pl then pl.household = pl.household or h.id; VP.homes[h.id] = pl end
	end
	VP.declared = true
	return true
end

-- ---------------------------------------------------------------- the job
local function run(spawn)
	if mapPlaces() then
		VP.center = VP.byId.square and VP.byId.square.pos or spawn
		return
	end
	VP.center = findCenter(spawn)
	fineScan(VP.center)
	makeBuildings()
	findFurniture(VP.center)
	findBeds()                                         -- (beds by material; the prop rule's beds are replaced)
	assign()
end

function VlPlaces.start(spawn)
	VP.ready, VP.list, VP.byId, VP.buildings = false, {}, {}, {}
	VP.stats = {rays = 0, frames = 0, columns = 0}
	VP.spawn = VecCopy(spawn)
	job = coroutine.create(run)
	VP.firstResume = true
end

function VlPlaces.tick(dt)
	if not job then return end
	budget = VL_CFG.placeRaysPerFrame
	VP.stats.frames = VP.stats.frames + 1
	local ok, err
	if VP.firstResume then VP.firstResume = false; ok, err = coroutine.resume(job, VP.spawn)
	else ok, err = coroutine.resume(job) end
	if not ok then
		VP.error = tostring(err)
		job = nil
		VP.ready = true                                    -- (the villagers make do: everyone camps at the spawn)
		if not VP.homes then VP.homes = {} end
		return
	end
	if coroutine.status(job) == "dead" then
		job = nil
		VP.ready = true
		G = G and {n = G.n, step = G.step, x0 = G.x0, z0 = G.z0, top = G.top, water = G.water, mat = G.mat, indoor = G.indoor}
	end
end

-- ---------------------------------------------------------------- for the villagers
function VlPlaces.home(person) return VP.homes and VP.homes[person.home or person.id] end

function VlPlaces.ofKind(kind)
	for _, p in ipairs(VP.list) do if p.kind == kind then return p end end
	return nil
end

function VlPlaces.byName(name)
	if not name then return nil end
	local n = name:lower():gsub("^%s+", ""):gsub("%s+$", "")
	for _, p in ipairs(VP.list) do
		local pn = p.name:lower()
		if pn == n or pn:gsub("^the ", "") == n:gsub("^the ", "") then return p end
	end
	for _, p in ipairs(VP.list) do
		if p.name:lower():find(n, 1, true) or n:find(p.kind, 1, true) then return p end
	end
	return nil
end

-- a free spot at a place for villager vid: {pos, posture, face}; spots are held until released
function VlPlaces.claim(place, vid, want)
	if not place then return nil end
	for _, s in ipairs(place.spots) do if s.taken == vid then return s end end
	local free = {}
	for _, s in ipairs(place.spots) do
		if not s.taken and (not want or s.posture == want) then free[#free + 1] = s end
	end
	if #free == 0 and want then return VlPlaces.claim(place, vid, nil) end
	if #free == 0 then return {pos = place.inside or place.pos, posture = "stand", shared = true} end
	local s = free[VlRand(#free)]
	s.taken = vid
	return s
end

function VlPlaces.release(vid)
	for _, p in ipairs(VP.list) do
		for _, s in ipairs(p.spots) do if s.taken == vid then s.taken = nil end end
		for _, b in ipairs(p.beds or {}) do if b.taken == vid then b.taken = nil end end
	end
end

-- a bed in the villager's home: {pos (where the body lies), head = Vec (direction to the head end), top}
function VlPlaces.bed(person, vid)
	local home = VlPlaces.home(person)
	if not home then return nil end
	for _, b in ipairs(home.beds or {}) do if b.taken == vid then return b end end
	for _, b in ipairs(home.beds or {}) do
		local n = 0
		for _, other in pairs(b.sleepers or {}) do n = n + 1 end
		if not b.taken or (b.double and n < 2) then
			b.sleepers = b.sleepers or {}
			b.sleepers[vid] = true
			if not b.taken then b.taken = vid end
			return b
		end
	end
	return nil
end

-- where a bed's sleeper lies right now (beds are loose props: they move): the middle of its top, the head end
-- toward the nearer wall
function VlPlaces.bedPose(b, side)
	local pos, axis = b.pos, b.axis or Vec(1, 0, 0)
	if b.body and IsHandleValid(b.body) then
		local lo, hi = GetBodyBounds(b.body)
		pos = VecScale(VecAdd(lo, hi), 0.5)
		local h, L, W, ax = propShape(b.body)
		if ax then axis = VecNormalize(ax) end
		b.top = hi[2]
		local hit, d = QueryRaycast(Vec(pos[1], hi[2] + 0.5, pos[3]), Vec(0, -1, 0), 2)
		if hit then b.top = hi[2] + 0.5 - d end
	end
	-- (the head end: toward the nearer wall, looked for just over the mattress)
	local o = b.top and Vec(pos[1], b.top + 0.15, pos[3]) or VecAdd(pos, Vec(0, 0.2, 0))
	local head
	if b.L and b.W and b.L / math.max(0.1, b.W) < 1.4 then
		-- (seen in game, Frustrum 2026-11-14: a sleeper lay across a square double bed) square beds: the head is
		-- toward the nearest headboard or wall of the four sides
		local bestD = 99
		for _, dv in ipairs({Vec(1, 0, 0), Vec(-1, 0, 0), Vec(0, 0, 1), Vec(0, 0, -1)}) do
			local dd = select(2, QueryRaycast(o, dv, 2.5)) or 9
			if dd < bestD then bestD, head = dd, dv end
		end
	else
		local f1 = select(2, QueryRaycast(o, axis, 2)) or 9
		local f2 = select(2, QueryRaycast(o, VecScale(axis, -1), 2)) or 9
		head = f1 <= f2 and axis or VecScale(axis, -1)
	end
	local p = Vec(pos[1], b.top or pos[2], pos[3])
	if b.double and side then
		local right = Vec(-head[3], 0, head[1])
		p = VecAdd(p, VecScale(right, side * 0.35))
	end
	return p, head
end

-- the grid's view round a point for VlSense (when VlNav has none): floor / wall / water / unknown
function VlPlaces.cellKind(p)
	if not G then return "unknown" end
	local ix = math.floor((p[1] - G.x0) / G.step + 0.5)
	local iz = math.floor((p[3] - G.z0) / G.step + 0.5)
	local k = key(ix, iz)
	if G.water[k] then return "water" end
	local top = G.top[k]
	if not top then return "unknown" end
	local fl = G.indoor[k]
	if fl then
		for _, y in ipairs(fl) do if math.abs(y - p[2]) < 0.8 then return "floor" end end
	end
	if math.abs(top - p[2]) < 0.8 then return "floor" end
	if top > p[2] + 0.8 then return "wall" end
	return "drop"
end

-- a one-line summary for logs and the TEST overlay
function VlPlaces.summary()
	local s = string.format("places %s: %d buildings, %d beds, %d chairs, %d tables, %d places, rays %d, frames %d",
		VP.ready and "ready" or "scanning", #VP.buildings, #VP.beds, #VP.chairs, #VP.tables, #VP.list, VP.stats.rays, VP.stats.frames)
	if VP.error then s = s .. " ERROR " .. VP.error end
	return s
end
