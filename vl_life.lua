-- Villagers: the clock and each villager's day. A villager V (server) wants to be somewhere by the hour (asleep in
-- bed, at breakfast at home, at work, on a break, out in the evening); the LLM can override that for a while (go
-- somewhere, follow someone, stay, put out a fire, run away). VlNav walks them; VlPlaces gives the spots.
-- (no #version line: included by main.lua)

VlLife = {}

-- ---------------------------------------------------------------- the clock
local clk = {own = false, hour = 8, day = 1, lastT = nil, dnTime = nil, dnAt = 0}

function VlLife.hasDayNight() return GetBool("daynight.present") and GetBool("daynight.active") end

function VlLife.tick(dt)
	if GetBool("daynight.present") then
		clk.own = false
		local t = GetFloat("daynight.time")
		if t ~= clk.dnTime then clk.dnTime, clk.dnAt = t, GetTime() end
		local h = t + GetFloat("daynight.rate") * math.min(1.5, GetTime() - clk.dnAt)
		clk.hour = h % 24
		clk.day = math.max(1, GetInt("daynight.day"))
	else
		-- no Day & Night: our own clock (its default pace: 9 min of daylight, 6 of night) - the sky won't change
		clk.own = true
		local rate = (clk.hour >= 5.25 and clk.hour < 18.75) and (13.5 / VL_CFG.ownDaySec) or (10.5 / VL_CFG.ownNightSec)
		clk.hour = clk.hour + rate * dt
		if clk.hour >= 24 then clk.hour = clk.hour - 24; clk.day = clk.day + 1 end
	end
end

function VlLife.hour() return clk.hour end
function VlLife.secPerHour()
	if not clk.own then
		local r = GetFloat("daynight.rate")
		if r > 0 then return 1 / r end
	end
	local day = clk.hour >= 5.25 and clk.hour < 18.75
	return day and (VL_CFG.ownDaySec / 13.5) or (VL_CFG.ownNightSec / 10.5)
end
function VlLife.setHour(h) clk.hour = h % 24 end           -- (our own clock only; tests and a host command)
function VlLife.day() return clk.day end
function VlLife.ownClock() return clk.own end
function VlLife.night()
	if not clk.own then return GetBool("daynight.night") end
	return clk.hour < 5.25 or clk.hour >= 18.75
end
-- the date: Day & Night's calendar (daynight.date, asked of it 2026-11-14) when it publishes one, else "day N"
function VlLife.dateText()
	-- (Day & Night's calendar, built 2026-11-14: daynight.date "Sunday, 1 March", daynight.season, per map, kept
	--  across sessions; changes at midnight)
	local d = GetBool("daynight.present") and GetString("daynight.date") or ""
	if d ~= "" then
		local season = GetString("daynight.season")
		return season ~= "" and (d .. ", " .. season) or d
	end
	return "day " .. clk.day
end

-- (the user, 2026-11-14: "timestamp every line using the day night mod if it's present") "[day 3, 14:20]"
function VlLife.stamp()
	local h = clk.hour
	return string.format("[%s, %02d:%02d]", VlLife.dateText(), math.floor(h), math.floor((h % 1) * 60))
end

function VlLife.clockText()
	local h = clk.hour
	local hh, mm = math.floor(h), math.floor((h % 1) * 60)
	local part = h < 5 and "night" or (h < 9 and "morning" or (h < 12 and "late morning" or (h < 14 and "midday" or
		(h < 18 and "afternoon" or (h < 21 and "evening" or "night")))))
	return string.format("%02d:%02d, %s, %s", hh, mm, part, VlLife.dateText())
end

-- is hour h inside [a, b) on a 24 h circle
local function within(h, a, b)
	if a <= b then return h >= a and h < b end
	return h >= a or h < b
end

-- ---------------------------------------------------------------- what a villager wants now
local DOING = {
	smithy = "working at the forge", farm = "working the field", field = "working the field", tavern = "serving at the tavern",
	chapel = "tending the chapel", shop = "minding the shop", water = "fishing at the water's edge", patrol = "walking the rounds",
	home = "doing chores at home", workshop = "working in the workshop",
}

function VlLife.workPlace(V)
	local wk = V.p.workKind
	if wk == "farm" then wk = "field" end
	if wk == "home" then return VlPlaces.home(V.p) end
	return VlPlaces.byId[wk] or VlPlaces.ofKind(wk) or VlPlaces.home(V.p)
end

local function socialPlace(V)
	local s = V.p.schedule and V.p.schedule.social or "tavern"
	if s == "home" then return VlPlaces.home(V.p) end
	return VlPlaces.ofKind(s) or VlPlaces.ofKind("tavern") or VlPlaces.ofKind("square") or VlPlaces.home(V.p)
end

-- the plan for hour h: {kind, place, label}
function VlLife.want(V, h)
	local sc = V.p.schedule or {}
	local j = V.jitter or 0
	local wake, sleep = (sc.wake or 6.5) + j, (sc.sleep or 22) + j
	local w0, w1 = (sc.work and sc.work[1] or 8) + j, (sc.work and sc.work[2] or 17) + j
	if V.sleepNow or within(h, sleep % 24, wake % 24) then
		return {kind = "sleep", place = VlPlaces.home(V.p), label = "asleep in bed"}
	end
	if within(h, w0, w1) then
		if V.lunch and within(h, 12.25, 13.0) then
			local pl = VlPlaces.ofKind(V.lunch) or VlPlaces.ofKind("square")
			if pl then return {kind = "break", place = pl, label = "on a midday break at " .. pl.name} end
		end
		local pl = VlLife.workPlace(V)
		return {kind = "work", place = pl, label = DOING[V.p.workKind] or ("working as " .. (V.p.job or "a villager"))}
	end
	if within(h, wake, w0) then
		return {kind = "home", place = VlPlaces.home(V.p), label = "having breakfast at home"}
	end
	local pl = socialPlace(V)
	return {kind = "social", place = pl, label = pl and ("spending the evening at " .. pl.name) or "out for the evening"}
end

-- a new day: each villager's own small differences (session dice: VlRand)
function VlLife.newDay(V)
	V.jitter = (VlRand() - 0.5) * 0.8
	V.lunch = ({"tavern", "square", nil})[VlRand(3)]
end

-- ---------------------------------------------------------------- the machine
-- V.mode: "go" (walking to V.spot) | "at" (at the spot: posture) | "engaged" (talking: stands, faces someone)
-- V.override = {kind = "goto"|"follow"|"stay"|"fire"|"flee"|"fetch", until = GetTime() + s, ...}

local function face(V, pos)
	local d = VecSub(pos, V.w.pos)
	d[2] = 0
	if VecLength(d) > 0.05 then V.faceTo = VecNormalize(d) end
end

local function goSpot(V, place, spot, speed)
	V.place, V.spot = place, spot
	V.posture = "stand"
	V.mode = "go"
	V.arriveFace = spot and spot.face
	local target = spot and spot.pos or (place and (place.inside or place.pos))
	if not target then V.mode = "at"; return end
	V.target = target
	VlNav.goTo(V.w, target, {speed = speed or VlLife.speedOf(V), arrive = 0.5})
end

local function settle(V)
	V.mode = "at"
	V.atSince = GetTime()
	V.nextShift = GetTime() + 25 + VlRand() * 60
	local s = V.spot
	if V.plan and V.plan.kind == "sleep" then
		local bed = VlPlaces.bed(V.p, V.id)
		if bed then
			local pos, head = VlPlaces.bedPose(bed, V.k % 2 == 0 and 1 or -1)
			V.lie = {pos = pos, head = head, floor = VecCopy(V.w.pos)}
		elseif (VlPlaces.indoorAt(V.w.pos, 0.6) and V.place and V.place.building and VlPlaces.buildingAt(V.w.pos) == V.place.building
				and VlPlaces.enclosedAt(V.w.pos))
			or (V.place and V.place.kind == "camp") then
			V.lie = {pos = VecCopy(V.w.pos), head = V.w.fwd, floor = VecCopy(V.w.pos)}   -- (no bed: the floor, or a bedroll)
		else
			-- (the user, 2026-11-15: "if villagers can't find a spare bed or a surface to lie down on, they just sit down
			-- to sleep") no bed and nowhere fit to lie (not inside their own home): they nod off sitting - on the chair
			-- of their spot if it has one, else on the ground where they are
			V.posture = "sit"
			if s and s.posture == "sit" then
				V.sitPos = VecCopy(s.pos)
				if s.body and IsHandleValid(s.body) then
					local lo, hi = GetBodyBounds(s.body)
					V.sitPos = Vec((lo[1] + hi[1]) / 2, lo[2] + 0.45, (lo[3] + hi[3]) / 2)
				end
			else
				V.sitPos = VecAdd(V.w.pos, Vec(0, 0.15, 0))
			end
			V.asleep = true
			return
		end
		V.posture = "lie"
		V.asleep = true
		return
	end
	if s and s.posture == "sit" then
		V.posture = "sit"
		V.sitPos = VecCopy(s.pos)
		if s.body and IsHandleValid(s.body) then
			local lo, hi = GetBodyBounds(s.body)
			V.sitPos = Vec((lo[1] + hi[1]) / 2, lo[2] + 0.45, (lo[3] + hi[3]) / 2)
		end
	else
		V.posture = "stand"
	end
	if V.place and V.place.inside and V.posture == "stand" then face(V, V.place.inside) end
end

local function wakeUp(V)
	if V.posture == "lie" then
		V.posture = "stand"
		if V.lie then VlNav.warp(V.w, V.lie.floor or V.w.pos) end
		V.lie = nil
	elseif V.posture == "sit" and V.asleep then
		V.posture = "stand"                                 -- (dozed off sitting: up again)
	end
	V.asleep = false
end

-- a villager's step (server.update rate is fine; VlNav.update moves the walker separately)
function VlLife.update(V, dt)
	if not V.alive then return end
	if V.carried then return end                           -- (held by another mod's creature: vl_api.lua places them)
	if V.ragUntil then                                     -- (thrown by a car: limp until ragUntil, then up again)
		if GetTime() < V.ragUntil then return end
		V.ragUntil = nil
		V.planKey = nil
		V.thinkDue = true
	end
	if V.downed then
		if V.hp >= VL_CFG.downAbove then VlBrain.recover(V) else return end
	end
	local now = GetTime()
	local h = clk.hour
	-- a day changed: new dice
	if V.dayDone ~= clk.day then V.dayDone = clk.day; VlLife.newDay(V) end
	-- overrides from the LLM or the game end by themselves
	local o = V.override
	if V.asleep and V.hp < 100 then V.hp = math.min(100, V.hp + VL_CFG.sleepHeal * dt) end   -- (a night's sleep mends a little)
	if o and o.untilT and now > o.untilT then
		if o.kind == "tend" then
			if o.villager then o.villager.tendedBy = nil end
			V.tending, V.tendAt = nil, nil
		end
		V.override = nil; o = nil; V.planKey = nil
		V.thinkDue = true                                   -- (what they chose to do is done: they decide again)
	end
	-- (the user: they sleep at night) an hour and a half past their bedtime they go to bed whatever they chose;
	-- their own "sleep" ends when their morning comes
	local sc = V.p.schedule or {}
	local bed, wake = ((sc.sleep or 22) + (V.jitter or 0) + 1.5) % 24, ((sc.wake or 6.5) + (V.jitter or 0)) % 24
	if o and within(h, bed, wake) and o.kind ~= "fire" and o.kind ~= "fetch" and o.kind ~= "flee" and not V.engaged then
		V.override = nil; o = nil; V.planKey = nil
	end
	if V.sleepNow and within(h, wake, (wake + 1) % 24) then V.sleepNow = nil; V.planKey = nil end
	-- someone is talking with them: stand and face them (asleep: they wake when the brain says so)
	if V.engaged and now < V.engaged.untilT and not V.asleep then
		if V.mode ~= "engaged" then
			V.mode = "engaged"
			VlNav.stop(V.w)
			if V.posture == "lie" then wakeUp(V) end
		end
		local tp = V.engaged.pos and V.engaged.pos()
		if tp then face(V, tp) end
		return
	elseif V.mode == "engaged" then
		V.engaged = nil
		V.planKey = nil
	end
	if o then return VlLife.overrideStep(V, o, dt) end
	-- the plan by the hour; a new plan (or the place changed) sends them off
	local plan = VlLife.want(V, h)
	local key = plan.kind .. ":" .. tostring(plan.place and plan.place.id)
	if key ~= V.planKey then
		V.planKey = key
		V.plan = plan
		if plan.kind ~= "sleep" and V.asleep then wakeUp(V) end
		VlPlaces.release(V.id)
		local want = (plan.kind == "social" or plan.kind == "break") and "sit" or nil
		local spot = plan.place and VlPlaces.claim(plan.place, V.id, want)
		goSpot(V, plan.place, spot)
		return
	end
	if V.mode == "go" then
		if V.w.state == "arrived" then settle(V)
		elseif V.w.state == "failed" then
			V.failN = (V.failN or 0) + 1
			if V.failN >= 2 and V.target and not VlLife.seen(V.w.pos) and not VlLife.seen(V.target) then
				-- (seen in game: some routes in a real map can't be found) nobody is looking: they get there unseen
				VlNav.warp(V.w, V.target)
				V.failN = 0
				settle(V)
			elseif V.failN > 3 then settle(V); V.failN = 0     -- (stays where it got to)
			else goSpot(V, V.place, V.spot) end
		end
		return
	end
	-- at the spot: now and then another spot at the same place (patrols always walk on)
	if V.mode == "at" and not V.asleep and V.place and now > (V.nextShift or 0) then
		if V.place.kind == "patrol" or VlRand() < 0.5 then
			VlPlaces.release(V.id)
			local spot = VlPlaces.claim(V.place, V.id, V.posture == "sit" and "sit" or nil)
			goSpot(V, V.place, spot)
		else
			V.nextShift = now + 30 + VlRand() * 60
		end
	end
end

-- can a player see this point (near enough and a clear line from their eyes)?
function VlLife.seen(p)
	for _, pl in ipairs(GetAllPlayers()) do
		local e = GetPlayerEyeTransform(pl).pos
		local d = VecLength(VecSub(p, e))
		if d < 12 then return true end
		if d < 70 then
			QueryCollisionMask(255 - 32 - 64)
			local to = VecSub(VecAdd(p, Vec(0, 1.2, 0)), e)
			local L = VecLength(to)
			local hit = QueryRaycast(e, VecScale(to, 1 / L), L - 0.3)
			if not hit then return true end
		end
	end
	return false
end

-- walking speed by health (the user: "they should look weak")
function VlLife.speedOf(V, run)
	local s = run and VL_CFG.runSpeed or VL_CFG.walkSpeed
	if V.hp < VL_CFG.bleedBelow then s = math.min(s, VL_CFG.walkSpeed) * 0.55 end
	return s
end

-- ---------------------------------------------------------------- overrides
function VlLife.setOverride(V, o)
	if V.asleep then wakeUp(V) end
	-- (something to do now: no longer standing there talking; a fight, a chase or a flight leaves the talk)
	if o.kind ~= "stay" then V.engaged = nil; V.mode = "override" end
	if V.conv and (o.kind == "fight" or o.kind == "flee" or o.kind == "tend" or (o.kind == "follow" and o.chase)) and VlBrain then
		VlBrain.leaveConv(V)
	end
	VlPlaces.release(V.id)
	V.override = o
	o.started = GetTime()
	o.phase = nil
	V.planKey = nil
	V.mode = "override"
end

function VlLife.overrideStep(V, o, dt)
	local now = GetTime()
	if o.kind == "stay" then
		if o.phase == nil then VlNav.stop(V.w); o.phase = "stay"; V.posture = "stand" end
		return
	end
	if o.kind == "goto" then
		if o.phase == nil then
			o.phase = "walk"
			if o.place then
				o.spot = VlPlaces.claim(o.place, V.id, o.sit and "sit" or nil)
				o.pos = o.spot and o.spot.pos or (o.place.inside or o.place.pos)
			end
			V.posture = "stand"
			VlNav.goTo(V.w, o.pos, {speed = VlLife.speedOf(V, o.run), arrive = o.spot and 0.5 or 0.8})
		elseif (V.w.state == "arrived" or V.w.state == "failed") and o.phase == "walk" then
			o.phase = "there"
			o.untilT = math.min(o.untilT or now + 60, now + (o.stayFor or 60))
			if o.spot and o.spot.posture == "sit" and V.w.state == "arrived" then
				V.posture = "sit"
				V.mode = "at"
				V.sitPos = VecCopy(o.spot.pos)
				if o.spot.body and IsHandleValid(o.spot.body) then
					local lo, hi = GetBodyBounds(o.spot.body)
					V.sitPos = Vec((lo[1] + hi[1]) / 2, lo[2] + 0.45, (lo[3] + hi[3]) / 2)
				end
			end
		end
		return
	end
	if o.kind == "follow" then
		local tp = o.pos and o.pos()
		if not tp then V.override = nil; return end
		local d = VecLength(VecSub(tp, V.w.pos))
		if d > 3 and (not o.lastGoal or VecLength(VecSub(o.lastGoal, tp)) > 1.5 or V.w.state ~= "walking") then
			o.lastGoal = VecCopy(tp)
			VlNav.goTo(V.w, tp, {speed = VlLife.speedOf(V, o.chase or d > 8), arrive = o.chase and 1.4 or 2.2})
		elseif d <= 2.4 and V.w.state == "walking" then
			VlNav.stop(V.w)
		end
		face(V, tp)
		return
	end
	if o.kind == "flee" then
		if o.phase == nil or (V.w.state ~= "walking" and V.w.state ~= "planning") then
			local from = o.from or V.w.pos
			local away = VecSub(V.w.pos, from)
			away[2] = 0
			if VecLength(away) < 0.1 then away = Vec(VlRand() - 0.5, 0, VlRand() - 0.5) end
			away = VecNormalize(away)
			if VecLength(VecSub(V.w.pos, from)) > (o.dist or 18) then
				o.untilT = math.min(o.untilT or now + 5, now + 5)
				return
			end
			o.phase = "run"
			VlNav.goTo(V.w, VecAdd(V.w.pos, VecScale(away, 9)), {speed = VlLife.speedOf(V, true), arrive = 1.5})
		end
		return
	end
	if o.kind == "fetch" or o.kind == "fire" then return VlLife.fireStep(V, o, dt) end
	if o.kind == "tend" then return VlLife.tendStep(V, o, dt) end
	if o.kind == "fight" then return VlLife.fightStep(V, o, dt) end
end

-- ---------------------------------------------------------------- fighting: run at them, swing when in reach
local function endFight(V, o, why)
	V.override = nil
	V.planKey = nil
	V.thinkDue = true
	if why and VlBrain then VlBrain.happen(V, why, true) end
end

function VlLife.fightStep(V, o, dt)
	local now = GetTime()
	local T = o.villager
	if V.downed then return endFight(V, o) end
	if T and (not T.alive) then return endFight(V, o, T.name .. " is dead.") end
	if T and T.downed and not o.once then return endFight(V, o, T.name .. " has collapsed and can't fight any more.") end
	if o.player and (not IsPlayerValid(o.player) or GetPlayerHealth(o.player) <= 0) then return endFight(V, o, (o.who or "They") .. " is down.") end
	if o.thing and VlApi and not VlApi.thingById(o.thing.id) then return endFight(V, o, (o.who or "It") .. " is gone.") end
	local tp = o.pos and o.pos()
	if not tp then return endFight(V, o) end
	local d = VecLength(VecSub(tp, V.w.pos))
	if d > VL_CFG.fightLose then return endFight(V, o, (o.who or "They") .. " got away from you.") end
	if d > VL_CFG.punchReach then
		if V.w.state ~= "walking" and V.w.state ~= "planning" or not o.goal or VecLength(VecSub(o.goal, tp)) > 1.0 then
			o.goal = VecCopy(tp)
			VlNav.goTo(V.w, tp, {speed = VlLife.speedOf(V, true), arrive = VL_CFG.punchReach * 0.8})
		end
		return
	end
	if V.w.state == "walking" then VlNav.stop(V.w) end
	face(V, tp)
	if now >= (o.nextBlow or 0) then
		o.nextBlow = now + VL_CFG.punchEvery * (0.8 + 0.4 * VlRand())
		VlBrain.blow(V, o)
		o.blows = (o.blows or 0) + 1
		if o.once then return endFight(V, o) end
	end
end

-- ---------------------------------------------------------------- bandaging (the user, 2026-11-14: "an action to heal
-- each other (bandaging animation, and it heals slowly)") over to the patient, kneel by them (the clients: crouched,
-- the right hand working at the patient's chest), VL_CFG.healRate a second until they are well or the time is up
local function stopTend(V, o)
	if o.villager then o.villager.tendedBy = nil end
	V.tending, V.tendAt = nil, nil
	V.override = nil
	V.planKey = nil
	V.thinkDue = true
end

function VlLife.tendStep(V, o, dt)
	local now = GetTime()
	local P = o.villager
	if (P and not P.alive) or (o.player and (not IsPlayerValid(o.player) or GetPlayerHealth(o.player) <= 0)) then return stopTend(V, o) end
	local tp = o.pos and o.pos()
	if not tp then return stopTend(V, o) end
	local at = (P and P.posture == "lie" and P.lie) and P.lie.pos or tp
	local d = VecLength(VecSub(at, V.w.pos))
	if d > 1.4 then
		V.tending, V.tendAt = nil, nil
		if P and P.tendedBy == V.name then P.tendedBy = nil end
		if V.w.state ~= "walking" and V.w.state ~= "planning" or not o.goal or VecLength(VecSub(o.goal, at)) > 1.0 then
			o.goal = VecCopy(at)
			VlNav.goTo(V.w, at, {speed = VlLife.speedOf(V, true), arrive = 1.1, keepAway = 0.6})
		end
		if V.w.state == "failed" and now - (o.failT or 0) > 3 then
			o.failT = now
			o.fails = (o.fails or 0) + 1
			if o.fails > 3 then return stopTend(V, o) end
		end
		return
	end
	if V.w.state == "walking" then VlNav.stop(V.w) end
	face(V, at)
	if not V.tending then
		V.tending = {who = o.who, since = now}
		o.untilT = now + VL_CFG.tendFor
		if P then
			P.tendedBy = V.name
			VlBrain.happen(P, V.name .. " kneels by you and bandages your wounds.", true,
				{text = V.name .. " bandaged my wounds", who = {V.name}, importance = 4, kind = "event", feel = 2})
		end
	end
	V.tendAt = VecAdd(at, Vec(0, P and P.posture == "lie" and 0.25 or 1.1, 0))
	if P then
		P.hp = math.min(100, P.hp + VL_CFG.healRate * dt)
		if P.hp >= 95 then return stopTend(V, o) end
	elseif o.player then
		local h = GetPlayerHealth(o.player)
		SetPlayerHealth(math.min(1, h + VL_CFG.healRate * 0.01 * dt), o.player)
		if h >= 0.98 then return stopTend(V, o) end
	end
end

-- ---------------------------------------------------------------- fire
-- Villagers are wary of fire: within 3 m of flames they step back on their own. Putting a fire out: a villager
-- with an extinguisher walks up to it (1.3-2.2 m off), sprays (the clients draw the spray) and the server removes the
-- fires in front of the nozzle; without one they first fetch one from the nearest house, tavern or workshop.

function VlLife.nearestFire(pos, dist)
	local ok, hit, fp = pcall(QueryClosestFire, pos, dist)
	if ok and hit then return fp end
	return nil
end

local function extinguisherPlace(V)
	local best, bd = nil, math.huge
	for _, p in ipairs(VlPlaces.list) do
		if p.indoor and p.kind ~= "chapel" then
			local d = VecLength(VecSub(p.pos, V.w.pos))
			if d < bd then best, bd = p, d end
		end
	end
	return best, bd
end

function VlLife.putOutFire(V, firePos)
	if V.carrying ~= "extinguisher" and VlBrain and VlBrain.hasExtinguisher(V) then V.carrying = "extinguisher" end
	if V.carrying ~= "extinguisher" then
		local pl, d = extinguisherPlace(V)
		if not pl or d > 60 then return false, "no extinguisher anywhere near" end
		VlLife.setOverride(V, {kind = "fetch", place = pl, fire = VecCopy(firePos), untilT = GetTime() + 90})
		return true, "fetching the extinguisher from " .. pl.name
	end
	VlLife.setOverride(V, {kind = "fire", fire = VecCopy(firePos), untilT = GetTime() + 60})
	return true, "going to put it out"
end

function VlLife.fireStep(V, o, dt)
	local now = GetTime()
	if o.kind == "fetch" then
		if o.phase == nil then
			o.phase = "walk"
			VlNav.goTo(V.w, o.place.inside or o.place.pos, {speed = VL_CFG.runSpeed, arrive = 1.0})
		elseif V.w.state == "arrived" or V.w.state == "failed" then
			V.carrying = "extinguisher"
			V.override = {kind = "fire", fire = o.fire, untilT = now + 60, started = now}
		end
		return
	end
	-- the fire may have moved on: the nearest flames to where it was
	if not o.checkT or now > o.checkT then
		o.checkT = now + 0.5
		local fp = VlLife.nearestFire(o.fire, 6)
		if not fp then
			V.spraying = false
			o.out = (o.out or 0) + 1
			if o.out >= 3 then
				V.override = nil
				V.planKey = nil
				V.fireOut = now
				return
			end
		else
			o.out = 0
			o.fire = fp
		end
	end
	local d = VecLength(VecSub(o.fire, V.w.pos))
	-- (the user, 2026-11-15, asked whether they put out fires from across the map: no - only within 2.4 m; and since
	--  then only with a clear line from the nozzle to the flames, not through a wall)
	local eye = VecAdd(V.w.pos, Vec(0, 1.2, 0))
	local blocked = d <= 2.4 and not VlPerceive.clearNear(eye, VecAdd(o.fire, Vec(0, 0.2, 0)), nil, 0.8)   -- (a hit on the burning thing itself counts)
	if blocked then o.blockedT = now + 5 end
	if d > 2.4 then blocked = blocked or now < (o.blockedT or 0) end     -- (held a while: no flipping at the edge)
	if d > 2.4 or blocked then
		V.spraying = false
		-- blocked (a wall between them, though near): closer, round by the door if need be
		local arrive = blocked and 0.9 or 1.9
		if o.phase ~= "approach" or o.arrive ~= arrive or not o.goal or VecLength(VecSub(o.goal, o.fire)) > 1
			or (V.w.state ~= "walking" and V.w.state ~= "planning" and now > (o.retryT or 0)) then
			o.phase, o.arrive, o.retryT = "approach", arrive, now + 2
			o.goal = VecCopy(o.fire)
			VlNav.goTo(V.w, o.fire, {speed = VL_CFG.runSpeed, arrive = arrive, keepAway = blocked and 0.4 or 1.3})
		end
	else
		if V.w.state == "walking" then VlNav.stop(V.w) end
		o.phase = "spray"
		face(V, o.fire)
		V.spraying = true
		V.sprayAt = VecCopy(o.fire)
		-- the spray: fires in a box in front of them, 0.5 s at a time
		if not o.sprayT or now > o.sprayT then
			o.sprayT = now + 0.5
			local r = VL_CFG.sprayRadius
			pcall(RemoveAabbFires, VecSub(o.fire, Vec(r, r, r)), VecAdd(o.fire, Vec(r, r, r)))
		end
	end
end

-- the reflex: too close to flames -> a few steps back (not while fighting the fire)
function VlLife.fireReflex(V)
	if not V.alive or V.asleep then return end
	local o = V.override
	if o and (o.kind == "fire" or o.kind == "fetch" or o.kind == "flee") then return end
	local fp = VlLife.nearestFire(V.w.pos, 3)
	if fp then
		VlLife.setOverride(V, {kind = "flee", from = fp, dist = 6, untilT = GetTime() + 8})
		return fp
	end
end

-- ---------------------------------------------------------------- for the state text
function VlLife.doingText(V)
	if not V.alive then return "dead" end
	if V.downed then return "lying collapsed on the ground" end
	if V.asleep then return "asleep in bed" end
	local o = V.override
	if o then
		if o.kind == "fire" then return o.phase == "spray" and "spraying the fire with an extinguisher" or "running to the fire with an extinguisher" end
		if o.kind == "fetch" then return "running to fetch the fire extinguisher from " .. (o.place and o.place.name or "nearby") end
		if o.kind == "flee" then return "running away" end
		if o.kind == "tend" then return V.tending and ("kneeling by " .. (o.who or "someone") .. ", bandaging their wounds") or ("hurrying to bandage " .. (o.who or "someone")) end
		if o.kind == "follow" then return (o.chase and "chasing " or "following ") .. (o.who or "someone") end
		if o.kind == "fight" then return "fighting " .. (o.who or "someone") end
		if o.kind == "stay" then return "waiting here, as you decided" end
		if o.kind == "goto" and o.activity then
			local where = o.place and o.place.name or "somewhere"
			return (o.phase == "there" and "" or "on the way to ") .. (o.label or "busy") .. (o.phase == "there" and (" (" .. where .. ")") or (", at " .. where))
		end
		if o.kind == "goto" then return (o.phase == "there" and "at " or "walking to ") .. (o.label or "somewhere") end
	end
	if V.mode == "engaged" then return "talking" end
	local plan = V.plan
	if not plan then return "standing about" end
	if V.mode == "go" then return "on the way: " .. plan.label end
	if V.posture == "sit" then return plan.label .. ", sitting" end
	return plan.label
end
