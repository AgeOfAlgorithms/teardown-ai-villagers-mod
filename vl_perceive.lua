-- Villagers: what a villager can sense right now, as VlSense's P table. Only what it could really perceive: SEEN
-- (in range, in its field of view, a clear line from its eyes - shorter at night outdoors), HEARD (someone moving
-- close by out of sight, gunshots, explosions, breaking), SMELLED (smoke from a fire it can't see). Things it
-- doesn't sense are not in P at all. Every thing keeps its height, so VlSense can say above / below / upstairs.
-- (no #version line: included by main.lua)

VlPerceive = {sounds = {}}

local VP = VlPerceive
local LAYER_OURS = 32

local TOOL_NAMES = {
	sledge = "a sledgehammer", gun = "a pistol", shotgun = "a shotgun", rifle = "a rifle", rocket = "a rocket launcher",
	blowtorch = "a blowtorch", extinguisher = "a fire extinguisher", spraycan = "a spray can", plank = "a plank",
	pipebomb = "a pipe bomb", bomb = "a bomb", explosive = "explosives", wire = "a wire tool", leafblower = "a leaf blower",
	booster = "a vehicle booster", turbo = "a turbo", steroid = "a strange syringe",
}
VP.TOOL_NAMES = TOOL_NAMES

-- (the user, 2026-11-14: "villagers should be able to see what I'm holding and what I'm wearing (if inventory mod is
-- turned on)") a held tool by its name (the game's tools; a mod's weapon by its registered name), and the worn
-- clothing from the Inventory mod's host key inventory.wear.<player> (item ids, "none" = only underwear, "own" = the
-- character as it is) with the names under inventory.clothing.<id>.name / inventory.items.<id>.name
local function nameOf(prefixes, id)
	for _, pre in ipairs(prefixes) do
		local n = GetString(pre .. id .. ".name")
		if n ~= "" and not n:find("^loc@") then return n:lower() end
	end
	return nil
end

-- (the Inventory mod, 2026-11-15: inventory.colors.<id>.text "grey and red", by the same ids) a colour in front
local function coloured(id, name)
	local c = GetString("inventory.colors." .. id .. ".text")
	if c == "" or not name then return name end
	local art, rest = name:match("^(an?) (.+)$")
	if art then return (c:find("^[aeiouAEIOU]") and "an " or "a ") .. c .. " " .. rest end
	return c .. " " .. name
end

function VlPerceive.holding(p)
	local tool = GetPlayerTool(p)
	if not tool or tool == "" or tool == "none" then return nil end
	return coloured(tool, TOOL_NAMES[tool] or nameOf({"inventory.weapons.", "inventory.items.", "game.tool."}, tool))
end

-- a player's looks: the game character they picked (VL_LOOKS), none for a character we don't know (a mod's)
function VlPerceive.playerLooks(p)
	local ok, id = pcall(GetPlayerCharacter, p)
	if not ok or not id or not VL_LOOKS then return nil end
	return VL_LOOKS[id]
end

function VlPerceive.wearing(p, V)
	local w = GetString("inventory.wear." .. p)
	if w == "" or w == "own" then return nil end
	if w == "none" then return "only underwear" end
	local l = {}
	for id in w:gmatch("%S+") do
		local n = nameOf({"inventory.clothing.", "inventory.items.", "wardrobe.items."}, id)
		if n then
			local f = V and VlApi and VlApi.feelText(VlApi.itemFeel(V, id))     -- (another mod's say: villagers.item.<id>.feel)
			l[#l + 1] = coloured(id, n) .. (f and (" (" .. f .. ")") or "")
		end
	end
	if #l == 0 then return nil end
	return table.concat(l, ", ")
end

local function eyes(pos) return VecAdd(pos, Vec(0, 1.6, 0)) end

-- a clear line between two points (static and loose things block; villagers' own models and the target don't)
function VlPerceive.clear(a, b, reject)
	local d = VecSub(b, a)
	local L = VecLength(d)
	if L < 0.3 then return true end
	QueryCollisionMask(255 - LAYER_OURS - 64)
	if reject then QueryRejectBody(reject) end
	local hit, dist = QueryRaycast(a, VecScale(d, 1 / L), L - 0.3)
	return not hit
end

-- seeing (not hearing, not reaching): no wall and no smoke (another mod's villagers.cover clouds, vl_api.lua) between
function VlPerceive.sight(a, b, reject)
	return VlPerceive.clear(a, b, reject) and not (VlApi and VlApi.smokeBlocks and VlApi.smokeBlocks(a, b))
end

-- a creature of another mod given as a point (no body to ignore): the ray may stop on the creature itself, so a hit
-- within `slack` m of the point still counts as seeing it
function VlPerceive.clearNear(a, b, reject, slack)
	local d = VecSub(b, a)
	local L = VecLength(d)
	if L < 0.3 then return true end
	QueryCollisionMask(255 - LAYER_OURS - 64)
	if reject then QueryRejectBody(reject) end
	local hit, dist = QueryRaycast(a, VecScale(d, 1 / L), L - 0.3)
	return not hit or (L - dist) < (slack or 0.3)
end

local function inView(self, pos)
	if self.blind then return false end                      -- (a flash-bang: villagers.flash, vl_api.lua)
	local d = VecSub(pos, self.pos)
	d[2] = 0
	local L = VecLength(d)
	if L < 2.5 then return true end                          -- (close by: they notice whatever the angle)
	local c = VecDot(VecScale(d, 1 / L), self.fwd)
	return c > -0.35                                         -- (about 220 degrees: eyes and a turning head)
end

local function seeRange(V)
	local r = VL_CFG.seeRange
	if VlLife.night() then
		local indoor = V.place and V.place.indoor and V.mode == "at"
		r = indoor and r * 0.6 or r * 0.4                     -- (lamps indoors, moonlight outside)
	end
	local fog = GetFloat("daynight.fog")
	if fog > 0 then r = r * (1 - 0.6 * fog) end
	return r
end

-- ---------------------------------------------------------------- sounds (gathered once per tick for everyone)
-- {kind = "gunshot"|"explosion"|"impact", pos, t, by = player id | nil, loud = 0..1}
local ammoSeen = {}
local SHOOTERS = {gun = true, shotgun = true, rifle = true, rocket = true}

function VlPerceive.tick(dt)
	local now = GetTime()
	local list = VP.sounds
	for i = #list, 1, -1 do if now - list[i].t > 12 then table.remove(list, i) end end
	local n = GetEventCount("explosion")
	for i = 1, n do
		local pos, strength = GetEvent("explosion", i)
		if pos then list[#list + 1] = {kind = "explosion", pos = VecCopy(pos), t = now, loud = math.min(1, (strength or 1) / 2)} end
	end
	for _, p in ipairs(GetAllPlayers()) do
		local tool = GetPlayerTool(p)
		if SHOOTERS[tool] then
			local a = GetToolAmmo(tool, p)
			local k = p .. tool
			if ammoSeen[k] and a < ammoSeen[k] then
				list[#list + 1] = {kind = "gunshot", pos = GetPlayerTransform(p).pos, t = now, by = p, tool = tool, loud = 0.8}
			end
			ammoSeen[k] = a
		end
	end
	if #list > 40 then table.remove(list, 1) end
end

-- ---------------------------------------------------------------- the P table for VlSense
-- (the user, 2026-11-15: "villagers should be able to see players' health status as well as other villagers if they
-- can see them") how hurt someone looks, in words; nil when unharmed (no words spent)
function VlPerceive.healthWords(frac, downed)
	if downed then return "collapsed, bleeding badly" end
	if frac >= 0.95 then return nil end
	if frac >= 0.7 then return "a few scrapes" end
	if frac >= 0.45 then return "hurt" end
	if frac >= 0.2 then return "badly hurt and bleeding" end
	return "barely standing, covered in blood"
end

local function playerDoing(p)
	if GetPlayerHealth(p) <= 0 then return "lying on the ground, dead or unconscious" end
	if GetPlayerVehicle(p) ~= 0 then return "driving a vehicle" end
	local v = GetPlayerVelocity(p)
	local s = math.sqrt(v[1] * v[1] + v[3] * v[3])
	if math.abs(v[2]) > 3.5 then return v[2] < 0 and "falling" or "jumping" end
	if s > 4.5 then return "running" end
	if s > 0.8 then return "walking" end
	return "standing"
end

local function villagerDoing(O)
	if not O.alive then return "lying dead" end
	if O.downed then return "lying collapsed on the ground, bleeding" end
	if O.tending then return "kneeling, bandaging " .. (O.tending.who or "someone") end
	if O.override and O.override.kind == "fight" then return "fighting " .. (O.override.who or "someone") end
	if O.override and O.override.kind == "follow" and O.override.chase then return "chasing " .. (O.override.who or "someone") end
	if O.override and O.override.kind == "flee" then return "running away" end
	if O.asleep then return "asleep" end
	if O.spraying then return "spraying a fire with an extinguisher" end
	if O.mode == "engaged" then return "talking" end
	if O.posture == "sit" then return "sitting" end
	if O.w.state == "walking" then return O.w.speedNow and O.w.speedNow > 2.5 and "running" or "walking" end
	return "standing"
end

-- V: the villager; all: every villager; returns P (see vl_sense.lua's contract)
function VlPerceive.build(V, all)
	local now = GetTime()
	local pos, fwd = V.w.pos, V.w.fwd
	local e = eyes(pos)
	local range = seeRange(V)
	local self = {name = V.name, pos = VecCopy(pos), fwd = VecCopy(fwd), doing = VlLife.doingText(V),
		place = V.place and V.place.name or nil, blind = VlApi and VlApi.blind and VlApi.blind(V) or nil}
	if self.blind then self.doing = "blinded by a flash, rubbing your eyes" end
	local b = VlPlaces.buildingAt and VlPlaces.buildingAt(pos)
	if b then
		self.indoor = true
		self.level = (pos[2] > b.floorY + 1.5) and 1 or 0           -- (VlSense: a floor number, 1 = upstairs)
	end
	local P = {self = self, things = {}, places = {},
		time = {hour = VlLife.hour(), day = VlLife.day(), night = VlLife.night(),
			date = (GetBool("daynight.present") and GetString("daynight.date") ~= "") and VlLife.dateText() or nil,
			weather = GetBool("daynight.present") and GetString("daynight.weather.all") or nil}}
	if V.place and V.mode ~= "go" then P.here = {name = V.place.name, kind = V.place.kind, indoor = V.place.indoor} end
	local T = P.things
	-- players
	for _, p in ipairs(GetAllPlayers()) do
		local t = GetPlayerTransform(p)
		local chest = VecAdd(t.pos, Vec(0, 1.2, 0))
		local d = VecLength(VecSub(chest, e))
		if d < range and inView(self, t.pos) and VlPerceive.sight(e, chest) then
			local held = VlPerceive.holding(p)
			local hf = held and VlApi and VlApi.feelText(VlApi.itemFeel(V, GetPlayerTool(p)))
			if hf then held = held .. " (" .. hf .. ")" end
			T[#T + 1] = {kind = "player", name = GetPlayerName(p), pos = VecCopy(t.pos), sense = "seen",
				fwd = QuatRotateVec(t.rot, Vec(0, 0, -1)), doing = playerDoing(p), holding = held,
				wearing = d < VL_CFG.seeClothes and VlPerceive.wearing(p, V) or nil,
				looks = d < VL_CFG.seeClothes and VlPerceive.playerLooks(p) or nil,
				hurt = GetPlayerHealth(p) < 0.5 and GetPlayerHealth(p) > 0 or nil, player = p,
				health = GetPlayerHealth(p) > 0 and VlPerceive.healthWords(GetPlayerHealth(p)) or nil}
		elseif d < VL_CFG.hearStep then
			local v = GetPlayerVelocity(p)
			if math.abs(v[1]) + math.abs(v[3]) > 0.8 then
				T[#T + 1] = {kind = "player", name = "someone", pos = VecCopy(t.pos), sense = "heard", doing = "footsteps", player = p}
			end
		end
	end
	-- the other villagers
	for _, O in ipairs(all) do
		if O ~= V then
			local chest = VecAdd(O.w.pos, Vec(0, O.posture == "lie" and 0.5 or 1.2, 0))
			local d = VecLength(VecSub(chest, e))
			if d < range and inView(self, O.w.pos) and VlPerceive.sight(e, chest) then
				T[#T + 1] = {kind = "villager", name = O.name, pos = VecCopy(O.w.pos), fwd = VecCopy(O.w.fwd), sense = "seen",
					doing = villagerDoing(O), holding = O.carrying == "extinguisher" and "a fire extinguisher" or nil, id = O.id,
					hurt = O.alive and O.hp < VL_CFG.bleedBelow or nil,
					health = O.alive and VlPerceive.healthWords(O.hp / 100, O.downed) or nil,
					looks = d < VL_CFG.seeClothes and VL_LOOKS and VL_LOOKS[O.p.character] or nil}
			elseif d < VL_CFG.hearStep and O.alive and O.w.state == "walking" then
				T[#T + 1] = {kind = "villager", name = "someone", pos = VecCopy(O.w.pos), sense = "heard", doing = "footsteps", id = O.id}
			end
		end
	end
	-- other AI characters (Mochi, Duchess, ...): agents whose .at is a body
	local ok, ids = pcall(ListKeys, "proxchat.agent")
	if ok and ids then
		for _, id in ipairs(ids) do
			if id:sub(1, 3) ~= "vl_" then
				local at = GetString("proxchat.agent." .. id .. ".at")
				local h = tonumber(at:match("^body:(%d+)"))
				local registered = false                       -- (the pet's own mod registered it through vl_api: seen there)
				if h and VlApi then for _, t in ipairs(VlApi.things) do if t.body == h then registered = true end end end
				if h and IsHandleValid(h) and not registered then
					local ap = GetBodyTransform(h).pos
					local d = VecLength(VecSub(ap, e))
					if d < range and inView(self, ap) and VlPerceive.sight(e, ap, h) then
						local nm = GetString("proxchat.agent." .. id .. ".name")
						local kind = (id:find("mochi") or id:find("duchess")) and "animal" or "character"
						local what = id:find("mochi") and " (a corgi dog)" or (id:find("duchess") and " (a black cat)" or "")
						T[#T + 1] = {kind = kind, name = (nm ~= "" and nm or id) .. what, pos = VecCopy(ap), sense = "seen", doing = "about"}
					end
				end
			end
		end
	end
	-- other mods' creatures and things (vl_api.lua: villagers.kind.* + bodies tagged vlkind=<k> / villagers.thing.*):
	-- seen when in sight (not hidden), else heard within the kind's hearing range if it makes a sound; each with the
	-- villager's feeling for its kind
	if VlApi then
		local n = 0
		for _, t in ipairs(VlApi.things) do
			local d = VecLength(VecSub(t.pos, e))
			if d < math.max(range, t.hear or 0) and n < 8 then
				local feel = VlApi.feel(V, t.kind)
				if feel ~= "ignore" then
					local K = VlApi.kinds[t.kind] or {}
					if not t.hidden and d < range and inView(self, t.pos) and VlPerceive.clearNear(e, t.pos, t.body, t.body and 0.3 or 1.5)
						and not (VlApi and VlApi.smokeBlocks and VlApi.smokeBlocks(e, t.pos)) then
						n = n + 1
						T[#T + 1] = {kind = "creature", name = t.name, pos = VecCopy(t.pos), sense = "seen",
							doing = t.doing ~= "" and t.doing or nil, feel = feel, thing = t, danger = K.danger or 0}
					elseif (t.sound or "") ~= "" and d < (t.hear or 0) then
						n = n + 1
						T[#T + 1] = {kind = "creature", name = t.sound, pos = VecCopy(t.pos), sense = "heard",
							doing = t.sound, feel = feel, thing = t, danger = K.danger or 0}
					end
				end
			end
		end
	end
	-- fire: seen flames or smelled smoke
	local fp = VlLife.nearestFire(e, VL_CFG.smellRange)
	if fp then
		local d = VecLength(VecSub(fp, e))
		local n = 0
		pcall(function() n = QueryAabbFireCount(VecSub(fp, Vec(3, 3, 3)), VecAdd(fp, Vec(3, 3, 3))) end)
		local size = n > 25 and "a big fire" or (n > 6 and "a fire" or "small flames")
		if d < range and inView(self, fp) and VlPerceive.sight(e, VecAdd(fp, Vec(0, 0.3, 0))) then
			T[#T + 1] = {kind = "fire", name = size, pos = VecCopy(fp), sense = "seen", doing = "burning", size = n > 25 and "big" or (n <= 6 and "small" or nil)}
		else
			T[#T + 1] = {kind = "fire", name = "smoke", pos = VecCopy(fp), sense = "smelled", doing = "something is burning"}
		end
	end
	-- sounds in the last 8 s
	for _, s in ipairs(VP.sounds) do
		if now - s.t < 8 then
			local d = VecLength(VecSub(s.pos, e))
			if d < VL_CFG.hearShot * (s.kind == "explosion" and 2 or 1) then
				T[#T + 1] = {kind = "sound", name = s.kind == "gunshot" and "a gunshot" or (s.kind == "explosion" and "an explosion" or "a crash"),
					pos = VecCopy(s.pos), sense = "heard", doing = string.format("%d s ago", math.floor(now - s.t)), loud = s.loud}
			end
		end
	end
	-- where things are, in words: upstairs in a building, or up on a roof
	for _, th in ipairs(T) do
		if th.sense == "seen" and th.kind ~= "sound" then
			local tb = VlPlaces.buildingAt and VlPlaces.buildingAt(th.pos)
			if tb and th.pos[2] > tb.floorY + 1.5 then
				th.where = VlPlaces.indoorAt(th.pos, 1.0) and "upstairs" or "on the roof"
			end
		end
	end
	-- places nearby (they know their own village whether they see it or not)
	for _, pl in ipairs(VlPlaces.list) do
		local d = VecLength(VecSub(pl.pos, pos))
		if d < 70 and pl ~= V.place then
			P.places[#P.places + 1] = {name = pl.name, kind = pl.kind, pos = VecCopy(pl.pos), door = pl.pos}
		end
	end
	table.sort(P.places, function(a, b2) return VecLength(VecSub(a.pos, pos)) < VecLength(VecSub(b2.pos, pos)) end)
	while #P.places > 5 do table.remove(P.places) end
	-- the floor plan round them (indoors or when someone asks the way: the brain decides whether to describe it)
	if VlNav and VlNav.grid then
		local okg, g = pcall(VlNav.grid, pos, 6, 1.0)
		if okg then P.grid = g end
	end
	return P
end
