-- Villagers' API for other mods: host registry keys (the guide for mod makers: API.md, shipped with the mod).
-- (the user, 2026-11-15: "APIs ... that lets other mods indicate what creatures or things the villagers should fear,
-- love, hate, etc" + other ways to interact)
--   in:  villagers.kind.<k>.*   what a kind of creature / thing is (description, baseline danger); each villager decides
--                               how they feel about it with their own model (feel_about / feel_about_creature)
--        bodies tagged vlkind=<k>, or villagers.thing.<id>.*   where the creatures / things are
--        villagers.item.<id>.*   how villagers feel about an item someone holds or wears
--        villagers.news.<n % 16>.*, villagers.news.last   something happened (seen / heard / smelled / told)
--        villagers.tell.<villager id | all>   a private word to a villager (quests, game modes)
--        villagers.hurt.<n % 16>.*, villagers.hurt.last   damage to a villager from another mod
--        villagers.carry.<id>.x/.y/.z/.by   a creature holds / drags a villager (cleared: let go)
--        villagers.slow.<id>.factor/.until   webs and the like slow a villager's walking
--   out: villagers.present, villagers.version, villagers.list, villagers.v.<id>.*   who and where the villagers are
--        villagers.strike.<n % 16>.*, villagers.strike.last   a villager hit one of your creatures
--        villagers.feel.<villager id>.<k>, villagers.fear.<villager id>.<k>   each villager's own feeling and fear

VlApi = VlApi or {things = {}, kinds = {}}
local VA = VlApi
VA.VERSION = 1

-- a feeling word -> how it reads to the villager (sense lists, events); anything else is shown as "you feel <word>"
VA.FEELS = {
	fear = "you fear it", hate = "you hate it", love = "you love it", like = "you like it", wary = "you are wary of it",
	curious = "you are curious about it", revere = "you revere it", disgust = "it disgusts you", pity = "you pity it",
	covet = "you want it", ignore = nil,
}
function VA.feelText(f)
	if not f or f == "" or f == "ignore" then return nil end
	return VA.FEELS[f] or ("you feel " .. f .. " about it")
end

local function num(k, d) return HasKey(k) and GetFloat(k) or d end
local function str(k) return HasKey(k) and GetString(k) or "" end

-- a kind's definition (read fresh every refresh: mods may change them any time)
local function readKind(k)
	local b = "villagers.kind." .. k .. "."
	local name = str(b .. "name")
	if name == "" then return nil end
	local K = {id = k, name = name, note = str(b .. "note"), feel = str(b .. "feel"), danger = num(b .. "danger", 0),
		flee = num(b .. "flee", 0), sound = str(b .. "sound"), hear = num(b .. "hear", 0), doing = str(b .. "doing")}
	return K
end

-- (the user, 2026-11-15: "They should get a general description of the enemy/creature from the other mod and decide for
-- themselves (using LLM) whether they like it or not. The other mod can set a baseline fear value, but the LLM should
-- decide multipliers and bonuses") The other mod gives a description (.name, .note), a baseline danger and at most a
-- general reputation (.feel). How EACH villager feels about it, and how much they fear it, they decide themselves with
-- their own model on first meeting it (feel_about: a feeling, a multiplier on the baseline danger, a bonus), and may
-- reassess any time. Until then, or without the AI: the reputation (else a word from the danger), fear = danger
-- scaled by temper.
local FEEL_WORDS = {fear = 1, hate = 1, love = 1, like = 1, wary = 1, curious = 1, revere = 1, disgust = 1, pity = 1,
	covet = 1, ignore = 1}
VA.FEEL_LIST = {"fear", "hate", "love", "like", "wary", "curious", "revere", "disgust", "pity", "covet", "ignore"}

local function baseFeel(K)
	if K.feel ~= "" then return K.feel end
	return K.danger >= 0.5 and "fear" or (K.danger >= 0.2 and "wary" or "curious")
end

-- villager V's own view of kind k (their feel_about call): {feel, mult, bonus, why} or nil
function VA.appraisal(V, k)
	return V.creatureFeel and V.creatureFeel[k] or nil
end

function VA.feel(V, k)
	if not k then return nil end
	local K = VA.kinds[k]
	if not K then return nil end
	local a = VA.appraisal(V, k)
	if a and FEEL_WORDS[a.feel] then return a.feel end
	return baseFeel(K)
end

-- how much villager V fears kind k, 0..1: the baseline danger x their multiplier + their bonus
function VA.fear(V, k)
	local K = VA.kinds[k]
	if not K then return 0 end
	local a = VA.appraisal(V, k)
	local mult, bonus
	if a then mult, bonus = a.mult, a.bonus
	else
		local temper = (VL_CFG.temper or {})[V.id] or 0.4
		mult, bonus = temper >= 0.8 and 0.6 or 1, 0
	end
	local f = K.danger * math.max(0, math.min(3, mult)) + math.max(-1, math.min(1, bonus))
	if VA.feel(V, k) == "fear" then f = math.max(f, K.danger * 0.5) end
	return math.max(0, math.min(1, f))
end

function VA.why(V, k)
	local a = VA.appraisal(V, k)
	return a and a.why ~= "" and a.why or nil
end

-- how an item is generally regarded (a tool or an Inventory item / garment): villagers.item.<id>.feel - the villager's
-- own model makes of it what their nature does (no per-villager entries: the user, 2026-11-15)
function VA.itemFeel(V, id)
	if not id or id == "" then return nil end
	local b = "villagers.item." .. id .. ".feel"
	if HasKey(b) and GetString(b) ~= "" then return GetString(b) end
	return nil
end
function VA.itemNote(id) return str("villagers.item." .. id .. ".note") end

-- every creature / thing of every kind, refreshed twice a second: {id, kind, name, pos, body, doing, hidden, sound, hear}
local function refresh()
	VA.kinds = {}
	local ok, ks = pcall(ListKeys, "villagers.kind")
	for _, k in ipairs(ok and ks or {}) do VA.kinds[k] = readKind(k) end
	local list = {}
	local okb, bodies = pcall(FindBodies, "vlkind", true)
	for _, b in ipairs(okb and bodies or {}) do
		local k = GetTagValue and GetTagValue(b, "vlkind") or ""
		local K = VA.kinds[k]
		if K and IsHandleValid(b) then
			local pos = GetBodyTransform(b).pos
			if GetBodyBounds then
				local okk, lo, hi = pcall(GetBodyBounds, b)
				if okk and lo and hi then pos = VecLerp(lo, hi, 0.5) end
			end
			list[#list + 1] = {id = "b" .. b, kind = k, name = K.name, pos = pos, body = b, doing = K.doing,
				sound = K.sound, hear = K.hear}
		end
	end
	local okt, ts = pcall(ListKeys, "villagers.thing")
	for _, id in ipairs(okt and ts or {}) do
		local b = "villagers.thing." .. id .. "."
		local k = str(b .. "kind")
		local K = VA.kinds[k]
		if K and not (HasKey(b .. "gone") and GetBool(b .. "gone")) then
			local body = HasKey(b .. "body") and GetInt(b .. "body") or 0
			local pos
			if body ~= 0 and IsHandleValid(body) then pos = GetBodyTransform(body).pos
			elseif HasKey(b .. "x") then pos = Vec(GetFloat(b .. "x"), GetFloat(b .. "y"), GetFloat(b .. "z")) end
			if pos then
				local nm = str(b .. "name")
				list[#list + 1] = {id = id, kind = k, name = nm ~= "" and nm or K.name, pos = pos, body = body ~= 0 and body or nil,
					doing = str(b .. "doing") ~= "" and str(b .. "doing") or K.doing,
					hidden = HasKey(b .. "hidden") and GetBool(b .. "hidden"),
					sound = str(b .. "sound") ~= "" and str(b .. "sound") or K.sound,
					hear = HasKey(b .. "hear") and GetFloat(b .. "hear") or K.hear}
			end
		end
	end
	VA.things = list
end

-- a creature / thing by the name a villager used (the nearest one to V when several share it)
function VA.thingByName(name, near)
	local n = (name or ""):lower():gsub("^the ", ""):gsub("^an? ", "")
	if n == "" then return nil end
	local best, bd = nil, 1e9
	for _, t in ipairs(VA.things) do
		local tn = t.name:lower()
		if tn:find(n, 1, true) or n:find((tn:gsub("^the ", ""):gsub("^an? ", "")), 1, true) or t.id:lower() == n then
			local d = near and VecLength(VecSub(t.pos, near)) or 0
			if d < bd then best, bd = t, d end
		end
	end
	return best
end

function VA.thingById(id)
	for _, t in ipairs(VA.things) do if t.id == id then return t end end
	return nil
end

-- out: a villager struck one of another mod's creatures (the owner applies the damage if it wants to)
function VA.strike(V, t, amount)
	local n = GetInt("villagers.strike.last") + 1
	local b = "villagers.strike." .. (n % 16) .. "."
	SetString(b .. "by", V.id)
	SetString(b .. "name", V.name)
	SetString(b .. "thing", t.id)
	SetString(b .. "kind", t.kind)
	SetInt(b .. "body", t.body or 0)
	SetFloat(b .. "amount", amount)
	SetFloat(b .. "x", V.w.pos[1]); SetFloat(b .. "y", V.w.pos[2]); SetFloat(b .. "z", V.w.pos[3])
	SetInt("villagers.strike.last", n)
end

-- ---------------------------------------------------------------- each villager's own view (their own LLM)
-- (the user, 2026-11-15: "each villager decides what their fear, love, hate, etc are on their first time meeting a
-- creature using an LLM call, and that gets saved throughout the session - in fact, reassessment should be a tool call
-- that the villager can use") The first sighting asks the villager (vl_brain.creatureSeen); their feel_about call
-- with a feeling lands here, and so does any later one (a reassessment). Kept for the session in V.creatureFeel.
function VA.setFeel(V, k, feeling, mult, bonus, why)
	if not VA.kinds[k] then return "error: no such creature here" end
	if not FEEL_WORDS[feeling or ""] then return "error: feeling must be one of " .. table.concat(VA.FEEL_LIST, ", ") end
	V.creatureFeel = V.creatureFeel or {}
	local old = V.creatureFeel[k]
	V.creatureFeel[k] = {feel = feeling, mult = math.max(0, math.min(3, tonumber(mult) or 1)),
		bonus = math.max(-1, math.min(1, tonumber(bonus) or 0)), why = tostring(why or ""):sub(1, 100)}
	return string.format("ok: you %s %s (fear %.2f)", old and "now feel this way about" or "feel this way about", VA.kinds[k].name, VA.fear(V, k))
end

-- the kind a name means: a creature in sight by that name, or a kind's own name / id
function VA.kindByName(name)
	local t = VA.thingByName(name)
	if t then return t.kind end
	local n = (name or ""):lower():gsub("^the ", ""):gsub("^an? ", "")
	for k, K in pairs(VA.kinds) do
		local kn = K.name:lower():gsub("^the ", ""):gsub("^an? ", "")
		if k == n or kn == n or kn:find(n, 1, true) then return k end
	end
	return nil
end

-- ---------------------------------------------------------------- in: news, private words, damage
local function hearsNews(V, pos, range, sense)
	if sense == "told" and range <= 0 then return true end
	if not pos then return sense == "told" end
	local e = VecAdd(V.w.pos, Vec(0, 1.6, 0))
	local d = VecLength(VecSub(pos, e))
	if d > (range > 0 and range or 40) then return false end
	if sense == "seen" then return VlPerceive.clear(e, pos) end
	return true
end

local SENSE_WORD = {seen = "You SEE: ", heard = "You HEAR: ", smelled = "You SMELL: ", told = "You are told: "}

local function newsTick()
	local last = GetInt("villagers.news.last")
	VA.newsSeen = VA.newsSeen or last
	if VA.newsSeen > last then VA.newsSeen = last end
	while VA.newsSeen < last do
		VA.newsSeen = VA.newsSeen + 1
		local b = "villagers.news." .. (VA.newsSeen % 16) .. "."
		local text = str(b .. "text")
		local sense = str(b .. "sense")
		if not SENSE_WORD[sense] then sense = "heard" end
		local pos = HasKey(b .. "x") and Vec(GetFloat(b .. "x"), GetFloat(b .. "y"), GetFloat(b .. "z")) or nil
		local range = num(b .. "range", 0)
		local imp = math.max(1, math.min(5, math.floor(num(b .. "importance", 2))))
		if text ~= "" then
			for _, V in ipairs(VL.all or {}) do
				if V.alive and not V.asleep and hearsNews(V, pos, range, sense) then
					local where = ""
					if pos and sense ~= "told" then where = string.format(" (%d m away)", math.floor(VecLength(VecSub(pos, V.w.pos)))) end
					VlBrain.happen(V, SENSE_WORD[sense] .. text .. where, imp >= 3,
						{text = text, importance = imp, kind = "event"})
					if pos and imp >= 4 and sense ~= "told" then V.lastThreat = VecCopy(pos) end
				end
			end
		end
	end
end

local function tellTick()
	local ok, ids = pcall(ListKeys, "villagers.tell")
	for _, id in ipairs(ok and ids or {}) do
		local text = GetString("villagers.tell." .. id)
		ClearKey("villagers.tell." .. id)
		if text ~= "" then
			for _, V in ipairs(VL.all or {}) do
				if (id == "all" or V.id == id) and V.alive then
					VlBrain.happen(V, text, true, {text = text, importance = 3, kind = "event"})
					V.thinkDue = true
				end
			end
		end
	end
end

local function hurtTick()
	local last = GetInt("villagers.hurt.last")
	VA.hurtSeen = VA.hurtSeen or last
	if VA.hurtSeen > last then VA.hurtSeen = last end
	while VA.hurtSeen < last do
		VA.hurtSeen = VA.hurtSeen + 1
		local b = "villagers.hurt." .. (VA.hurtSeen % 16) .. "."
		local V = nil
		local id = str(b .. "target")
		for _, O in ipairs(VL.all or {}) do if O.id == id or O.name == id then V = O end end
		if not V and HasKey(b .. "shape") and VL.byShape then V = VL.byShape[GetInt(b .. "shape")] end
		local amount = num(b .. "amount", 0)
		if V and V.alive and amount > 0 then
			local from = HasKey(b .. "x") and Vec(GetFloat(b .. "x"), GetFloat(b .. "y"), GetFloat(b .. "z")) or nil
			local by = str(b .. "by")
			VlBrain.knockNext = HasKey(b .. "knock") and GetFloat(b .. "knock") > 0 and GetFloat(b .. "knock") or nil
			VlBrain.hurt(V, amount, by ~= "" and by or "something", from, VecAdd(V.w.pos, Vec(0, 1.1, 0)))
		end
	end
end

-- held by a creature: placed at the point each tick, lying limp (or struggling), can't act; let go when the key goes
local function carryTick()
	local now = GetTime()
	for _, V in ipairs(VL.all or {}) do
		local b = "villagers.carry." .. V.id .. "."
		if V.alive and HasKey(b .. "x") then
			local p = Vec(GetFloat(b .. "x"), GetFloat(b .. "y"), GetFloat(b .. "z"))
			local by = str(b .. "by")
			if by == "" then by = "something" end
			if not V.carried then
				V.carried = {by = by, t = now}
				if V.conv then VlBrain.endConv(V.conv) end
				V.override, V.engaged, V.asleep, V.tending = nil, nil, false, nil
				VlNav.stop(V.w)
				VlPlaces.release(V.id)
				VlBrain.happen(V, by .. " has grabbed you and is dragging you away!", true,
					{text = by .. " grabbed me and dragged me off", importance = 5, kind = "event", feel = -3})
				VlBrain.witness("carry:" .. V.id, VecAdd(p, Vec(0, 0.4, 0)), {skip = {[V] = true}, alarm = true,
					seen = "You SEE " .. by .. " dragging " .. V.name .. " away, {d} m away!",
					heard = "You HEAR " .. V.name .. " screaming, {d} m away.",
					mem = {text = "Saw " .. by .. " drag " .. V.name .. " away", who = {V.name}, importance = 5, kind = "event"}})
			end
			local prev = V.carried.last or p
			local dir = VecSub(p, prev)
			dir[2] = 0
			if VecLength(dir) > 0.01 then V.carried.head = VecNormalize(VecScale(dir, -1)) end
			V.carried.last = VecCopy(p)
			V.posture = "lie"
			V.lie = {pos = VecCopy(p), head = V.carried.head or VecCopy(V.w.fwd), floor = VecCopy(p)}
			VlNav.warp(V.w, p)
		elseif V.carried then
			V.carried = nil
			if V.alive and not V.downed then
				V.posture = "stand"
				V.lie = nil
				V.planKey = nil
				V.freedT = now                     -- (told a second later: a creature that lets go to kill - Lily - first)
			end
		end
		if V.freedT and now - V.freedT > 1 then
			V.freedT = nil
			if V.alive and not V.downed and not V.carried then
				V.thinkDue = true
				VlBrain.happen(V, "You are free! You scramble to your feet.", true)
			end
		end
		-- slowed (webs): until the host time .until
		local sb = "villagers.slow." .. V.id .. "."
		local f = HasKey(sb .. "factor") and now < GetFloat(sb .. "until") and math.max(0.05, math.min(1, GetFloat(sb .. "factor"))) or nil
		if f and not V.w.slow then
			VlBrain.happen(V, "You are stuck in something sticky: you can barely move!", true)
		end
		V.w.slow = f
	end
end

-- how much noise a villager makes, 0..1 (for creatures that hunt by sound)
local function noiseOf(V)
	if not V.alive then return 0 end
	if V.carried then return 0.9 end
	if V.asleep then return 0.02 end
	local n = 0.05
	if V.w.state == "walking" then n = (V.w.speedNow or 0) > 2.5 and 0.7 or 0.3 end
	if V.spraying or V.striking and GetTime() - V.striking < 1 then n = math.max(n, 0.8) end
	if V.override and V.override.kind == "fight" then n = math.max(n, 0.8) end
	if V.lineT and #V.lineT > 0 and GetTime() - V.lineT[#V.lineT] < 4 then
		n = math.max(n, VlBrain.voiceOf(V) == "yell" and 1 or (VlBrain.voiceOf(V) == "whisper" and 0.15 or 0.6))
	end
	if V.downed then n = math.min(n, 0.2) end
	return n
end

-- ---------------------------------------------------------------- out: who and where the villagers are
local function publish()
	SetBool("villagers.present", true)
	SetInt("villagers.version", VA.VERSION)
	local ids = {}
	for _, V in ipairs(VL.all or {}) do
		ids[#ids + 1] = V.id
		local b = "villagers.v." .. V.id .. "."
		local p = V.posture == "lie" and V.lie and V.lie.pos or V.w.pos
		SetString(b .. "name", V.name)
		SetFloat(b .. "x", p[1]); SetFloat(b .. "y", p[2]); SetFloat(b .. "z", p[3])
		SetFloat(b .. "hp", V.alive and V.hp or 0)
		SetBool(b .. "alive", V.alive == true)
		SetBool(b .. "asleep", V.asleep == true)
		SetBool(b .. "downed", V.downed == true)
		SetString(b .. "doing", V.alive and (VlLife.doingText(V) or "") or "dead")
		SetInt(b .. "shape", V.hitShape or 0)
		SetFloat(b .. "noise", noiseOf(V))
		SetBool(b .. "carried", V.carried ~= nil)
		for k in pairs(VA.kinds) do
			local f = VA.feel(V, k)
			SetString("villagers.feel." .. V.id .. "." .. k, f or "")
			SetFloat("villagers.fear." .. V.id .. "." .. k, VA.fear(V, k))
		end
	end
	SetString("villagers.list", table.concat(ids, ","))
end

function VlApi.tick(dt)
	local now = GetTime()
	if now >= (VA.refreshT or 0) then
		VA.refreshT = now + 0.5
		refresh()
		publish()
	end
	newsTick()
	tellTick()
	hurtTick()
	carryTick()
end
