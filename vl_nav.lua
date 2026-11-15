-- vl_nav.lua: VlNav, the villagers' walking (server). Contract: villagers/PROJECT.md "VlNav"; measurements and the
-- choice of method: villagers/export/nav_report.md. Included by main.lua (no #version line). One global: VlNav;
-- everything else is file-local.
--
-- The walk grid: a lazy 2.5D grid of 0.5 m columns. A node is a walkable surface in a column, found by a probe
-- (one ray down from 1.1-1.35 m above the floor of the node it is reached from, so stairs, upper floors and the
-- street under a bridge are different nodes), then tested once and cached:
--   water deeper than WADE -> blocked; a sphere (CLR) at BODY_LO above the floor touches nothing heavy (static, or
--   dynamic and not light: doors and small loose things are pushed aside, not walked round) -> free, else the point
--   is nudged away from the nearest surface (up to NUDGE_N times, within the cell: doorways narrower than the grid);
--   a sphere cast up to BODY_TOP finds no low ceiling. Fire near a node blocks it while the fire burns.
-- Edges: 8 neighbours, a step up of STEP_UP at most, down STEP_DOWN (never off a drop), no corner cutting; an edge
-- with a nudged end is checked with a sphere cast at hip height.
-- A plan runs through stages over frames, under one per-frame budget (us of estimated PUC Lua + engine time) shared
-- by every pending request: route cache -> snap start / goal -> straight line (a march along the grid) ->
-- [engine planner (method "engine" / "hybrid"): its path validated on the grid] -> weighted A* -> string pulling
-- (marches on cached cells + hip-height casts) -> the route cache (routes between the same places are reused, in
-- both directions when no step is one-way).
-- Following: turning at a natural rate, one ground ray per step, separation from walkers and players, yielding
-- head-on (in narrow spots the walker that is not in the doorway waits), pushing light bodies, stuck -> replan ->
-- teleport along the path while nobody sees it -> failed. Far from every player (VL_CFG.lodDist) and unseen a
-- walker moves along its path at 4 Hz with no queries at all.

VlNav = {}

local sqrt, floor, ceil, abs, min, max = math.sqrt, math.floor, math.ceil, math.abs, math.min, math.max

-- ---------------------------------------------------------------- tunables
local CELL = 0.5
local CLR = 0.25            -- m: clearance radius at a node point (a 0.8 m doorway leaves a 0.3 m band for it)
local NARROW = 0.55         -- m: nearer than this to a wall = a narrow node (doorways, alleys): cost, yielding
local STEP_UP = 0.45
local STEP_DOWN = 0.45       -- (a ledge; steeper stairs and slopes pass the midpoint test)
local STAIR_MAX = 0.8       -- m: the most a stair / slope edge may rise or fall over one cell (diagonals: 0.7 m)
local PROBE_UP = 1.1        -- probes start 1.1-1.35 m above the floor they are made from (quantised to PROBE_Q)
local PROBE_Q = 0.25
local PROBE_LEN = 2.0
local BODY_LO = 0.7         -- the clearance sphere's centre above the floor (its bottom clears a 0.45 m step)
local BODY_TOP = 1.6        -- the upward sweep's end (its top: 1.85 m)
local HIP = 0.9
local HIP_R = 0.15
local NUDGE_N = 2
local WADE = 0.35           -- m of water a walker may wade
local LIGHT_MASS = 40       -- loose dynamic bodies lighter than this and smaller than LIGHT_SIZE are pushed aside
local LIGHT_SIZE = 0.9
local DOOR_MASS = 600       -- dynamic bodies jointed to something static (doors, gates) up to this are pushed open
local PASS_TTL = 30         -- s: how long a body's light / heavy verdict is kept
local DYN_TTL = 20          -- s: a node blocked by a dynamic body is tested again after this
local FIRE_R = 1.5          -- m: nodes this near a fire are blocked
local FIRE_TTL = 3          -- s: a node's fire verdict
local FIRE_REGION = 30      -- m: only nodes this near a known fire point are checked for fire
local MASK = 255 - 32 - 64  -- layers 32 (villagers' client models) and 64 (their hitboxes)
local W_DEFAULT = 1.5       -- A* heuristic weight (the comparison in nav_report.md)
local MAXEXP = 12000        -- expansions per search before it gives up (partial path)
local LINE_MAX = 80         -- m: longer straight lines are not tried
local NARROW_PEN = 0.35     -- extra cost of entering a narrow node (paths keep off walls)
local TURN = 4.0            -- rad/s
local ACCEL, DECEL = 2.5, 5.0
local LOD_STEP = 0.25       -- s between coarse moves
local ENGINE_SECS = 3.0     -- s before an engine query is abandoned
local ENGINE_POOL = 4
local PLAN_FRAMES = 600     -- a plan still unfinished after this many frames of its own work fails ("timeout")
local QCAP = 40000          -- queries one grid search may spend before it gives up (then the engine's planner)

-- per-frame budget: estimated us (PUC Lua 5.1 + engine), calibrated offline with tools/lua51/bin/lua51.exe
local BUDGET_US = 900
local Q_US = 10             -- one query with its Lua round it (in game on Frustrum: ~1.5x the offline estimate)
local EXP_US = 5            -- one A* expansion (heap pop, 8 neighbour reads, pushes)
local MARCH_US = 1.5        -- one march step on cached cells

-- ---------------------------------------------------------------- state
local T = 0
local CFG = {method = "grid", weight = W_DEFAULT, cache = true, line = true, budget = BUDGET_US, fallback = true}
local PRB, NODES = {}, {}
local COLS = {}             -- column key -> {probe keys..., nodes...}: what forget() clears without scanning all
local nNodes, nPrb = 0, 0
local function colIndex(ck, v)
	local l = COLS[ck]
	if not l then l = {}; COLS[ck] = l end
	l[#l + 1] = v
end
local PASS, PASS_T = {}, {}
local ROUTES, nRoutes = {}, 0
local QUEUE = {}
local WALKERS = {}
local PL = {}               -- players: {id, x, y, z, ex, ey, ez, fx, fy, fz, vx, vz}
local FIREPTS = {}          -- {x, y, z, t}: fire points seen lately
local fireCount, fireT = 0, 0
local POOL = {}             -- engine planners: {id, busy}
local AREA = nil            -- {x, z, r2}
local ST
local B = {left = 0, q = 0}
local nextId = 0
local reqSeq = 0

local function resetStats()
	ST = {plans = 0, done = 0, failed = 0, partial = 0, cacheHits = 0, lineHits = 0, astar = 0, engine = 0,
		engineOk = 0, engineBad = 0, engineFail = 0, engineRepairs = 0, queries = 0, expansions = 0, frameQ = 0, maxFrameQ = 0,
		frameUs = 0, maxFrameUs = 0, planFrames = 0, replans = 0, teleports = 0, stuck = 0, pushes = 0,
		fireReplans = 0, followQ = 0, nTested = 0, n_ok = 0, n_wall = 0, n_low = 0, n_water = 0, n_object = 0,
		n_nudgefloor = 0, p_cap = 0, p_closed = 0, v_wall = 0, v_low = 0, v_object = 0, v_water = 0, v_step = 0,
		v_ground = 0, v_edge = 0, v_jump = 0, f_start = 0, f_goal = 0, f_nopath = 0, f_cap = 0, f_timeout = 0, f_engine = 0, viaEngine = 0}
end
resetStats()

local QA, QB = {0, 0, 0}, {0, 0, 0}
local DOWN, UP = {0, -1, 0}, {0, 1, 0}

local function q()
	ST.queries = ST.queries + 1
	B.q = B.q + 1
	B.left = B.left - Q_US
end

-- ---------------------------------------------------------------- bodies: light (pushed aside) or heavy
local function passable(b)
	if b == nil or b == 0 then return false end
	local v = PASS[b]
	if v ~= nil and T - PASS_T[b] < PASS_TTL then return v end
	v = false
	if IsHandleValid(b) and IsBodyDynamic(b) then
		local m = GetBodyMass(b)
		if IsBodyJointedToStatic(b) then
			v = m < DOOR_MASS
		elseif m < LIGHT_MASS then
			local lo, hi = GetBodyBounds(b)
			v = max(hi[1] - lo[1], hi[3] - lo[3]) < LIGHT_SIZE
		end
	end
	PASS[b], PASS_T[b] = v, T
	return v
end

-- closest heavy surface within r of (x, y, z): hit, distance, px, pz, dynamic
local REJ = {}
local function clearCP(x, y, z, r)
	local nrej = 0
	for _ = 1, 4 do
		q()
		QueryRequire("physical")
		QueryCollisionMask(MASK)
		for i = 1, nrej do QueryRejectBody(REJ[i]) end
		QA[1], QA[2], QA[3] = x, y, z
		local hit, p, _, shape = QueryClosestPoint(QA, r)
		if not hit then return false end
		local b = GetShapeBody(shape)
		if not passable(b) then
			local dx, dy, dz = p[1] - x, p[2] - y, p[3] - z
			return true, sqrt(dx * dx + dy * dy + dz * dz), p[1], p[3], b ~= 0 and IsBodyDynamic(b)
		end
		nrej = nrej + 1
		REJ[nrej] = b
	end
	return false
end

-- ---------------------------------------------------------------- the grid
local function colKey(ix, iz) return (ix + 32768) * 65536 + (iz + 32768) end

-- the floor in column (ix, iz) seen from a floor at height y: its height, or false
local function probe(ix, iz, y)
	local band = ceil((y + PROBE_UP) / PROBE_Q)
	local pk = colKey(ix, iz) * 8192 + band + 4096
	local v = PRB[pk]
	if v ~= nil then return v end
	q()
	local ys = band * PROBE_Q
	QA[1], QA[2], QA[3] = (ix + 0.5) * CELL, ys, (iz + 0.5) * CELL
	QueryRequire("physical static")
	QueryCollisionMask(MASK)
	local hit, d = QueryRaycast(QA, DOWN, PROBE_LEN)
	if hit and d > 0.02 then v = ys - d else v = false end     -- (a hit at once: the probe started inside a wall)
	PRB[pk] = v
	nPrb = nPrb + 1
	colIndex(colKey(ix, iz), pk)
	return v
end

-- the cached probe only (no query): height, false, or nil when never probed
local function probeCached(ix, iz, y)
	return PRB[colKey(ix, iz) * 8192 + ceil((y + PROBE_UP) / PROBE_Q) + 4096]
end

local function nodeKey(ix, iz, gy) return colKey(ix, iz) * 32768 + floor(gy * 20 + 0.5) + 16384 end

local function verdict(n, why)
	n.why = why
	ST["n_" .. why] = (ST["n_" .. why] or 0) + 1
end

local function nodeTest(n)
	local x, y, z = (n.ix + 0.5) * CELL, n.y, (n.iz + 0.5) * CELL
	ST.nTested = ST.nTested + 1
	n.t = T
	n.ok, n.nud, n.nar, n.dyn, n.why = false, false, false, false, nil
	q()
	QA[1], QA[2], QA[3] = x, y + 0.05, z
	local wet, depth = IsPointInWater(QA)
	if wet and depth > WADE then
		-- (a level's water plane is infinite: under a roof or under ground it is no pond)
		q()
		QA[2] = y + 0.1
		QueryRequire("physical static")
		QueryCollisionMask(MASK)
		if not QueryRaycast(QA, UP, depth + 0.5) then
			verdict(n, "water")
			return
		end
	end
	local cx, cz = x, z
	local moved = false
	for t = 0, NUDGE_N do
		local hit, d, px, pz, dyn = clearCP(x, y + BODY_LO, z, NARROW)
		if not hit or d >= CLR then
			if hit and d < NARROW then
				-- a narrow spot: centre the point in the gap (doorways, alleys), when the far side is near
				local ax, az = x - px, z - pz
				local l = sqrt(ax * ax + az * az)
				if l > 1e-4 then
					ax, az = ax / l, az / l
					q()
					QA[1], QA[2], QA[3] = x, y + BODY_LO, z
					QB[1], QB[2], QB[3] = ax, 0, az
					QueryRequire("physical static")
					QueryCollisionMask(MASK)
					local hr, hd = QueryRaycast(QA, QB, 2 * NARROW)
					if hr and hd > d + 0.06 then
						local sh = (hd - d) / 2
						local nx, nz = x + ax * sh, z + az * sh
						if abs(nx - cx) <= 0.3 and abs(nz - cz) <= 0.3 then
							local h2, d2 = clearCP(nx, y + BODY_LO, nz, NARROW)
							if not h2 or d2 >= d then x, z, moved = nx, nz, true end
						end
					end
				end
			end
			q()
			QA[1], QA[2], QA[3] = x, y + BODY_LO, z
			QueryRequire("physical static")
			QueryCollisionMask(MASK)
			if QueryRaycast(QA, UP, BODY_TOP - BODY_LO, CLR - 0.04) then verdict(n, "low"); return end
			if moved then
				-- the floor under a nudged point must be the same floor
				q()
				QA[2] = y + 0.5
				QueryRequire("physical static")
				QueryCollisionMask(MASK)
				local h2, d2 = QueryRaycast(QA, DOWN, 1.0)
				if not h2 or abs(y + 0.5 - d2 - y) > 0.12 then verdict(n, "nudgefloor"); return end
			end
			n.x, n.z = x, z
			n.ok, n.nud, n.nar = true, moved, hit and true or false
			ST.n_ok = ST.n_ok + 1
			return
		end
		if dyn then n.dyn = true end
		if t == NUDGE_N then break end
		local ax, az = x - px, z - pz
		local l = sqrt(ax * ax + az * az)
		if l < 1e-4 then break end
		local push = CLR + 0.03 - d
		x, z = x + ax / l * push, z + az / l * push
		if abs(x - cx) > 0.3 or abs(z - cz) > 0.3 then break end
		moved = true
	end
	verdict(n, n.dyn and "object" or "wall")
end

local function nodeAt(ix, iz, gy)
	local k = nodeKey(ix, iz, gy)
	local n = NODES[k]
	if n then return n end
	n = {ix = ix, iz = iz, x = (ix + 0.5) * CELL, y = gy, z = (iz + 0.5) * CELL, k = k}
	NODES[k] = n
	nNodes = nNodes + 1
	colIndex(colKey(ix, iz), n)
	nodeTest(n)
	return n
end

-- fire: only checked while the level has fires, only near fire points seen lately
local function fireNear(x, z)
	for i = 1, #FIREPTS do
		local f = FIREPTS[i]
		local dx, dz = f[1] - x, f[3] - z
		if dx * dx + dz * dz < FIRE_REGION * FIRE_REGION then return true end
	end
	return false
end

local FIRE_FREE = nil       -- (a search may leave a start that fire has reached)
local function fireBlocked(n)
	if fireCount == 0 or #FIREPTS == 0 then return false end
	if n.ft and T - n.ft < FIRE_TTL then return n.fire end
	n.ft = T
	n.fire = false
	if fireNear(n.x, n.z) then
		q()
		QA[1], QA[2], QA[3] = n.x, n.y + 0.5, n.z
		n.fire = QueryClosestFire(QA, FIRE_R) and true or false
	end
	if n.fire and FIRE_FREE then
		local dx, dz = n.x - FIRE_FREE[1], n.z - FIRE_FREE[3]
		if dx * dx + dz * dz < 4 then return false end
	end
	return n.fire
end

-- sphere cast at hip height between two node points
local function hipClear(ax, ay, az, bx, by, bz, r)
	local dx, dy, dz = bx - ax, by - ay, bz - az
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1e-3 then return true end
	q()
	QA[1], QA[2], QA[3] = ax, ay + HIP, az
	QB[1], QB[2], QB[3] = dx / l, dy / l, dz / l
	QueryRequire("physical static")
	QueryCollisionMask(MASK)
	return not QueryRaycast(QA, QB, l, r or HIP_R)
end

-- a rise (or fall) above STEP_UP between two cells is a stair or a slope when the floor half-way lies in between,
-- each half no more than STEP_UP (a 45 degree stair rises 0.5 m over a cell); a ledge has no such middle
local function stairEdge(n, ix, iz, gy)
	local mx, mz = (n.x + (ix + 0.5) * CELL) / 2, (n.z + (iz + 0.5) * CELL) / 2
	local top = max(n.y, gy)
	q()
	QA[1], QA[2], QA[3] = mx, top + 0.3, mz
	QueryRequire("physical static")
	QueryCollisionMask(MASK)
	local hit, d = QueryRaycast(QA, DOWN, abs(gy - n.y) + 0.6)
	if not hit or d < 0.02 then return false end
	local my = top + 0.3 - d
	return abs(my - n.y) <= STEP_UP and abs(gy - my) <= STEP_UP
end

local DIRX = {1, -1, 0, 0, 1, 1, -1, -1}
local DIRZ = {0, 0, 1, -1, 1, -1, 1, -1}
local DIRC = {1, 1, 1, 1, 1.41421356, 1.41421356, 1.41421356, 1.41421356}
local ORTH = {nil, nil, nil, nil, {1, 3}, {1, 4}, {2, 3}, {2, 4}}
local DIROF = {[-1] = {[-1] = 8, [0] = 2, [1] = 7}, [0] = {[-1] = 4, [1] = 3}, [1] = {[-1] = 6, [0] = 1, [1] = 5}}

local function inArea(ix, iz)
	if not AREA then return true end
	local dx, dz = (ix + 0.5) * CELL - AREA.x, (iz + 0.5) * CELL - AREA.z
	return dx * dx + dz * dz <= AREA.r2
end

-- the node reached from n in direction dir, or false. cachedOnly: no queries (nil = not known yet)
local neighbour
neighbour = function(n, dir, cachedOnly)
	local e = n.e
	if e then
		local v = e[dir]
		if v ~= nil then
			if v == false then return false end
			if v.dead then
				e[dir] = nil
			else
				if v.dyn and T - v.t > DYN_TTL then
					if cachedOnly then return nil end
					nodeTest(v)
				end
				if not v.ok then return false end
				if fireCount > 0 and fireBlocked(v) then return false end
				return v
			end
		end
	end
	if cachedOnly then return nil end
	if not e then e = {}; n.e = e end
	if dir > 4 then
		local o = ORTH[dir]
		if not neighbour(n, o[1]) or not neighbour(n, o[2]) then e[dir] = false; return false end
	end
	local ix, iz = n.ix + DIRX[dir], n.iz + DIRZ[dir]
	if not inArea(ix, iz) then e[dir] = false; return false end
	local gy = probe(ix, iz, n.y)
	-- (n.edge: beside a drop or a ledge, e.g. a stair's open side: lines are not smoothed through it)
	if not gy or gy - n.y > STAIR_MAX or n.y - gy > STAIR_MAX then
		if dir <= 4 then n.edge = true end
		e[dir] = false
		return false
	end
	if (gy - n.y > STEP_UP or n.y - gy > STEP_DOWN) and not stairEdge(n, ix, iz, gy) then
		if dir <= 4 then n.edge = true end
		e[dir] = false
		return false
	end
	local m = nodeAt(ix, iz, gy)
	if m.ok and (n.nud or m.nud or n.nar or m.nar) and not hipClear(n.x, n.y, n.z, m.x, m.y, m.z) then
		e[dir] = false
		return false
	end
	e[dir] = m                                  -- (kept even when blocked: a blocked node may be tested again)
	if not m.ok then return false end
	if fireCount > 0 and fireBlocked(m) then return false end
	return m
end

-- the node under a point (from the point's height), with queries
local function nodeUnder(x, y, z)
	local ix, iz = floor(x / CELL), floor(z / CELL)
	local gy = probe(ix, iz, y - 0.05)
	if not gy or abs(gy - y) > 1.2 then
		gy = probe(ix, iz, y - 1.0)             -- (the point may sit on a bed or a step: look a little lower too)
		if not gy then return nil end
	end
	return nodeAt(ix, iz, gy)
end

-- the node under a point from the caches only
local function nodeCached(x, y, z)
	local ix, iz = floor(x / CELL), floor(z / CELL)
	local gy = probeCached(ix, iz, y - 0.05)
	if not gy then return nil end
	return NODES[nodeKey(ix, iz, gy)]
end

-- a free node at or near a point (rings of cells round it), or nil
local function snap(x, y, z, rings)
	local n = nodeUnder(x, y, z)
	if n and n.ok and not fireBlocked(n) then return n end
	local ix0, iz0 = floor(x / CELL), floor(z / CELL)
	local best, bd = nil, 1e9
	for r = 1, rings or 2 do
		for dx = -r, r do
			for dz = -r, r do
				if abs(dx) == r or abs(dz) == r then
					local ix, iz = ix0 + dx, iz0 + dz
					local gy = probe(ix, iz, y - 0.05)
					if gy and abs(gy - y) < 1.0 then
						local m = nodeAt(ix, iz, gy)
						if m.ok and not fireBlocked(m) then
							local ex, ez = m.x - x, m.z - z
							local d = ex * ex + ez * ez + (m.y - y) * (m.y - y)
							if d < bd then best, bd = m, d end
						end
					end
				end
			end
		end
		if best then return best end
	end
	return nil
end

-- ---------------------------------------------------------------- marching a straight line over the grid
-- From node a toward point (bx, bz): the cells under the line, each a neighbour of the last (no corner cutting, the
-- step limits); nudged cells only as the last one. Resumable: M = {a, cur, dx, dz, steps, s, rec, rect}.
local function marchNew(a, bx, bz, rec)
	local dx, dz = bx - a.x, bz - a.z
	local L = sqrt(dx * dx + dz * dz)
	return {a = a, cur = a, dx = dx, dz = dz, steps = max(1, ceil(L / 0.3)), s = 0, rec = rec and {} or nil,
		rect = rec and {} or nil, L = L}
end

-- runs until the line ends (true, last node), fails (false) or the budget is out (nil); goal: node or region test
local function marchRun(M, cachedOnly, goalNode, region)
	local a, steps = M.a, M.steps
	while M.s < steps do
		if not cachedOnly and B.left <= 0 then return nil end
		M.s = M.s + 1
		B.left = B.left - MARCH_US
		local t = M.s / steps
		local ix, iz = floor((a.x + M.dx * t) / CELL), floor((a.z + M.dz * t) / CELL)
		local cur = M.cur
		local ddx, ddz = ix - cur.ix, iz - cur.iz
		if ddx ~= 0 or ddz ~= 0 then
			if ddx > 1 or ddx < -1 or ddz > 1 or ddz < -1 then return false end
			local m = neighbour(cur, DIROF[ddx][ddz], cachedOnly)
			if not m then return false end
			if (m.nud or m.edge) and m ~= goalNode and not (region and region(m)) then return false end
			M.cur = m
			if M.rec then M.rec[#M.rec + 1] = m; M.rect[#M.rect + 1] = t end
			if region and region(m) then return true, m end
		end
	end
	local c = M.cur
	if goalNode then
		return c == goalNode or (c.ix == goalNode.ix and c.iz == goalNode.iz and abs(c.y - goalNode.y) < 0.3), c
	end
	if region then return region(c) and true or false, c end
	return true, c
end

-- ---------------------------------------------------------------- the binary heap (A* open list)
local function hpush(H, n, f)
	local i = H.n + 1
	H.n = i
	local hn, hf = H.nd, H.f
	while i > 1 do
		local p = floor(i / 2)
		local pf = hf[p]
		if pf <= f then break end
		hn[i], hf[i] = hn[p], pf
		i = p
	end
	hn[i], hf[i] = n, f
end

local function hpop(H)
	local hn, hf = H.nd, H.f
	local top = hn[1]
	local cnt = H.n
	local ln, lf = hn[cnt], hf[cnt]
	hn[cnt], hf[cnt] = nil, nil
	cnt = cnt - 1
	H.n = cnt
	if cnt == 0 then return top end
	local i = 1
	while true do
		local c = i * 2
		if c > cnt then break end
		if c < cnt and hf[c + 1] < hf[c] then c = c + 1 end
		if hf[c] >= lf then break end
		hn[i], hf[i] = hn[c], hf[c]
		i = c
	end
	hn[i], hf[i] = ln, lf
	return top
end

-- ---------------------------------------------------------------- the route cache
local function rkey(x, z) return (floor(x / 2) + 32768) * 65536 + floor(z / 2) + 32768 end

local function routeOneWay(pts)
	for i = 2, #pts do
		local d = pts[i][2] - pts[i - 1][2]
		if d < -STEP_UP - 0.02 then return true end      -- (a step down the walker could not climb back)
	end
	return false
end

local function routeAdd(sx, sy, sz, gx, gy, gz, pts, reg)
	reg = reg or 0
	local function add(ax, ay, az, bx, by, bz, p)
		local k = rkey(bx, bz)
		local l = ROUTES[k]
		if not l then l = {}; ROUTES[k] = l end
		for i = #l, 1, -1 do                                   -- (a newer route between the same places replaces)
			local r = l[i]
			local d1 = (r.s[1] - ax) ^ 2 + (r.s[3] - az) ^ 2
			local d2 = (r.g[1] - bx) ^ 2 + (r.g[3] - bz) ^ 2
			if d1 < 0.25 and d2 < 0.25 and r.reg == reg then table.remove(l, i); nRoutes = nRoutes - 1 end
		end
		l[#l + 1] = {s = {ax, ay, az}, g = {bx, by, bz}, pts = p, t = T, reg = reg}
		nRoutes = nRoutes + 1
	end
	add(sx, sy, sz, gx, gy, gz, pts)
	if reg == 0 and not routeOneWay(pts) then
		local r = {}
		for i = #pts, 1, -1 do r[#r + 1] = pts[i] end
		add(gx, gy, gz, sx, sy, sz, r)
	end
end

local function routeFind(sx, sy, sz, gx, gy, gz, reg)
	local k0x, k0z = floor(gx / 2), floor(gz / 2)
	for ddx = -1, 1 do
		for ddz = -1, 1 do
			local l = ROUTES[(k0x + ddx + 32768) * 65536 + k0z + ddz + 32768]
			if l then
				for i = 1, #l do
					local r = l[i]
					if abs(r.reg - reg) < 0.05 and abs(r.g[2] - gy) < 0.6 and abs(r.s[2] - sy) < 0.6
						and (r.g[1] - gx) ^ 2 + (r.g[3] - gz) ^ 2 < 0.36
						and (r.s[1] - sx) ^ 2 + (r.s[3] - sz) ^ 2 < 0.64 then
						return r
					end
				end
			end
		end
	end
	return nil
end

local function routesForget(x, z, r)
	local r2 = r * r
	for k, l in pairs(ROUTES) do
		for i = #l, 1, -1 do
			local pts = l[i].pts
			for j = 1, #pts do
				local p = pts[j]
				if (p[1] - x) ^ 2 + (p[3] - z) ^ 2 < r2 then table.remove(l, i); nRoutes = nRoutes - 1; break end
			end
		end
		if #l == 0 then ROUTES[k] = nil end
	end
end

-- ---------------------------------------------------------------- planning requests
-- R = {x, y, z (start), gx, gy, gz, arrive, keep, method, state = "planning" | "done" | "failed", path, why,
--      frames, queries, w (walker or nil)}
local function goalIn(R, n)
	local dx, dz = n.x - R.gx, n.z - R.gz
	local d2 = dx * dx + dz * dz
	if abs(n.y - R.gy) > 1.0 then return false end
	if R.keep and d2 < (R.keep + 0.1) ^ 2 then return false end
	return d2 <= (R.reg - 0.2) ^ 2
end

local function hdist(n, R)
	local dx, dz = abs(n.x - R.gx), abs(n.z - R.gz)
	local h
	if dx > dz then h = dx + 0.41421356 * dz else h = dz + 0.41421356 * dx end
	h = h - R.reg
	if h < 0 then return 0 end
	return h
end

local function finish(R, pts, why)
	R.frames = R.frames or 0
	if pts then
		R.state, R.path = "done", pts
		ST.done = ST.done + 1
	else
		R.state, R.why = "failed", why or "no path"
		ST.failed = ST.failed + 1
	end
	ST.planFrames = ST.planFrames + R.frames
	if R.pl then POOL[R.pl].busy = false; R.pl = nil end
	if R.onDone then R.onDone(R) end
end

-- the final points: the start, the smoothed corners, points every <= 4 m between them (heights from the grid),
-- the exact goal when it is right by the last node
local function emit(R, nodes)
	local pts = {}
	local function add(x, y, z) pts[#pts + 1] = {x, y, z} end
	add(R.x, nodes[1].y, R.z)
	local n1 = nodes[1]
	if #nodes >= 2 and (n1.x - R.x) ^ 2 + (n1.z - R.z) ^ 2 > 0.01 then
		-- (the walker's own spot is not the start node's: is the first leg clear from there?)
		local n2 = nodes[2]
		if not hipClear(R.x, n1.y, R.z, n2.x, n2.y, n2.z) then add(n1.x, n1.y, n1.z) end
	end
	for i = 2, #nodes do
		local a, b = nodes[i - 1], nodes[i]
		local seg = R.segs and R.segs[i]
		if seg then
			local last = 0
			for j = 1, #seg.rec do
				local t = seg.rect[j]
				if (t - last) * seg.L >= 3.5 and t < 0.95 then
					add(a.x + (b.x - a.x) * t, seg.rec[j].y, a.z + (b.z - a.z) * t)
					last = t
				end
			end
		end
		add(b.x, b.y, b.z)
		if b.nar or b.nud or b.edge then pts[#pts].tight = true end      -- (doorways: no corner rounding there)
	end
	local e = pts[#pts]
	local dx, dz = R.gx - e[1], R.gz - e[3]
	local d2 = dx * dx + dz * dz
	if not R.region and d2 > 0.0025 and d2 < 0.6 * 0.6 and abs(R.gy - e[2]) < 0.4 then
		-- the exact goal: a short last leg from the goal's node (its cell or the next)
		pts[#pts + 1] = {R.gx, e[2], R.gz}
	end
	return pts
end

local function stage(R, s)
	R.stage = s
end

local function storeRoute(R, pts)
	if CFG.cache and not R.nocache and not R.keep and not R.partial then
		routeAdd(R.x, R.y, R.z, R.gx, R.gy, R.gz, pts, R.reg)
	end
end

local engineInit
-- the grid found no way (or no free start / goal, or ran out of effort): method "grid" asks the engine's planner next
-- and trusts its path (the walker still snaps to the ground every step); other methods fail
local function gridFailed(R, why)
	ST["f_" .. why] = (ST["f_" .. why] or 0) + 1
	if R.method == "grid" and CFG.fallback and not R.triedEngine then
		R.triedEngine, R.trust = true, true
		engineInit(R)
		return
	end
	finish(R, nil, why)
end

-- smoothing: from each anchor the farthest later node whose straight line marches on cached cells and whose
-- hip-height casts (every ~3 m) are clear; candidates are the turning points of the node path
local function smoothInit(R, nodes)
	-- turning points only (plus the ends)
	local tp = {nodes[1]}
	for i = 2, #nodes - 1 do
		local a, b, c = nodes[i - 1], nodes[i], nodes[i + 1]
		if b.ix - a.ix ~= c.ix - b.ix or b.iz - a.iz ~= c.iz - b.iz or b.nud or abs(b.y - a.y) > 0.05 then
			tp[#tp + 1] = b
		end
	end
	if #nodes > 1 then tp[#tp + 1] = nodes[#nodes] end
	R.raw, R.tp, R.out, R.segs, R.si = nodes, tp, {tp[1]}, {}, 1
	stage(R, "smooth")
end

-- the ground along a marched line every 0.5 m lies at the height of the cell it crosses (no drop at a cell's edge:
-- a stairwell beside the upper floor, a quay)
local function footOK(a, M)
	local L = M.L
	local ns = floor(L / 0.3)
	local rec, rect = M.rec, M.rect
	local j = 0
	for s = 1, ns do
		local t = s * 0.3 / L
		while j < #rec and rect[j + 1] <= t do j = j + 1 end
		local ny = j > 0 and rec[j].y or a.y
		if j < #rec and j > 0 then                         -- (between two cell heights: stairs)
			local n2 = rec[j + 1]
			local t0, t1 = rect[j], rect[j + 1]
			if t1 > t0 then ny = ny + (n2.y - ny) * (t - t0) / (t1 - t0) * 0.5 end
		end
		q()
		QA[1], QA[2], QA[3] = a.x + M.dx * t, ny + 0.5, a.z + M.dz * t
		QueryRequire("physical static")
		QueryCollisionMask(MASK)
		local hit, d = QueryRaycast(QA, DOWN, 1.0)
		if not hit or abs(ny + 0.5 - d - ny) > 0.3 then return false end
	end
	return true
end

local function segOK(a, b, goalNode)
	local M = marchNew(a, b.x, b.z, true)
	local ok, last = marchRun(M, true, b)
	if not ok then return nil end
	-- hip casts between kept points about 3 m apart along the line
	local px, py, pz = a.x, a.y, a.z
	local acc = 0
	for j = 1, #M.rec do
		local n = M.rec[j]
		acc = acc + 1
		if acc >= 6 or j == #M.rec then
			local t = M.rect[j]
			local qx, qz = a.x + M.dx * t, a.z + M.dz * t
			if j == #M.rec then qx, qz = b.x, b.z end
			if not hipClear(px, py, pz, qx, n.y, qz) then return nil end
			px, py, pz = qx, n.y, qz
			acc = 0
		end
	end
	if not footOK(a, M) then return nil end
	return M
end

local SMOOTH_TRIES = 10      -- candidate lines per anchor (farthest first)

local function smoothRun(R)
	local tp = R.tp
	while R.si < #tp do
		local i = R.si
		local a = tp[i]
		if not R.sj then R.sj, R.tries = #tp, 0 end
		local chosen, seg = nil, nil
		-- farthest first: a blocked line usually fails early and cheaply; resumable between candidates
		while R.sj >= i + 2 and R.tries < SMOOTH_TRIES do
			if B.left <= 0 then return end
			local j = R.sj
			R.sj = j - 1
			local b = tp[j]
			if (b.x - a.x) ^ 2 + (b.z - a.z) ^ 2 < 900 then        -- (lines up to 30 m)
				R.tries = R.tries + 1
				local M = segOK(a, b)
				if M then chosen, seg = j, M; break end
			end
		end
		R.sj = nil
		if not seg then
			-- the plain node path to the next turning point
			chosen = i + 1
			local b = tp[chosen]
			local M = marchNew(a, b.x, b.z, true)
			if marchRun(M, true, b) then seg = M end
		end
		R.out[#R.out + 1] = tp[chosen]
		R.segs[#R.out] = seg
		if not seg then
			-- (an unsmoothable piece goes through the raw nodes in between)
			local out = R.out
			out[#out] = nil
			local from, to
			for k = 1, #R.raw do
				if R.raw[k] == a then from = k end
				if R.raw[k] == tp[chosen] then to = k end
			end
			for k = (from or 1) + 1, to or #R.raw do out[#out + 1] = R.raw[k] end
		end
		R.si = chosen
	end
	local pts = emit(R, R.out)
	storeRoute(R, pts)
	finish(R, pts)
end

local function astarInit(R)
	local H = {n = 0, nd = {}, f = {}}
	R.H, R.g, R.par, R.closed, R.exp = H, {[R.sn] = 0}, {}, {}, 0
	R.best, R.bestH = R.sn, hdist(R.sn, R)
	hpush(H, R.sn, R.bestH * CFG.weight)
	ST.astar = ST.astar + 1
	stage(R, "astar")
end

local function astarPath(R, n)
	local l = {}
	while n do l[#l + 1] = n; n = R.par[n] end
	local r = {}
	for i = #l, 1, -1 do r[#r + 1] = l[i] end
	return r
end

local function astarRun(R)
	local H, g, par, closed = R.H, R.g, R.par, R.closed
	local W = CFG.weight
	local gn, region = R.gn, R.region
	while true do
		if B.left <= 0 then return end
		if H.n == 0 then break end
		local n = hpop(H)
		if not closed[n] then
			closed[n] = true
			R.exp = R.exp + 1
			ST.expansions = ST.expansions + 1
			B.left = B.left - EXP_US
			if n == gn or (gn and n.ix == gn.ix and n.iz == gn.iz and abs(n.y - gn.y) < 0.3) or (region and goalIn(R, n)) then
				smoothInit(R, astarPath(R, n))
				return
			end
			local h = hdist(n, R)
			if h < R.bestH then R.best, R.bestH = n, h end
			if R.exp >= MAXEXP or ST.queries - R.q0 > QCAP then R.capped = true; break end
			local gN = g[n]
			for dir = 1, 8 do
				local m = neighbour(n, dir)
				if m and not closed[m] then
					local c = gN + DIRC[dir] * CELL + abs(m.y - n.y)
					if m.nar then c = c + NARROW_PEN end
					local old = g[m]
					if old == nil or c < old then
						g[m] = c
						par[m] = n
						hpush(H, m, c + W * hdist(m, R))
					end
				end
			end
		end
	end
	-- no way to the goal: the reachable node nearest to it, if that gets the walker a good part of the way
	local d0 = hdist(R.sn, R)
	if R.capped then ST.p_cap = ST.p_cap + 1 else ST.p_closed = ST.p_closed + 1 end
	if R.best ~= R.sn and R.bestH < d0 * 0.7 then
		ST.partial = ST.partial + 1
		R.partial = true
		R.nocache = true
		smoothInit(R, astarPath(R, R.best))
		return
	end
	gridFailed(R, R.capped and "cap" or "nopath")
end

-- the engine's planner: async in the engine; its path is accepted only when every 0.25 m sample lies on a free
-- node and the steps between them are walkable
engineInit = function(R)
	ST.engine = ST.engine + 1
	stage(R, "engine")
end

local function engineRun(R)
	if not R.pl then
		local slot = nil
		for i = 1, ENGINE_POOL do
			local p = POOL[i]
			if not p then
				local ok, id = pcall(CreatePathPlanner)
				if not ok then break end
				p = {id = id, busy = false}
				POOL[i] = p
			end
			if not p.busy then slot = i; break end
		end
		if not slot then return "wait" end
		POOL[slot].busy = true
		R.pl, R.et, R.et0 = slot, 0, T
		local dx, dz = R.gx - R.x, R.gz - R.z
		QueryRequire("physical static")
		QueryCollisionMask(MASK)
		QA[1], QA[2], QA[3] = R.x, R.y + 0.1, R.z
		QB[1], QB[2], QB[3] = R.gx, R.gy + 0.1, R.gz
		q()
		local ok = pcall(PathPlannerQuery, POOL[slot].id, QA, QB, 2 * sqrt(dx * dx + dz * dz) + 30, max(1.0, R.reg),
			R.etype or "standard")
		if not ok then
			POOL[slot].busy = false
			R.pl, R.efail = nil, true
			ST.engineFail = ST.engineFail + 1
			if R.trust then finish(R, nil, "no path (grid; engine refused)")
			elseif R.method == "engine" then finish(R, nil, "engine query refused") else astarInit(R) end
		end
		return "wait"
	end
	local id = POOL[R.pl].id
	local st = GetPathState(id)
	if st == "busy" or st == "idle" then
		R.et = R.et + 1
		if T - R.et0 > ENGINE_SECS then
			AbortPath(id)
			ST.engineFail = ST.engineFail + 1
			POOL[R.pl].busy = false; R.pl = nil
			R.efail, R.etimeout = true, true
			if R.trust then finish(R, nil, "no path (grid, engine timeout)")
			elseif R.method == "engine" then finish(R, nil, "engine timeout") else astarInit(R) end
		end
		return "wait"
	end
	local len = GetPathLength(id)
	local pts = {}
	if st == "done" and len > 0 then
		local s = 0
		while s < len do pts[#pts + 1] = GetPathPoint(s, id); s = s + 0.25 end
		pts[#pts + 1] = GetPathPoint(len, id)
	end
	POOL[R.pl].busy = false
	R.pl = nil
	R.elen = len
	local e = pts[#pts]
	if st ~= "done" or not e or (e[1] - R.gx) ^ 2 + (e[3] - R.gz) ^ 2 > (R.reg + 1.5) ^ 2 then
		ST.engineFail = ST.engineFail + 1
		R.efail = true
		if R.trust then finish(R, nil, "no path (grid and engine)")
		elseif R.method == "engine" then finish(R, nil, "engine failed") else astarInit(R) end
		return
	end
	if R.trust then
		-- the grid's fallback: the engine's path as it is, a point about every metre
		local out = {{R.x, R.y, R.z}}
		local acc = 0
		for i = 2, #pts do
			acc = acc + 0.25
			if acc >= 1.0 or i == #pts then
				local p = pts[i]
				q()
				QA[1], QA[2], QA[3] = p[1], p[2] + 0.05, p[3]
				local wet, depth = IsPointInWater(QA)
				if wet and depth > WADE then finish(R, nil, "no path (engine path through water)"); return end
				out[#out + 1] = {p[1], p[2], p[3]}
				acc = 0
			end
		end
		ST.viaEngine = ST.viaEngine + 1
		R.viaEngine = true
		R.nocache = true
		finish(R, out)
		return
	end
	R.ept, R.ei, R.enodes = pts, 1, {R.sn}
	stage(R, "validate")
end

local function validateRun(R)
	local pts, nodes = R.ept, R.enodes
	R.eseen = R.eseen or {}
	while R.ei <= #pts do
		if B.left <= 0 then return end
		local p = pts[R.ei]
		R.ei = R.ei + 1
		B.left = B.left - MARCH_US
		local ix, iz = floor(p[1] / CELL), floor(p[3] / CELL)
		local guard = 0
		local prev = nodes[#nodes]
		while (ix ~= prev.ix or iz ~= prev.iz) and guard < 4 do
			guard = guard + 1
			local ddx, ddz = ix - prev.ix, iz - prev.iz
			local m = false
			local direct = ddx >= -1 and ddx <= 1 and ddz >= -1 and ddz <= 1
			if direct then m = neighbour(prev, DIROF[ddx][ddz]) end
			local repaired = false
			if not m then
				-- the engine's paths hug walls: a free neighbour of the last node that gets nearer the sample
				local bd = (prev.x - p[1]) ^ 2 + (prev.z - p[3]) ^ 2 - 0.01
				for dir = 1, 8 do
					local c = neighbour(prev, dir)
					if c and not R.eseen[c] then
						local d = (c.x - p[1]) ^ 2 + (c.z - p[3]) ^ 2
						if d < bd then m, bd = c, d end
					end
				end
				repaired = m and true or false
			end
			if not m then
				-- (why: for the benchmark's board)
				local why = "jump"
				if direct then
					local gy = probe(ix, iz, prev.y)
					if not gy then why = "ground"
					elseif abs(gy - prev.y) > STEP_UP then why = "step"
					else
						local c = nodeAt(ix, iz, gy)
						if not c.ok then why = c.why or "wall" else why = "edge" end
					end
				end
				ST["v_" .. why] = (ST["v_" .. why] or 0) + 1
				ST.engineBad = ST.engineBad + 1
				R.ebad = true
				if R.method == "engine" then finish(R, nil, "engine path not walkable") else astarInit(R) end
				return
			end
			if repaired then ST.engineRepairs = ST.engineRepairs + 1 end
			R.eseen[m] = true
			nodes[#nodes + 1] = m
			prev = m
			if repaired and abs(m.ix - ix) <= 1 and abs(m.iz - iz) <= 1 then break end
		end
	end
	-- the chain must end by the goal (the engine stops within 1 m of it): the last metre or two over the grid
	local last = nodes[#nodes]
	if R.gn and last ~= R.gn then
		local M = marchNew(last, R.gn.x, R.gn.z, true)
		if M.L < 2.5 and marchRun(M, false, R.gn) then
			for i = 1, #M.rec do nodes[#nodes + 1] = M.rec[i] end
			last = nodes[#nodes]
		end
	end
	local dx, dz = last.x - R.gx, last.z - R.gz
	if dx * dx + dz * dz > (R.reg + 1.0) ^ 2 or (R.region and not goalIn(R, last) and dx * dx + dz * dz > R.reg ^ 2) then
		ST.v_jump = ST.v_jump + 1
		ST.engineBad = ST.engineBad + 1
		R.ebad = true
		if R.method == "engine" then finish(R, nil, "engine path not walkable") else astarInit(R) end
		return
	end
	ST.engineOk = ST.engineOk + 1
	smoothInit(R, nodes)
end

local function snapRun(R)
	R.sn = snap(R.x, R.y, R.z, 3)
	if not R.sn then gridFailed(R, "start"); return end
	if R.region then
		R.gn = nil
		if goalIn(R, R.sn) then R.segs = {}; R.out = {R.sn}; finish(R, emit(R, {R.sn})); return end
	else
		R.gn = snap(R.gx, R.gy, R.gz, 2)
		if not R.gn then gridFailed(R, "goal"); return end
		if R.gn == R.sn then finish(R, emit(R, {R.sn})); return end
	end
	local dx, dz = R.gx - R.x, R.gz - R.z
	if CFG.line and R.method ~= "engine" and dx * dx + dz * dz < LINE_MAX * LINE_MAX then
		local tx, tz = R.gx, R.gz
		if R.gn then tx, tz = R.gn.x, R.gn.z end
		R.M = marchNew(R.sn, tx, tz, true)
		stage(R, "line")
	elseif R.method == "engine" or R.method == "hybrid" then
		engineInit(R)
	else
		astarInit(R)
	end
end

local function lineRun(R)
	local regionF = R.region and function(n) return goalIn(R, n) end or nil
	local ok, last = marchRun(R.M, false, R.gn, regionF)
	if ok == nil then return end
	if ok then
		local M = R.M
		local nodes = {R.sn}
		for i = 1, #M.rec do nodes[#nodes + 1] = M.rec[i] end
		-- hip casts along the line
		local okc = true
		local a = R.sn
		local px, py, pz = a.x, a.y, a.z
		local acc = 0
		for j = 1, #M.rec do
			acc = acc + 1
			if acc >= 6 or j == #M.rec then
				local n = M.rec[j]
				if not hipClear(px, py, pz, n.x, n.y, n.z) then okc = false; break end
				px, py, pz = n.x, n.y, n.z
				acc = 0
			end
		end
		if okc and not footOK(a, M) then okc = false end
		if okc then
			ST.lineHits = ST.lineHits + 1
			-- one straight segment with its points (heights) every few metres
			R.raw, R.out, R.segs = nodes, {R.sn, last}, {}
			local L = sqrt((last.x - a.x) ^ 2 + (last.z - a.z) ^ 2)
			R.segs[2] = {rec = M.rec, rect = M.rect, L = L}
			local pts = emit(R, R.out)
			storeRoute(R, pts)
			finish(R, pts)
			return
		end
	end
	R.M = nil
	if R.method == "hybrid" then engineInit(R) else astarInit(R) end
end

local function runRequest(R)
	local s = R.stage
	FIRE_FREE = R.ffree
	if s == "snap" then snapRun(R)
	elseif s == "line" then lineRun(R)
	elseif s == "engine" then return engineRun(R)
	elseif s == "validate" then validateRun(R)
	elseif s == "astar" then astarRun(R)
	elseif s == "smooth" then smoothRun(R) end
	FIRE_FREE = nil
end

-- a plan from -> to. opts: method ("grid": grid, then the engine's planner when the grid fails | "gridonly" |
-- "engine": the engine's planner, its path checked on the grid | "hybrid": engine first, then the grid), etype (engine: "standard" | "low"), arrive (m:
-- a goal region instead of a point when > 0.6), keep (m: not nearer than this), lod (low priority), onDone(R)
function VlNav.request(from, to, opts)
	opts = opts or {}
	ST.plans = ST.plans + 1
	reqSeq = reqSeq + 1
	local R = {seq = reqSeq, x = from[1], y = from[2], z = from[3], gx = to[1], gy = to[2], gz = to[3], state = "planning",
		frames = 0, q0 = ST.queries, method = opts.method or CFG.method, etype = opts.etype, keep = opts.keepAway or opts.keep,
		lod = opts.lod, onDone = opts.onDone, w = opts.w, stage = "snap", nocache = opts.nocache}
	local arr = opts.arrive or 0.4
	R.region = arr > 0.6 or R.keep ~= nil
	R.reg = R.region and arr or 0
	if fireCount > 0 then R.ffree = {R.x, R.y, R.z} end
	if CFG.cache and not R.keep and not opts.nocache then
		local r = routeFind(R.x, R.y, R.z, R.gx, R.gy, R.gz, R.reg)
		if r and (fireCount == 0 or not fireNear(R.x, R.z)) then
			local p0 = r.pts[1]
			local dx, dy, dz = p0[1] - R.x, 0, p0[3] - R.z
			-- (a walker a little off the route's start: one cast says no wall lies between)
			if dx * dx + dz * dz < 0.01 or hipClear(R.x, R.y, R.z, p0[1], p0[2], p0[3], 0.1) then
				ST.cacheHits = ST.cacheHits + 1
				r.t = T
				local pts = {}
				for i = 1, #r.pts do local p = r.pts[i]; pts[i] = {p[1], p[2], p[3], tight = p.tight} end
				pts[1] = {R.x, R.y, R.z}
				R.cached = true
				finish(R, pts)
				return R
			end
		end
	end
	QUEUE[#QUEUE + 1] = R
	return R
end

function VlNav.cancel(R)
	if not R then return end
	for i = #QUEUE, 1, -1 do if QUEUE[i] == R then table.remove(QUEUE, i) end end
	if R.pl then
		pcall(AbortPath, POOL[R.pl].id)
		POOL[R.pl].busy = false
		R.pl = nil
	end
	if R.state == "planning" then R.state = "cancelled" end
end

-- ---------------------------------------------------------------- players, fire, sight
local function updatePlayers(dt)
	local ids = GetAllPlayers()
	local old = PL
	PL = {}
	for i = 1, #ids do
		local p = ids[i]
		local t = GetPlayerTransform(p)
		local e = GetPlayerEyeTransform(p)
		local f = TransformToParentVec(e, Vec(0, 0, -1))
		local o = nil
		for j = 1, #old do if old[j].id == p then o = old[j] end end
		local r = {id = p, x = t.pos[1], y = t.pos[2], z = t.pos[3], ex = e.pos[1], ey = e.pos[2], ez = e.pos[3],
			fx = f[1], fy = f[2], fz = f[3], vx = 0, vz = 0}
		if o and dt > 0 then r.vx, r.vz = (r.x - o.x) / dt, (r.z - o.z) / dt end
		if GetPlayerHealth(p) > 0 then PL[#PL + 1] = r end
	end
end

local function updateFire()
	fireCount = GetFireCount and GetFireCount() or 1          -- (no count function: always look)
	if fireCount == 0 then FIREPTS = {}; return end
	local keep = {}
	for i = 1, #FIREPTS do if T - FIREPTS[i][4] < 5 then keep[#keep + 1] = FIREPTS[i] end end
	FIREPTS = keep
	local function look(x, y, z)
		ST.followQ = ST.followQ + 1
		QA[1], QA[2], QA[3] = x, y, z
		local hit, p = QueryClosestFire(QA, 40)
		if hit then
			for i = 1, #FIREPTS do
				local f = FIREPTS[i]
				if (f[1] - p[1]) ^ 2 + (f[3] - p[3]) ^ 2 < 1 then f[4] = T; return end
			end
			FIREPTS[#FIREPTS + 1] = {p[1], p[2], p[3], T}
		end
	end
	for i = 1, #WALKERS do
		local w = WALKERS[i]
		if w.state ~= "idle" and not w.lod then look(w.pos[1], w.pos[2] + 1, w.pos[3]) end
	end
	for i = 1, #QUEUE do local R = QUEUE[i]; look(R.gx, R.gy + 1, R.gz) end
end

-- does any player see this point? (near, or in view with a clear line)
local function seen(x, y, z, far)
	for i = 1, #PL do
		local p = PL[i]
		local dx, dy, dz = x - p.ex, y + 1.0 - p.ey, z - p.ez
		local d = sqrt(dx * dx + dy * dy + dz * dz)
		if d < 8 then return true end
		if d < (far or 120) and (dx * p.fx + dy * p.fy + dz * p.fz) / d > 0.5 then
			ST.followQ = ST.followQ + 1
			QA[1], QA[2], QA[3] = p.ex, p.ey, p.ez
			QB[1], QB[2], QB[3] = dx / d, dy / d, dz / d
			QueryRequire("physical")
			QueryCollisionMask(MASK)
			if not QueryRaycast(QA, QB, d - 0.3) then return true end
		end
	end
	return false
end

-- ---------------------------------------------------------------- module API
function VlNav.init(opts)
	opts = opts or {}
	if opts.center and opts.radius then
		AREA = {x = opts.center[1], z = opts.center[3], r2 = (opts.radius + 10) ^ 2}
	end
	if opts.method then CFG.method = opts.method end
	if opts.weight then CFG.weight = opts.weight end
	if opts.cache ~= nil then CFG.cache = opts.cache end
	if opts.line ~= nil then CFG.line = opts.line end
	if opts.budget then CFG.budget = opts.budget end
	if opts.fallback ~= nil then CFG.fallback = opts.fallback end
	if VL_CFG then
		CFG.budget = opts.budget or VL_CFG.navBudgetUs or CFG.budget
		CFG.method = opts.method or VL_CFG.navMethod or CFG.method
	end
end

-- set one option at run time (the benchmark): method, weight, cache, line, budget
function VlNav.config(k, v) CFG[k] = v end

function VlNav.clearCache()
	PRB, NODES, COLS, nNodes, nPrb = {}, {}, {}, 0, 0
	ROUTES, nRoutes = {}, 0
	PASS, PASS_T = {}, {}
end

-- the grid round a point is out of date (explosions, holes, a moved obstacle): tested again when next needed
function VlNav.forget(pos, r)
	if not pos then VlNav.clearCache(); return end
	local x, z = pos[1], pos[3]
	local r2, r3 = r * r, (r + 1) * (r + 1)
	local c = ceil((r + 1) / CELL)
	local ix0, iz0 = floor(x / CELL), floor(z / CELL)
	for ix = ix0 - c, ix0 + c do
		for iz = iz0 - c, iz0 + c do
			local d = ((ix + 0.5) * CELL - x) ^ 2 + ((iz + 0.5) * CELL - z) ^ 2
			local ck = colKey(ix, iz)
			local l = COLS[ck]
			if l and d < r3 then
				local keep = {}
				for i = 1, #l do
					local v = l[i]
					if type(v) == "table" then
						if d < r2 then
							if NODES[v.k] == v then NODES[v.k] = nil; nNodes = nNodes - 1 end
							v.dead = true
						else
							v.e = nil
							keep[#keep + 1] = v
						end
					else
						if PRB[v] ~= nil then PRB[v] = nil; nPrb = nPrb - 1 end
					end
				end
				COLS[ck] = #keep > 0 and keep or nil
			end
		end
	end
	routesForget(x, z, r)
end

function VlNav.tick(dt)
	T = T + (dt or 0)
	ST.frameQ = B.q
	if B.q > ST.maxFrameQ then ST.maxFrameQ = B.q end
	local used = CFG.budget - B.left
	if B.q > 0 or used > 0 then
		ST.frameUs = used
		if used > ST.maxFrameUs then ST.maxFrameUs = used end
	end
	B.left, B.q = CFG.budget, 0
	-- nothing walking and nothing to plan: no work at all
	local active = #QUEUE > 0
	if not active then
		for i = 1, #WALKERS do
			local st = WALKERS[i].state
			if st == "walking" or st == "planning" then active = true; break end
		end
	end
	if not active then return end
	updatePlayers(dt or 0)
	if T - fireT > 0.5 then fireT = T; updateFire() end
	if GetEventCount then
		local ne = GetEventCount("explosion")
		for i = 1, ne do
			local p, s = GetEvent("explosion", i)
			if p then VlNav.forget(p, 2 + 3 * (s or 1)) end
		end
	end
	if #QUEUE == 0 then return end
	-- walkers near players first, then the oldest
	table.sort(QUEUE, function(a, b)
		if (a.lod and 1 or 0) ~= (b.lod and 1 or 0) then return not a.lod end
		return a.seq < b.seq
	end)
	for i = #QUEUE, 1, -1 do
		local R = QUEUE[i]
		R.frames = R.frames + 1
		if (R.work or 0) > PLAN_FRAMES or R.frames > 6 * PLAN_FRAMES then     -- (never "planning" for ever)
			ST.f_timeout = ST.f_timeout + 1
			table.remove(QUEUE, i)
			if R.pl then pcall(AbortPath, POOL[R.pl].id) end
			R.queries = ST.queries - R.q0
			finish(R, nil, "timeout")
		end
	end
	if #QUEUE == 0 then return end
	local i = 1
	while i <= #QUEUE and B.left > 0 do
		local R = QUEUE[i]
		if R.wf ~= T then R.wf = T; R.work = (R.work or 0) + 1 end
		local r = runRequest(R)
		if R.state ~= "planning" then
			R.queries = ST.queries - R.q0
			table.remove(QUEUE, i)
		elseif r == "wait" then
			i = i + 1                                    -- (the engine works on it: next request)
		end
	end
end

-- ---------------------------------------------------------------- walkers
function VlNav.newWalker(pos, opts)
	opts = opts or {}
	nextId = nextId + 1
	local w = {id = opts.id or nextId, prio = nextId, pos = {pos[1], pos[2], pos[3]},
		fwd = opts.fwd and {opts.fwd[1], 0, opts.fwd[3]} or {0, 0, -1},
		radius = opts.radius or 0.3, baseSpeed = opts.speed or (VL_CFG and VL_CFG.walkSpeed) or 1.4,
		state = "idle", speedNow = 0, lod = false, lodT = (nextId % 10) * 0.05, lodAcc = 0}
	w.speed = w.baseSpeed
	WALKERS[#WALKERS + 1] = w
	return w
end

function VlNav.removeWalker(w)
	VlNav.cancel(w.req)
	for i = #WALKERS, 1, -1 do if WALKERS[i] == w then table.remove(WALKERS, i) end end
end

local function plan(w)
	VlNav.cancel(w.req)
	w.state = "planning"
	w.path = nil
	w.req = VlNav.request(w.pos, w.goal, {arrive = w.arrive, keep = w.keep, lod = w.lod, w = w,
		nocache = w.nocache})
	w.nocache = nil
end

function VlNav.goTo(w, pos, opts)
	opts = opts or {}
	local keep = opts.keepAway or opts.keep
	local arr = opts.arrive or 0.4
	-- the same goal again while on the way to it: keep the plan (callers may ask every frame)
	if w.goal and (w.state == "planning" or w.state == "walking") and w.arrive == arr and w.keep == keep
		and (w.goal[1] - pos[1]) ^ 2 + (w.goal[2] - pos[2]) ^ 2 + (w.goal[3] - pos[3]) ^ 2 < 0.09 then
		w.speed = opts.speed or w.baseSpeed
		w.face = opts.face and {opts.face[1], 0, opts.face[3]} or nil
		return
	end
	-- the same goal again right after it failed: no new plan for 2 s (callers that retry every frame cost nothing)
	if w.state == "failed" and w.goal and w.failT and T - w.failT < 2 and w.arrive == arr
		and (w.goal[1] - pos[1]) ^ 2 + (w.goal[2] - pos[2]) ^ 2 + (w.goal[3] - pos[3]) ^ 2 < 0.09 then
		return
	end
	w.goal = {pos[1], pos[2], pos[3]}
	w.arrive = arr
	w.keep = keep
	w.face = opts.face and {opts.face[1], 0, opts.face[3]} or nil
	w.speed = opts.speed or w.baseSpeed
	w.stuckN, w.stuckStage, w.waitT, w.ghostT, w.replans = 0, 0, 0, 0, 0
	w.why, w.blockedBy = nil, nil
	w.lastPos, w.lastT = {w.pos[1], w.pos[2], w.pos[3]}, T
	local dx, dz = pos[1] - w.pos[1], pos[3] - w.pos[3]
	local d2 = dx * dx + dz * dz
	if d2 <= w.arrive * w.arrive and abs(pos[2] - w.pos[2]) < 0.6 and (not w.keep or d2 >= w.keep * w.keep) then
		w.state = "arrived"
		return
	end
	plan(w)
end

function VlNav.stop(w)
	VlNav.cancel(w.req)
	w.req, w.path = nil, nil
	w.state = "idle"
	w.speedNow = 0
end

-- put a walker somewhere at once (off-screen simulation, spawning)
function VlNav.warp(w, pos, fwd)
	VlNav.stop(w)
	w.pos = {pos[1], pos[2], pos[3]}
	if fwd then w.fwd = {fwd[1], 0, fwd[3]} end
end

local function turnToward(w, tx, tz, dt)
	local l = sqrt(tx * tx + tz * tz)
	if l < 1e-6 then return 1 end
	tx, tz = tx / l, tz / l
	local fx, fz = w.fwd[1], w.fwd[3]
	local dot = fx * tx + fz * tz
	local crs = fx * tz - fz * tx
	local ang = math.atan2(crs, dot)
	local maxA = TURN * dt
	if ang > maxA then ang = maxA elseif ang < -maxA then ang = -maxA end
	local c, s = math.cos(ang), math.sin(ang)
	w.fwd = {fx * c - fz * s, 0, fx * s + fz * c}
	return w.fwd[1] * tx + w.fwd[3] * tz
end

local function arrive(w)
	w.state = "arrived"
	w.path = nil
	w.speedNow = 0
end

-- the point at the walker's distance along its path: interpolated height of the current segment
local function segY(w, x, z)
	local P = w.path
	local b = P[w.pi]
	local a = P[w.pi - 1] or b
	local dx, dz = b[1] - a[1], b[3] - a[3]
	local l2 = dx * dx + dz * dz
	if l2 < 1e-6 then return b[2] end
	local t = ((x - a[1]) * dx + (z - a[3]) * dz) / l2
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return a[2] + (b[2] - a[2]) * t
end

local function lodUpdate(w, dt)
	w.lodAcc = w.lodAcc + dt
	if w.lodAcc < LOD_STEP then return end
	local step = w.speed * (w.slow or 1) * w.lodAcc                -- (w.slow: webs and the like, vl_api.lua)
	w.lodAcc = 0
	local P = w.path
	while step > 0 do
		local b = P[w.pi]
		local dx, dy, dz = b[1] - w.pos[1], b[2] - w.pos[2], b[3] - w.pos[3]
		local d = sqrt(dx * dx + dz * dz)
		if d > 1e-4 then w.fwd = {dx / d, 0, dz / d} end
		if d <= step then
			w.pos = {b[1], b[2], b[3]}
			step = step - d
			if w.pi >= #P then
				arrive(w)
				if w.face then w.fwd = {w.face[1], 0, w.face[3]}; w.face = nil end
				return
			end
			w.pi = w.pi + 1
		else
			local t = step / d
			w.pos = {w.pos[1] + dx * t, w.pos[2] + dy * t, w.pos[3] + dz * t}
			step = 0
		end
	end
	w.speedNow = w.speed
end

local function updateLod(w)
	local dmin = 1e9
	for i = 1, #PL do
		local p = PL[i]
		local d = (p.x - w.pos[1]) ^ 2 + (p.z - w.pos[3]) ^ 2
		if d < dmin then dmin = d end
	end
	local L = (VL_CFG and VL_CFG.lodDist) or 70
	dmin = sqrt(dmin)
	local lod = dmin > L and (dmin > 2 * L or not seen(w.pos[1], w.pos[2], w.pos[3], 2 * L))
	if w.lod and not lod then w.lodAcc = 0 end
	w.lod = lod
end

-- other agents ahead: an avoidance push (ax, az), whether to wait, who blocks
local function avoid(w, ux, uz)
	local ax, az, wait, by = 0, 0, false, nil
	local px, py, pz = w.pos[1], w.pos[2], w.pos[3]
	local rx, rz = -uz, ux                         -- the walker's right
	local function agent(ox, oy, oz, ofx, ofz, moving, prio, nar, who)
		local dx, dz = ox - px, oz - pz
		if abs(oy - py) > 1.2 then return end
		local d2 = dx * dx + dz * dz
		if d2 > 4 or d2 < 1e-6 then return end
		local d = sqrt(d2)
		local sep = 0.75
		if d < sep then
			local s = (sep - d) / sep * 1.5
			ax, az = ax - dx / d * s, az - dz / d * s
		end
		local ahead = (dx * ux + dz * uz) / d
		if ahead > 0.6 and d < 1.5 then
			local side = (dx * rx + dz * rz) / d          -- > 0: it is on my right
			if moving and (ofx * ux + ofz * uz) < -0.3 then
				-- head on: both keep right; in a narrow spot the one with the lower priority waits outside it
				if (nar or w.nar) and prio < w.prio and not w.nar then wait, by = true, who
				else ax, az = ax + rx * 0.7, az + rz * 0.7 end
			elseif moving and (ofx * ux + ofz * uz) > 0.5 then
				-- same way, slower ahead: follow
				if d < 1.0 then wait, by = true, who end
			else
				-- standing in the way: round it on the freer side, or wait
				local s = side > 0 and -1 or 1
				ax, az = ax + rx * s * 0.9, az + rz * s * 0.9
				if d < 0.9 then
					local n = nodeCached(px + rx * s * 0.6, py, pz + rz * s * 0.6)
					if not n or not n.ok then wait, by = true, who end
				end
			end
		end
	end
	for i = 1, #WALKERS do
		local o = WALKERS[i]
		if o ~= w and not o.lod then
			agent(o.pos[1], o.pos[2], o.pos[3], o.fwd[1], o.fwd[3], o.state == "walking" and o.speedNow > 0.2,
				o.prio, o.nar, o.id)
		end
	end
	for i = 1, #PL do
		local p = PL[i]
		local sp = sqrt(p.vx * p.vx + p.vz * p.vz)
		local fx, fz = 0, 0
		if sp > 0.3 then fx, fz = p.vx / sp, p.vz / sp end
		agent(p.x, p.y, p.z, fx, fz, sp > 0.3, -1, false, "player" .. p.id)
	end
	return ax, az, wait, by
end

local function recover(w)
	ST.stuck = ST.stuck + 1
	w.stuckStage = (w.stuckStage or 0) + 1
	w.stuckN = 0
	if w.stuckStage == 1 then
		-- the grid round the block is out of date: test it again and plan from here
		ST.replans = ST.replans + 1
		local f = w.fwd
		VlNav.forget({w.pos[1] + f[1] * 0.6, w.pos[2], w.pos[3] + f[3] * 0.6}, 1.0)
		w.nocache = true
		plan(w)
	elseif w.stuckStage == 2 and w.path then
		-- teleport past the block along the path, only while nobody sees either end
		local P = w.path
		local acc, j = 0, w.pi
		local prev = w.pos
		while j <= #P and acc < 2.0 do
			acc = acc + sqrt((P[j][1] - prev[1]) ^ 2 + (P[j][3] - prev[3]) ^ 2)
			prev = P[j]
			j = j + 1
		end
		j = min(j, #P)
		local to = P[j]
		if not seen(w.pos[1], w.pos[2], w.pos[3]) and not seen(to[1], to[2], to[3]) then
			ST.teleports = ST.teleports + 1
			w.pos = {to[1], to[2], to[3]}
			w.pi = min(j + 1, #P)
		else
			w.stuckStage = 1                         -- (seen: try again later)
		end
	else
		w.state = "failed"
		w.why = "stuck"
		w.failT = T
		w.path = nil
		w.speedNow = 0
	end
end

-- the path ahead runs near a fire (checked every 0.5 s while fires burn near the walker)
local function fireAhead(w)
	if fireCount == 0 or #FIREPTS == 0 or not fireNear(w.pos[1], w.pos[3]) then return false end
	local P = w.path
	local acc = 0
	local px, py, pz = w.pos[1], w.pos[2], w.pos[3]
	for j = w.pi, #P do
		local p = P[j]
		local d = sqrt((p[1] - px) ^ 2 + (p[3] - pz) ^ 2)
		local n = max(1, ceil(d / 1.0))
		for s = 1, n do
			local t = s / n
			ST.followQ = ST.followQ + 1
			QA[1], QA[2], QA[3] = px + (p[1] - px) * t, py + (p[2] - py) * t + 0.5, pz + (p[3] - pz) * t
			if QueryClosestFire(QA, FIRE_R - 0.1) then return true end
		end
		acc = acc + d
		if acc > 12 then break end
		px, py, pz = p[1], p[2], p[3]
	end
	return false
end

-- the walker is beyond point b of segment a -> b (pushed aside, overshot)
local function passed(w, b, a)
	if not a then return false end
	local sx, sz = b[1] - a[1], b[3] - a[3]
	return (w.pos[1] - b[1]) * sx + (w.pos[3] - b[3]) * sz > 0.05 * sqrt(sx * sx + sz * sz)
end

local function follow(w, dt)
	local P = w.path
	local px, py, pz = w.pos[1], w.pos[2], w.pos[3]
	local tgt = P[w.pi]
	local dx, dz = tgt[1] - px, tgt[3] - pz
	local d = sqrt(dx * dx + dz * dz)
	while w.pi < #P and (d < (tgt.tight and 0.08 or 0.15) or passed(w, tgt, P[w.pi - 1])) do
		w.pi = w.pi + 1
		tgt = P[w.pi]
		dx, dz = tgt[1] - px, tgt[3] - pz
		d = sqrt(dx * dx + dz * dz)
	end
	local last = w.pi == #P
	if last then
		local gx, gz = w.goal[1] - px, w.goal[3] - pz
		local gd2 = gx * gx + gz * gz
		local inReg = gd2 <= w.arrive * w.arrive and (not w.keep or gd2 >= w.keep * w.keep)
		if d < 0.15 or (inReg and d < w.arrive) then
			arrive(w)
			if w.req and w.req.partial then w.state, w.why, w.failT = "failed", "no path", T end
			return
		end
	end
	if d < 1e-4 then return end
	local ux, uz = dx / d, dz / d
	-- pure pursuit: steer at a point 0.6 m ahead on the segment, so a walker pushed aside comes back onto the line
	-- the plan checked (heading straight for the next corner from aside can clip a door jamb)
	local a = P[w.pi - 1]
	if a then
		local sx, sz = tgt[1] - a[1], tgt[3] - a[3]
		local sl2 = sx * sx + sz * sz
		if sl2 > 1e-4 then
			local sl = sqrt(sl2)
			local t = ((px - a[1]) * sx + (pz - a[3]) * sz) / sl2 + 0.6 / sl
			if t < 1 then
				if t < 0 then t = 0 end
				local cx, cz = a[1] + sx * t - px, a[3] + sz * t - pz
				local cl = sqrt(cx * cx + cz * cz)
				if cl > 1e-4 then ux, uz = cx / cl, cz / cl end
			end
		end
	end
	-- the cell ahead's narrowness (yielding) from the cache, a few times a second
	w.narT = (w.narT or 0) - dt
	if w.narT <= 0 then
		w.narT = 0.25
		local n = nodeCached(px, py, pz)
		w.nar = n and n.nar or false
	end
	local ax, az, wait, by = 0, 0, false, nil
	if (w.ghostT or 0) > 0 then
		w.ghostT = w.ghostT - dt
	else
		ax, az, wait, by = avoid(w, ux, uz)
	end
	w.blockedBy = by
	if wait then
		w.waitT = (w.waitT or 0) + dt
		if w.waitT > 6 then w.ghostT, w.waitT = 2.5, 0 end            -- (deadlocks end: walk on through)
	else
		w.waitT = 0
	end
	local vmax = w.speed * (w.slow or 1)
	if last then vmax = min(vmax, 0.35 + d * 1.2) end
	if wait then vmax = 0 end
	local mx, mz = ux + ax, uz + az
	local ml = sqrt(mx * mx + mz * mz)
	if ml < 1e-4 then mx, mz = ux, uz else mx, mz = mx / ml, mz / ml end
	local align = turnToward(w, mx, mz, dt)
	local f = (align - 0.3) / 0.6
	if f < 0 then f = 0 elseif f > 1 then f = 1 end
	vmax = vmax * f
	-- door pushing / blocking: one ray ahead every 0.2 s
	w.rayT = (w.rayT or 0) - dt
	if w.rayT <= 0 and vmax > 0 then
		w.rayT = 0.2
		ST.followQ = ST.followQ + 1
		QA[1], QA[2], QA[3] = px, py + HIP, pz
		QB[1], QB[2], QB[3] = mx, 0, mz
		QueryRequire("physical")
		QueryCollisionMask(MASK)
		local hit, hd, _, shape = QueryRaycast(QA, QB, 0.7)
		w.blocked = false
		if hit then
			local b = GetShapeBody(shape)
			if passable(b) then
				ST.pushes = ST.pushes + 1
				local m = min(GetBodyMass(b), 80)
				QA[1], QA[2], QA[3] = px + mx * hd, py + HIP, pz + mz * hd
				ApplyBodyImpulse(b, QA, Vec(mx * m * 1.2, 0, mz * m * 1.2))
			elseif b ~= 0 and IsBodyDynamic(b) and hd < 0.5 then
				-- (only a heavy loose thing that moved into the way blocks: static geometry was cleared by the plan,
				-- and stopping at it gave false "stuck" events in game, 2026-11-14)
				w.blocked = true
			end
		end
	end
	if w.blocked then vmax = 0 end
	if w.speedNow < vmax then w.speedNow = min(vmax, w.speedNow + ACCEL * dt)
	else w.speedNow = max(vmax, w.speedNow - DECEL * dt) end
	local step = w.speedNow * dt
	if step > 0 then
		if step > d and last then step = d end
		local nx, nz = px + mx * step, pz + mz * step
		local pushed = ax ~= 0 or az ~= 0
		if pushed then
			-- pushed off the line: only onto open cells known to be free (not by walls, drops, steps)
			local n = nodeCached(nx, py, nz)
			if not n or not n.ok or n.nar or n.edge then nx, nz, pushed = px + ux * step, pz + uz * step, false end
		end
		-- the ground: one ray down from above the path's height; off the path's surface (a stair's side, a ledge)
		-- the walker keeps to the path
		local yi = segY(w, nx, nz)
		local ys = max(yi, py) + 0.6
		ST.followQ = ST.followQ + 1
		QA[1], QA[2], QA[3] = nx, ys, nz
		QueryRequire("physical static")
		QueryCollisionMask(MASK)
		local hit, hd = QueryRaycast(QA, DOWN, 1.4)
		local gy = yi
		if hit then
			local h = ys - hd
			if abs(h - yi) <= 0.3 or (not pushed and h - py <= STEP_UP + 0.05 and py - h <= STEP_UP + 0.05) then gy = h
			elseif pushed then nx, nz = px + ux * step, pz + uz * step end
		end
		local ny = py
		local dy = gy - py
		local rate = (dy > 0 and 2.5 or 4.0) * dt + 0.02
		if dy > rate then ny = py + rate elseif dy < -rate then ny = py - rate else ny = gy end
		w.pos = {nx, ny, nz}
	end
	-- progress, stuck
	if T - (w.lastT or T) >= 1.0 then
		local moved = sqrt((w.pos[1] - w.lastPos[1]) ^ 2 + (w.pos[3] - w.lastPos[3]) ^ 2)
		if moved < 0.1 and not wait then w.stuckN = (w.stuckN or 0) + 1 else w.stuckN = 0 end
		if moved > 1.0 and w.stuckStage == 1 then w.stuckStage = 0 end
		w.lastPos, w.lastT = {w.pos[1], w.pos[2], w.pos[3]}, T
		if w.stuckN >= 3 then recover(w); return end
	end
	w.fireT = (w.fireT or 0) - dt
	if w.fireT <= 0 then
		w.fireT = 0.5
		if fireAhead(w) then
			ST.fireReplans = ST.fireReplans + 1
			w.nocache = true
			plan(w)
		end
	end
end

function VlNav.update(w, dt)
	local st = w.state
	if st == "idle" or st == "failed" then return end
	if st == "arrived" then
		if w.face then
			if turnToward(w, w.face[1], w.face[3], dt) > 0.995 then w.face = nil end
		end
		return
	end
	w.lodT = w.lodT - dt
	if w.lodT <= 0 then w.lodT = 0.5; updateLod(w) end
	if st == "planning" then
		local R = w.req
		if not R then w.state = "idle"; return end
		R.lod = w.lod
		if R.state == "done" then
			w.path, w.pi = R.path, 2
			if #w.path < 2 then w.path[2] = w.path[1] end
			w.state = "walking"
			w.lastPos, w.lastT = {w.pos[1], w.pos[2], w.pos[3]}, T
		elseif R.state == "failed" or R.state == "cancelled" then
			w.state, w.why, w.failT = "failed", R.why or "cancelled", T
		else
			w.speedNow = max(0, w.speedNow - DECEL * dt)
			local gx, gz = w.goal[1] - w.pos[1], w.goal[3] - w.pos[3]
			turnToward(w, gx, gz, dt * 0.5)
		end
		return
	end
	-- walking
	if w.lod then lodUpdate(w, dt) else follow(w, dt) end
end

-- ---------------------------------------------------------------- queries for other modules
function VlNav.walkable(pos)
	local n = nodeUnder(pos[1], pos[2], pos[3])
	if n and n.ok then return true, Vec(n.x, n.y, n.z) end
	return false, nil
end

-- the P.grid table for VlSense: (2 * half + 1)^2 cells of `cell` m round pos, row 1 = most -z; classified from the
-- walk grid, probing at most `budget` (120) new queries per call (the rest reads "unknown")
function VlNav.grid(pos, half, cell)
	half, cell = half or 10, cell or 1.0
	local px, py, pz = pos[1], pos[2], pos[3]
	local memo = {}
	local spent = 0
	local g = {cell = cell, half = half, origin = Vec(px, py, pz)}
	function g.at(ix, iz)
		local key = ix * 4096 + iz
		local v = memo[key]
		if v then return v end
		local x, z = px + (ix - half - 1) * cell, pz + (iz - half - 1) * cell
		local cx, cz = floor(x / CELL), floor(z / CELL)
		local gy = probeCached(cx, cz, py)
		local n = nil
		if gy == nil then
			if spent >= 120 then return "unknown" end
			local q0 = ST.queries
			gy = probe(cx, cz, py)
			spent = spent + (ST.queries - q0)
		end
		if gy == false then
			-- no floor within reach: a wall top or a drop - a ray from eye height tells
			if spent >= 120 then return "unknown" end
			spent = spent + 1
			ST.queries = ST.queries + 1
			QA[1], QA[2], QA[3] = x, py + 1.7, z
			QueryRequire("physical static")
			QueryCollisionMask(MASK)
			local hit, d = QueryRaycast(QA, DOWN, 1.7 + 6)
			if hit and d < 0.3 then v = "wall" else v = "drop" end
			memo[key] = v
			return v
		end
		if abs(gy - py) > 1.5 then v = gy > py and "wall" or "drop"; memo[key] = v; return v end
		n = NODES[nodeKey(cx, cz, gy)]
		if not n then
			if spent >= 120 then return "unknown" end
			local q0 = ST.queries
			n = nodeAt(cx, cz, gy)
			spent = spent + (ST.queries - q0)
		end
		if n.ok then v = (n.nud and n.nar) and "door" or "floor"
		elseif n.why == "water" then v = "water"
		else v = "wall" end
		memo[key] = v
		return v
	end
	return g
end

function VlNav.stats()
	local s = {}
	for k, v in pairs(ST) do s[k] = v end
	s.cells = nNodes
	s.probes = nPrb
	s.routes = nRoutes
	s.pending = #QUEUE
	s.walkers = #WALKERS
	s.fires = #FIREPTS
	return s
end

function VlNav.resetStats() resetStats() end

-- (tests: the node under a point, with queries)
function VlNav.debugNode(pos) return nodeUnder(pos[1], pos[2], pos[3]) end
function VlNav.debugHip(a, b) return hipClear(a.x, a.y, a.z, b.x, b.y, b.z) end

-- (tests and the benchmark: the walkers, the queue)
function VlNav.walkers() return WALKERS end
function VlNav.pending() return #QUEUE end
