#version 2
-- Villagers: a dozen AI villagers on any map (villagers/PROJECT.md). Thin: includes and callbacks.
-- Host: places (vl_places), walking (vl_nav), days (vl_life), senses (vl_perceive -> vl_sense), minds and the LLM
-- (vl_brain), memories (vl_memory). Every machine: the villagers drawn as the game's own characters (vl_view).

#include "vl_config.lua"
#include "vl_people.lua"
#include "vl_places.lua"
#include "vl_nav.lua"
#include "vl_sense.lua"
#include "vl_memory.lua"
#include "vl_life.lua"
#include "vl_perceive.lua"
#include "vl_brain.lua"
#include "vl_view.lua"
#include "vl_api.lua"
-- (test builds add their modules here)

VL = {all = {}, started = false, seq = 0, pubT = 0}
VL_LAYER = 32                         -- villagers' client models and anchors: players and our rays ignore it
VL_HITLAYER = 64                      -- villagers' hitboxes: bullets hit them, players walk through, our rays ignore them
VL_RAYMASK = 255 - 32 - 64            -- every ray of ours
VL_CAST_VERSION = 2                   -- (raised when the cast's names change: saved memories are wiped)

-- ---------------------------------------------------------------- the villagers
local function spawnAnchor(V)
	if V.anchor and IsHandleValid(V.anchor) then Delete(V.anchor) end
	local ok, ents = pcall(Spawn, "<body dynamic='true' tags='vlanchor'><vox file='MOD/vox/anchor.vox' tags='invisible unbreakable vlanchor'/></body>",
		Transform(VecAdd(V.w.pos, Vec(0, 1.9, 0))))
	V.anchor = nil
	if not ok or type(ents) ~= "table" then return end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then
			V.anchor = h
			for _, s in ipairs(GetBodyShapes(h) or {}) do SetShapeCollisionFilter(s, VL_LAYER, 0) end
		end
	end
end

-- (the user, 2026-11-14: "they should have hit boxes and HP") an invisible static box per villager that bullets hit
-- (projectilehit names its shape), moved with them every step; players walk through it (their CollisionMask leaves
-- layer 64 out), our rays ignore it. Lying: laid flat. Dead: removed (the clients' ragdoll lies there).
local function spawnHitbox(V)
	if V.hit and IsHandleValid(V.hit) then Delete(V.hit) end
	local ok, ents = pcall(Spawn, "<body tags='vlhit'><voxbox size='5 18 4' material='plastic' tags='invisible unbreakable vlhit nohole'/></body>",
		Transform(V.w.pos), true)
	V.hit, V.hitShape = nil, nil
	if not ok or type(ents) ~= "table" then return end
	for _, h in ipairs(ents) do
		if GetEntityType(h) == "body" then V.hit = h end
		if GetEntityType(h) == "shape" then V.hitShape = h; SetShapeCollisionFilter(h, VL_HITLAYER, 255) end
	end
	VL.byShape = VL.byShape or {}
	if V.hitShape then VL.byShape[V.hitShape] = V end
end

local function placeHitbox(V)
	if not V.alive then
		if V.hit and IsHandleValid(V.hit) then Delete(V.hit) end
		V.hit = nil
		return
	end
	if not (V.hit and IsHandleValid(V.hit)) then spawnHitbox(V) end
	if not V.hit then return end
	local f = V.w.fwd
	local yaw = QuatLookAt(Vec(0, 0, 0), Vec(f[1], 0, f[3]))
	if V.posture == "lie" and V.lie then
		local h = V.lie.head
		-- (the box's long side is local y: turned to lie along the head direction)
		local rot = QuatRotateQuat(QuatLookAt(Vec(0, 0, 0), Vec(h[1], 0, h[3])), QuatEuler(-90, 0, 0))
		SetBodyTransform(V.hit, Transform(VecAdd(VecSub(V.lie.pos, VecScale(h, 0.9)), Vec(0, 0.05, 0)), rot))
	elseif V.posture == "sit" and V.sitPos then
		SetBodyTransform(V.hit, Transform(VecSub(V.sitPos, Vec(0, 0.5, 0)), yaw))
	else
		SetBodyTransform(V.hit, Transform(VecAdd(V.w.pos, Vec(0, 0.02, 0)), yaw))
	end
	-- (the voxbox's corner is the body's origin: centre it on the villager)
	if V.hitShape and IsHandleValid(V.hitShape) then SetShapeLocalTransform(V.hitShape, Transform(Vec(-0.25, 0, -0.2))) end
end

local function anchorOk(V)
	if not (V.anchor and IsHandleValid(V.anchor)) then return false end
	local shapes = GetBodyShapes(V.anchor) or {}
	return #shapes > 0 and IsHandleValid(shapes[1]) and (GetShapeVoxelCount(shapes[1]) or 0) > 0
end

local function startPos(V)
	local plan = VlLife.want(V, VlLife.hour())
	local pl = plan.place or VlPlaces.home(V.p)
	local spot = pl and VlPlaces.claim(pl, V.id)
	VlPlaces.release(V.id)
	local p = spot and spot.pos or (pl and (pl.inside or pl.pos)) or VlPlaces.center or VlPlaces.spawn
	-- spread them a little so nobody starts inside another
	return VecAdd(p, Vec((V.k % 3 - 1) * 0.6, 0.05, (math.floor(V.k / 3) % 3 - 1) * 0.6))
end

-- in this village? the host's pick in the options (savegame.mod.vill.<id> = "on" / "off"), else VL_CFG.defaultVillagers
function VlPicked(id)
	local v = GetString("savegame.mod.vill." .. id)
	if v == "on" then return true elseif v == "off" then return false end
	return (VL_CFG.defaultVillagers or {})[id] == true
end

local function makeVillagers()
	VL.all = {}
	for k, p in ipairs(VL_PEOPLE or {}) do
	if VlPicked(p.id) then                                    -- (the options' pick, else the default four)
		local V = {k = k, id = p.id, p = p, name = p.name, agent = "vl_" .. p.id, hp = 100, alive = true, notes = {},
			posture = "stand", mode = "at"}
		VlLife.newDay(V)
		V.dayDone = VlLife.day()
		V.w = VlNav.newWalker(Vec(0, 0, 0), {id = p.id, radius = 0.3, speed = VL_CFG.walkSpeed})
		VlNav.warp(V.w, startPos(V))
		spawnAnchor(V)
		VlBrain.goalsInit(V, VL.levelKey or "map")
		VL.all[#VL.all + 1] = V
	end
	end
	VlBrain.init(VL.all)
end

-- ---------------------------------------------------------------- harm: bullets through them, blasts near them
local function segDist(a0, a1, b0, b1)                -- closest distance between two segments (sampled; cheap enough)
	local best = math.huge
	for i = 0, 6 do
		local p = VecLerp(a0, a1, i / 6)
		local d = VecSub(b1, b0)
		local L2 = VecDot(d, d)
		local t = L2 > 0 and math.max(0, math.min(1, VecDot(VecSub(p, b0), d) / L2)) or 0
		local q = VecAdd(b0, VecScale(d, t))
		local dd = VecLength(VecSub(p, q))
		if dd < best then best = dd end
	end
	return best
end

local function shooterOf(point, dir)
	local best, bd = nil, 3
	for _, p in ipairs(GetAllPlayers()) do
		local e = GetPlayerEyeTransform(p).pos
		local to = VecSub(e, point)
		local along = -VecDot(to, dir)
		if along < 0 then
			local off = VecLength(VecAdd(to, VecScale(dir, along)))
			if off < bd then best, bd = p, off end
		end
	end
	return best
end

local MELEE = {sledge = 34, plank = 12, crowbar = 26, knife = 30, axe = 40, machete = 40, bat = 26, hammer = 26}

local function harm()
	local n = GetEventCount("projectilehit")
	for i = 1, n do
		local shape, point, dir = GetEvent("projectilehit", i)
		if point and dir then
			local d = VecNormalize(dir)
			local from = VecSub(point, VecScale(d, 120))
			local V = VL.byShape and shape and VL.byShape[shape]
			local p = shooterOf(point, d)
			local by = p and GetPlayerName(p) or "Someone"
			local at = p and GetPlayerTransform(p).pos or from
			if V and V.alive then
				local head = V.posture ~= "lie" and point[2] > (V.posture == "sit" and V.sitPos and V.sitPos[2] + 0.55 or V.w.pos[2] + 1.45)
				VlBrain.hurt(V, VL_CFG.bulletDamage * (head and 2 or 1), by, at, point)
			else
				-- (a bullet that did not stop in a hitbox but went past a villager: the old line test)
				for _, O in ipairs(VL.all) do
					if O.alive then
						local feet = O.posture == "lie" and O.lie and O.lie.pos or O.w.pos
						local top = O.posture == "lie" and VecAdd(feet, Vec(0, 0.4, 0)) or VecAdd(feet, Vec(0, 1.75, 0))
						if segDist(VecAdd(feet, Vec(0, 0.2, 0)), top, from, point) < 0.25 then
							VlBrain.hurt(O, VL_CFG.bulletDamage, by, at, VecLerp(feet, top, 0.6))
						end
					end
				end
			end
		end
	end
	n = GetEventCount("explosion")
	for i = 1, n do
		local point, strength = GetEvent("explosion", i)
		if point then
			local r = 3 + 3 * (strength or 1)
			for _, V in ipairs(VL.all) do
				if V.alive then
					local dd = VecLength(VecSub(VecAdd(V.w.pos, Vec(0, 1, 0)), point))
					if dd < r then VlBrain.hurt(V, 120 * (1 - dd / r), nil, point, VecAdd(V.w.pos, Vec(0, 1.1, 0))) end
				end
			end
		end
	end
	-- melee: a swing (usetool) with a striking tool, a villager in front within reach and in sight. The Inventory
	-- mod's melee weapons (its swing hits players only; on our hitboxes it only sounds - seen in game 2026-11-15, a
	-- sword) by their published inventory.weapons.<id>.power (share of full health) / .delay (wind-up) / .reach /
	-- .cooldown: the blow lands after the wind-up. Also its exact hits when it publishes them (inventory.melee.hit.*).
	local now = GetTime()
	VL.swings = VL.swings or {}
	for _, p in ipairs(GetAllPlayers()) do
		local tool = GetPlayerTool(p) or ""
		local wk = "inventory.weapons." .. tool .. "."
		local power = GetFloat(wk .. "power")
		local dmg, reach, delay, cool = MELEE[tool], 2.4, 0.05, 0.6
		if power > 0 then
			dmg = power * 100
			reach = math.max(1.6, GetFloat(wk .. "reach") + 0.4)
			delay = GetFloat(wk .. "delay")
			cool = math.max(0.3, GetFloat(wk .. "cooldown") + delay)
		end
		-- (the press, from InputDown's edge as Mochi's laser reads it on the server; InputPressed too)
		VL.downs = VL.downs or {}
		local down = InputDown("usetool", p)
		local pressed = (down and not VL.downs[p]) or InputPressed("usetool", p)
		VL.downs[p] = down
		if dmg and pressed and GetPlayerHealth(p) > 0 and now > (VL.swings[p] and VL.swings[p].nextT or 0) then
			local kb = GetFloat(wk .. "knockback")
			VL.swings[p] = {t = now + delay, dmg = dmg, reach = reach, nextT = now + cool, pending = true, inv = power > 0,
				knock = kb > 0 and kb or (tool == "sledge" and 6 or nil)}
		end
		local sw = VL.swings[p]
		if sw and sw.pending and now >= sw.t and not (sw.inv and GetBool("inventory.melee.hits")) then
			sw.pending = false
			local e = GetPlayerEyeTransform(p)
			local fwd = QuatRotateVec(e.rot, Vec(0, 0, -1))
			-- (the sight check starts in front of the face and ignores the player's own tool: from the eye the ray hit
			--  the sledge / sword itself, and no swing ever counted)
			local from = VecAdd(e.pos, VecScale(fwd, 0.35))
			local tb = GetToolBody and GetToolBody(p) or 0
			local best, bd = nil, sw.reach
			for _, V in ipairs(VL.all) do
				if V.alive then
					local c = VecAdd(V.posture == "lie" and V.lie and V.lie.pos or V.w.pos, Vec(0, V.posture == "lie" and 0.3 or 1.1, 0))
					local to = VecSub(c, e.pos)
					local dd = VecLength(to)
					if dd < bd and VecDot(VecScale(to, 1 / math.max(dd, 0.01)), fwd) > 0.45
						and (dd < 1.0 or VlPerceive.clear(from, c, tb ~= 0 and tb or nil)) then best, bd = V, dd end
				end
			end
			VL.swingN = (VL.swingN or 0) + 1                                   -- (counts for the TEST overlay)
			if best then
				VL.blowN = (VL.blowN or 0) + 1
				VlBrain.knockNext = sw.knock
				VlBrain.hurt(best, sw.dmg, GetPlayerName(p), GetPlayerTransform(p).pos, VecAdd(best.w.pos, Vec(0, 1.2, 0)))
			end
		end
	end
	-- exact melee hits from the Inventory mod (built 2026-11-15, commit f6d8fd77): inventory.melee.hit.last + .<n % 16>.shape
	-- / .x .y .z / .attacker / .power / .knockback / .dir.* / .swing. One swing lands as several events (4-12 on one
	-- box in its test): the damage once per (swing, villager)
	local last = GetInt("inventory.melee.hit.last")
	VL.meleeSeen = VL.meleeSeen or last
	VL.swingHit = VL.swingHit or {}
	while VL.meleeSeen < last do
		VL.meleeSeen = VL.meleeSeen + 1
		local k = "inventory.melee.hit." .. (VL.meleeSeen % 16) .. "."
		local V = VL.byShape and VL.byShape[GetInt(k .. "shape")]
		local key = GetInt(k .. "swing") .. ":" .. tostring(V and V.id)
		if V and V.alive and not VL.swingHit[key] then
			VL.swingHit[key] = now
			local a = GetInt(k .. "attacker")
			local pt = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z"))
			local dir = Vec(GetFloat(k .. "dir.x"), 0, GetFloat(k .. "dir.z"))
			local valid = a > 0 and IsPlayerValid(a)
			local from = valid and GetPlayerTransform(a).pos or (VecLength(dir) > 0.01 and VecSub(V.w.pos, dir) or nil)
			local kb = GetFloat(k .. "knockback")
			VlBrain.knockNext = kb > 0 and kb or nil
			VlBrain.hurt(V, math.max(5, GetFloat(k .. "power") * 100), valid and GetPlayerName(a) or "Someone", from, pt)
		end
	end
	for key, t in pairs(VL.swingHit) do if now - t > 5 then VL.swingHit[key] = nil end end
	-- (the user, 2026-11-15: "villagers should be knocked back (ragdoll) and damaged by cars crashing into them") a vehicle
	-- moving at carHitSpeed or more whose body's bounds hold a villager, heading their way: damage by speed and mass, the
	-- driver named; thrown along the car's way and limp (a ragdoll) for ragdollFor s
	local okv, vehs = pcall(FindVehicles, "", true)
	for _, veh in ipairs(okv and vehs or {}) do
		local body = GetVehicleBody(veh)
		if body and body ~= 0 and IsHandleValid(body) then
			local vel = GetBodyVelocity(body)
			local speed = VecLength(vel)
			if speed >= VL_CFG.carHitSpeed then
				local lo, hi = GetBodyBounds(body)
				local mid = VecLerp(lo, hi, 0.5)
				for _, V in ipairs(VL.all) do
					if V.alive and not V.carried and now > (V.carHitT or 0) then
						local feet = V.posture == "lie" and V.lie and V.lie.pos or V.w.pos
						local c = VecAdd(feet, Vec(0, V.posture == "lie" and 0.2 or 0.9, 0))
						local inside = c[1] > lo[1] - 0.3 and c[1] < hi[1] + 0.3 and c[3] > lo[3] - 0.3 and c[3] < hi[3] + 0.3
							and c[2] > lo[2] - 0.2 and c[2] < hi[2] + 0.4
						if inside and VecDot(vel, VecSub(c, mid)) > 0 then
							V.carHitT = now + 1.0
							local mass = GetBodyMass(body) or 1500
							local dmg = (speed - VL_CFG.carHitSpeed + 1) * VL_CFG.carDamage * math.max(0.5, math.min(2, mass / 1500))
							local by = "a vehicle"
							for _, p in ipairs(GetAllPlayers()) do if GetPlayerVehicle(p) == veh then by = GetPlayerName(p) end end
							VlBrain.hurt(V, dmg, by, mid, c)
							if V.alive then
								-- thrown along the car's way (and off it), limp for a while
								local flat = Vec(vel[1], 0, vel[3])
								local away = VecSub(c, mid); away[2] = 0
								if VecLength(away) > 0.01 then flat = VecAdd(flat, VecScale(VecNormalize(away), speed * 0.3)) end
								V.knock = {vel = VecScale(flat, 0.8), untilT = now + 0.6}
								V.ragUntil = now + VL_CFG.ragdollFor
								V.ragN = (V.ragN or 0) + 1
								V.ragVel = VecAdd(VecScale(vel, 0.9), Vec(0, 2 + speed * 0.15, 0))
								if V.conv then VlBrain.endConv(V.conv) end
								VlNav.stop(V.w)
							end
						end
					end
				end
			end
		end
	end
	-- (the user, 2026-11-15: "flaming them should damage them") the blowtorch (the game's engine tool: no event of its
	-- own, and the hitboxes don't burn): a player firing it (use held, fuel left) at a villager within its flame's reach,
	-- in front of the nozzle and in sight, burns them - 2 health every 0.25 s
	if now > (VL.torchT or 0) then
		VL.torchT = now + 0.25
		for _, p in ipairs(GetAllPlayers()) do
			-- (the game's blowtorch while use is held with fuel left, or the McPuppet Tools Pack's own torch,
			--  "mctools_torch", which says mctools.torch.<p> while it burns)
			local tool = GetPlayerTool(p)
			local burning = GetBool("mctools.torch." .. p)
				or (tool == "blowtorch" and InputDown("usetool", p) and (GetToolAmmo("blowtorch", p) or 1) > 0)
			if burning and GetPlayerHealth(p) > 0 then
				local e = GetPlayerEyeTransform(p)
				local fwd = QuatRotateVec(e.rot, Vec(0, 0, -1))
				local best, bd = nil, VL_CFG.torchReach
				for _, V in ipairs(VL.all) do
					if V.alive then
						local base = V.posture == "lie" and V.lie and V.lie.pos or V.w.pos
						local c = VecAdd(base, Vec(0, V.posture == "lie" and 0.3 or 1.1, 0))
						local to = VecSub(c, e.pos)
						local d = VecLength(to)
						if d < bd and VecDot(VecScale(to, 1 / math.max(d, 0.01)), fwd) > 0.8
							and (d < 1.0 or VlPerceive.clear(VecAdd(e.pos, VecScale(fwd, 0.35)), c, GetToolBody and GetToolBody(p) or nil)) then
							best, bd = V, d
						end
					end
				end
				if best then
					VlBrain.hurt(best, VL_CFG.torchDamage, GetPlayerName(p), e.pos, VecAdd(e.pos, VecScale(fwd, bd)))
				end
			end
		end
	end
	-- fire: standing in flames burns
	if GetTime() > (VL.burnT or 0) then
		VL.burnT = GetTime() + 0.5
		for _, V in ipairs(VL.all) do
			if V.alive and VlLife.nearestFire(VecAdd(V.w.pos, Vec(0, 0.4, 0)), 0.9) then
				VlBrain.hurt(V, 4, "the fire", nil, VecAdd(V.w.pos, Vec(0, 0.6, 0)))
			end
		end
	end
	-- bleeding: a red stain under the badly hurt now and then (the world, so everyone sees it)
	if GetTime() > (VL.bloodT or 0) then
		VL.bloodT = GetTime() + 1.5
		for _, V in ipairs(VL.all) do
			if V.alive and V.hp < VL_CFG.bleedBelow then
				local at = V.posture == "lie" and V.lie and V.lie.pos or V.w.pos
				pcall(PaintRGBA, VecAdd(at, Vec((VlRand() - 0.5) * 0.4, 0.02, (VlRand() - 0.5) * 0.4)), 0.25, 0.35, 0.02, 0.02, 1, 0.6)
			end
		end
	end
end

-- ---------------------------------------------------------------- publishing (every machine draws them)
local function publish()
	local d = {}
	for i, V in ipairs(VL.all) do
		local post = "stand"
		local sp = V.w.speedNow or 0
		if not V.alive then post = "dead"
		elseif V.ragUntil and GetTime() < V.ragUntil then post = "rag"
		elseif V.posture == "lie" then post = "lie"
		elseif V.posture == "sit" and V.mode == "at" then post = "sit"
		elseif V.spraying then post = "spray"
		elseif sp > 2.4 then post = "run"
		elseif sp > 0.25 then post = "walk" end
		local fx, fz = V.w.fwd[1], V.w.fwd[3]
		if V.faceTo and (post == "stand" or post == "spray" or post == "sit") then fx, fz = V.faceTo[1], V.faceTo[3] end
		local e = {k = i, id = V.id, char = V.p.character, x = V.w.pos[1], y = V.w.pos[2], z = V.w.pos[3], fx = fx, fz = fz,
			post = post, spd = sp, talk = (V.talkUntil or 0) > GetTime(), ext = V.carrying == "extinguisher",
			name = V.name, hp = math.floor(V.hp + 0.5), hitN = V.hitN or 0, down = V.downed or nil,
			stag = V.knock and true or nil, sleep = V.asleep or nil}
		if post == "rag" and V.ragVel then e.ragN, e.rvx, e.rvy, e.rvz = V.ragN, V.ragVel[1], V.ragVel[2], V.ragVel[3] end
		if V.lastHit then e.bx, e.by, e.bz = V.lastHit[1], V.lastHit[2], V.lastHit[3] end
		if V.tending and V.tendAt then e.post = "kneel"; e.tx, e.ty, e.tz = V.tendAt[1], V.tendAt[2], V.tendAt[3] end
		if post == "lie" and V.lie then e.x, e.y, e.z, e.hx, e.hz = V.lie.pos[1], V.lie.pos[2], V.lie.pos[3], V.lie.head[1], V.lie.head[3] end
		if post == "sit" and V.sitPos then e.x, e.y, e.z = V.sitPos[1], V.sitPos[2], V.sitPos[3] end
		if post == "spray" and V.sprayAt then e.ax, e.ay, e.az = V.sprayAt[1], V.sprayAt[2], V.sprayAt[3] end
		if V.striking and GetTime() - V.striking < 0.35 then
			e.strike = true
			if V.strikeAt then e.kx, e.ky, e.kz = V.strikeAt[1], V.strikeAt[2], V.strikeAt[3] end
		end
		d[i] = e
	end
	VL.seq = VL.seq + 1
	shared.vl = {n = VL.seq, t = GetTime(), d = d, frozen = VL.frozen}
end

-- ---------------------------------------------------------------- server
-- the host's "Village life" option (options.lua): how often villagers decide and talk on their own
local PACE = {
	{think = 0, conv = 0},          -- Quiet: routine only, the AI answers when spoken to
	{think = 3, conv = 1},          -- Calm
	{think = 6, conv = 2},          -- Lively (default)
	{think = 10, conv = 3},         -- Bustling
}

function server.init()
	local pace = GetInt("savegame.mod.pace")
	if pace < 1 or pace > 4 then pace = 3 end
	VL_CFG.thinkPerMinute, VL_CFG.convPerMinute = PACE[pace].think, PACE[pace].conv
	VL_CFG.pace = pace
	local talk = GetInt("savegame.mod.talk")
	VL_CFG.talkLength = (talk >= 1 and talk <= 4) and talk or 2
	VlSeed(GetInt("savegame.mod.vl.seed") + 1)
	SetInt("savegame.mod.vl.seed", GetInt("savegame.mod.vl.seed") + 1)
	VL.t0 = GetTime()
end

function server.tick(dt)
	if VL_TEST and VL_TEST.serverTick then VL_TEST.serverTick(dt) end
	VlLife.tick(dt)
	if not VL.started then
		local ps = GetAllPlayers()
		if #ps > 0 and GetTime() > 1.0 and not VL.scanning then
			VL.scanning = true
			VlPlaces.start(GetPlayerTransform(ps[1]).pos)
		end
		if VL.scanning then
			VlPlaces.tick(dt)
			if VlPlaces.ready then
				VL.started = true
				VlNav.init({center = VlPlaces.center, radius = VL_CFG.placeRadius + 20})
				local lk = GetString("game.levelid")
				if lk == "" then lk = "map" end
				VL.levelKey = lk
				if VlMemory and VlMemory.init then pcall(VlMemory.init, lk) end
				-- (the cast was renamed 2026-11-14 for voice to text: memories and aims saved under the old names go)
				if GetInt("savegame.mod.vl.cast") < VL_CAST_VERSION then
					if VlMemory and VlMemory.wipe then pcall(VlMemory.wipe) end
					ClearKey("savegame.mod.vl." .. lk .. ".goals")
					SetInt("savegame.mod.vl.cast", VL_CAST_VERSION)
				end
				makeVillagers()
			end
		end
		return
	end
	VlNav.tick(dt)
	VlPerceive.tick(dt)
	VlApi.tick(dt)
	harm()
	if GetTime() > (VL.fireT or 0) then
		VL.fireT = GetTime() + 0.5
		for _, V in ipairs(VL.all) do
			local fp = VlLife.fireReflex(V)
			if fp then VlBrain.happen(V, "Flames right next to you! You jump back.", true) end
		end
	end
	-- no AI (Koetama not connected, or its budget ran out): everyone freezes where they are, nobody listens, the reason
	-- over their heads (vl_view); they carry on when it is back (the user, 2026-11-15)
	local prob = VlBrain.aiProblem()
	if prob ~= VL.frozen then
		VL.frozen = prob
		for _, V in ipairs(VL.all) do
			if prob then VlNav.stop(V.w) end
			if VlBrain.keys then pcall(VlBrain.keys, V) end
		end
	end
	if not VL.frozen then VlBrain.tick(dt) end
	-- the players never bump into the villagers' models (layer 32)
	if GetTime() > (VL.maskT or 0) then
		VL.maskT = GetTime() + 0.25
		for _, p in ipairs(GetAllPlayers()) do SetPlayerParam("CollisionMask", VL_RAYMASK, p) end
	end
	if GetTime() > VL.pubT then
		VL.pubT = GetTime() + 1 / 15
		publish()
	end
	if VlMemory and VlMemory.save and GetTime() > (VL.saveT or 0) then
		VL.saveT = GetTime() + 20
		for _, V in ipairs(VL.all) do pcall(VlMemory.save, V.id) end
	end
end

function server.update(dt)
	if not VL.started then return end
	for _, V in ipairs(VL.all) do
		local k = V.knock
		if k and V.alive then
			if GetTime() > k.untilT or V.downed then
				V.knock = nil
				V.planKey = nil                                             -- (back on their feet: walk on)
				if V.override and V.override.phase then V.override.phase = nil end
			else
				local step = VecScale(k.vel, dt)
				local L = VecLength(step)
				QueryCollisionMask(VL_RAYMASK)
				local hit = L > 0 and QueryRaycast(VecAdd(V.w.pos, Vec(0, 0.9, 0)), VecScale(step, 1 / L), L + 0.35)
				if not hit then
					local np = VecAdd(V.w.pos, step)
					QueryCollisionMask(VL_RAYMASK)
					local g, gd = QueryRaycast(VecAdd(np, Vec(0, 0.6, 0)), Vec(0, -1, 0), 1.6)
					if g then np[2] = np[2] + 0.6 - gd end
					VlNav.warp(V.w, np, V.w.fwd)
				end
				k.vel = VecScale(k.vel, math.max(0, 1 - 6 * dt))
			end
		end
		if not VL.frozen then VlLife.update(V, dt) end
		if V.alive and not VL.frozen and V.posture ~= "lie" and not (V.posture == "sit" and V.mode == "at") then
			VlNav.update(V.w, dt)
		end
		if V.faceTo and V.w.state ~= "walking" then V.w.fwd = V.faceTo end
	end
end

function server.postUpdate()
	if not VL.started then return end
	for _, V in ipairs(VL.all) do
		placeHitbox(V)
		if not anchorOk(V) then spawnAnchor(V) end
		if V.anchor then
			local base = V.posture == "lie" and V.lie and V.lie.pos or (V.posture == "sit" and V.sitPos) or V.w.pos
			local up = V.posture == "lie" and 0.6 or (V.posture == "sit" and 1.2 or 1.85)
			SetBodyTransform(V.anchor, Transform(VecAdd(base, Vec(0, up, 0))))
		end
	end
end

function server.destroy()
	VlBrain.destroy()
	for _, V in ipairs(VL.all) do
		if VlMemory and VlMemory.save then pcall(VlMemory.save, V.id, true) end
	end
end

-- ---------------------------------------------------------------- client
function client.init() VlView.init() end
function client.tick(dt) VlView.tick(dt); if VL_TEST and VL_TEST.clientTick then VL_TEST.clientTick(dt) end end
function client.postUpdate(dt) VlView.postUpdate(dt) end
function client.render(dt) VlView.render(dt) end
function client.draw() VlView.draw(); if VL_TEST and VL_TEST.clientDraw then VL_TEST.clientDraw() end end
