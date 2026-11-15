-- Villagers: VlSense - what a villager senses, as text for the LLM (villagers have no eyes).
-- (no #version line: included by main.lua). Pure Lua 5.1: no engine calls, so it runs offline exactly as in game.
--
--   VlSense.describe(P, format, maxChars) -> string   (format default VL_CFG.senseFormat, else "json" - the benchmark's
--   pick, export/vision_report.md; maxChars default 900)
--
-- P (the server's P builder fills it; only what the villager really senses goes in - what it can't see, hear or
-- smell is simply absent):
--   self   = {name, pos = Vec, fwd = Vec (unit, y ignored), doing = "...", place = "...",
--             level = 0 (storey: 0 ground, 1 first floor, -1 cellar; nil = unknown), where = "upstairs" | nil}
--   time   = {hour = 14.5, day = 3, night = false, weather = "rain"}
--   here   = {name = "the smithy", kind = "work", indoor = true} | nil
--   things = { {kind = "player" | "villager" | "animal" | "object" | "fire" | "sound", name = "Alex", pos = Vec,
--               sense = "seen" | "heard" | "smelled",   -- (old field seen = false still reads as "heard")
--               fwd = Vec | nil,                        -- seen people: "looking at you"
--               doing = "running" | "talking" | ...,    -- seen: shown; heard people: only as a sound (voice, steps)
--               holding = "shotgun" | nil, hurt = bool, -- seen only (never shown for heard things)
--               wearing = "a helmet, a leather jacket" | "only underwear" | nil,   -- seen within ~12 m only
--               looks = "an old white woman with white curls ..." | nil,          -- seen within ~12 m only
--               health = "a few scrapes" | "hurt" | "badly hurt and bleeding" | "barely standing ..." | nil (unharmed)
--               where = "on the roof" | "upstairs" | "on a balcony" | "in the cellar" | nil,   -- optional words
--               size = "small" | "big" | nil,           -- fire
--               loud = "loud" | "faint" | nil,          -- sound (kind "sound": name = "a gunshot", "breaking glass")
--             }, ... }
--             heard things: a rough direction and a vague distance only; smelled (smoke, cooking): direction only.
--             pos.y matters: height differences of 1.2 m or more are said ("3 m above you", "on the floor below").
--   places = { {name = "the tavern", kind = "tavern", pos = Vec, door = Vec | nil} }   -- landmarks within ~60 m
--   grid   = {cell = 1.0, half = 10, origin = Vec, at = function(ix, iz) -> "floor" | "wall" | "water" | "drop" |
--             "door" | "unknown"} | nil -- a slice at the villager's level; ix, iz = 1 .. 2*half+1, iz 1 = most -z
--             (north); origin = the centre of cell (half+1, half+1)
--
-- Directions are the villager's own: angle 0 = straight ahead (P.self.fwd), +90 = right. North is -z, east +x.
-- Formats (benchmark: tools/bench/vision, export/vision_report.md):
--   sectors     grouped by side (in front / right / behind / left, empty sides said), closest + count spelled out
--   list        one line per thing: "Alex: front-left, 3 m, talking to you"
--   clock       the same with clock bearings: "Alex: at 11 o'clock, 3 m"
--   cardinal    compass directions plus "You face north-east"
--   radar       grouped by distance rings (beside you / close / near / farther), direction words inside
--   relational  coordinate-free sentences, nearest first, distance words and "by the well"
--   json        a compact JSON object (dir words, metres, up/down metres)
--   ascii       a top-down map turned so the villager faces up, letters for people, legend
--   ascii_north the same map with north up and the villager as an arrow
--   hybrid      sectors + a small turned map (walls, doors, people)

VlSense = {}
VlSense.FORMATS = {"sectors", "list", "clock", "cardinal", "radar", "relational", "json", "ascii", "ascii_north", "hybrid"}

local floor, sqrt, abs, deg = math.floor, math.sqrt, math.abs, math.deg
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local W8 = {"in front", "front-right", "right", "behind-right", "behind", "behind-left", "left", "front-left"}
local C8 = {"north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"}
local SIDE = {"In front of you", "On your right", "Behind you", "On your left"}
local SIDE_W = {"in front", "right", "behind", "left"}
local GRIDCH = {floor = ".", wall = "#", door = "+", water = "~", drop = "!", unknown = " "}

local function vx(v) return v[1] or v.x or 0 end
local function vy(v) return v[2] or v.y or 0 end
local function vz(v) return v[3] or v.z or 0 end
local function round(x) return floor(x + 0.5) end

-- the villager's frame: forward (fx, fz), right = (-fz, fx)
local function frame(P)
	local f = P.self.fwd or {0, 0, -1}
	local fx, fz = vx(f), vz(f)
	local l = sqrt(fx * fx + fz * fz)
	if l < 1e-6 then fx, fz = 0, -1 else fx, fz = fx / l, fz / l end
	return {px = vx(P.self.pos), py = vy(P.self.pos), pz = vz(P.self.pos), fx = fx, fz = fz}
end

-- a world position -> forward metres, right metres, horizontal distance, angle (degrees, + = right), height diff
local function rel(F, pos)
	local dx, dz = vx(pos) - F.px, vz(pos) - F.pz
	local f = dx * F.fx + dz * F.fz
	local r = -dx * F.fz + dz * F.fx
	return f, r, sqrt(dx * dx + dz * dz), deg(atan2(r, f)), vy(pos) - F.py
end

local function word8(a) return W8[(floor((a + 22.5) / 45) % 8) + 1] end
local function quad(a) return (floor((a + 45) / 90) % 4) + 1 end      -- 1 front, 2 right, 3 behind, 4 left
local function clockOf(a)
	local h = round(a / 30) % 12
	if h == 0 then h = 12 end
	return h
end
local function bearing(dx, dz)                            -- 0 = north (-z), 90 = east (+x)
	local b = deg(atan2(dx, -dz))
	if b < 0 then b = b + 360 end
	return b
end
local function compass(b) return C8[(floor((b + 22.5) / 45) % 8) + 1] end
local function metres(d)
	local m = round(d)
	if m < 1 then m = 1 end
	return m .. " m"
end
local function vague(d)                                   -- heard / smelled things: no exact distance
	if d < 4 then return "close by" elseif d < 10 then return "nearby" elseif d < 20 then return "some way off" end
	return "far off"
end
local function distWords(d)                               -- relational: distance as words
	if d < 1.5 then return "right beside you" elseif d < 3.5 then return "a step or two away"
	elseif d < 7 then return "a few steps away" elseif d < 14 then return "a stone's throw away"
	elseif d < 25 then return "some way off" end
	return "far off"
end

local function isPerson(t) return t.kind == "player" or t.kind == "villager" end
local function senseOf(t)
	if t.sense then return t.sense end
	if t.seen == false then return "heard" end
	return "seen"
end

local function article(s)
	if s == nil or s == "" then return s end
	local l = string.lower(s)
	if string.find(l, "^an? ") or string.find(l, "^the ") or string.find(l, "^some ") or string.find(l, "^his ") or
		string.find(l, "^her ") then
		return s
	end
	if string.find(l, "^[aeiou]") then return "an " .. s end
	return "a " .. s
end

-- height: nil on the same level, else "on the roof, 5 m above you" / "one floor up, 3 m above you" / "2 m below you"
local function vert(e, short)
	local dy = e.dy or 0
	if abs(dy) < 1.2 then return nil end
	local m = metres(abs(dy)) .. (dy > 0 and " above you" or " below you")
	local w = e.t and e.t.where
	if not w and abs(dy) >= 2.2 and abs(dy) <= 4.5 then w = dy > 0 and "one floor up" or "one floor down" end
	if short then return dy > 0 and "above you" or "below you" end
	if w then return w .. ", " .. m end
	return m
end

-- what a seen thing is doing: "talking, holding a shotgun, hurt, looking at you"
local function activity(F, e)
	local t, out = e.t, {}
	if t.looks and t.looks ~= "" then out[#out + 1] = t.looks end                 -- (up close: what they look like)
	if t.kind == "fire" then
		out[#out + 1] = (t.size and (t.size .. " ") or "") .. "flames"
	elseif t.doing and t.doing ~= "" and t.doing ~= "standing" then
		out[#out + 1] = t.doing
	end
	if t.holding and t.holding ~= "" then out[#out + 1] = "holding " .. article(t.holding) end
	if t.wearing and t.wearing ~= "" then out[#out + 1] = "wearing " .. t.wearing end      -- (seen up close only)
	if t.feel and VlApi then                                                         -- (another mod's creature: vl_api.lua)
		local f = VlApi.feelText(t.feel)
		if f then out[#out + 1] = f end
	end
	if t.health and t.health ~= "" then out[#out + 1] = t.health                  -- (how hurt they look, seen only)
	elseif t.hurt then out[#out + 1] = "hurt" end
	if t.fwd and isPerson(t) and e.d < 12 and e.d > 0.5 then
		local ex, ez = F.px - vx(t.pos), F.pz - vz(t.pos)
		local l = sqrt(ex * ex + ez * ez)
		local tfx, tfz = vx(t.fwd), vz(t.fwd)
		local tl = sqrt(tfx * tfx + tfz * tfz)
		if l > 1e-6 and tl > 1e-6 and (ex * tfx + ez * tfz) / (l * tl) > 0.87 then out[#out + 1] = "looking at you" end
	end
	return table.concat(out, ", ")
end
local function details(F, e)                              -- activity + height, comma separated
	local a, v = activity(F, e), vert(e)
	if v then a = (a ~= "" and (a .. ", ") or "") .. v end
	return a
end

-- a heard thing as words: "Sam's voice", "footsteps (Sam)", "a gunshot (loud)"
local function heardName(t)
	if isPerson(t) then
		local d = t.doing or ""
		if string.find(d, "talk") or string.find(d, "shout") or string.find(d, "sing") or string.find(d, "pray") or
			string.find(d, "laugh") or string.find(d, "argu") then
			return t.name .. "'s voice"
		end
		return t.name .. "'s footsteps"
	end
	local s = t.name or "a noise"
	if t.loud and t.loud ~= "" then s = s .. " (" .. t.loud .. ")" end
	return s
end
local function smellName(t)
	if t.kind == "fire" then return "smoke" end
	return t.name or "something"
end

local function timeLine(P)
	local T = P.time
	if not T then return "" end
	local h = T.hour or 12
	local part
	if T.night or h < 5 or h >= 21 then part = "night"
	elseif h < 12 then part = "morning" elseif h < 17 then part = "afternoon" else part = "evening" end
	local hh = floor(h) % 24
	local mm = floor((h - floor(h)) * 60 + 0.5)
	if mm >= 60 then hh, mm = (hh + 1) % 24, 0 end
	local s = string.format("%s %d:%02d", part, hh, mm)
	if T.date and T.date ~= "" then s = s .. ", " .. T.date            -- (Day & Night's calendar, when it has one)
	elseif T.day then s = s .. ", day " .. T.day end
	if T.weather and T.weather ~= "" and T.weather ~= "clear" then s = s .. ", " .. T.weather end
	return s
end

local function whereSelf(P)
	local S = P.self
	local where
	if P.here and P.here.name then
		where = (P.here.indoor and "inside " or "at ") .. P.here.name
	elseif S.place and S.place ~= "" then
		where = "at " .. S.place
	else
		where = "outdoors"
	end
	if S.where and S.where ~= "" then
		where = where .. ", " .. S.where
	elseif S.level and S.level >= 1 then
		where = where .. ", upstairs"
	elseif S.level and S.level <= -1 then
		where = where .. ", down in the cellar"
	end
	return where
end

local function selfLine(P)
	local S = P.self
	local s = "You: " .. (S.name or "you") .. ", " .. whereSelf(P)
	if S.doing and S.doing ~= "" then s = s .. ", " .. S.doing end
	local t = timeLine(P)
	if t ~= "" then s = s .. ". " .. t end
	return s .. "."
end

-- ---------------------------------------------------------------- the grid
local function gridAtWorld(G, x, z)                      -- a world point -> "wall" | "floor" | ... | nil (off grid)
	local n = 2 * G.half + 1
	local ix = round((x - vx(G.origin)) / G.cell) + G.half + 1
	local iz = round((z - vz(G.origin)) / G.cell) + G.half + 1
	if ix < 1 or iz < 1 or ix > n or iz > n then return nil end
	return G.at(ix, iz) or "unknown"
end

local function nearestDoor(F, G)                         -- the nearest door cell (indoors: the way out)
	if not G then return nil end
	local n = 2 * G.half + 1
	local best, bd = nil, 1e9
	for iz = 1, n do
		for ix = 1, n do
			if G.at(ix, iz) == "door" then
				local x = vx(G.origin) + (ix - G.half - 1) * G.cell
				local z = vz(G.origin) + (iz - G.half - 1) * G.cell
				local dx, dz = x - F.px, z - F.pz
				local d = dx * dx + dz * dz
				if d < bd then bd, best = d, {x, F.py, z} end
			end
		end
	end
	return best
end

-- metres to the first wall (or door / water / drop) along a direction of the frame, up to maxD
local function ray(F, G, af, ar, maxD)
	local dx = af * F.fx - ar * F.fz
	local dz = af * F.fz + ar * F.fx
	local step = G.cell * 0.5
	local s = step
	while s <= maxD do
		local c = gridAtWorld(G, F.px + dx * s, F.pz + dz * s)
		if c == nil then return nil end
		if c == "wall" or c == "door" or c == "water" or c == "drop" then return s, c end
		s = s + step
	end
	return nil
end

-- indoors: {{word, metres, "door"|"water"|nil} | {word, nil} (open)} for front, right, behind, left of frame F
local function walls(F, P)
	local G = P.grid
	if not G or not (P.here and P.here.indoor) then return nil end
	local dirs = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}}
	local out = {}
	for i = 1, 4 do
		local d, c = ray(F, G, dirs[i][1], dirs[i][2], 6)
		out[i] = {d = d, c = c}
	end
	return out
end
local function wallsLine(W, words)
	if not W then return nil end
	local hit, open = {}, {}
	for i = 1, 4 do
		if W[i].d then
			local s = words[i] .. " " .. metres(W[i].d)
			if W[i].c == "door" then s = s .. " (door)" elseif W[i].c == "water" then s = s .. " (water)" end
			hit[#hit + 1] = s
		else
			open[#open + 1] = words[i]
		end
	end
	local s = "Walls: " .. (#hit > 0 and table.concat(hit, ", ") or "none near")
	if #open > 0 then s = s .. "; open " .. table.concat(open, ", ") end
	return s .. "."
end

-- ---------------------------------------------------------------- gathering
local function entry(F, t, pos)
	local f, r, d, a, dy = rel(F, pos)
	return {t = t, f = f, r = r, d = d, a = a, dy = dy, pos = pos}
end

local function gather(P, F, maxThings, maxPlaces)
	local range = (VL_CFG and VL_CFG.senseRange) or 30
	local O = {seen = {}, heard = {}, smelled = {}, places = {}}
	for _, t in ipairs(P.things or {}) do
		local e = entry(F, t, t.pos)
		local s = senseOf(t)
		if s == "seen" then
			if e.d <= range then O.seen[#O.seen + 1] = e end
		elseif s == "heard" then
			if e.d <= range * 2 then O.heard[#O.heard + 1] = e end
		elseif s == "smelled" then
			O.smelled[#O.smelled + 1] = e
		end
	end
	local byD = function(p, q) return p.d < q.d end
	table.sort(O.seen, byD); table.sort(O.heard, byD); table.sort(O.smelled, byD)
	while #O.seen > maxThings do table.remove(O.seen) end
	while #O.heard > math.max(1, floor(maxThings / 2)) do table.remove(O.heard) end
	while #O.smelled > 2 do table.remove(O.smelled) end
	local hereName = P.here and P.here.name
	for _, pl in ipairs(P.places or {}) do
		if pl.name ~= hereName then
			local e = entry(F, nil, pl.door or pl.pos)
			e.p = pl
			O.places[#O.places + 1] = e
		end
	end
	table.sort(O.places, byD)
	while #O.places > maxPlaces do table.remove(O.places) end
	if P.here and P.here.indoor then
		local dp = nearestDoor(F, P.grid)
		if dp then O.door = entry(F, nil, dp) end
	end
	O.walls = walls(F, P)
	O.people = 0
	for _, e in ipairs(O.seen) do
		if isPerson(e.t) then
			O.people = O.people + 1
			if not O.closest then O.closest = e end
		end
	end
	return O
end

-- the place a thing is by (within 4 m of a landmark's door or centre), for relational text
local function nearPlace(P, e)
	local best, bd = nil, 4
	local hereName = P.here and P.here.name
	for _, pl in ipairs(P.places or {}) do
		for _, q in ipairs({pl.door or false, pl.pos}) do
			if q and pl.name ~= hereName then
				local dx, dz = vx(q) - vx(e.pos), vz(q) - vz(e.pos)
				local d = sqrt(dx * dx + dz * dz)
				if d < bd then bd, best = d, (q == pl.door and (pl.name .. "'s door") or pl.name) end
			end
		end
	end
	return best
end

-- the lines every text format shares: heard, smelled (dirf(e) gives the format's direction words)
local function senseLines(L, O, dirf)
	if #O.heard > 0 then
		local h = {}
		for _, e in ipairs(O.heard) do
			local v = vert(e, true)
			h[#h + 1] = heardName(e.t) .. " (" .. dirf(e) .. (v and (", " .. v) or "") .. ", " .. vague(e.d) .. ")"
		end
		L[#L + 1] = "You hear, but can't see: " .. table.concat(h, "; ") .. "."
	end
	if #O.smelled > 0 then
		local h = {}
		for _, e in ipairs(O.smelled) do h[#h + 1] = smellName(e.t) .. " from " .. dirf(e) end
		L[#L + 1] = "You smell (can't see it): " .. table.concat(h, "; ") .. "."
	end
end

-- ---------------------------------------------------------------- text formats
local function lineFormat(P, F, O, dirf, header, wallWords, smellDir)
	local L = {selfLine(P)}
	if header then L[#L + 1] = header end
	if #O.seen == 0 then
		L[#L + 1] = "You see nobody."
	else
		L[#L + 1] = "You see:"
		for _, e in ipairs(O.seen) do
			local det = details(F, e)
			local nm = e.t.name or "something"
			if e.t.kind == "fire" then nm = "a fire" end
			L[#L + 1] = "- " .. nm .. ": " .. dirf(e) .. ", " .. metres(e.d) .. (det ~= "" and (", " .. det) or "")
		end
	end
	senseLines(L, O, smellDir or dirf)
	if O.door then L[#L + 1] = "Door out: " .. dirf(O.door) .. ", " .. metres(O.door.d) .. "." end
	local w = wallsLine(O.walls, wallWords)
	if w then L[#L + 1] = w end
	if #O.places > 0 then
		local s = {}
		for _, e in ipairs(O.places) do s[#s + 1] = e.p.name .. " " .. dirf(e) .. ", " .. metres(e.d) end
		L[#L + 1] = "Places: " .. table.concat(s, "; ") .. "."
	end
	return table.concat(L, "\n")
end

local function fmtList(P, F, O)
	return lineFormat(P, F, O, function(e) return word8(e.a) end, nil, SIDE_W)
end

local function fmtClock(P, F, O)
	return lineFormat(P, F, O, function(e) return "at " .. clockOf(e.a) .. " o'clock" end,
		"(12 o'clock = straight ahead, 3 = your right, 6 = behind you, 9 = your left)",
		{"12 o'clock", "3 o'clock", "6 o'clock", "9 o'clock"})
end

local function fmtCardinal(P, F, O)
	local cdir = function(e) return compass(bearing(vx(e.pos) - F.px, vz(e.pos) - F.pz)) end
	O.walls = walls({px = F.px, py = F.py, pz = F.pz, fx = 0, fz = -1}, P)   -- along the world axes
	return lineFormat(P, F, O, cdir, "You face " .. compass(bearing(F.fx, F.fz)) .. ".", {"north", "east", "south", "west"},
		function(e) return "the " .. cdir(e) end)
end

local function sectorLines(P, F, O)
	local L = {selfLine(P)}
	local groups = {{}, {}, {}, {}}
	for _, e in ipairs(O.seen) do
		local g = groups[quad(e.a)]
		local det = details(F, e)
		local nm = e.t.kind == "fire" and "a fire" or (e.t.name or "something")
		g[#g + 1] = nm .. " " .. metres(e.d) .. (det ~= "" and (" (" .. det .. ")") or "")
	end
	for i = 1, 4 do
		L[#L + 1] = SIDE[i] .. ": " .. (#groups[i] > 0 and table.concat(groups[i], ", ") or "nobody") .. "."
	end
	senseLines(L, O, function(e) return SIDE_W[quad(e.a)] end)
	if O.closest then
		L[#L + 1] = "Closest: " .. O.closest.t.name .. ". People in sight: " .. O.people .. "."
	else
		L[#L + 1] = "People in sight: 0."
	end
	if O.door then L[#L + 1] = "Door out: " .. word8(O.door.a) .. ", " .. metres(O.door.d) .. "." end
	local w = wallsLine(O.walls, SIDE_W)
	if w then L[#L + 1] = w end
	return L
end

local function placesLine(O)
	if #O.places == 0 then return nil end
	local s = {}
	for _, e in ipairs(O.places) do s[#s + 1] = e.p.name .. " " .. word8(e.a) .. ", " .. metres(e.d) end
	return "Places: " .. table.concat(s, "; ") .. "."
end

local function fmtSectors(P, F, O)
	local L = sectorLines(P, F, O)
	L[#L + 1] = placesLine(O)
	return table.concat(L, "\n")
end

local RINGS = {{2, "Beside you (under 2 m)"}, {5, "Close (2-5 m)"}, {12, "Near (5-12 m)"}, {1e9, "Farther (over 12 m)"}}
local function fmtRadar(P, F, O)
	local L = {selfLine(P)}
	local groups = {{}, {}, {}, {}}
	for _, e in ipairs(O.seen) do
		local k = 4
		for i = 1, 4 do if e.d < RINGS[i][1] then k = i break end end
		local det = details(F, e)
		local nm = e.t.kind == "fire" and "a fire" or (e.t.name or "something")
		local g = groups[k]
		g[#g + 1] = nm .. " " .. word8(e.a) .. (det ~= "" and (" (" .. det .. ")") or "")
	end
	local any = false
	for i = 1, 4 do
		if #groups[i] > 0 then
			any = true
			L[#L + 1] = RINGS[i][2] .. ": " .. table.concat(groups[i], ", ") .. "."
		end
	end
	if not any then L[#L + 1] = "You see nobody." end
	L[#L + 1] = "People in sight: " .. O.people .. "."
	senseLines(L, O, function(e) return word8(e.a) end)
	if O.door then L[#L + 1] = "Door out: " .. word8(O.door.a) .. ", " .. metres(O.door.d) .. "." end
	local w = wallsLine(O.walls, SIDE_W)
	if w then L[#L + 1] = w end
	L[#L + 1] = placesLine(O)
	return table.concat(L, "\n")
end

local REL_DIR = {"in front of you", "ahead to your right", "to your right", "behind you on the right", "behind you",
	"behind you on the left", "to your left", "ahead to your left"}
local function relDir(a) return REL_DIR[(floor((a + 22.5) / 45) % 8) + 1] end
local function fmtRelational(P, F, O)
	local L = {"You are " .. (P.self.name or "you") .. ", " .. whereSelf(P) ..
		((P.self.doing and P.self.doing ~= "") and (", " .. P.self.doing) or "") ..
		((timeLine(P) ~= "") and (". It is " .. timeLine(P)) or "") .. "."}
	if #O.seen == 0 then
		L[#L + 1] = "You see nobody around you."
	else
		local n = 0
		for _, e in ipairs(O.seen) do
			n = n + 1
			local t = e.t
			local nm = t.kind == "fire" and "A fire" or (t.name or "something")
			local s = nm .. (n == 1 and " is the closest, " or " is ") .. relDir(e.a) .. ", " .. distWords(e.d)
			local det = details(F, e)
			if det ~= "" then s = s .. ", " .. det end
			local by = nearPlace(P, e)
			if by then s = s .. ", by " .. by end
			L[#L + 1] = s .. "."
		end
		L[#L + 1] = "That is " .. O.people .. (O.people == 1 and " person" or " people") .. " in sight."
	end
	senseLines(L, O, function(e) return relDir(e.a) end)
	if O.door then L[#L + 1] = "The way out is the door " .. relDir(O.door.a) .. ", " .. distWords(O.door.d) .. "." end
	if O.walls then
		local near = {}
		for i = 1, 4 do if O.walls[i].d and O.walls[i].d < 2 then near[#near + 1] = SIDE_W[i] end end
		if #near > 0 then L[#L + 1] = "A wall is close " .. table.concat(near, " and ") .. "." end
	end
	if #O.places > 0 then
		local s = {}
		for _, e in ipairs(O.places) do s[#s + 1] = e.p.name .. " is " .. relDir(e.a) .. " (" .. metres(e.d) .. ")" end
		L[#L + 1] = table.concat(s, "; ") .. "."
	end
	return table.concat(L, "\n")
end

local function jstr(s) return '"' .. string.gsub(tostring(s), '["\\]', "\\%0") .. '"' end
local function fmtJson(P, F, O)
	local function obj(...)                              -- obj(key, value, key, value, ...): nil values left out
		local kv, n, p = {...}, select("#", ...), {}
		for i = 1, n, 2 do if kv[i + 1] ~= nil then p[#p + 1] = jstr(kv[i]) .. ":" .. kv[i + 1] end end
		return "{" .. table.concat(p, ",") .. "}"
	end
	local function up(e) if abs(e.dy) >= 1.2 then return tostring(round(e.dy)) end end
	local parts = {}
	parts[#parts + 1] = jstr("me") .. ":" .. obj("name", jstr(P.self.name or "you"), "at", jstr(whereSelf(P)),
		"doing", P.self.doing and jstr(P.self.doing), "time", timeLine(P) ~= "" and jstr(timeLine(P)) or nil)
	local see = {}
	for _, e in ipairs(O.seen) do
		local act = activity(F, e)
		see[#see + 1] = obj("who", jstr(e.t.kind == "fire" and "fire" or e.t.name), "dir", jstr(word8(e.a)),
			"m", tostring(round(e.d)), "up_m", up(e), "where", e.t.where and jstr(e.t.where),
			"doing", act ~= "" and jstr(act) or nil)
	end
	parts[#parts + 1] = jstr("see") .. ":[" .. table.concat(see, ",") .. "]"
	parts[#parts + 1] = jstr("people_in_sight") .. ":" .. O.people
	if #O.heard > 0 then
		local h = {}
		for _, e in ipairs(O.heard) do
			h[#h + 1] = obj("sound", jstr(heardName(e.t)), "dir", jstr(word8(e.a)), "dist", jstr(vague(e.d)),
				"up_m", up(e))
		end
		parts[#parts + 1] = jstr("hear_unseen") .. ":[" .. table.concat(h, ",") .. "]"
	end
	if #O.smelled > 0 then
		local h = {}
		for _, e in ipairs(O.smelled) do h[#h + 1] = obj("smell", jstr(smellName(e.t)), "dir", jstr(word8(e.a))) end
		parts[#parts + 1] = jstr("smell_unseen") .. ":[" .. table.concat(h, ",") .. "]"
	end
	if O.door then parts[#parts + 1] = jstr("door_out") .. ":" .. obj("dir", jstr(word8(O.door.a)), "m", tostring(round(O.door.d))) end
	if O.walls then
		local w = {}
		for i = 1, 4 do w[#w + 1] = SIDE_W[i]; w[#w + 1] = O.walls[i].d and tostring(round(O.walls[i].d)) or jstr("open") end
		parts[#parts + 1] = jstr("walls_m") .. ":" .. obj(unpack(w))
	end
	local pl = {}
	for _, e in ipairs(O.places) do pl[#pl + 1] = obj("name", jstr(e.p.name), "dir", jstr(word8(e.a)), "m", tostring(round(e.d))) end
	if #pl > 0 then parts[#parts + 1] = jstr("places") .. ":[" .. table.concat(pl, ",") .. "]" end
	return "{" .. table.concat(parts, ",\n") .. "}"
end

-- ---------------------------------------------------------------- maps
-- letters: seen people upper case, heard people / animals / objects / sounds lower case, fire F/f, places digits
local function letters(O)
	local used, out = {}, {}
	local function pick(name, upper)
		local s = string.gsub(name or "?", "^[Tt]he ", "")
		s = string.gsub(s, "^[Aa]n? ", "")
		for i = 1, #s do
			local c = string.sub(s, i, i)
			if string.find(c, "%a") then
				c = upper and string.upper(c) or string.lower(c)
				if not used[c] then used[c] = true return c end
			end
		end
		local pool = upper and "ABCDEGHJKLMNOPQRSTUWXYZ" or "abcdeghjkmnopqrstuwxyz"
		for i = 1, #pool do
			local c = string.sub(pool, i, i)
			if not used[c] then used[c] = true return c end
		end
		return "?"
	end
	used["I"], used["l"], used["v"] = true, true, true   -- look like other marks (1, the arrow v)
	used["F"], used["f"] = true, true                     -- fire
	for _, e in ipairs(O.seen) do
		if e.t.kind == "fire" then out[e] = "F" else out[e] = pick(e.t.name, isPerson(e.t)) end
	end
	for _, e in ipairs(O.heard) do out[e] = pick(e.t.name, false) end
	for i, e in ipairs(O.places) do out[e] = tostring(i) end
	return out
end

-- a map Wc columns each side, A rows ahead, B rows behind (turned: villager faces up; north: north up)
local function drawMap(P, F, O, north, Wc, A, B, showPlaces, hideHeard)
	local G = P.grid
	local cell = (G and G.cell) or 1
	local rows = {}
	for r = -A, B do
		local row = {}
		for c = -Wc, Wc do
			local ch = "."
			if G then
				local dx, dz
				if north then dx, dz = c * cell, r * cell
				else
					local fw, rt = -r * cell, c * cell
					dx, dz = fw * F.fx - rt * F.fz, fw * F.fz + rt * F.fx
				end
				ch = GRIDCH[gridAtWorld(G, F.px + dx, F.pz + dz) or "unknown"] or " "
			end
			row[#row + 1] = ch
		end
		rows[r] = row
	end
	-- a turned map samples the grid at slants and can skip a one-cell door: splat every wall / water / door cell
	-- onto the map too (doors last, so a doorway always shows)
	if G and not north then
		local n = 2 * G.half + 1
		local PRI = {water = 1, drop = 1, wall = 2, door = 3}
		local pri = {}
		for iz = 1, n do
			for ix = 1, n do
				local k = G.at(ix, iz)
				local p = PRI[k]
				if p then
					local dx = vx(G.origin) + (ix - G.half - 1) * G.cell - F.px
					local dz = vz(G.origin) + (iz - G.half - 1) * G.cell - F.pz
					local c = round((-dx * F.fz + dz * F.fx) / cell)
					local r = -round((dx * F.fx + dz * F.fz) / cell)
					if c >= -Wc and c <= Wc and r >= -A and r <= B and (pri[r * 1000 + c] or 0) < p then
						pri[r * 1000 + c] = p
						rows[r][c + Wc + 1] = GRIDCH[k]
					end
				end
			end
		end
	end
	local off = {}
	local function put(e, ch)
		local c, r
		if north then c, r = (vx(e.pos) - F.px) / cell, (vz(e.pos) - F.pz) / cell
		else c, r = e.r / cell, -e.f / cell end
		local s = math.max(abs(c) / Wc, (r < 0) and (-r / A) or (r / math.max(B, 1)))
		if s > 1 then off[e] = true; c, r = c / s, r / s end
		c, r = round(c), round(r)
		if c < -Wc then c = -Wc elseif c > Wc then c = Wc end
		if r < -A then r = -A elseif r > B then r = B end
		if c == 0 and r == 0 then c = (e.r and e.r < 0) and -1 or 1 end   -- never on top of the villager
		rows[r][c + Wc + 1] = ch
	end
	local L = letters(O)
	if showPlaces then for i = #O.places, 1, -1 do put(O.places[i], L[O.places[i]]) end end
	if not hideHeard then for i = #O.heard, 1, -1 do put(O.heard[i], L[O.heard[i]]) end end
	for i = #O.seen, 1, -1 do put(O.seen[i], L[O.seen[i]]) end
	local me = "^"
	if north then me = ({"^", ">", "v", "<"})[(floor((bearing(F.fx, F.fz) + 45) / 90) % 4) + 1] end
	rows[0][Wc + 1] = me
	local lines = {}
	for r = -A, B do lines[#lines + 1] = table.concat(rows[r]) end
	return table.concat(lines, "\n"), L, off
end

local function mapLegend(F, O, L, off, showPlaces)
	local items = {}
	for _, e in ipairs(O.seen) do
		local det = details(F, e)
		local extra = {}
		if det ~= "" then extra[#extra + 1] = det end
		if off[e] then extra[#extra + 1] = metres(e.d) .. " away, past the edge" end
		local nm = e.t.kind == "fire" and "a fire" or (e.t.name or "?")
		items[#items + 1] = L[e] .. " " .. nm .. (#extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or "")
	end
	for _, e in ipairs(O.heard) do
		local v = vert(e, true)
		items[#items + 1] = L[e] .. " " .. heardName(e.t) .. " (heard, not seen" .. (v and (", " .. v) or "") ..
			(off[e] and (", " .. vague(e.d)) or "") .. ")"
	end
	local s = #items > 0 and ("On the map: " .. table.concat(items, "; ") .. ".") or "Nobody else on the map."
	if #O.smelled > 0 then
		local h = {}
		for _, e in ipairs(O.smelled) do h[#h + 1] = smellName(e.t) .. " from " .. word8(e.a) end
		s = s .. "\nYou smell (can't see it): " .. table.concat(h, "; ") .. "."
	end
	if showPlaces and #O.places > 0 then
		local p = {}
		for _, e in ipairs(O.places) do p[#p + 1] = L[e] .. " " .. e.p.name .. " (" .. metres(e.d) .. ")" end
		s = s .. "\nPlaces (at the map edge if farther): " .. table.concat(p, "; ") .. "."
	end
	return s
end

local function fmtAscii(P, F, O, north, half)
	local map, L, off = drawMap(P, F, O, north, half, half, half, true)
	local head
	if north then
		head = "Map from above, north up, 1 char = 1 m. You are the arrow in the middle, facing " ..
			compass(bearing(F.fx, F.fz)) .. "."
	else
		head = "Map from above, turned so you face up (up = in front of you, left = your left), 1 char = 1 m. You are ^ in the middle."
	end
	return table.concat({selfLine(P), head, "# wall, + door, ~ water, ! drop, . open ground.", map,
		mapLegend(F, O, L, off, true)}, "\n")
end

local function fmtHybrid(P, F, O, half)
	local L = sectorLines(P, F, O)
	L[#L + 1] = placesLine(O)
	local map = drawMap(P, F, O, false, half, half, math.max(2, half - 1), false, true)
	return table.concat(L, "\n") .. "\nNearby, seen from overhead (you are ^ facing up; # wall, + door, ~ water; " ..
		"letters = first letters of the people you see):\n" .. map
end

-- ---------------------------------------------------------------- entry
local BUILD = {
	sectors = fmtSectors, list = fmtList, clock = fmtClock, cardinal = fmtCardinal, radar = fmtRadar,
	relational = fmtRelational, json = fmtJson,
	ascii = function(P, F, O, half) return fmtAscii(P, F, O, false, half) end,
	ascii_north = function(P, F, O, half) return fmtAscii(P, F, O, true, half) end,
	hybrid = function(P, F, O, half) return fmtHybrid(P, F, O, half - 2) end,
}

function VlSense.describe(P, format, maxChars)
	format = format or (VL_CFG and VL_CFG.senseFormat) or "json"
	local fn = BUILD[format] or fmtJson
	maxChars = maxChars or 900
	local F = frame(P)
	local nT, nP, half = 8, 4, 7
	local isMap = format == "ascii" or format == "ascii_north" or format == "hybrid"
	local s = fn(P, F, gather(P, F, nT, nP), half)
	-- too long: fewer places, a smaller map, fewer things
	local guard = 0
	while #s > maxChars and guard < 24 do
		guard = guard + 1
		if nP > 2 then nP = nP - 1
		elseif half > 5 and isMap then half = half - 1
		elseif nT > 3 then nT = nT - 1
		elseif nP > 0 then nP = nP - 1
		elseif half > 3 and isMap then half = half - 1
		else break end
		s = fn(P, F, gather(P, F, nT, nP), half)
	end
	return s
end

-- for tests and the benchmark: the same direction words the formats use
VlSense._word8 = word8
VlSense._clock = clockOf
VlSense._compass = compass
VlSense._rel = function(P, pos) return rel(frame(P), pos) end
