-- Villagers: memory. An episodic store per villager (scored, capped, decaying), relationships (opinion, familiarity,
-- a one-line impression), long-term facts, a diary line a day; retrieval pushed into .state / the persona and pulled
-- by the `recall` function; a nightly consolidation by a non-character "scribe" agent (with a deterministic fallback
-- that needs no LLM); gossip between villagers without the LLM; persistence per map in savegame.mod.vl.<levelKey>.
-- (no #version line: included by main.lua. Server only. Randomness only through VlRand.)
--
-- Texts are kept in the villager's own words (first person: "Alex stole a loaf from my stall"). Players and
-- villagers are both known by NAME (GetPlayerName for players); villagers' stores are keyed by their id.

VlMemory = {}

-- ------------------------------------------------------------------------------------------------ tunables
VlMemory.CAP = 32               -- episodes per villager
VlMemory.FACT_CAP = 8           -- long-term facts per villager
VlMemory.REL_CAP = 24           -- people per villager
VlMemory.DIARY_KEEP = 3         -- diary lines kept
VlMemory.TEXT_MAX = 160         -- bytes of an episode's text
VlMemory.FACT_MAX = 130
VlMemory.IMPRESSION_MAX = 100
VlMemory.DIARY_MAX = 300
VlMemory.STATE_MAX = 700        -- chars of forState
VlMemory.PERSONA_MAX = 1500     -- chars of forPersona
VlMemory.RECALL_MAX = 420       -- chars of a recall result
VlMemory.FORGET_BELOW = 0.35    -- a night's decay forgets episodes whose keep score fell below this
VlMemory.SAVE_BYTES = 6000      -- persisted bytes per villager (all fields together)
VlMemory.SAVE_MIN = 20          -- s between two writes of one villager
VlMemory.SAVE_GAP = 1           -- s between two writes at all (spreads the cost)
VlMemory.MODEL_REMEMBER_DAY = 8 -- `remember` calls a villager may make a day
VlMemory.MODEL_FEEL_DAY = 3     -- total |change| a villager's `feel_about` calls may move one person a day
VlMemory.JOB_MIN = 8            -- a night gets a scribe job only when the day weighs this much (VlMemory.dayWeight)
VlMemory.JOBS_PER_NIGHT = 2     -- scribe jobs a night for the whole village (VlMemory.nightPlan): the LLM's output budget
VlMemory.LOG_CAP = 24           -- lines heard / said today, kept for the night's scribe (not saved)
VlMemory.LOG_MAX = 140          -- bytes of a logged line

local KINDS = {event = true, talk = true, promise = true, secret = true, opinion = true, gossip = true, fact = true}
local HALF = {0.4, 1, 3, 10, 40}  -- half-life in days by importance 1..5

-- ------------------------------------------------------------------------------------------------ state
local M = {lk = "default", base = "savegame.mod.vl.default", v = {}, day = 1, hour = 12, dirty = {}, wrote = {},
	lastWrite = -1e9, profiles = {}, players = {}}
VlMemory._M = M                 -- (tests)

local function now()
	if GetTime then return GetTime() end
	return 0
end

local function clamp(x, a, b)
	if x < a then return a end
	if x > b then return b end
	return x
end

local function round(x) return math.floor(x + 0.5) end

local function regName(s)
	s = string.lower(tostring(s or ""))
	s = string.gsub(s, "[^a-z0-9_%-]", "_")
	if s == "" then s = "_" end
	return s
end

-- UTF-8 safe cut to n bytes (never in the middle of a character)
local function cut(s, n)
	if #s <= n then return s end
	local i = n
	while i > 0 do
		local b = string.byte(s, i + 1)
		if not b or b < 128 or b >= 192 then break end
		i = i - 1
	end
	return string.sub(s, 1, i)
end

local function clean(s, n)
	if s == nil then return "" end
	s = tostring(s)
	s = string.gsub(s, "[%z\1-\31\127]", " ")
	s = string.gsub(s, "%s+", " ")
	s = string.gsub(s, "^ ", "")
	s = string.gsub(s, " $", "")
	if n and #s > n then                        -- cut at a word when one ends near the limit
		local c = cut(s, n - 3)
		local w = string.match(c, "^(.*%S)%s+%S*$")
		if w and #w > n * 0.6 then c = w end
		s = c .. "..."
	end
	return s
end

-- a short line for a list: no trailing full stop (the list adds its own)
local function phrase(s, n)
	s = clean(s, n)
	s = string.gsub(s, "[%.;,%s]+$", "")
	return s
end

local function lowerKey(name) return string.lower(clean(name, 40)) end

-- ------------------------------------------------------------------------------------------------ words
local STOP = {}
for w in string.gmatch("a an the and or but of to in on at for with from by is are was were be been am i me my mine " ..
	"you your he him his she her it its we us our they them their this that these those there here what who when " ..
	"then than so as if not no yes do did does done have has had will would can could should just very really " ..
	"about into out up down over again too also some any all one said says say told tell", "%a+") do STOP[w] = true end

local SYN = {}
local function syn(canon, words) for w in string.gmatch(words, "%S+") do SYN[w] = canon end SYN[canon] = canon end
syn("steal", "stole stolen stealing steals thief thieves theft rob robbed robbing robber took nick nicked pinch pinched swipe swiped")
syn("hit", "hits hitting punch punched struck strike beat beaten attack attacked hurt hurting kick kicked slap slapped smack shot shoot")
syn("give", "gave given gives giving gift gifts present presents brought bring handed")
syn("bread", "loaf loaves bun buns roll rolls")
syn("promise", "promised promises swear swore sworn vow vowed owe owes owed debt debts")
syn("kill", "killed kills killing murder murdered dead death die died")
syn("explode", "explosion exploded explosions blast bomb bombs boom")
syn("fire", "burn burned burnt burning flame flames fires")
syn("coin", "coins money gold silver pay paid payment cash")
syn("lie", "lied lies liar lying")
syn("sleep", "slept sleeping bed beds")
syn("break", "broke broken smash smashed wreck wrecked destroy destroyed damage damaged")
syn("help", "helped helping helps aid aided saved save")
syn("drink", "drunk drank ale beer wine")
syn("church", "chapel temple shrine priest")
syn("tavern", "inn pub bar")
syn("smith", "smithy forge blacksmith anvil")
syn("secret", "secrets confess confessed confided")

local function stem(w)
	if SYN[w] then return SYN[w] end
	if #w > 4 then
		local s = string.gsub(w, "ing$", "")
		if s == w then s = string.gsub(w, "ed$", "") end
		if s == w then s = string.gsub(w, "es$", "") end
		if s == w then s = string.gsub(w, "s$", "") end
		if s == w then s = string.gsub(w, "ly$", "") end
		if SYN[s] then return SYN[s] end
		if #s >= 3 then return s end
	end
	return w
end

-- the set of meaningful stems in a text (lower-case ASCII; other bytes kept as part of words)
local function words(s)
	local set, n = {}, 0
	s = string.lower(tostring(s or ""))
	s = string.gsub(s, "'s%f[^%w]", "")
	for w in string.gmatch(s, "[%w\128-\255]+") do
		if not STOP[w] and (#w > 1 or string.byte(w) >= 128) then
			local st = stem(w)
			if not set[st] then set[st] = true; n = n + 1 end
		end
	end
	return set, n
end
VlMemory._words = words

-- an episode's words (text, people, place, teller), cached on it until its text changes
local function mwords(m)
	if not m._w or m._wt ~= m.t then
		m._w = words(m.t .. " " .. table.concat(m.who, " ") .. " " .. (m.where or "") .. " " .. (m.src or ""))
		m._wt = m.t
	end
	return m._w
end

local function overlap(a, b)                       -- Jaccard of two word sets
	local inter, na, nb = 0, 0, 0
	for k in pairs(a) do na = na + 1; if b[k] then inter = inter + 1 end end
	for _ in pairs(b) do nb = nb + 1 end
	if na + nb == 0 then return 0 end
	return inter / (na + nb - inter)
end

-- ------------------------------------------------------------------------------------------------ villagers
local function newV()
	return {ep = {}, rel = {}, facts = {}, diary = {}, nid = 1, nfact = 1, today = {rem = 0, feel = {}}, todayDay = 0, log = {}}
end

local function V(id)
	id = regName(id)
	local v = M.v[id]
	if not v then v = newV(); M.v[id] = v end
	if v.todayDay ~= M.day then
		v.today = {rem = 0, feel = {}}
		if v.todayDay ~= 0 and not v.job then v.log = {} end          -- (a day without a night: its talk is gone)
		v.todayDay = M.day
	end
	return v, id
end

local function dirty(id) M.dirty[regName(id)] = true end

local function nameOf(id)
	local p = M.profiles[regName(id)]
	if p and p.name then return p.name end
	id = tostring(id)
	return string.upper(string.sub(id, 1, 1)) .. string.sub(id, 2)
end

-- the lead tells who a villager is (the scribe needs the voice): name and a short description
function VlMemory.setProfile(id, name, blurb)
	M.profiles[regName(id)] = {name = clean(name, 40), blurb = clean(blurb, 400)}
end

-- the lead names each player it sees (GetPlayerName): relationships with them are marked as strangers / outsiders
function VlMemory.player(name)
	M.players[lowerKey(name)] = true
end

function VlMemory.setTime(hour) M.hour = tonumber(hour) or M.hour end
function VlMemory.day() return M.day end

local function curHour()
	if VlLife and VlLife.hour then
		local ok, h = pcall(VlLife.hour)
		if ok and type(h) == "number" then M.hour = h end
	end
	return M.hour
end

local function ageDays(m)
	return math.max(0, (M.day - m.day) + (curHour() - m.hour) / 24)
end

local function isOpen(m) return (m.kind == "promise" or m.kind == "secret") and not m.done end

-- how much an episode is worth keeping now
function VlMemory.keep(m)
	local imp = clamp(m.imp or 1, 1, 5)
	local base = imp + 0.5 * math.abs(m.emo or 0) + 0.4 * math.min(m.rc or 0, 4)
	if m.kind == "talk" or m.kind == "gossip" then base = base - 0.5 end
	local hl = HALF[imp] * (1 + 0.5 * math.min(m.rc or 0, 4))
	if isOpen(m) then hl = hl * 4; base = base + 1 end
	if (m.n or 1) > 1 then hl = hl * (1 + 0.25 * math.min(m.n - 1, 4)) end
	return base * math.pow(0.5, ageDays(m) / hl)
end
local keep = VlMemory.keep

local function protected(m)
	return (m.imp or 1) >= 5 or (isOpen(m) and ageDays(m) < 1)
end

-- strict deterministic order: higher score first, then newer id
local function byScore(list, f)
	local s = {}
	for _, m in ipairs(list) do s[m] = f(m) end
	table.sort(list, function(a, b)
		if s[a] ~= s[b] then return s[a] > s[b] end
		return a.id > b.id
	end)
end

local function evict(v)
	while #v.ep > VlMemory.CAP do
		local worst, wi, ws = nil, nil, 1e9
		for i, m in ipairs(v.ep) do
			local s = keep(m)
			if protected(m) then s = s + 100 end
			if s < ws or (s == ws and m.id < worst.id) then worst, wi, ws = m, i, s end
		end
		table.remove(v.ep, wi)
	end
end

local function relFor(v, name, kind)
	local key = lowerKey(name)
	if key == "" then return nil end
	local r = v.rel[key]
	if not r then
		r = {name = clean(name, 40), op = 0, fam = 0, imp = "", kind = kind or "", day = M.day}
		v.rel[key] = r
		local n = 0
		for _ in pairs(v.rel) do n = n + 1 end
		if n > VlMemory.REL_CAP then                  -- forget the least notable acquaintance (not the new one)
			local wk, ws = nil, 1e9
			for k, x in pairs(v.rel) do
				if k ~= key then
					local s = math.abs(x.op) * 2 + math.min(x.fam, 10) - (M.day - (x.day or M.day)) * 0.3
					if s < ws or (s == ws and k < wk) then wk, ws = k, s end
				end
			end
			if wk then v.rel[wk] = nil end
		end
	end
	if kind and kind ~= "" then r.kind = kind
	elseif M.players[key] then r.kind = "player" end
	return r
end

local function whoList(who)
	local out, seen = {}, {}
	if type(who) == "string" then
		local t = {}
		for w in string.gmatch(who, "[^,;/]+") do t[#t + 1] = w end
		who = t
	end
	if type(who) ~= "table" then return out end
	for _, w in ipairs(who) do
		local c = clean(w, 40)
		c = string.gsub(c, "^and ", "")
		local k = string.lower(c)
		if c ~= "" and not seen[k] and k ~= "me" and k ~= "i" and k ~= "myself" then seen[k] = true; out[#out + 1] = c end
		if #out >= 4 then break end
	end
	return out
end

local function emoGuess(ws)
	local e = 0
	if ws.steal or ws.hit or ws.kill or ws.lie or ws["break"] or ws.fire or ws.explode then e = e - 2 end
	if ws.give or ws.help then e = e + 2 end
	return clamp(e, -3, 3)
end

-- ------------------------------------------------------------------------------------------------ writing
-- m = {text, who = {names} | "a, b", where, importance 1-5, kind, emo -3..3 (default: guessed), feel = opinion change
-- for everyone in who, src = who told it ("" = seen myself), done = promise kept}. Returns the stored episode and
-- whether it was new (a near-duplicate of today merges into the existing one: its count goes up).
function VlMemory.add(id, m)
	if type(m) ~= "table" then return nil end
	local v
	v, id = V(id)
	local text = phrase(m.text, VlMemory.TEXT_MAX)
	if text == "" then return nil end
	local kind = KINDS[m.kind or "event"] and (m.kind or "event") or "event"
	local imp = clamp(round(tonumber(m.importance or m.imp) or 2), 1, 5)
	local who = whoList(m.who)
	local ws = words(text)
	local where = clean(m.where, 40)
	-- a duplicate: same text, or very similar about the same people, within the last day
	for _, o in ipairs(v.ep) do
		if o.kind == kind or (kind ~= "promise" and kind ~= "secret" and o.kind ~= "promise" and o.kind ~= "secret") then
			local recent = (M.day - o.day) <= 1
			if recent and (string.lower(o.t) == string.lower(text) or overlap(words(o.t), ws) >= 0.6) then
				o.n = (o.n or 1) + 1
				if imp > o.imp then o.imp = imp end
				o.day, o.hour = M.day, curHour()
				for _, w in ipairs(who) do
					local has = false
					for _, x in ipairs(o.who) do if string.lower(x) == string.lower(w) then has = true end end
					if not has and #o.who < 4 then o.who[#o.who + 1] = w end
				end
				if m.feel then for _, w in ipairs(who) do VlMemory.feel(id, w, m.feel, nil) end end
				dirty(id)
				return o, false
			end
		end
	end
	local e = {id = v.nid, t = text, who = who, where = where, imp = imp, kind = kind, day = M.day, hour = curHour(),
		rc = 0, emo = clamp(round(tonumber(m.emo) or emoGuess(ws)), -3, 3), n = 1, src = clean(m.src, 40),
		done = (m.done == "kept" or m.done == "broken") and m.done or (m.done and "kept" or false)}
	v.nid = v.nid + 1
	v.ep[#v.ep + 1] = e
	for _, w in ipairs(who) do
		local r = relFor(v, w)
		if r then
			r.day = M.day
			if kind ~= "gossip" and kind ~= "fact" and r.metDay ~= M.day then r.fam = math.min(r.fam + 1, 99); r.metDay = M.day end
		end
	end
	if m.feel then for _, w in ipairs(who) do VlMemory.feel(id, w, m.feel, nil) end end
	evict(v)
	dirty(id)
	return e, true
end

-- relationship: opinion -5..+5 by delta, a one-line impression (why) when it says something
function VlMemory.feel(id, name, delta, why, kind)
	local v
	v, id = V(id)
	local r = relFor(v, name, kind)
	if not r then return nil end
	delta = tonumber(delta) or 0
	r.op = clamp(r.op + delta, -5, 5)
	r.day = M.day
	why = phrase(why, VlMemory.IMPRESSION_MAX)
	if why ~= "" and (r.imp == "" or math.abs(delta) >= 2 or (delta ~= 0 and (delta > 0) == (r.op > 0))) then r.imp = why end
	dirty(id)
	return r
end

-- seed a relationship only if none exists yet (the people file's ties)
function VlMemory.setRel(id, name, op, impression, kind)
	local v
	v, id = V(id)
	if v.rel[lowerKey(name)] then return v.rel[lowerKey(name)] end
	local r = relFor(v, name, kind)
	if not r then return nil end
	r.op = clamp(tonumber(op) or 0, -5, 5)
	r.imp = phrase(impression, VlMemory.IMPRESSION_MAX)
	r.fam = math.max(r.fam or 0, 10)               -- (seeded ties are people they have known for years, not strangers)
	dirty(id)
	return r
end

-- a meeting (a conversation with a player, or villagers meeting off-screen): familiarity up, and a "talk" memory
function VlMemory.meet(id, name, place, kind)
	local v
	v, id = V(id)
	local r = relFor(v, name, kind)
	if not r then return end
	place = clean(place, 40)
	if r.metDay == M.day and (place == "" or r.metAt == place) then return end     -- (one "talked with" a day and place)
	if r.metDay ~= M.day then r.fam = math.min(r.fam + 1, 99); r.metDay = M.day end
	r.metAt = place
	r.day = M.day
	local t = "Talked with " .. r.name
	if place ~= "" then t = t .. " at " .. place end
	VlMemory.add(id, {text = t, who = {r.name}, where = place, importance = 1, kind = "talk", emo = 0})
end

-- ------------------------------------------------------------------------------------------------ what was said
-- Lines heard or said go into today's log for the night's scribe. A few kinds are kept at once by keywords, so they are
-- in .state the same day (the model itself rarely calls remember: see export/memory_report.md).
local SECRET_PAT = {"between us", "between you and me", "secret", "don't tell", "dont tell", "do not tell", "tell no one",
	"keep it quiet", "keep this quiet", "confess", "nobody knows", "no one knows"}
local PROMISE_PAT = {"i promise", "i swear", "i'll pay", "i will pay", "pay you back", "i owe you", "you owe me", "i'll bring",
	"i will bring", "i'll be back", "i'll have it", "i will have it", "on my word", "on my honour", "on my honor", "i give you my word"}
local INSULT = {}
for w in string.gmatch("hag witch idiot fool stupid ugly liar scum pig hate bastard moron cheat cheater crook coward " ..
	"rat worm useless pathetic disgusting sawdust", "%a+") do INSULT[w] = true end
local THREAT = {"i'll kill", "i will kill", "i'll burn", "i will burn", "i'll hurt", "watch your back", "you'll regret", "you will regret"}

local function anyOf(low, list)
	for _, p in ipairs(list) do if string.find(low, p, 1, true) then return true end end
	return false
end

-- what kind of line it is: kind, importance, emo, insult (nil: nothing special)
local function flagLine(text, own)
	local low = " " .. string.lower(text) .. " "
	low = string.gsub(low, "\226\128\153", "'")                    -- (a typographic apostrophe)
	if not own and anyOf(low, SECRET_PAT) then return "secret", 3, 0, false end
	if anyOf(low, PROMISE_PAT) then return "promise", 3, 0, false end
	if own then return nil end
	if anyOf(low, THREAT) then return "event", 3, -3, true end
	for w in string.gmatch(low, "%a+") do if INSULT[w] then return "event", 2, -2, true end end
	return nil
end
VlMemory._flagLine = flagLine

-- villager id heard speaker say text (speaker = its own name for its own replies). place: where (optional).
-- Returns the episode it was kept as at once, if any.
function VlMemory.heard(id, speaker, text, place)
	local v
	v, id = V(id)
	speaker = clean(speaker, 40)
	text = clean(text, VlMemory.LOG_MAX)
	if text == "" or speaker == "" then return nil end
	local own = string.lower(speaker) == string.lower(nameOf(id))
	local entry = {h = curHour(), who = own and "me" or speaker, t = text}
	v.log[#v.log + 1] = entry
	while #v.log > VlMemory.LOG_CAP do table.remove(v.log, 1) end
	if not own then VlMemory.meet(id, speaker, place) end
	local kind, imp, emo, insult = flagLine(text, own)
	if not kind then return nil end
	local quote = own and ("I said: \"" .. text .. "\"") or (speaker .. " told me: \"" .. text .. "\"")
	local who = {}
	if not own then who[1] = speaker end
	local e = VlMemory.add(id, {text = cut(quote, VlMemory.TEXT_MAX - 1) .. ((#quote > VlMemory.TEXT_MAX - 1) and "\"" or ""),
		who = who, importance = imp, kind = kind, emo = emo, where = place})
	if e then entry.kept = e.id end
	if insult and not own then VlMemory.feel(id, speaker, -1, nil) end
	return e
end

function VlMemory.addFact(id, text, src)
	local v
	v, id = V(id)
	text = clean(text, VlMemory.FACT_MAX)
	if text == "" then return nil end
	local ws = words(text)
	for _, f in ipairs(v.facts) do
		if string.lower(f.t) == string.lower(text) or overlap(words(f.t), ws) >= 0.7 then
			f.t, f.day = text, M.day
			dirty(id)
			return f
		end
	end
	local f = {id = v.nfact, t = text, day = M.day}
	v.nfact = v.nfact + 1
	v.facts[#v.facts + 1] = f
	while #v.facts > VlMemory.FACT_CAP do table.remove(v.facts, 1) end   -- the oldest goes
	dirty(id)
	return f
end

local function setDiary(v, text)
	text = clean(text, VlMemory.DIARY_MAX)
	if text == "" then return end
	for _, d in ipairs(v.diary) do
		if d.day == M.day then d.t = text return end
	end
	v.diary[#v.diary + 1] = {day = M.day, t = text}
	while #v.diary > VlMemory.DIARY_KEEP do table.remove(v.diary, 1) end
end

-- ------------------------------------------------------------------------------------------------ reading
local function ago(m)
	local d = M.day - m.day
	if d <= 0 then
		if curHour() - m.hour < 1 then return "just now" end
		if m.hour < 12 then return "this morning" end
		if m.hour < 17 then return "this afternoon" end
		return "this evening"
	end
	if d == 1 then return "yesterday" end
	if d < 7 then return d .. " days ago" end
	return "long ago"
end

local function epLine(m, withAgo)
	local t = m.t
	if m.kind == "gossip" and m.src ~= "" then
		local teller, from = string.match(m.src, "^(.-)<(.+)$")
		if teller then t = teller .. " told me (from " .. from .. "): " .. t else t = m.src .. " told me: " .. t end
	elseif m.src ~= "" and m.src ~= nil then
		t = t .. " (" .. m.src .. " said)"
	end
	if (m.n or 1) > 1 then t = t .. " (x" .. m.n .. ")" end
	if m.kind == "promise" then t = ((m.done == "broken") and "[broken promise] " or (m.done and "[kept promise] " or "[promise] ")) .. t
	elseif m.kind == "secret" then t = "[secret, don't tell] " .. t end
	if withAgo then t = ago(m) .. ": " .. t end
	return t
end

local function opWord(op)
	op = round(op)
	if op <= -4 then return "hate" end
	if op <= -2 then return "dislike" end
	if op >= 4 then return "love" end
	if op >= 2 then return "like" end
	return "neutral"
end

local function relLine(r)
	local s = r.name
	if r.kind == "player" then s = s .. ((r.fam < 2) and " (stranger)" or " (outsider)") end
	s = s .. ": " .. opWord(r.op) .. " (" .. (round(r.op) > 0 and "+" or "") .. round(r.op) .. ")"
	if r.imp ~= "" then s = s .. ", " .. r.imp end
	if r.fam == 0 then s = s .. ", never met" end
	return s
end

local function addLimited(parts, line, budget, used)
	if used + #line + 2 > budget then return used, false end
	parts[#parts + 1] = line
	return used + #line + 2, true
end

-- the memory part of .state: whoever is present, this place, open promises (<= STATE_MAX chars)
-- ctx = {present = {names}, place = "the tavern", hour = 14}
function VlMemory.forState(id, ctx)
	local v
	v, id = V(id)
	ctx = ctx or {}
	if ctx.hour then M.hour = ctx.hour end
	local present, pres = {}, whoList(ctx.present or {})
	for _, n in ipairs(pres) do present[string.lower(n)] = n end
	v.lastPresent = pres
	local place = string.lower(clean(ctx.place, 40))
	-- the topic: the last lines heard (a conversation stays on its subject), plus ctx.topic
	local topic, tn = words(ctx.topic or "")
	for i = math.max(1, #v.log - 2), #v.log do
		for w in pairs(words(v.log[i].t)) do if not topic[w] then topic[w] = true; tn = tn + 1 end end
	end
	local budget = VlMemory.STATE_MAX
	local parts, used = {}, 0
	-- the people here
	local people = {}
	for _, n in ipairs(pres) do
		local r = v.rel[string.lower(n)]
		if r then people[#people + 1] = relLine(r) end
	end
	if #people > 0 then
		local ok
		used, ok = addLimited(parts, "People here: " .. table.concat(people, "; ") .. ".", budget, used)
		if not ok then used = addLimited(parts, "People here: " .. cut(table.concat(people, "; "), budget - 20) .. ".", budget, used) end
	end
	-- memories ranked for this moment
	local cand, onTopic = {}, {}
	for _, m in ipairs(v.ep) do cand[#cand + 1] = m end
	byScore(cand, function(m)
		local s = keep(m) * 0.6
		for _, w in ipairs(m.who) do if present[string.lower(w)] then s = s + 4 end end
		if place ~= "" and string.lower(m.where) == place then s = s + 1.5 end
		if isOpen(m) then s = s + 2 end
		if m.day == M.day then s = s + 0.5 end
		if m.kind == "talk" then s = s - 2 end
		if tn > 0 then
			local hit = 0
			for w in pairs(mwords(m)) do if topic[w] then hit = hit + 1 end end
			s = s + math.min(hit * 1.5, 4)
			if hit > 0 then onTopic[m] = true end
		end
		return s
	end)
	local lines, unrelated = {}, 0
	local head = "You remember: "
	local room = budget - used - #head - 2
	local skip = (ctx.skipPersona ~= false) and v.personaIds or {}
	for _, m in ipairs(cand) do
		if #lines >= 6 then break end
		local about = false
		for _, w in ipairs(m.who) do if present[string.lower(w)] then about = true end end
		if not skip[m.id] and (about or (unrelated < 3 and m.kind ~= "secret" and (onTopic[m] or m.imp >= 3 or isOpen(m) or m.day == M.day))) then
			local l = epLine(m, true)
			if room - #l - 2 >= 0 then
				lines[#lines + 1] = l; room = room - #l - 2
				if not about then unrelated = unrelated + 1 end
			end
		end
	end
	if #lines > 0 then used = addLimited(parts, head .. table.concat(lines, "; ") .. ".", budget, used) end
	return table.concat(parts, " ")
end

-- long-lived memory for the persona: people, facts, yesterday's diary (<= PERSONA_MAX chars)
function VlMemory.forPersona(id)
	local v
	v, id = V(id)
	local budget = VlMemory.PERSONA_MAX
	local parts, used = {}, 0
	local head = "Your memory of earlier days (yours alone; bring it up when it fits, never recite it):"
	used = addLimited(parts, head, budget, used)
	-- diary: the latest line before today
	local last = nil
	for _, d in ipairs(v.diary) do if d.day < M.day and (not last or d.day > last.day) then last = d end end
	if last then
		used = addLimited(parts, ((M.day - last.day == 1) and "Yesterday" or ("Day " .. last.day)) ..
			" (your diary): " .. last.t, budget, used)
	end
	local rels = {}
	for _, r in pairs(v.rel) do rels[#rels + 1] = r end
	table.sort(rels, function(a, b)
		local sa, sb = math.abs(a.op) * 2 + math.min(a.fam, 10), math.abs(b.op) * 2 + math.min(b.fam, 10)
		if sa ~= sb then return sa > sb end
		return a.name < b.name
	end)
	local facts = {}
	for i = #v.facts, 1, -1 do facts[#facts + 1] = v.facts[i] end
	if #facts > 0 then
		used = addLimited(parts, "Things you know:", budget, used)
		for _, f in ipairs(facts) do
			local ok
			used, ok = addLimited(parts, "- " .. f.t, budget, used)
			if not ok then break end
		end
	end
	if #rels > 0 then
		used = addLimited(parts, "People you know:", budget, used)
		for _, r in ipairs(rels) do
			if r.fam > 0 or r.op ~= 0 or r.imp ~= "" then
				local ok
				used, ok = addLimited(parts, "- " .. relLine(r), budget, used)
				if not ok then break end
			end
		end
	end
	-- the strongest older memories (today's go in .state)
	local old = {}
	local fw = {}
	for _, f in ipairs(v.facts) do fw[#fw + 1] = words(f.t) end
	for _, m in ipairs(v.ep) do
		if m.day < M.day and (m.imp >= 3 or isOpen(m)) then
			local covered = false
			local mw = words(m.t)
			for _, w in ipairs(fw) do if overlap(mw, w) >= 0.4 then covered = true end end
			if not covered then old[#old + 1] = m end
		end
	end
	byScore(old, keep)
	v.personaIds = {}                                -- (forState leaves these out: the persona has them all day)
	if #old > 0 then
		local ok
		used, ok = addLimited(parts, "Earlier:", budget, used)
		if ok then
			for i = 1, math.min(#old, 6) do
				used, ok = addLimited(parts, "- " .. epLine(old[i], true), budget, used)
				if not ok then break end
				v.personaIds[old[i].id] = true
			end
		end
	end
	if #parts == 1 then return "" end
	return table.concat(parts, "\n")
end

-- keyword retrieval: names, places, stems and synonyms. Returns the episodes (best first), up to n (default 3)
function VlMemory.recall(id, query, n)
	local v
	v, id = V(id)
	n = n or 3
	local q, qn = words(query)
	if qn == 0 then return {} end
	local scored = {}
	for _, m in ipairs(v.ep) do
		local s = 0
		local mw = mwords(m)
		for w in pairs(q) do if mw[w] then s = s + 1 end end
		for _, w in ipairs(m.who) do if q[stem(string.lower(w))] then s = s + 1 end end
		if s > 0 then scored[#scored + 1] = m; m._s = s + keep(m) * 0.1 end
	end
	byScore(scored, function(m) return m._s end)
	local out = {}
	for i = 1, math.min(n, #scored) do
		out[i] = scored[i]
		scored[i].rc = (scored[i].rc or 0) + 1
	end
	for _, m in ipairs(scored) do m._s = nil end
	if #out > 0 then dirty(id) end
	return out
end

-- the text for a `recall` call's result
function VlMemory.recallText(id, query)
	local v
	v, id = V(id)
	local list = VlMemory.recall(id, query, 4)
	local q = words(query)
	local parts, used = {}, 0
	for _, m in ipairs(list) do
		local ok
		used, ok = addLimited(parts, epLine(m, true), VlMemory.RECALL_MAX, used)
		if not ok then break end
	end
	for _, f in ipairs(v.facts) do
		local fw = words(f.t)
		for w in pairs(q) do
			if fw[w] then used = addLimited(parts, f.t, VlMemory.RECALL_MAX, used) break end
		end
	end
	for _, r in pairs(v.rel) do
		if q[stem(string.lower(r.name))] or q[string.lower(r.name)] then used = addLimited(parts, relLine(r), VlMemory.RECALL_MAX, used) end
	end
	if #parts == 0 then return "nothing comes to mind" end
	return table.concat(parts, "; ")
end

-- ------------------------------------------------------------------------------------------------ JSON (calls)
local function utf8char(cp)
	if cp < 128 then return string.char(cp) end
	if cp < 2048 then return string.char(192 + math.floor(cp / 64), 128 + cp % 64) end
	if cp < 65536 then return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64) end
	return string.char(240 + math.floor(cp / 262144), 128 + math.floor(cp / 4096) % 64, 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
end

local ESC = {n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/"}

-- a small, strict JSON decoder: returns value or nil, error
function VlMemory.json(s)
	if type(s) ~= "string" then return nil, "not a string" end
	local pos = 1
	local function fail(msg) error("json: " .. msg .. " at " .. pos, 0) end
	local function ws() pos = string.find(s, "[^ \t\r\n]", pos) or (#s + 1) end
	local value
	local function str()
		pos = pos + 1
		local buf = {}
		while true do
			local c = string.sub(s, pos, pos)
			if c == "" then fail("unterminated string") end
			if c == '"' then pos = pos + 1 break end
			if c == "\\" then
				local e = string.sub(s, pos + 1, pos + 1)
				if e == "u" then
					local cp = tonumber(string.sub(s, pos + 2, pos + 5), 16)
					if not cp then fail("bad \\u") end
					pos = pos + 6
					if cp >= 55296 and cp <= 56319 and string.sub(s, pos, pos + 1) == "\\u" then
						local lo = tonumber(string.sub(s, pos + 2, pos + 5), 16)
						if lo and lo >= 56320 and lo <= 57343 then cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); pos = pos + 6 end
					end
					buf[#buf + 1] = utf8char(cp)
				else
					buf[#buf + 1] = ESC[e] or e
					pos = pos + 2
				end
			else
				local j = string.find(s, '["\\]', pos) or (#s + 1)
				buf[#buf + 1] = string.sub(s, pos, j - 1)
				pos = j
			end
		end
		return table.concat(buf)
	end
	value = function(depth)
		if depth > 20 then fail("too deep") end
		ws()
		local c = string.sub(s, pos, pos)
		if c == "{" then
			pos = pos + 1
			local t = {}
			ws()
			if string.sub(s, pos, pos) == "}" then pos = pos + 1 return t end
			while true do
				ws()
				if string.sub(s, pos, pos) ~= '"' then fail("key expected") end
				local k = str()
				ws()
				if string.sub(s, pos, pos) ~= ":" then fail("colon expected") end
				pos = pos + 1
				t[k] = value(depth + 1)
				ws()
				local d = string.sub(s, pos, pos)
				pos = pos + 1
				if d == "}" then return t end
				if d ~= "," then fail("comma expected") end
			end
		elseif c == "[" then
			pos = pos + 1
			local t = {}
			ws()
			if string.sub(s, pos, pos) == "]" then pos = pos + 1 return t end
			while true do
				t[#t + 1] = value(depth + 1)
				ws()
				local d = string.sub(s, pos, pos)
				pos = pos + 1
				if d == "]" then return t end
				if d ~= "," then fail("comma expected") end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, pos, pos + 3) == "true" then pos = pos + 4 return true
		elseif string.sub(s, pos, pos + 4) == "false" then pos = pos + 5 return false
		elseif string.sub(s, pos, pos + 3) == "null" then pos = pos + 4 return nil
		else
			local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not num or num == "" then fail("unexpected '" .. c .. "'") end
			pos = pos + #num
			return tonumber(num)
		end
	end
	local ok, res = pcall(function()
		local r = value(0)
		ws()
		if pos <= #s then fail("trailing text") end
		return r
	end)
	if not ok then return nil, res end
	if type(res) == "string" and string.match(res, "^%s*[{%[]") then return VlMemory.json(res) end  -- double-encoded
	return res
end

local function argTable(args)
	if type(args) == "table" then return args end
	if type(args) == "string" then
		local t = VlMemory.json(args)
		if type(t) == "table" then return t end
	end
	return {}
end

-- ------------------------------------------------------------------------------------------------ agent functions
-- Optional (the benchmark: the model rarely calls them unprompted, never `recall`): register FUNCTIONS_WRITE (remember,
-- feel_about) with the lead's actions, "[" .. VlMemory.FUNCTIONS_WRITE .. "," .. actions .. "]", and add PERSONA_HINT to
-- the persona. Route calls whose .name is in VlMemory.FUNCTION_NAMES to VlMemory.onCall.
VlMemory.FUNCTION_NAMES = {remember = true, feel_about = true, recall = true}
VlMemory.FUNCTION_REMEMBER = [[{"name": "remember", "description": "Keep something for later days: a promise or a debt, a secret told to you, a wrong or a kindness done to you, news that matters. Never greetings, small talk, the weather, or what you already remember.", "parameters": {"type": "object", "properties": {"text": {"type": "string", "description": "one short line in your own words, first person, with names: 'Alex promised me 5 coins by tomorrow'"}, "importance": {"type": "integer", "description": "2 worth keeping a few days, 3 notable, 4 a big deal to you"}, "kind": {"type": "string", "enum": ["event", "promise", "secret"], "description": "promise: someone owes or promised something (also you to them)"}, "about": {"type": "string", "description": "the names it is about, comma-separated"}}, "required": ["text", "importance"]}}]]
-- feel_about for people only (agents with room for feel_about_creature: Koetama 0.5.15+, proxchat.agentfunctions >= 17)
VlMemory.FUNCTION_FEEL_PEOPLE = [[{"name": "feel_about", "description": "Your opinion of someone changed because of what they did or said to you (never for small talk).", "parameters": {"type": "object", "properties": {"person": {"type": "string", "description": "their name"}, "change": {"type": "integer", "description": "-2 much worse, -1 worse, 1 better, 2 much better"}, "why": {"type": "string", "description": "a few words: 'stole my bread'"}}, "required": ["person", "change", "why"]}}]]
-- feel_about that also takes a creature or thing (16 functions: no room for feel_about_creature)
VlMemory.FUNCTION_FEEL_WIDE = [[{"name": "feel_about", "description": "Your opinion of someone changed because of what they did or said to you (never for small talk). Also for a creature or strange thing: when you first meet one, and whenever your view of it changes, give your feeling and how much its danger frightens YOU.", "parameters": {"type": "object", "properties": {"person": {"type": "string", "description": "their name, or the creature's as you see it"}, "change": {"type": "integer", "description": "a person: -2 much worse, -1 worse, 1 better, 2 much better"}, "feeling": {"type": "string", "enum": ["fear", "hate", "love", "like", "wary", "curious", "revere", "disgust", "pity", "covet", "ignore"], "description": "a creature or thing: your attitude to it"}, "fear_multiplier": {"type": "number", "description": "a creature: how your nature scales its known danger, 0 not afraid at all, 1 as afraid as it deserves, 2 twice as frightened"}, "fear_bonus": {"type": "number", "description": "a creature: -0.5 .. 0.5 more or less fear for a reason of your own, usually 0"}, "why": {"type": "string", "description": "a few words: 'stole my bread', 'it took my brother'"}}, "required": ["person", "why"]}}]]
VlMemory.FUNCTIONS_WRITE = VlMemory.FUNCTION_REMEMBER .. ", " .. VlMemory.FUNCTION_FEEL_WIDE
VlMemory.FUNCTION_RECALL = [[{"name": "recall", "description": "Search your memory for something not in what you know right now (a person, a place, a thing). What you remember about the people near you is already given.", "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "names or words: 'Alex bread'"}}, "required": ["query"]}}]]
VlMemory.FUNCTIONS = VlMemory.FUNCTIONS_WRITE .. ", " .. VlMemory.FUNCTION_RECALL   -- (all three)

-- if the lead registers remember / feel_about, add this to each villager's persona (without it the model almost never
-- calls them: export/memory_report.md)
VlMemory.PERSONA_HINT = "Your memory works through your functions: when someone makes you a promise, tells you a secret, " ..
	"wrongs you or does you a kindness, call remember (and feel_about) as you answer. Never for small talk."

local function resolveName(v, name)
	name = clean(name, 40)
	local k = string.lower(name)
	if v.rel[k] then return v.rel[k].name end
	for _, n in ipairs(v.lastPresent or {}) do if string.lower(n) == k then return n end end
	-- "Alex the stranger" / "alex": a known name at the start
	for rk, r in pairs(v.rel) do
		if #rk >= 3 and string.sub(k, 1, #rk) == rk then return r.name end
	end
	for _, n in ipairs(v.lastPresent or {}) do
		local nk = string.lower(n)
		if #nk >= 3 and string.sub(k, 1, #nk) == nk then return n end
	end
	if name == "" or #name > 24 then return nil end
	return name
end

-- a memory function call from villager id. args: the call's .args JSON, or a table of its .arg.<parameter> texts;
-- (from: the call's speakers, reserved; the model's importance is capped at 4 and its calls rate-limited instead).
-- Returns the text for proxchat.agentcall.<k>.result, or nil when name is not a memory function.
function VlMemory.onCall(id, name, args, from)
	if not VlMemory.FUNCTION_NAMES[name] then return nil end
	local v
	v, id = V(id)
	local a = argTable(args)
	if name == "remember" then
		local text = clean(a.text, VlMemory.TEXT_MAX)
		if text == "" then return "error: nothing to remember" end
		if v.today.rem >= VlMemory.MODEL_REMEMBER_DAY then return "error: your head is full today; keep only what matters" end
		local kind = a.kind
		if kind ~= "promise" and kind ~= "secret" then kind = "event" end
		local imp = clamp(round(tonumber(a.importance) or 2), 1, 4)          -- 5 is for what the game saw
		local who = whoList(a.about or "")
		if #who == 0 then                                                   -- names in the text the villager knows
			for _, r in pairs(v.rel) do if string.find(string.lower(text), string.lower(r.name), 1, true) then who[#who + 1] = r.name end end
		end
		for i, w in ipairs(who) do who[i] = resolveName(v, w) or w end
		local e, new = VlMemory.add(id, {text = text, who = who, importance = imp, kind = kind})
		if not e then return "error: nothing to remember" end
		if not new then return "ok: you already remember that" end
		v.today.rem = v.today.rem + 1
		return "ok: remembered"
	elseif name == "feel_about" then
		local who = resolveName(v, a.person)
		if not who then return "error: who?" end
		local ch = clamp(round(tonumber(a.change) or 0), -2, 2)
		if ch == 0 then return "ok: unchanged" end
		local k = string.lower(who)
		local spent = v.today.feel[k] or 0
		local left = VlMemory.MODEL_FEEL_DAY - spent
		if left <= 0 then return "ok: your mind about " .. who .. " is made up for today" end
		if math.abs(ch) > left then ch = (ch > 0) and left or -left end
		v.today.feel[k] = spent + math.abs(ch)
		local r = VlMemory.feel(id, who, ch, a.why)
		if math.abs(ch) >= 2 and clean(a.why, 80) ~= "" then
			VlMemory.add(id, {text = (ch > 0 and "Warmed to " or "Turned against ") .. who .. ": " .. clean(a.why, 80),
				who = {who}, importance = 2, kind = "opinion", emo = ch})
		end
		return "ok: you now " .. opWord(r.op) .. " " .. who
	elseif name == "recall" then
		return VlMemory.recallText(id, clean(a.query, 120))
	end
	return nil
end

-- ------------------------------------------------------------------------------------------------ the night
VlMemory.SCRIBE_PERSONA = [[You tidy the memory of a villager in a game while they sleep. You get their memories as numbered entries (#id [when, importance 1-5, kind, who] text), the people they know, their lasting facts and what was said today, all on one line with the parts separated by //. Answer only by calling consolidate once.

How to decide:
- drop: trivia nobody will need tomorrow: greetings, small talk, routine work, the weather, walking about, "talked with X" with nothing said. Also every id you merged away.
- merge: lines that tell the same thing or one story become ONE line (ids + new text). Write it in the villager's own words, first person, past tense, short, with the exact names and place.
- new: from "Said today", only what matters later and is not kept yet: a promise or debt, a secret, a threat or insult, a request, real news. Not chatter.
- Never drop or water down: promises and debts, secrets, theft, violence, lies, betrayals, gifts and help from someone, anything of importance 4-5. If unsure, keep (just leave the id out).
- A promise kept or broken today: merge it with what happened (or rewrite it alone) and set its status.
- facts: at most 3 lasting things learned today that will matter for weeks (who someone is to them, a grudge, a debt still open), each a short line, not already in their facts.
- impressions: for each person whose standing changed today, a new one-line impression in the villager's voice and their overall opinion of them now.
- diary: one or two sentences in the villager's own voice about today: what mattered, how they feel about it.
Be brief: leave out any part with nothing to say (no facts or impressions just to fill them).]]

VlMemory.SCRIBE_FUNCTIONS = [[[{"name": "consolidate", "description": "Apply the night's memory changes for one villager. Ids you leave out are kept as they are.", "parameters": {"type": "object", "properties": {
"villager": {"type": "string", "description": "the villager's id from the request"},
"drop": {"type": "array", "items": {"type": "integer"}, "description": "ids of memories to forget"},
"merge": {"type": "array", "items": {"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "integer"}}, "text": {"type": "string", "description": "at most 20 words"}, "importance": {"type": "integer"}, "status": {"type": "string", "enum": ["open", "kept", "broken"], "description": "for a promise or debt"}}, "required": ["ids", "text"]}, "description": "groups of ids that become one memory (one id: a rewrite, e.g. a promise now kept or broken)"},
"new": {"type": "array", "items": {"type": "object", "properties": {"text": {"type": "string", "description": "at most 20 words, first person"}, "importance": {"type": "integer"}, "kind": {"type": "string", "enum": ["event", "promise", "secret"]}, "about": {"type": "string", "description": "names, comma-separated"}}, "required": ["text", "importance"]}, "description": "memories from what was said today that matter and are not kept yet (at most 5)"},
"facts": {"type": "array", "items": {"type": "string"}, "description": "new lasting facts (at most 3, each at most 20 words)"},
"drop_facts": {"type": "array", "items": {"type": "string"}, "description": "ids of facts no longer true (F1, F2, ...)"},
"impressions": {"type": "array", "items": {"type": "object", "properties": {"person": {"type": "string"}, "impression": {"type": "string", "description": "at most 12 words"}, "opinion": {"type": "integer", "description": "their overall opinion of the person now, -5 hate .. 5 love"}}, "required": ["person", "impression"]}},
"diary": {"type": "string", "description": "one or two sentences in the villager's voice, at most 40 words"}}, "required": ["villager", "diary"]}}]
]]

-- the nightly maintenance without the LLM: forget what decayed, merge exact duplicates, cap; a diary line if none
local function nightly(v, id, withDiary)
	local kept = {}
	for _, m in ipairs(v.ep) do
		if protected(m) or keep(m) >= VlMemory.FORGET_BELOW then kept[#kept + 1] = m end
	end
	v.ep = kept
	evict(v)
	if withDiary then
		local today = {}
		for _, m in ipairs(v.ep) do if m.day == M.day and m.kind ~= "talk" then today[#today + 1] = m end end
		byScore(today, function(m) return m.imp + math.abs(m.emo or 0) * 0.5 end)
		local bits = {}
		for i = 1, math.min(2, #today) do bits[#bits + 1] = today[i].t end
		local talks = {}
		for _, m in ipairs(v.ep) do if m.day == M.day and m.kind == "talk" then talks[#talks + 1] = m.who[1] end end
		if #talks > 0 then table.sort(talks); bits[#bits + 1] = "Talked with " .. table.concat(talks, ", ", 1, math.min(3, #talks)) end
		if #bits == 0 then bits[1] = "A quiet day" end
		setDiary(v, table.concat(bits, ". ") .. ".")
	end
	dirty(id)
end

-- night without the LLM (no scribe, it failed or was not worth a request)
function VlMemory.sleepLocal(id)
	local v
	v, id = V(id)
	nightly(v, id, true)
	v.job = nil
	v.log = {}
end

-- how much a villager's day is worth a scribe: what players did with them counts double, chatter little
function VlMemory.dayWeight(id)
	local v
	v, id = V(id)
	local w = 0
	for _, m in ipairs(v.ep) do
		if m.day == M.day and m.kind ~= "talk" then
			local player = false
			for _, n in ipairs(m.who) do if M.players[string.lower(n)] then player = true end end
			w = w + (m.imp - 1) * (player and 2 or 1)
		end
	end
	for _, l in ipairs(v.log) do
		if not l.kept then w = w + ((l.who ~= "me" and M.players[string.lower(l.who)]) and 1 or 0.3) end
	end
	return w
end

-- tonight's plan for villagers going to sleep: the ids (at most max, default JOBS_PER_NIGHT) whose day is worth a
-- scribe job, heaviest first. The lead sends sleepJob(id) for those and calls sleepLocal(id) for the rest.
function VlMemory.nightPlan(ids, max)
	max = max or VlMemory.JOBS_PER_NIGHT
	local list = {}
	for _, id in ipairs(ids or {}) do
		local w = VlMemory.dayWeight(id)
		if w >= VlMemory.JOB_MIN then list[#list + 1] = {id = id, w = w} end
	end
	table.sort(list, function(a, b) if a.w ~= b.w then return a.w > b.w end return tostring(a.id) < tostring(b.id) end)
	local out = {}
	for i = 1, math.min(max, #list) do out[i] = list[i].id end
	return out
end

-- the consolidation request for the scribe agent (its .event text), or nil: then the night was done locally
-- opts.force: a job even for a quiet day; opts.lines: parts on separate lines (default: one line joined by " // ")
function VlMemory.sleepJob(id, opts)
	local v
	v, id = V(id)
	opts = opts or {}
	if VlMemory.dayWeight(id) < VlMemory.JOB_MIN and not opts.force then
		VlMemory.sleepLocal(id)
		return nil
	end
	local L = {}
	local p = M.profiles[id] or {}
	L[#L + 1] = "Villager: " .. nameOf(id) .. " (id " .. id .. ")" .. ((p.blurb and p.blurb ~= "") and (": " .. p.blurb) or "") ..
		". Today is day " .. M.day .. "."
	local rels = {}
	for _, r in pairs(v.rel) do
		rels[#rels + 1] = r.name .. (r.kind == "player" and " (stranger)" or "") .. " " .. (round(r.op) > 0 and "+" or "") ..
			round(r.op) .. (r.imp ~= "" and (" '" .. r.imp .. "'") or "")
	end
	table.sort(rels)
	if #rels > 0 then L[#L + 1] = "People: " .. table.concat(rels, "; ") end
	if #v.facts > 0 then
		local fs = {}
		for _, f in ipairs(v.facts) do fs[#fs + 1] = "F" .. f.id .. " " .. f.t end
		L[#L + 1] = "Facts: " .. table.concat(fs, "; ")
	end
	L[#L + 1] = "Memories, oldest first:"
	local eps = {}
	for _, m in ipairs(v.ep) do eps[#eps + 1] = m end
	table.sort(eps, function(a, b) return a.id < b.id end)
	for _, m in ipairs(eps) do
		local when = (m.day == M.day) and "today" or ("day " .. m.day)
		local t = m.t
		if m.kind == "gossip" and m.src ~= "" then t = (string.match(m.src, "^(.-)<") or m.src) .. " told me: " .. t
		elseif m.src ~= "" then t = t .. " (" .. m.src .. " said)" end
		if (m.n or 1) > 1 then t = t .. " (x" .. m.n .. ")" end
		L[#L + 1] = "#" .. m.id .. " [" .. when .. " " .. string.format("%02d", math.floor(m.hour)) .. "h, " .. m.imp .. ", " ..
			m.kind .. (m.done and (" " .. m.done) or "") .. ((#m.who > 0) and (", " .. table.concat(m.who, ", ")) or "") .. "] " .. t
	end
	if #v.log > 0 then
		L[#L + 1] = "Said today (me = " .. nameOf(id) .. "; worth keeping only through new):"
		for _, l in ipairs(v.log) do
			L[#L + 1] = string.format("%02dh ", math.floor(l.h)) .. l.who .. ": " .. l.t .. (l.kept and (" (kept as #" .. l.kept .. ")") or "")
		end
	end
	L[#L + 1] = "Call consolidate for " .. id .. "."
	v.job = {day = M.day}
	if opts.lines then return table.concat(L, "\n") end
	return table.concat(L, " // ")              -- (one line: a newline in .event would make several events)
end

local function idList(x)
	local out = {}
	if type(x) == "number" or type(x) == "string" then x = {x} end
	if type(x) ~= "table" then return out end
	for _, i in ipairs(x) do
		local n = tonumber(i) or tonumber(string.match(tostring(i), "(%d+)"))
		if n then out[#out + 1] = math.floor(n) end
	end
	return out
end

-- apply the scribe's consolidate call for villager id (args: the call's .args JSON or a table). Tolerates anything:
-- unknown ids, wrong types, a missing part. Returns the call's result text and a summary table.
function VlMemory.sleepResult(id, args)
	local a = argTable(args)
	if (id == nil or id == "") and type(a.villager) == "string" then id = a.villager end
	local v
	v, id = V(id)
	local byId = {}
	for i, m in ipairs(v.ep) do byId[m.id] = i end
	local sum = {dropped = 0, merged = 0, facts = 0, ignored = 0, impressions = 0, diary = false}
	local gone = {}
	-- merges first (an id merged is never also dropped)
	local merges = (type(a.merge) == "table") and a.merge or {}
	if merges.ids then merges = {merges} end
	for _, g in ipairs(merges) do
		if type(g) == "table" then
			local ids = idList(g.ids or g.id)
			local text = phrase(g.text, VlMemory.TEXT_MAX)
			local members = {}
			for _, i in ipairs(ids) do
				if byId[i] and not gone[i] then members[#members + 1] = v.ep[byId[i]] end
			end
			if #members > 0 and text ~= "" then
				table.sort(members, function(x, y) return x.id < y.id end)
				local into = members[1]
				local imp, emo, rc, kind, done = 1, 0, 0, into.kind, true
				local who, seen = {}, {}
				for _, m in ipairs(members) do
					imp = math.max(imp, m.imp)
					if math.abs(m.emo or 0) > math.abs(emo) then emo = m.emo end
					rc = rc + (m.rc or 0)
					if m.kind == "promise" or m.kind == "secret" then kind = m.kind; done = done and m.done end
					if m.kind == "promise" then kind = "promise" end
					if m.day > into.day or (m.day == into.day and m.hour > into.hour) then into.day, into.hour = m.day, m.hour end
					for _, w in ipairs(m.who) do
						if not seen[string.lower(w)] and #who < 4 then seen[string.lower(w)] = true; who[#who + 1] = w end
					end
					if m ~= into then gone[m.id] = true end
				end
				local gi = tonumber(g.importance)
				into.t, into.who, into.rc, into.emo, into.n = text, who, rc, emo, 1
				into.imp = gi and clamp(round(gi), math.max(1, imp - 1), 5) or imp     -- a merge can't bury a memory
				if into.kind ~= "promise" and into.kind ~= "secret" then into.kind = kind end
				if kind == "promise" or kind == "secret" then into.done = done or false end
				if into.kind == "promise" then
					if g.status == "kept" or g.status == "broken" then into.done = g.status
					elseif g.status == "open" then into.done = false end
				end
				if into.kind == "gossip" and #members > 1 then into.kind = "event" end
				sum.merged = sum.merged + 1
			else
				sum.ignored = sum.ignored + 1
			end
		end
	end
	for _, i in ipairs(idList(a.drop)) do
		local k = byId[i]
		if k and not gone[i] then
			local m = v.ep[k]
			local merged = false
			for _, g in ipairs(merges) do
				if type(g) == "table" then for _, j in ipairs(idList(g.ids or g.id)) do if j == i then merged = true end end end
			end
			if merged then
				-- (kept as the merge's target)
			elseif protected(m) then
				sum.ignored = sum.ignored + 1
			else
				gone[i] = true
				sum.dropped = sum.dropped + 1
			end
		elseif not k then
			sum.ignored = sum.ignored + 1
		end
	end
	local kept = {}
	for _, m in ipairs(v.ep) do if not gone[m.id] then kept[#kept + 1] = m end end
	v.ep = kept
	-- facts
	if type(a.drop_facts) == "table" then
		for _, f in ipairs(idList(a.drop_facts)) do
			for i, x in ipairs(v.facts) do if x.id == f then table.remove(v.facts, i) break end end
		end
	end
	local facts = a.facts
	if type(facts) == "string" then facts = {facts} end
	if type(facts) == "table" then
		local n = 0
		for _, f in ipairs(facts) do
			if type(f) == "table" then f = f.text or f.fact end
			if type(f) == "string" and clean(f) ~= "" and n < 3 then
				VlMemory.addFact(id, f)
				n = n + 1
			end
		end
		sum.facts = n
	end
	if type(a.impressions) == "table" then
		local list = a.impressions
		if list.person then list = {list} end
		for _, x in ipairs(list) do
			if type(x) == "table" and type(x.person) == "string" and type(x.impression) == "string" then
				local nm = resolveName(v, x.person)
				local r = nm and v.rel[string.lower(nm)]
				if r then
					r.imp = phrase(x.impression, VlMemory.IMPRESSION_MAX)
					local op = tonumber(x.opinion)
					if op then r.op = clamp(clamp(op, r.op - 2, r.op + 2), -5, 5) end   -- a night moves it 2 at most
					sum.impressions = sum.impressions + 1
				end
			end
		end
	end
	local diary = (type(a.diary) == "string") and clean(a.diary, VlMemory.DIARY_MAX) or ""
	if diary ~= "" then setDiary(v, diary); sum.diary = true end
	-- new memories from what was said today
	local news = a.new
	if type(news) == "table" and news.text then news = {news} end
	sum.new = 0
	if type(news) == "table" then
		for _, x in ipairs(news) do
			if type(x) == "table" and type(x.text) == "string" and sum.new < 5 then
				local k = (x.kind == "promise" or x.kind == "secret") and x.kind or "event"
				local who = whoList(x.about or x.who or "")
				for i, w in ipairs(who) do who[i] = resolveName(v, w) or w end
				local e, isNew = VlMemory.add(id, {text = x.text, who = who, importance = clamp(round(tonumber(x.importance) or 2), 1, 4), kind = k})
				if e and isNew then sum.new = sum.new + 1 end
			end
		end
	end
	nightly(v, id, diary == "")
	v.job = nil
	v.log = {}
	return "ok: " .. sum.dropped .. " forgotten, " .. sum.merged .. " merged, " .. sum.new .. " new, " .. sum.facts .. " facts", sum
end

-- once a morning, for the whole village (before the villagers' personas are rebuilt with forPersona)
function VlMemory.newDay()
	M.day = M.day + 1
	M.dayDirty = true
end

-- ------------------------------------------------------------------------------------------------ gossip
local function thirdPerson(text, teller)
	local t = " " .. text .. " "
	t = string.gsub(t, "([^%w'])[Mm]yself([^%w'])", "%1" .. teller .. "%2")
	t = string.gsub(t, "([^%w'])[Mm]ine([^%w'])", "%1" .. teller .. "'s%2")
	t = string.gsub(t, "([^%w'])[Mm]y([^%w'])", "%1" .. teller .. "'s%2")
	t = string.gsub(t, "([^%w'])me([^%w'])", "%1" .. teller .. "%2")
	t = string.gsub(t, "([^%w'])I'm([^%w'])", "%1" .. teller .. " is%2")
	t = string.gsub(t, "([^%w'])I've([^%w'])", "%1" .. teller .. " has%2")
	t = string.gsub(t, "([^%w'])I([^%w'])", "%1" .. teller .. "%2")
	t = string.gsub(t, "([^%w'])[Ww]e([^%w'])", "%1" .. teller .. " and others%2")
	t = string.gsub(t, "^ ", "")
	t = string.gsub(t, " $", "")
	return t
end
VlMemory._thirdPerson = thirdPerson

local SPIN = {"", "", "", " (or so they say)", " - and not for the first time", " - and wasn't sorry"}

-- villager a tells villager b its juiciest shareable memory (off-screen, no LLM). Both remember talking (at place);
-- b's opinion of the people in it drifts toward a's, as far as b trusts a. Returns the gossip text b now remembers
-- (the lead may have b say it when a player is near), or nil when a had nothing to tell.
function VlMemory.gossip(a, b, place)
	local va, ia = V(a)
	local vb, ib = V(b)
	local nameA, nameB = nameOf(ia), nameOf(ib)
	VlMemory.meet(ia, nameB, place, "villager")
	VlMemory.meet(ib, nameA, place, "villager")
	-- b already knows these (by origin)
	local known = {}
	for _, m in ipairs(vb.ep) do if m.org then known[m.org] = true end end
	local cand = {}
	for _, m in ipairs(va.ep) do
		local hops = m.hops or 0
		local aboutB = false
		for _, w in ipairs(m.who) do if string.lower(w) == string.lower(nameB) then aboutB = true end end
		local org = m.org or (ia .. ":" .. m.id)
		if m.kind ~= "secret" and m.kind ~= "talk" and m.kind ~= "opinion" and m.imp >= 3 and hops < 2 and not aboutB
			and not known[org] and #m.who > 0 then
			cand[#cand + 1] = m
		end
	end
	if #cand == 0 then return nil end
	byScore(cand, function(m)
		local s = keep(m) + math.abs(m.emo or 0)
		for _, w in ipairs(m.who) do
			local r = va.rel[string.lower(w)]
			if r and r.kind == "player" then s = s + 1 end
		end
		return s
	end)
	local pick = cand[1]
	if #cand > 1 and VlRand() < 0.35 then pick = cand[2] end
	local core = (pick.kind == "gossip") and pick.t or thirdPerson(pick.t, nameA)
	local imp = math.max(2, pick.imp - 1)
	local r = VlRand()
	local spin = SPIN[math.floor(r * #SPIN) + 1]
	if spin ~= "" then imp = math.min(4, imp + 1) end
	local src = nameA
	if pick.kind == "gossip" then src = nameA .. "<" .. (string.match(pick.src or "", "^(.-)<") or pick.src or "someone") end
	local e = VlMemory.add(ib, {text = cut(core, VlMemory.TEXT_MAX - #spin) .. spin, who = pick.who, where = pick.where,
		importance = imp, kind = "gossip", emo = pick.emo, src = src})
	if e then
		e.org = pick.org or (ia .. ":" .. pick.id)
		e.hops = (pick.hops or 0) + 1
	end
	pick.rc = (pick.rc or 0) + 1
	local trust = clamp(((vb.rel[string.lower(nameA)] or {op = 0}).op + 5) / 10, 0, 1)
	for _, w in ipairs(pick.who) do
		if string.lower(w) ~= string.lower(nameB) then
			local ra = va.rel[string.lower(w)]
			if ra and ra.op ~= 0 then
				local rb = relFor(vb, w, ra.kind)
				rb.op = clamp(rb.op + clamp(ra.op * 0.25 * trust, -1, 1), -5, 5)
				if rb.imp == "" then rb.imp = cut("heard: " .. core, VlMemory.IMPRESSION_MAX) end
			end
		end
	end
	dirty(ia); dirty(ib)
	return nameA .. " says " .. core .. spin, e
end

-- ------------------------------------------------------------------------------------------------ persistence
local ESC_SET = "[%%|~,<>&\"'\1-\31\127]"
local function esc(s)
	return (string.gsub(tostring(s or ""), ESC_SET, function(c) return string.format("%%%02X", string.byte(c)) end))
end
local function unesc(s)
	return (string.gsub(s or "", "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
VlMemory._esc, VlMemory._unesc = esc, unesc

local function split(s, sep)
	local out = {}
	if s == nil or s == "" then return out end
	local i = 1
	while true do
		local j = string.find(s, sep, i, true)
		if not j then out[#out + 1] = string.sub(s, i) break end
		out[#out + 1] = string.sub(s, i, j - 1)
		i = j + 1
	end
	return out
end

local function encWho(who)
	local t = {}
	for _, w in ipairs(who or {}) do t[#t + 1] = esc(w) end
	return table.concat(t, ",")
end

local function encEp(m)
	return table.concat({m.id, m.day, round(m.hour * 10), m.imp, m.kind, m.rc or 0, m.emo or 0, m.n or 1,
		(m.done == "broken") and 2 or (m.done and 1 or 0), m.hops or 0, esc(m.org or ""), esc(m.src or ""), encWho(m.who), esc(m.where or ""), esc(m.t)}, "~")
end

local function decEp(s)
	local f = split(s, "~")
	if #f ~= 15 then return nil end
	local m = {id = tonumber(f[1]), day = tonumber(f[2]), hour = (tonumber(f[3]) or 120) / 10, imp = tonumber(f[4]),
		kind = f[5], rc = tonumber(f[6]) or 0, emo = tonumber(f[7]) or 0, n = tonumber(f[8]) or 1, done = (f[9] == "1" and "kept") or (f[9] == "2" and "broken") or false,
		hops = tonumber(f[10]) or 0, src = clean(unesc(f[12]), 40), where = clean(unesc(f[14]), 40), t = clean(unesc(f[15]), VlMemory.TEXT_MAX)}
	if not m.id or not m.day or not m.imp or m.t == "" then return nil end
	if not KINDS[m.kind] then m.kind = "event" end
	m.imp = clamp(round(m.imp), 1, 5)
	m.emo = clamp(round(m.emo), -3, 3)
	m.hour = clamp(m.hour, 0, 24)
	local org = unesc(f[11])
	if org ~= "" then m.org = org end
	if m.hops == 0 then m.hops = nil end
	m.who = {}
	for _, w in ipairs(split(f[13], ",")) do
		local c = clean(unesc(w), 40)
		if c ~= "" then m.who[#m.who + 1] = c end
	end
	return m
end

local function encRel(r)
	return table.concat({esc(r.name), string.format("%.2f", r.op), r.fam, esc(r.kind or ""), r.day or 0, esc(r.imp or "")}, "~")
end

local function decRel(s)
	local f = split(s, "~")
	if #f ~= 6 then return nil end
	local r = {name = clean(unesc(f[1]), 40), op = clamp(tonumber(f[2]) or 0, -5, 5), fam = clamp(math.floor(tonumber(f[3]) or 0), 0, 99),
		kind = clean(unesc(f[4]), 12), day = tonumber(f[5]) or 0, imp = clean(unesc(f[6]), VlMemory.IMPRESSION_MAX)}
	if r.name == "" then return nil end
	return r
end

local function encode(v)
	local eps, rels, facts, diary = {}, {}, {}, {}
	for _, m in ipairs(v.ep) do eps[#eps + 1] = encEp(m) end
	local rk = {}
	for k in pairs(v.rel) do rk[#rk + 1] = k end
	table.sort(rk)
	for _, k in ipairs(rk) do rels[#rels + 1] = encRel(v.rel[k]) end
	for _, f in ipairs(v.facts) do facts[#facts + 1] = f.id .. "~" .. f.day .. "~" .. esc(f.t) end
	for _, d in ipairs(v.diary) do diary[#diary + 1] = d.day .. "~" .. esc(d.t) end
	return {e = table.concat(eps, "|"), r = table.concat(rels, "|"), f = table.concat(facts, "|"),
		d = table.concat(diary, "|"), n = v.nid .. "~" .. v.nfact}
end

local function size(enc) return #enc.e + #enc.r + #enc.f + #enc.d + #enc.n end

local function write(id)
	local v = M.v[id]
	if not v then return end
	local enc = encode(v)
	while size(enc) > VlMemory.SAVE_BYTES and #v.ep > 0 do       -- over budget: the least worth keeping goes
		local wi, ws = 1, 1e9
		for i, m in ipairs(v.ep) do
			local s = keep(m) + (protected(m) and 100 or 0)
			if s < ws then wi, ws = i, s end
		end
		table.remove(v.ep, wi)
		enc = encode(v)
	end
	local k = M.base .. ".mem." .. id .. "."
	SetString(k .. "v", "1")
	SetString(k .. "e", enc.e)
	SetString(k .. "r", enc.r)
	SetString(k .. "f", enc.f)
	SetString(k .. "d", enc.d)
	SetString(k .. "n", enc.n)
	M.dirty[id] = nil
	M.wrote[id] = now()
	M.lastWrite = now()
end

local function writeDay()
	SetInt(M.base .. ".memday", M.day)
	M.dayDirty = false
end

local function load(id)
	local k = M.base .. ".mem." .. id .. "."
	local v = newV()
	if GetString(k .. "v") ~= "1" then return v end
	local n = split(GetString(k .. "n"), "~")
	v.nid, v.nfact = math.max(1, tonumber(n[1]) or 1), math.max(1, tonumber(n[2]) or 1)
	for _, s in ipairs(split(GetString(k .. "e"), "|")) do
		local ok, m = pcall(decEp, s)
		if ok and m then
			v.ep[#v.ep + 1] = m
			if m.id >= v.nid then v.nid = m.id + 1 end
		end
	end
	for _, s in ipairs(split(GetString(k .. "r"), "|")) do
		local ok, r = pcall(decRel, s)
		if ok and r then v.rel[lowerKey(r.name)] = r end
	end
	for _, s in ipairs(split(GetString(k .. "f"), "|")) do
		local f = split(s, "~")
		local fid, fday, t = tonumber(f[1]), tonumber(f[2]), clean(unesc(f[3] or ""), VlMemory.FACT_MAX)
		if fid and fday and t ~= "" and #f == 3 then
			v.facts[#v.facts + 1] = {id = fid, day = fday, t = t}
			if fid >= v.nfact then v.nfact = fid + 1 end
		end
	end
	for _, s in ipairs(split(GetString(k .. "d"), "|")) do
		local f = split(s, "~")
		local dday, t = tonumber(f[1]), clean(unesc(f[2] or ""), VlMemory.DIARY_MAX)
		if dday and t ~= "" and #f == 2 then v.diary[#v.diary + 1] = {day = dday, t = t} end
	end
	while #v.ep > VlMemory.CAP do table.remove(v.ep, 1) end
	while #v.facts > VlMemory.FACT_CAP do table.remove(v.facts, 1) end
	while #v.diary > VlMemory.DIARY_KEEP do table.remove(v.diary, 1) end
	return v
end

-- loads savegame.mod.vl.<levelKey>.* (every villager saved for this map)
function VlMemory.init(levelKey)
	M.lk = regName(levelKey or "default")
	M.base = "savegame.mod.vl." .. M.lk
	M.v, M.dirty, M.wrote, M.lastWrite = {}, {}, {}, -1e9
	M.day = math.max(1, GetInt(M.base .. ".memday"))
	local ids = ListKeys and ListKeys(M.base .. ".mem") or {}
	for _, id in ipairs(ids) do
		local ok, v = pcall(load, id)
		M.v[id] = (ok and v) or newV()
	end
end

-- mark for writing (written by tick within SAVE_MIN s); force: write now
function VlMemory.save(id, force)
	id = regName(id)
	M.dirty[id] = true
	if force then write(id) end
end

-- each server tick: writes at most one changed villager every SAVE_GAP s, none more often than SAVE_MIN s
function VlMemory.tick(dt)
	if M.dayDirty then writeDay() end
	local t = now()
	if t - M.lastWrite < VlMemory.SAVE_GAP then return end
	local ids = {}
	for id in pairs(M.dirty) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		if t - (M.wrote[id] or -1e9) >= VlMemory.SAVE_MIN then write(id) return end
	end
end

-- write everything changed now (the morning, before a level change)
function VlMemory.flush()
	if M.dayDirty then writeDay() end
	local ids = {}
	for id in pairs(M.dirty) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do write(id) end
end

-- forget a map's village entirely (a reset option)
function VlMemory.wipe()
	ClearKey(M.base)
	M.v, M.dirty, M.day = {}, {}, 1
end

function VlMemory.stats(id)
	local v = V(id)
	local n = 0
	for _ in pairs(v.rel) do n = n + 1 end
	return {episodes = #v.ep, people = n, facts = #v.facts, diary = #v.diary, bytes = size(encode(v)), day = M.day}
end
