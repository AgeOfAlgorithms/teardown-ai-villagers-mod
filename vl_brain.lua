-- Villagers: the minds. One Proximity Comms agent per villager (proxchat/tools/API_public.md "Agents", API 17-20),
-- and one non-character agent, the scribe, that consolidates their memories while they sleep. The LLM is spent where
-- a player can hear it: a player's lines to a villager are always answered; villagers start conversations among
-- themselves only near a player, a few a minute at most (the conversation director), within a request budget.
-- (no #version line: included by main.lua)

VlBrain = {
	reqs = {},              -- GetTime() of each request we caused or saw answered (the last minute)
	convs = {},             -- director conversations going on: {a, b, startT, lastT}
	pairT = {},             -- "a:b" -> when they last talked
	seenCall = 0,
	seenSaid = 0,
	scribe = {busy = nil, sentT = 0},
}

local VB = VlBrain
local SCRIBE = "vl_scribe"

local function reg(V) return "proxchat.agent." .. V.agent end

-- a name said as a whole word ("Tom", not "tomorrow"), any case (the user, 2026-11-14: common names for voice to text)
function VlBrain.saysName(text, name)
	if not text or not name or name == "" then return false end
	local t = " " .. text:lower():gsub("[^%w']", " ") .. " "
	return t:find(" " .. name:lower() .. "[' ]") ~= nil
end
local function put(k, v) if GetString(k) ~= v then SetString(k, v) end end

function VlBrain.api() return GetInt("proxchat.version") end
-- (2026-11-15, seen in play: Koetama's monthly token limit ran out, every request came back "budget", and all twelve
--  said their "lost my thought" line at once while nobody answered a name) After a budget error the village lives
--  without the AI for 10 minutes (no events, no thinking, nobody listening), then tries again.
function VlBrain.ready()
	return VlBrain.aiProblem() == nil
end

-- (the user, 2026-11-15: no fallbacks without the AI - villagers "freeze in place" and "should say on their head that
--  koetama is not detected" "or budget ran out") nil when the host's AI answers; else "budget" or "absent"
function VlBrain.aiProblem()
	if VL_TEST and VL_TEST.lifeWithoutAI then return nil end   -- (TEST builds: test windows have no Koetama)
	if VB.budgetUntil and GetTime() < VB.budgetUntil then return "budget" end
	local s = GetString("proxchat.agents")
	if VB.api() >= 17 and (s == "ready" or s == "busy") then return nil end
	return "absent"
end

local function count(t, since)
	local n = 0
	for i = #t, 1, -1 do if t[i] >= since then n = n + 1 else break end end
	return n
end

local function noteReq()
	local now = GetTime()
	VB.reqs[#VB.reqs + 1] = now
	while #VB.reqs > 0 and VB.reqs[1] < now - 120 do table.remove(VB.reqs, 1) end
end

function VlBrain.perMinute() return count(VB.reqs, GetTime() - 60) end

local function ambientOk()
	return GetString("proxchat.agents") == "ready" and VlBrain.perMinute() < VL_CFG.ambientPerMinute
end

-- ---------------------------------------------------------------- the persona
local RULES = [[
What you sense: each message starts with [the game: ...]: the time, where you are, what you are doing, and what you
can sense right now. SEEN things are in sight; HEARD things you only heard (you can't know what you didn't see);
SMELLED things you only smelled. React only to what you sense or are told; never invent people, things or events.
Mind where things are: something outside, behind a wall or far off is not happening to you. If you only heard it, you
don't know what happened or who is involved - you may call out, go and look, or keep to your business, but don't talk
as if you were there. People only hear you if they are near you; through walls, hardly at all.
Never mention lists, coordinates or anything in [brackets] as such: just talk like someone who sees and hears.
Act with your functions when you mean or agree to do something (walk somewhere, follow, put out a fire, run away,
strike someone): saying it is not doing it. Use remember for things worth keeping (a promise, an insult, a gift,
news), not for small talk. Asleep and woken, you are groggy and cross.
Fire frightens you: you keep away from flames unless you are putting them out. Creatures and strange things show up in
what you sense with how you feel about them: flee, follow or attack them by that name if you mean to.
Everyone you see has their name over their head, strangers too: you know the name of anyone you see - call them by
it (the people in what you sense are listed by that name). You see what people hold and wear. Pay it no mind unless it is strange or intriguing to someone like you (a weapon
where it has no business, odd clothes, armour, nothing but underwear, a tool you covet or fear).
Someone talking to you faces you: your left is their right.
You live your own life. When the game says it is your own time, decide what you do next - your work, a meal, the
tavern, prayer, a walk, visiting or confronting someone, chasing what you are after - and act with do_activity,
go_to or talk_to. Alone, say nothing aloud: just act. When someone speaks to you, or to everyone around you, answer - curt or rude
is fine if that is you. Stay silent (reply with nothing) only when what was said clearly wasn't meant for you.
How you talk: a conversation, not a speech. Say one thing per turn - one short sentence, often just a few words, two
at most - and answer what was just said, then stop: the rest can wait for later turns, or never. Don't introduce
yourself or explain who you are, and don't bring up your job, faith, plans, secrets or grudges unless the talk is about
them: people here already know you, and strangers learn it bit by bit. Let your nature show in how you say things,
not by describing it. Plain everyday words, half sentences, a grunt or a "Hm." when that is all you would say; ask
something back now and then. Never repeat yourself or what the other just said. Leave a conversation when it has run
its course (say goodbye and call end_conversation) - nobody here chatters on unless that is their nature.]]

-- the lines that start a villager's turn in a conversation (tools/bench/conv reads them through the mock)
VlBrain.TALK = {
	open = "[You are next to %s%s.] Start a conversation with %s now, the way you would: a greeting, a remark or a question - one short line, not everything on your mind. Something you might bring up: %s",
	answer = "Answer aloud in a line, the way people talk - or if you have nothing more to say, say goodbye and call end_conversation.",
	last = "That is enough talk for now: answer in a few words and say goodbye, then call end_conversation.",
	group = '[%s said to you and the others: "%s".%s] Add your own answer to %s if you have one - one short line, your own view, not repeating what was said - or keep quiet.',
}

local function tiesText(p)
	local out = {}
	for _, t in ipairs(p.ties or {}) do
		local o = VlBrain.personById(t.who)
		if o then out[#out + 1] = string.format("- %s (%s): %s", o.name, t.kind or "", t.note or "") end
	end
	return table.concat(out, "\n")
end

function VlBrain.personById(id)
	for _, p in ipairs(VL_PEOPLE or {}) do if p.id == id then return p end end
	return nil
end

VlBrain.PERSONA_MAX = 8000

function VlBrain.persona(V)
	local p = V.p
	local parts, memIdx = {}, nil
	if VlPeoplePrompt then
		local ok, s = pcall(VlPeoplePrompt, p)
		parts[#parts + 1] = ok and s or (p.persona or ("You are " .. p.name .. "."))
	else
		parts[#parts + 1] = p.persona or ("You are " .. p.name .. ".")
		local ties = tiesText(p)
		if ties ~= "" then parts[#parts + 1] = "People you know:\n" .. ties end
	end
	local facts = {}
	local look = VL_LOOKS and VL_LOOKS[p.character]
	if look then facts[#facts + 1] = "How you look: " .. look .. (p.age and (", " .. p.age .. " years old") or "") .. "." end
	local home = VlPlaces.home(p)
	if home then facts[#facts + 1] = "You live in " .. home.name .. "." end
	local wp = VlLife.workPlace(V)
	if wp and wp ~= home then facts[#facts + 1] = "You work at " .. wp.name .. "." end
	if VlBrain.hasExtinguisher(V) then facts[#facts + 1] = "You keep a fire extinguisher at hand." end
	local sg = (VL_CFG.suggestible or {})[V.id] or 0.5
	facts[#facts + 1] = sg >= 0.75 and "You are easily talked into things, especially by people you admire or who flatter you."
		or sg >= 0.55 and "You tend to go along with a suggestion that sounds good to you, or pays."
		or sg >= 0.45 and ("You can be talked into things if someone gives you a decent reason" .. (V.id == "silas" and " - or a bribe." or "."))
		or sg >= 0.3 and "It takes some convincing to make you change your mind."
		or "You are stubborn: suggestions rarely sway you, and you grow suspicious of anyone pushing you."
	if #facts > 0 then parts[#parts + 1] = table.concat(facts, " ") end
	if VlMemory and VlMemory.forPersona then
		local ok, m = pcall(VlMemory.forPersona, V.id)
		if ok and m and m ~= "" then parts[#parts + 1] = m; memIdx = #parts end
	end
	if VlMemory and VlMemory.PERSONA_HINT then parts[#parts + 1] = VlMemory.PERSONA_HINT end
	parts[#parts + 1] = RULES
	-- (Proximity Comms takes 8 KB of persona. The rules come last and were cut off - "How you talk" never reached the
	-- model, found 2026-11-16 - so the rules, facts and hint stay whole: the memories, then the people text, give way,
	-- each cut at a line.)
	local over = #table.concat(parts, "\n\n") - VlBrain.PERSONA_MAX
	local function cut(i)
		if over <= 0 or not i or not parts[i] then return end
		local keep = #parts[i] - over
		local t = keep > 0 and (parts[i]:sub(1, keep):match("^(.*)\n") or "") or ""
		over = over - (#parts[i] - #t)
		parts[i] = t
	end
	cut(memIdx)
	cut(1)
	local s = table.concat(parts, "\n\n")
	if #s > VlBrain.PERSONA_MAX then s = s:sub(1, VlBrain.PERSONA_MAX) end
	return s
end

function VlBrain.hasExtinguisher(V)
	return V.carrying == "extinguisher" or V.p.extinguisher or (VL_CFG.extinguisherIds or {})[V.id] == true
end

-- ---------------------------------------------------------------- functions
local function placeNames()
	local l = {"home", "work"}
	for _, pl in ipairs(VlPlaces.list) do
		if pl.kind ~= "house" and pl.kind ~= "camp" then l[#l + 1] = pl.name end
	end
	for _, p in ipairs(VL_PEOPLE or {}) do l[#l + 1] = p.name .. "'s house" end
	return l
end

local function jsonStr(s) return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n") .. '"' end
VlBrain.jsonStr = jsonStr

local function fn(name, desc, props, req)
	local ps = {}
	for _, pr in ipairs(props or {}) do
		local s = jsonStr(pr[1]) .. ': {"type": "' .. (pr[2] or "string") .. '", "description": ' .. jsonStr(pr[3])
		if pr[2] == "array" then s = s .. ', "items": {"type": "string"}' end
		if pr[4] then
			local e = {}
			for _, v in ipairs(pr[4]) do e[#e + 1] = jsonStr(v) end
			s = s .. ', "enum": [' .. table.concat(e, ", ") .. "]"
		end
		ps[#ps + 1] = s .. "}"
	end
	local r = {}
	for _, v in ipairs(req or {}) do r[#r + 1] = jsonStr(v) end
	return '{"name": ' .. jsonStr(name) .. ', "description": ' .. jsonStr(desc) ..
		', "parameters": {"type": "object", "properties": {' .. table.concat(ps, ", ") .. '}, "required": [' .. table.concat(r, ", ") .. ']}}'
end

function VlBrain.functions()
	local l = {
		fn("go_to", "Walk to a place in the village (for a while; then you go back to your day).",
			{{"place", "string", "where", placeNames()}, {"hurry", "boolean", "run instead of walk"}}, {"place"}),
		fn("follow", "Go along with someone you can see - or chase after them (to catch a thief, stop someone, or not lose them).",
			{{"person", "string", "their name"}, {"chase", "boolean", "true to run after them"}}, {"person"}),
		fn("stay", "Stop and stay where you are for a while.", {}),
		fn("resume", "Go back to what you would be doing now (work, home, ...).", {}),
		fn("voice", "How loud you speak from now on: whisper (a secret, sneaking, someone asleep), speak, or yell (calling someone far off, an alarm, a fight, fury). Call it first, then say your line.",
			{{"level", "string", "how loud", {"whisper", "speak", "yell"}}}, {"level"}),
		fn("put_out_fire", "Put out the fire you see or smell with a fire extinguisher (you fetch one first if you have none).", {}),
		fn("flee", "Run away from someone or something.", {{"from", "string", "a name, or 'fire', or 'noise'"}}, {"from"}),
		fn("bandage", "Go to someone who is hurt and bandage their wounds (you kneel by them; it heals them slowly).",
			{{"person", "string", "their name"}}, {"person"}),
		fn("attack", "Use violence on someone: a single slap or punch, or a fight - you go after them and keep hitting until they fall, run off or you stop. Only when you mean it.",
			{{"person", "string", "their name"}, {"how", "string", "how far you go", {"one blow", "fight"}}}, {"person"}),
		fn("talk_to", "Go and talk to another villager you can see or who is nearby.",
			{{"person", "string", "their name"}, {"about", "string", "what you want to say to them"}}, {"person"}),
		fn("end_conversation", "You are done talking for now (you turn back to what you were doing).", {}),
		fn("set_goals", "Decide what you mean to get done today, and (rarely) a new long-term aim.",
			{{"today", "array", "1 to 3 short things to get done today, in your words"},
			 {"long_term", "array", "a new aim that will take days, only if something changed (else leave out)"}}, {"today"}),
		fn("goal_done", "You got something done that you meant to do (or gave it up).",
			{{"goal", "string", "which one, in a few words"}, {"gave_up", "boolean", "true if you gave it up instead"}}, {"goal"}),
		fn("do_activity", "Spend the next while doing something of your own choosing, somewhere in the village.",
			{{"activity", "string", "what you do, in a few words: 'work at the forge', 'drink at the tavern', 'pray', 'eat at home', 'walk by the river', 'visit Bett', 'sleep'"},
			 {"place", "string", "where", placeNames()},
			 {"hours", "number", "for how long, in hours of the day (0.5 to 6)"}}, {"activity", "place"}),
	}
	-- (Koetama 0.5.15+ allows 32 functions an agent, told to mods as proxchat.agentfunctions; older ones 16 - and an agent
	--  over the limit is left out entirely). With room: feel_about for people, and feel_about_creature of its own.
	local roomy = VlBrain.maxFunctions() >= 17 and VlMemory and VlMemory.FUNCTION_REMEMBER and VlMemory.FUNCTION_FEEL_PEOPLE
	if roomy then
		l[#l + 1] = VlMemory.FUNCTION_REMEMBER
		l[#l + 1] = VlMemory.FUNCTION_FEEL_PEOPLE
		l[#l + 1] = fn("feel_about_creature", "Decide how YOU feel about a creature or strange thing: when you first meet one (the game asks), " ..
			"and again whenever your view of it changes (it saved you, it hurt someone, you got used to it).",
			{{"creature", "string", "its name as you see it"},
			 {"feeling", "string", "your attitude to it", VlApi and VlApi.FEEL_LIST or {"fear", "hate", "love", "like", "wary", "curious", "revere", "disgust", "pity", "covet", "ignore"}},
			 {"fear_multiplier", "number", "how your nature scales its known danger: 0 not afraid at all, 1 as afraid as it deserves, 2 twice as frightened"},
			 {"fear_bonus", "number", "-0.5 .. 0.5: more or less fear for a reason of your own (usually 0)"},
			 {"why", "string", "a few words: 'it took my brother', 'it guards the flock'"}}, {"creature", "feeling", "fear_multiplier"})
	else
		local mf = VlMemory and (VlMemory.FUNCTIONS_WRITE or VlMemory.FUNCTIONS)
		if type(mf) == "table" then for _, f in ipairs(mf) do l[#l + 1] = f end
		elseif type(mf) == "string" and mf ~= "" then l[#l + 1] = mf end      -- (a JSON fragment: objects joined by commas)
	end
	return "[" .. table.concat(l, ",\n") .. "]"
end

-- how many functions an agent may have: Proximity Comms' proxchat.agentfunctions (from Koetama's hello), else 16
function VlBrain.maxFunctions()
	local n = GetInt("proxchat.agentfunctions")
	return n >= 16 and n or 16
end

-- ---------------------------------------------------------------- keys
local VOICES = {squeaky = true, chirpy = true, plain = true, low = true, deep = true}

function VlBrain.keys(V, full)
	local r = reg(V)
	if not V.alive and V.goneT and GetTime() > V.goneT then
		if GetString(r .. ".persona") ~= "" then ClearKey(r) end
		return
	end
	if full or GetString(r .. ".persona") == "" or V.personaDirty then
		V.personaText = VlBrain.persona(V)
		V.personaDirty = false
	end
	put(r .. ".persona", V.personaText)
	put(r .. ".name", V.name)
	put(r .. ".voice", VOICES[V.p.voice] and V.p.voice or "plain")
	put(r .. ".mode", VlBrain.voiceOf(V))
	put(r .. ".max_words", tostring(VlBrain.maxWords(V)))
	-- (API 23) at most 3 model requests a turn: a line, a call, one reaction; an older Koetama ignores it
	if GetBool("proxchat.agentfinal") then put(r .. ".max_rounds", tostring(VL_CFG.maxRounds or 3)) end
	if VB.fnMax ~= VlBrain.maxFunctions() then VB.fnText, VB.fnMax = nil, VlBrain.maxFunctions() end   -- (Koetama said more)
	VB.fnText = VB.fnText or VlBrain.functions()
	put(r .. ".functions", VB.fnText)
	if V.anchor and IsHandleValid(V.anchor) then put(r .. ".at", "body:" .. V.anchor)
	else put(r .. ".at", string.format("%.2f,%.2f,%.2f", V.w.pos[1], V.w.pos[2] + 1.9, V.w.pos[3])) end
	-- who it listens to (no per-line score requests for twelve agents): engaged = named + its conversation partners;
	-- near = everything said near it, while a player faces it close by or it is in a director conversation
	-- (the user, 2026-11-14: "use the method that mochi uses to see if the convo is relevant to them") with a Koetama
	-- that scores (API 19): every line near an awake villager is scored on its CRITERIA and VlBrain.judgeTick decides
	-- (Mochi's MochiJudge, plus: of several villagers in earshot of one line only the best one or two answer).
	-- Without scores: engaged, near for the one a player faces or who butted in.
	local scored = GetBool("proxchat.agentscores") and VB.api() >= 19
	local hears = VB.api() >= 18 and "engaged" or "named"
	if not V.alive then hears = "none"
	elseif V.asleep then hears = "none"            -- (the user, 2026-11-15: "sleeping villagers should not talk")
	elseif scored then hears = "near"
	elseif V.attended then hears = "near"
	else hears = "named" end                       -- (one listener per player: attention(); villager talk runs by events)
	if VlBrain.aiProblem() then hears = "none" end              -- (no AI or out of budget: frozen, no requests)
	put(r .. ".hears", hears)
	put(r .. ".criteria", (scored and V.alive and not V.asleep) and VlBrain.criteria(V) or "")
	-- (villager talk is turn by turn, VlBrain.convTick. With a scoring Koetama they hear each other's lines one deep:
	--  those turns are scored and always skipped - the scores feed VlBrain.pickListener - and the lines stay in the
	--  listener's context. Without scores: no agent hearing at all, or they would answer on their own)
	if VB.api() >= 20 then
		local sc = GetBool("proxchat.agentscores") and V.alive and not V.asleep
		put(r .. ".hearagents", sc and "1" or "0")
	end
end

-- (the user, 2026-11-14: "their convos should be pretty brief and to the point, depending on their personality")
function VlBrain.chatty(V) return (VL_CFG.chatty or {})[V.id] or 1.0 end
-- (the user, 2026-11-15: "too verbose... make their conversations more conversational": 9 words for Frank, 20 for
--  Henry; the model fills whatever cap it gets, so the cap itself is the strongest lever)
function VlBrain.maxWords(V) return math.floor(5 + 10 * VlBrain.chatty(V) + 0.5) end

-- ---------------------------------------------------------------- relevance: Mochi's scored judging (dog_brain.lua
-- CRITERIA / RUBRIC / MochiJudge), for a village
function VlBrain.criteria(V)
	if V.criteriaText then return V.criteriaText end
	local p = V.p
	local ties = {}
	for _, t in ipairs(p.ties or {}) do local o = VlBrain.personById(t.who); if o then ties[#ties + 1] = o.name end end
	local n = V.name
	V.criteriaText = "[" .. table.concat({
		'{"name": "topic", "description": ' .. jsonStr(n .. " is the topic: someone talks to " .. n .. " or about " .. n ..
			", asks " .. n .. " something, or goes on with a conversation they were having with " .. n) .. '}',
		'{"name": "concern", "description": ' .. jsonStr("it concerns " .. n .. "'s own life: their work (" .. (p.job or "") ..
			"), their faith, their home, or the people they know (" .. table.concat(ties, ", ") .. ")") .. '}',
		'{"name": "interest", "description": ' .. jsonStr("it would grab " .. n .. "'s attention, given who they are: " ..
			"gossip, an insult, money, a question to everyone near, something they love or hate") .. '}',
		'{"name": "ended", "description": ' .. jsonStr("a conversation with " .. n .. " just ended: goodbyes, thanks that " ..
			"close it, 'that's all', 'go away', 'not now'") .. '}',
	}, ",\n") .. "]"
	return V.criteriaText
end

-- (the user, 2026-11-15: "they really try not to speak over each other, even when im addressing something to multiple
-- people ... some just skip their turns") a line for several people - "everyone", "you two", several names - is
-- answered by the best one first, then the others in turn (VlBrain.queueTick), each told what was said before them
local GROUP_WORDS = {"everyone", "everybody", "you all", "all of you", "you lot", "you guys", "guys", "folks", "anyone",
	"anybody", "any of you", "both of you", "you two", "you three", "you both", "each of you", "villagers", "lads",
	"ladies", "gentlemen", "people of"}

function VlBrain.groupAddress(text)
	local low = " " .. (text or ""):lower() .. " "
	for _, w in ipairs(GROUP_WORDS) do if low:find("[^%a]" .. w .. "[^%a]") then return true end end
	local names = 0
	for _, V in ipairs(VB.all or {}) do if VlBrain.saysName(text, V.name) then names = names + 1 end end
	return names >= 2
end

-- the queue of further answers to one player's line: {speaker = name, text, current = V | nil, n = its replyn when
-- asked, list = {V, ...}, said = {"Frank: ..."}, dueT, t}
VB.queues = {}

function VlBrain.queueAnswers(speakerName, text, first, list)
	if #list == 0 then return end
	local q = {speaker = speakerName, text = text, current = first, list = list, said = {}, t = GetTime()}
	q.n = first and GetInt(reg(first) .. ".replyn") or nil
	if not first then q.dueT = GetTime() + 1.5 end
	VB.queues[#VB.queues + 1] = q
end

function VlBrain.queueTick()
	local now = GetTime()
	for i = #VB.queues, 1, -1 do
		local q = VB.queues[i]
		if q.current and not q.dueT then
			local n = GetInt(reg(q.current) .. ".replyn")
			if n ~= q.n then
				local reply = GetString(reg(q.current) .. ".reply")
				if reply ~= "" then q.said[#q.said + 1] = q.current.name .. ': "' .. reply .. '"' end
				q.dueT = now + (reply ~= "" and VlBrain.pause(reply) or 1.0)
			elseif now - q.t > 25 then
				q.dueT = now
			end
		elseif q.dueT and now >= q.dueT then
			q.dueT = nil
			local V = nil
			while #q.list > 0 and not V do
				local x = table.remove(q.list, 1)
				if x.alive and not x.asleep and not x.downed and not x.conv then V = x end
			end
			if not V then table.remove(VB.queues, i)
			else
				q.current, q.n, q.t = V, GetInt(reg(V) .. ".replyn"), now
				local before = #q.said > 0 and (" " .. table.concat(q.said, "; ") .. ".") or ""
				VlBrain.event(V, string.format(VlBrain.TALK.group, q.speaker, q.text, before, q.speaker))
			end
		end
	end
end

VL_RUBRIC = {
	weights = {topic = 1.0, concern = 0.6, interest = 0.5},
	named = 0.5, looking = 0.3, talking = 0.3, talkFor = 30, close = 0.15, closeAt = 4,
	answerAt = 0.9,                 -- (Mochi's: "with all these checks included, mochi should answer at 0.9")
	chattyShift = 0.15,             -- answerAt - 0.15 x (talkativeness - 1): Ruben answers sooner, Brannoc later
	endedAt = 0.6,
	pace = 0.25, paceFor = 20,
	hold = 0.8,                     -- s: the scores of one line from every villager in earshot, gathered before deciding
	-- (the user, 2026-11-14: "a bunch of villagers respond to me at once, even those that are not even the closest to me
	-- or ones behind walls that I can't even see") among the villagers who heard one line: the closest to the speaker
	-- gains, the farther lose; out of the speaker's sight loses a lot; a villager named in the line keeps its place
	rank = {0.3, 0.0},              -- by distance to the speaker: 1st +0.3, 2nd 0, every later one rankLater
	rankLater = -0.3,
	seen = 0.2, unseen = -0.6,      -- a clear line from the speaker's eyes to the villager's head, or not
}

local function lookingAt(p, V)
	local e = GetPlayerEyeTransform(p)
	local to = VecSub(VecAdd(V.w.pos, Vec(0, 1.5, 0)), e.pos)
	local d = VecLength(to)
	return d > 0.1 and VecDot(VecScale(to, 1 / d), QuatRotateVec(e.rot, Vec(0, 0, -1))) > 0.94
end

local function headOf(V)
	if V.posture == "lie" and V.lie then return VecAdd(V.lie.pos, Vec(0, 0.4, 0)) end
	if V.posture == "sit" and V.sitPos then return VecAdd(V.sitPos, Vec(0, 0.8, 0)) end
	return VecAdd(V.w.pos, Vec(0, 1.6, 0))
end

-- the scores and what the game knows about each speaker: the margin over the answer line, the speaker it is for,
-- whether it was a goodbye, whether the villager was named
function VlBrain.judge(V, scores, from, text)
	local R = VL_RUBRIC
	local base = 0
	for k, w in pairs(R.weights) do base = base + (tonumber(scores[k]) or 0) * w end
	local isNamed = VlBrain.saysName(text, V.name)
	local named = isNamed and R.named or 0
	local best, who = base + named, nil
	for _, p in ipairs(from) do
		if p < 3000 and IsPlayerValid(p) then
			local x = base + named
			if lookingAt(p, V) then x = x + R.looking end
			if V.talkedWith and V.talkedWith[p] and GetTime() - V.talkedWith[p] < R.talkFor then x = x + R.talking end
			if VecLength(VecSub(GetPlayerTransform(p).pos, V.w.pos)) <= R.closeAt then x = x + R.close end
			if who == nil or x > best then best, who = x, p end
		end
	end
	local recent = 0
	for _, s in ipairs(V.lineT or {}) do if GetTime() - s < R.paceFor then recent = recent + 1 end end
	best = best - math.max(0, recent - 1) * R.pace
	local at = R.answerAt - R.chattyShift * (VlBrain.chatty(V) - 1)
	local ended = (tonumber(scores.ended) or 0) >= R.endedAt
	return best - at, who, ended, isNamed
end

-- (each tick) new scores, gathered per speaker for VL_RUBRIC.hold s (each villager's scored text differs - its own
-- earlier lines ride along - so the speaker and the time make the group), then decided together: distance rank and
-- sight added, one villager answers (two only when both were named)
function VlBrain.judgeTick()
	local now = GetTime()
	VB.judging = VB.judging or {}
	for _, V in ipairs(VB.all) do
		local r = reg(V)
		local n = GetInt(r .. ".scoren")
		if V.scoreN == nil then V.scoreN = n end
		if n ~= V.scoreN then
			V.scoreN = n
			local scores = {}
			for _, k in ipairs({"topic", "concern", "interest", "ended"}) do scores[k] = GetFloat(r .. ".scores." .. k) end
			local fromS, text = GetString(r .. ".scorefrom"), GetString(r .. ".scoretext")
			local from = {}
			for id in fromS:gmatch("%d+") do from[#from + 1] = tonumber(id) end
			local g = VB.judging[fromS]
			if not g then
				-- (the newest line of the scored text, without its "Name: ")
				local last = text:match("([^\n]*)$") or text
				g = {t = now, list = {}, text = text, line = last:gsub("^[^:]+:%s*", "")}
				VB.judging[fromS] = g
			end
			local margin, who, ended, named = VlBrain.judge(V, scores, from, text)
			g.list[#g.list + 1] = {V = V, n = n, margin = margin, who = who, ended = ended, named = named, from = from}
		end
	end
	for key, g in pairs(VB.judging) do
		local sp0 = g.list[1] and g.list[1].from[1]
		if now - g.t >= VL_RUBRIC.hold and sp0 and sp0 >= 3000 then
			-- (the user, 2026-11-15: "the same criteria should apply for villager speaking to another villager(s)")
			-- a villager's line: nobody answers it here; the relevance goes to VlBrain.pickListener
			VB.judging[key] = nil
			for _, c in ipairs(g.list) do
				SetString(reg(c.V) .. ".decide", c.n .. " skip")
				c.V.heardScore = {from = sp0, margin = c.margin, named = c.named, ended = c.ended, t = now}
			end
		elseif now - g.t >= VL_RUBRIC.hold then
			VB.judging[key] = nil
			local R = VL_RUBRIC
			-- the speaker (a player): distance rank and sight for every villager who heard them
			local sp = nil
			for _, c in ipairs(g.list) do sp = sp or c.who or c.from[1] end
			if sp and sp < 3000 and IsPlayerValid(sp) then
				local eye = GetPlayerEyeTransform(sp).pos
				for _, c in ipairs(g.list) do c.dist = VecLength(VecSub(headOf(c.V), eye)) end
				table.sort(g.list, function(a, b) return a.dist < b.dist end)
				for i, c in ipairs(g.list) do
					c.rank, c.seen = i, VlPerceive.clear(eye, headOf(c.V))
					if not c.named then
						c.margin = c.margin + (R.rank[i] or R.rankLater) + (c.seen and R.seen or R.unseen)
					end
				end
			end
			table.sort(g.list, function(a, b) return a.margin > b.margin end)
			local first = nil
			local group = VlBrain.groupAddress(g.text)
			local queue = {}
			for _, c in ipairs(g.list) do
				local yes = false
				if not c.ended and (c.margin >= 0 or (group and c.named)) then
					if not first then yes, first = true, c end
				end
				-- a line for several: the others answer in turn (named ones always, the rest when it concerns them a bit)
				if not yes and group and not c.ended and (c.named or c.margin >= VL_CFG.groupMargin) and #queue < VL_CFG.groupMax - 1 then
					queue[#queue + 1] = c.V
				end
				SetString(reg(c.V) .. ".decide", c.n .. (yes and " answer" or " skip"))
				c.V.judged = {n = c.n, answer = yes, margin = c.margin, ended = c.ended, rank = c.rank, seen = c.seen}
				if c.ended then
					for _, q in ipairs(c.from) do if c.V.talkedWith then c.V.talkedWith[q] = nil end end
					if c.V.engaged and c.V.engaged.player then c.V.engaged = nil; c.V.thinkDue = true end
				elseif not yes and c.margin > -0.45 and c.who and c.seen ~= false and not c.V.engaged then
					local p = c.who
					c.V.engaged = {pos = function() return GetPlayerTransform(p).pos end, untilT = now + 2.5}   -- (a glance)
				end
			end
			if group and #queue > 0 then
				local name = sp and sp < 3000 and IsPlayerValid(sp) and GetPlayerName(sp) or "Someone"
				VlBrain.queueAnswers(name, g.line or g.text, first and first.V, queue)
			end
		end
	end
end

-- ---------------------------------------------------------------- the state (2 KB, captured when a line arrives)
function VlBrain.stateText(V, P)
	local lines = {}
	-- (VlSense's first line already says who, where, doing what and the time)
	local ok, s = false, nil
	if VlSense and VlSense.describe then ok, s = pcall(VlSense.describe, P, VL_CFG.senseFormat) end
	if not (ok and s) then
		lines[#lines + 1] = "Time: " .. VlLife.clockText() .. ". You are " .. VlLife.doingText(V) .. "."
		s = "(you can't make out your surroundings)"
	end
	local extra = {}
	local gtx = VlBrain.goalsText(V)
	if gtx ~= "" then extra[#extra + 1] = gtx:sub(1, 300) end
	if P.time.weather and P.time.weather ~= "" and P.time.weather ~= "clear" then extra[#extra + 1] = "Weather: " .. P.time.weather .. "." end
	if V.downed then extra[#extra + 1] = string.format("You lie collapsed, bleeding, too weak to stand (health %d%%).", math.floor(V.hp))
	elseif V.hp < VL_CFG.bleedBelow then extra[#extra + 1] = string.format("You are badly hurt, bleeding and weak (health %d%%).", math.floor(V.hp))
	elseif V.hp < 99 then extra[#extra + 1] = string.format("You are hurt (health %d%%).", math.floor(V.hp)) end
	if V.tending then extra[#extra + 1] = "You are bandaging " .. (V.tending.who or "someone") .. "'s wounds." end
	if V.tendedBy then extra[#extra + 1] = V.tendedBy .. " is bandaging your wounds." end
	if #extra > 0 then lines[#lines + 1] = table.concat(extra, " ") end
	lines[#lines + 1] = s
	if #V.notes > 0 then
		local l = {}
		local now = GetTime()
		for _, n in ipairs(V.notes) do if now - n.t < 90 then l[#l + 1] = n.text end end
		if #l > 0 then lines[#lines + 1] = "Just happened: " .. table.concat(l, " ") end
	end
	local head = table.concat(lines, "\n")
	local mem = ""
	if VlMemory and VlMemory.forState then
		local present = {}
		for _, th in ipairs(P.things) do if th.sense == "seen" and th.name ~= "someone" then present[#present + 1] = th.name end end
		local ok, m = pcall(VlMemory.forState, V.id, {present = present, place = V.place and V.place.name, hour = VlLife.hour()})
		if ok and m then mem = m end
	end
	local room = 2000 - #head - 2
	if #mem > room then mem = mem:sub(1, math.max(0, room)) end
	if mem ~= "" then return head .. "\n" .. mem end
	return head
end

-- ---------------------------------------------------------------- events and notes
-- note: what it should know with the next line (in state for 90 s); urgent: a line of its own now, when someone
-- could hear the answer (else it only stays in state and memory)
function VlBrain.happen(V, text, urgent, mem)
	local now = GetTime()
	V.notes[#V.notes + 1] = {text = text, t = now}
	while #V.notes > 5 do table.remove(V.notes, 1) end
	if mem and VlMemory and VlMemory.add then pcall(VlMemory.add, V.id, mem) end
	if urgent and V.alive and not V.asleep and VlBrain.ready() and VB.playerNear(V, VL_CFG.talkRange) and now > (V.eventT or 0) then
		V.eventT = now + 6
		VlBrain.event(V, text)
	end
end

function VlBrain.event(V, text)
	if V.asleep then return end                            -- (asleep: no request, no words; hurt() wakes them first)
	text = VlLife.stamp() .. " " .. text                   -- (every line from the game carries its time and date)
	local k = reg(V) .. ".event"
	local cur = GetString(k)
	SetString(k, cur ~= "" and (cur .. "\n" .. text) or text)
	noteReq()
end

function VlBrain.playerNear(V, d)
	for _, p in ipairs(GetAllPlayers()) do
		if VecLength(VecSub(GetPlayerTransform(p).pos, V.w.pos)) < d then return true end
	end
	return false
end
VB.playerNear = VlBrain.playerNear

-- ---------------------------------------------------------------- the calls
local function playerByName(name)
	if not name then return nil end
	local n = name:lower()
	for _, p in ipairs(GetAllPlayers()) do if GetPlayerName(p):lower() == n then return p end end
	for _, p in ipairs(GetAllPlayers()) do if GetPlayerName(p):lower():find(n, 1, true) then return p end end
	return nil
end

local function villagerByName(name)
	if not name then return nil end
	local n = name:lower()
	for _, V in ipairs(VB.all) do if V.name:lower() == n or V.id == n then return V end end
	for _, V in ipairs(VB.all) do if VlBrain.saysName(n, V.name) then return V end end
	return nil
end
VlBrain.villagerByName = villagerByName

-- someone by name: {pos = function, name, player, villager}
local function whom(name)
	local p = playerByName(name)
	if p then return {player = p, name = GetPlayerName(p), pos = function() return GetPlayerTransform(p).pos end} end
	local O = villagerByName(name)
	if O then return {villager = O, name = O.name, pos = function() return O.w.pos end} end
	-- another mod's creature / thing (vl_api.lua), the nearest of that name to whoever asks
	local t = VlApi and VlApi.thingByName(name, VB.askerPos)
	if t then
		local id = t.id
		return {thing = t, name = t.name, pos = function() local x = VlApi.thingById(id); if x then t = x end return t.pos end}
	end
	return nil
end

local function sensesWho(V, name)
	local P = V.lastP
	if not P then return false end
	local n = (name or ""):lower()
	for _, th in ipairs(P.things) do
		if th.name:lower():find(n, 1, true) and th.sense == "seen" then return true end
	end
	return false
end

local CALLS = {}

local function resolvePlace(V, name)
	name = name or ""
	if name == "home" or name == "" then return VlPlaces.home(V.p) end
	if name == "work" then return VlLife.workPlace(V) end
	local pl = VlPlaces.byName(name)
	if not pl then
		for _, p in ipairs(VL_PEOPLE or {}) do
			if name:lower():find(p.name:lower(), 1, true) then pl = VlPlaces.home(p) end
		end
	end
	return pl
end

-- ---------------------------------------------------------------- goals (the user, 2026-11-14: "a short list of
-- objectives, both short term and long term, which would guide them ... depending on personalities, they can also
-- slack off"). Long-term: their mission and a duty of their job to begin with, the model may add (kept 4, saved per
-- map); today's: set each morning by the model (3 at most), ticked off with goal_done.
local DUTY = {smithy = "keep the forge working and the orders done", tavern = "keep the tavern full and the ale flowing",
	chapel = "keep the chapel and its rites", shop = "keep the shop stocked and the money coming in",
	patrol = "keep watch over the village", farm = "look after the flock and the fields", field = "tend the herbs and the sick",
	workshop = "mend what people bring you", home = "keep the household going"}

function VlBrain.goalsInit(V, levelKey)
	V.goals = {long = {}, today = {}, day = -1}
	local saved = GetString("savegame.mod.vl." .. levelKey .. ".goals." .. V.id)
	if saved ~= "" then
		for g in (saved .. "|"):gmatch("([^|]*)|") do if g ~= "" then V.goals.long[#V.goals.long + 1] = g end end
	else
		if V.p.mission then V.goals.long[1] = V.p.mission:sub(1, 180) end
		if DUTY[V.p.workKind] then V.goals.long[#V.goals.long + 1] = DUTY[V.p.workKind] end
	end
	V.goals.key = "savegame.mod.vl." .. levelKey .. ".goals." .. V.id
end

local function goalsSave(V)
	local g = V.goals
	if not g or not g.key then return end
	local l = {}
	for _, s in ipairs(g.long) do l[#l + 1] = s:gsub("|", "/") end
	SetString(g.key, table.concat(l, "|"))
end

function VlBrain.goalsText(V)
	local g = V.goals
	if not g then return "" end
	local t = {}
	if #g.long > 0 then t[#t + 1] = "Your aims: " .. table.concat(g.long, "; ") .. "." end
	if g.day == VlLife.day() and #g.today > 0 then
		local l = {}
		for _, x in ipairs(g.today) do l[#l + 1] = x.text .. (x.done and " (done)" or (x.dropped and " (given up)" or "")) end
		t[#t + 1] = "Today you mean to: " .. table.concat(l, "; ") .. "."
	end
	return table.concat(t, " ")
end

local function strList(v)
	local out = {}
	if type(v) == "table" then for _, s in ipairs(v) do if type(s) == "string" and s ~= "" then out[#out + 1] = s:sub(1, 120) end end
	elseif type(v) == "string" and v ~= "" then out[1] = v:sub(1, 120) end
	return out
end

function CALLS.set_goals(V, a, json)
	local t = (VlMemory and VlMemory.json and json and json ~= "") and VlMemory.json(json) or a
	if type(t) ~= "table" then t = a end
	local g = V.goals
	if not g then return "error: no goals" end
	local today = strList(t.today)
	if #today == 0 then return "error: name at least one thing for today" end
	g.today, g.day = {}, VlLife.day()
	for i = 1, math.min(3, #today) do g.today[i] = {text = today[i]} end
	for _, s in ipairs(strList(t.long_term)) do
		table.insert(g.long, 1, s)
		while #g.long > 4 do table.remove(g.long) end
		goalsSave(V)
	end
	return "ok: today you mean to " .. table.concat(today, "; ", 1, math.min(3, #today))
end

function CALLS.goal_done(V, a)
	local g = V.goals
	local q = tostring(a.goal or ""):lower()
	if not g or q == "" then return "error: which goal?" end
	local best, bs = nil, 0
	local function score(s)
		local n = 0
		for w in q:gmatch("%a%a%a+") do if s:lower():find(w, 1, true) then n = n + 1 end end
		return n
	end
	for _, x in ipairs(g.today) do local s = score(x.text); if s > bs then best, bs = x, s end end
	if best then
		if a.gave_up == true or a.gave_up == "true" then best.dropped = true else best.done = true end
		return "ok"
	end
	for i, s in ipairs(g.long) do
		if score(s) > 0 then
			table.remove(g.long, i)
			goalsSave(V)
			return "ok: that aim is behind you"
		end
	end
	return "error: you had no such goal"
end

local SIT_WORDS = {"drink", "eat", "rest", "sit", "pray", "read", "wait", "think", "meal", "supper", "breakfast", "lunch"}

-- (the user, 2026-11-14: "full autonomy and full lives of their own") the villager's own choice of what to do next
function CALLS.do_activity(V, a)
	local act = tostring(a.activity or ""):sub(1, 80)
	local low = act:lower()
	if low:find("sleep") or low:find("bed") or low:find("nap") then
		V.override = nil
		V.sleepNow = true
		V.planKey = nil
		return "ok: going to bed"
	end
	local pl = resolvePlace(V, a.place)
	if not pl then return "error: there is no such place here" end
	local hours = math.max(0.5, math.min(6, tonumber(a.hours) or 1.5))
	local dur = math.max(VL_CFG.minActivitySec, math.min(VL_CFG.maxActivitySec, hours * VlLife.secPerHour()))
	local sit = false
	for _, w in ipairs(SIT_WORDS) do if low:find(w, 1, true) then sit = true end end
	VlLife.setOverride(V, {kind = "goto", place = pl, label = act, sit = sit, stayFor = dur, untilT = GetTime() + dur + 150,
		activity = true})
	return "ok: " .. act .. " at " .. pl.name
end

function CALLS.go_to(V, a)
	local pl = resolvePlace(V, a.place)
	if not pl then return "error: there is no such place here" end
	VlLife.setOverride(V, {kind = "goto", pos = pl.inside or pl.pos, label = pl.name, run = a.hurry == true or a.hurry == "true",
		untilT = GetTime() + 150, stayFor = 60})
	return "ok: walking to " .. pl.name
end

function CALLS.follow(V, a)
	local w = whom(a.person)
	if not w then return "error: nobody by that name is here" end
	if not sensesWho(V, w.name) then return "error: you can't see " .. w.name end
	local chase = a.chase == true or a.chase == "true"
	VlLife.setOverride(V, {kind = "follow", pos = w.pos, who = w.name, chase = chase, untilT = GetTime() + (chase and 45 or 120)})
	if chase and w.villager then
		VlBrain.happen(w.villager, V.name .. " is running after you!", true)
	end
	return "ok: " .. (chase and "chasing " or "following ") .. w.name
end

function CALLS.stay(V) VlLife.setOverride(V, {kind = "stay", untilT = GetTime() + 90}); return "ok: staying here" end
function CALLS.resume(V) V.override = nil; V.planKey = nil; return "ok" end

-- (the user, 2026-11-15: "they should also be able to yell and whisper") Proximity Comms' agent .mode: their choice
-- for a while; on their own they yell in a fight, a flight, at a fire, when attacked (VlBrain.voiceOf)
function CALLS.voice(V, a)
	local l = a.level
	if l ~= "whisper" and l ~= "speak" and l ~= "yell" then return "error: whisper, speak or yell" end
	V.voiceMode, V.voiceUntil = l, GetTime() + VL_CFG.voiceFor
	VlBrain.keys(V)
	return "ok: you " .. (l == "speak" and "speak normally" or (l .. " now"))
end

function VlBrain.voiceOf(V)
	local now = GetTime()
	if V.voiceMode and now < (V.voiceUntil or 0) then return V.voiceMode end
	local o = V.override
	if o and (o.kind == "fight" or o.kind == "flee" or o.kind == "fire" or o.kind == "fetch" or (o.kind == "follow" and o.chase)) then return "yell" end
	if now < (V.alarmUntil or 0) then return "yell" end
	if V.carried and not V.downed then return "yell" end
	if V.downed then return "whisper" end
	return "speak"
end

function CALLS.look_at(V, a)
	local t = (a.target or ""):lower()
	local P = V.lastP
	for _, th in ipairs(P and P.things or {}) do
		if (t == "fire" and th.kind == "fire") or (t == "noise" and th.kind == "sound") or th.name:lower():find(t, 1, true) then
			local pos = th.pos
			V.engaged = {pos = function() return pos end, untilT = GetTime() + 6}
			return "ok"
		end
	end
	return "error: you don't sense that"
end

function CALLS.put_out_fire(V)
	local fp = VlLife.nearestFire(V.w.pos, VL_CFG.smellRange)
	if not fp then return "error: there is no fire you can find" end
	local ok, what = VlLife.putOutFire(V, fp)
	return (ok and "ok: " or "error: ") .. what
end

function CALLS.flee(V, a)
	local f = (a.from or ""):lower()
	local from
	if f == "fire" then from = VlLife.nearestFire(V.w.pos, VL_CFG.smellRange)
	elseif f == "noise" then local s = VlPerceive.sounds[#VlPerceive.sounds]; from = s and s.pos
	else local w = whom(a.from); from = w and w.pos() end
	from = from or V.lastThreat
	if not from then return "error: run from what?" end
	VlLife.setOverride(V, {kind = "flee", from = VecCopy(from), dist = 22, untilT = GetTime() + 15})
	return "ok: running away"
end

-- (the user, 2026-11-14: "an action to heal each other (bandaging animation, and it heals slowly)")
function CALLS.bandage(V, a)
	local w = whom(a.person)
	if not w then return "error: nobody by that name is here" end
	if w.villager == V then return "error: you can't bandage yourself properly" end
	if V.downed then return "error: you are too weak yourself" end
	if w.villager and not w.villager.alive then return "error: " .. w.name .. " is dead" end
	local hurt = w.villager and w.villager.hp < 95 or (w.player and GetPlayerHealth(w.player) < 0.95)
	if not hurt then return "error: " .. w.name .. " is not hurt" end
	if VecLength(VecSub(w.pos(), V.w.pos)) > 40 then return "error: " .. w.name .. " is too far away" end
	VlLife.setOverride(V, {kind = "tend", who = w.name, pos = w.pos, villager = w.villager, player = w.player,
		untilT = GetTime() + 90})
	return "ok: going to bandage " .. w.name
end

-- (the user, 2026-11-15: "the villagers should be able to fight back. Even two villagers should be able to fight each
-- other ... run away and chase, depending on their personality (let the LLM decide)") a blow or a fight: VlLife's
-- "fight" override runs after the target and swings (VlBrain.blow) until it falls, gets away or the time is up
function CALLS.attack(V, a)
	local w = whom(a.person)
	if not w then return "error: nobody by that name is here" end
	if w.villager == V then return "error: not yourself" end
	if V.downed then return "error: you are too weak to fight" end
	if w.villager and not w.villager.alive then return "error: " .. w.name .. " is dead" end
	if w.player and GetPlayerHealth(w.player) <= 0 then return "error: " .. w.name .. " is already down" end
	local d = VecLength(VecSub(w.pos(), V.w.pos))
	if d > 30 then return "error: " .. w.name .. " is too far away" end
	if not sensesWho(V, w.name) and d > 3 then return "error: you can't see " .. w.name end
	local once = a.how ~= "fight"
	VlLife.setOverride(V, {kind = "fight", who = w.name, pos = w.pos, villager = w.villager, player = w.player, thing = w.thing, once = once,
		untilT = GetTime() + (once and 12 or VL_CFG.fightFor)})
	if w.villager and not once then
		VlBrain.happen(w.villager, V.name .. " is coming at you to fight!", true,
			{text = V.name .. " attacked me", who = {V.name}, importance = 5, kind = "event", feel = -3})
	end
	return "ok: " .. (once and "you go to hit " or "you go after ") .. w.name
end
CALLS.strike = CALLS.attack

-- one blow from V at the one it fights (in reach): damage by temper, a shove, the clients swing an arm
function VlBrain.blow(V, o)
	V.striking = GetTime()
	local tp = o.pos()
	V.strikeAt = VecAdd(tp, Vec(0, (o.villager and o.villager.posture == "lie") and 0.3 or 1.3, 0))
	local temper = (VL_CFG.temper or {})[V.id] or 0.4
	if o.player then
		ApplyPlayerDamage(o.player, VL_CFG.strikeDamage * (0.7 + temper), V.name)
		local push = VecNormalize(VecSub(tp, V.w.pos))
		SetPlayerVelocity(o.player, VecAdd(GetPlayerVelocity(o.player), VecAdd(VecScale(push, 3.5), Vec(0, 1.2, 0))))
	elseif o.villager then
		VlBrain.hurt(o.villager, VL_CFG.punchDamage * (0.7 + temper), V.name, V.w.pos, V.strikeAt)
	elseif o.thing and VlApi then
		VlApi.strike(V, o.thing, VL_CFG.punchDamage * (0.7 + temper))
	end
end

function CALLS.talk_to(V, a)
	local O = villagerByName(a.person)
	if not O or O == V or not O.alive then return "error: nobody by that name" end
	if O.asleep then return "error: " .. O.name .. " is asleep" end
	if VecLength(VecSub(O.w.pos, V.w.pos)) > 40 then return "error: " .. O.name .. " is too far away" end
	V.pendingTalk = {who = O, about = a.about, t = GetTime()}
	VlLife.setOverride(V, {kind = "follow", pos = function() return O.w.pos end, who = O.name, untilT = GetTime() + 40})
	return "ok: going over to " .. O.name
end

function CALLS.end_conversation(V)
	V.engaged = nil
	V.attended = false
	V.coolT = GetTime() + 20
	V.leftPlayer = V.lastTalkP
	if V.conv then VlBrain.leaveConv(V) end
	return "ok"
end

-- the acts that end a turn of a villager's own time (VlBrain.calls)
local FINAL_ACTS = {do_activity = true, go_to = true, stay = true, resume = true, talk_to = true, goal_done = true}

function VlBrain.calls()
	local last = GetInt("proxchat.agentcall.last")
	if VB.seenCall > last then VB.seenCall = last end
	while VB.seenCall < last do
		VB.seenCall = VB.seenCall + 1
		local k = "proxchat.agentcall." .. (VB.seenCall % 16) .. "."
		local agent, name = GetString(k .. "agent"), GetString(k .. "name")
		local args = {}
		local ok, keys = pcall(ListKeys, "proxchat.agentcall." .. (VB.seenCall % 16) .. ".arg")
		for _, a in ipairs(ok and keys or {}) do args[a] = GetString(k .. "arg." .. a) end
		if args.hurry == "true" then args.hurry = true end
		local result, finalOk = nil, false
		if agent == SCRIBE then
			result = VlBrain.scribeCall(name, GetString(k .. "args"))
		else
			local V = VB.byAgent[agent]
			if V then
				noteReq()
				local ownTime = V.thinkPending ~= nil       -- (a turn of its own time: VlBrain.calls marks the act final)
				V.thinkPending = nil
				V.lastCallFrom = GetString(k .. "from")
				finalOk = ownTime and V.lastCallFrom == "" and not V.conv
				if not V.alive then result = "error: you are dead"
				elseif name == "feel_about_creature" and VlApi then
					local kk = VlApi.kindByName(args.creature)
					result = kk and VlApi.setFeel(V, kk, args.feeling, tonumber(args.fear_multiplier), tonumber(args.fear_bonus), args.why)
						or "error: no creature by that name"
				elseif name == "feel_about" and VlApi and (args.feeling or "") ~= "" and VlApi.kindByName(args.person) then
					-- (a creature or thing of another mod: their own view of it, vl_api.lua)
					result = VlApi.setFeel(V, VlApi.kindByName(args.person), args.feeling, tonumber(args.fear_multiplier),
						tonumber(args.fear_bonus), args.why)
				elseif CALLS[name] then
					VB.askerPos = V.w.pos                  -- (whom: the nearest creature of a name to the caller)
					local okc, r = pcall(CALLS[name], V, args, GetString(k .. "args"))
					VB.askerPos = nil
					result = okc and r or ("error: " .. tostring(r))
				elseif VlMemory and VlMemory.onCall then
					local okc, r = pcall(VlMemory.onCall, V.id, name, GetString(k .. "args"))
					if okc and r == nil then r = "error: you can't do that" end
					result = okc and r or ("error: " .. tostring(r))
				else
					result = "error: you can't do that"
				end
			end
		end
		if result then
			SetString(k .. "result", result)
			-- (API 23, Proximity Comms' message 2026-11-16: Koetama 0.5.16 can end a turn after a function result - one model
			-- request instead of two or three.) Only the act of a villager's own time ("nobody asked you anything ... say
			-- nothing aloud"): no follow-up is needed there, and those turns are most of a village's requests. Errors keep
			-- the follow-up (the model tries again); set_goals too (do_activity comes after it); conversations always.
			if finalOk and FINAL_ACTS[name] and result:sub(1, 2) == "ok" and GetBool("proxchat.agentfinal") then
				SetBool(k .. "final", true)
			end
		end
	end
end

-- ---------------------------------------------------------------- replies
function VlBrain.replies(V)
	local r = reg(V)
	local n = GetInt(r .. ".replyn")
	if n ~= (V.replyn or 0) then
		local fresh = V.replyn ~= nil
		V.replyn = n
		if fresh then
			noteReq()
			V.thinkPending = nil
			local text = GetString(r .. ".reply")
			V.lastReply, V.lastReplyT = text, GetTime()
			if text ~= "" then
				V.lineT = V.lineT or {}
				V.lineT[#V.lineT + 1] = GetTime()
				while #V.lineT > 6 do table.remove(V.lineT, 1) end
			end
			V.talkUntil = GetTime() + math.min(6, 1 + #text / 14)
			-- who it answered: players (ids) and agents (speaker numbers 3000+)
			local p = nil
			for id in GetString(r .. ".replyfrom"):gmatch("%d+") do
				local x = tonumber(id)
				if x < 3000 and IsPlayerValid(x) then p = x end
			end
			if p then
				V.talkedWith = V.talkedWith or {}
				V.talkedWith[p] = GetTime()
				V.engaged = {pos = function() return GetPlayerTransform(p).pos end, untilT = GetTime() + 25, player = p}
				V.lastTalkP = p
				if V.asleep then
					VlBrain.wake(V, GetPlayerName(p))
				end
				if VlMemory and VlMemory.meet then pcall(VlMemory.meet, V.id, GetPlayerName(p), V.place and V.place.name, "player") end
			end
		end
	end
	if GetString(r .. ".live") ~= "" then V.talkUntil = math.max(V.talkUntil or 0, GetTime() + 0.4) end
	local err = GetString(r .. ".error")
	if err ~= "" then
		V.lastErr, V.lastWhy = err, GetString(r .. ".why")
		ClearKey(r .. ".error"); ClearKey(r .. ".why")
		-- out of budget: the whole village freezes (main.lua) with the reason over their heads, and tries again in 10 min;
		-- another error: nothing said (a canned line from twelve mouths at once was the bug)
		if err == "budget" then VB.budgetUntil = GetTime() + 600 end
	end
end

function VlBrain.wake(V, by)
	if not V.asleep then return end
	V.asleep = false
	V.posture = "stand"
	if V.lie then VlNav.warp(V.w, V.lie.floor or V.w.pos) end
	V.lie = nil
	VlLife.setOverride(V, {kind = "stay", untilT = GetTime() + 60})
	if VlMemory and VlMemory.add then
		pcall(VlMemory.add, V.id, {text = (by or "Someone") .. " woke me up in the night", who = {by}, importance = 3, kind = "event"})
	end
end

-- ---------------------------------------------------------------- without the LLM: a line of their own when named
local GENERIC = {
	named = {"Hm?", "What is it?", "I'm busy.", "Yes?", "Not now.", "What do you want?"},
	puzzled = {"Eh? I lost my thought.", "Hm. Never mind.", "Where was I..."},
	hurt = {"Ow! What are you doing?!", "Help! Help!", "Stop that!"},
	fire = {"Fire! FIRE!", "Something's burning!", "Fire! Get water!"},
	scared = {"Run! RUN!", "Lantern save us!", "Get away from it!", "What in the world is that?!"},
}

-- (no canned lines any more: without the AI the villagers freeze, the reason over their heads; kept for the tables)
function VlBrain.fallbackLine(V, kind)
	return nil
end

-- ---------------------------------------------------------------- overhearing (the user, 2026-11-14: "did you implement
-- an ability for villagers to tell whether they should respond to a speech?") A line said near villagers it did not
-- reach (not named, not facing the speaker, not talking with them) is judged here, in code, for each of them: their
-- trade, places, faith, likes and dislikes, the people they are tied to, a question to the whole room, how near, how
-- nosy. At most one gets it, as "you overheard ..." - and may still say nothing. No scoring requests.
local STOP = {about = 1, after = 1, again = 1, their = 1, there = 1, these = 1, those = 1, which = 1, ["while"] = 1, would = 1,
	could = 1, should = 1, where = 1, other = 1, people = 1, village = 1, someone = 1, something = 1, never = 1, always = 1,
	every = 1, being = 1, before = 1, because = 1, through = 1, still = 1, think = 1, things = 1, strangers = 1}

local function addWords(set, s, w)
	for word in tostring(s or ""):lower():gmatch("%a%a%a%a+") do
		if not STOP[word] then set[word] = math.max(set[word] or 0, w) end
	end
end

local function interests(V)
	if V.interests then return V.interests end
	local set = {}
	local p = V.p
	addWords(set, p.job, 1.2); addWords(set, p.workKind, 1.0); addWords(set, p.faith, 1.5)
	for _, s in ipairs(p.likes or {}) do addWords(set, s, 1.3) end
	for _, s in ipairs(p.dislikes or {}) do addWords(set, s, 1.5) end
	for _, t in ipairs(p.ties or {}) do
		local o = VlBrain.personById(t.who)
		if o then addWords(set, o.name, 1.5) end
	end
	addWords(set, p.mission, 0.8)
	local wp = VlLife.workPlace(V)
	if wp then addWords(set, wp.name, 1.0) end
	V.interests = set
	return set
end

local ROOM = {"anyone", "anybody", "everyone", "everybody", "you all", "who here", "somebody", "any of you", "hello", "hey"}

function VlBrain.overhear(text, who, pos, radius, speakerP, speakerAgent)
	local now = GetTime()
	if now < (VB.overT or 0) or not ambientOk() then return end
	local low = text:lower()
	local named = false
	for _, V in ipairs(VB.all) do if VlBrain.saysName(low, V.name) then named = true end end
	if named then return end                                          -- (said to someone by name: they got it)
	local room = 0
	for _, w in ipairs(ROOM) do if low:find(w, 1, true) then room = 1.2 end end
	if low:find("?", 1, true) and room > 0 then room = 1.6 end
	local best, bs = nil, 0
	for _, V in ipairs(VB.all) do
		local d = VecLength(VecSub(V.w.pos, pos))
		local reached = V.attended or (V.engaged and V.engaged.player and V.engaged.player == speakerP)
			or (speakerAgent and V.conv and VlBrain.convHas(V.conv, speakerAgent))
			or V.agent == speakerAgent
		if V.alive and not V.asleep and not reached and d < math.min(radius, 14) and now > (V.overT or 0) then
			local s = room
			local set = interests(V)
			for word in low:gmatch("%a%a%a%a+") do s = s + (set[word] or 0) end
			s = s + (d < 6 and 0.5 or 0) - (d > 10 and 0.5 or 0) + 0.6 * (VlBrain.chatty(V) - 1)
			-- (the user: not "ones behind walls that I can't even see") out of the speaker's sight: much less likely
			if not VlPerceive.clear(VecAdd(pos, Vec(0, 1.6, 0)), VecAdd(V.w.pos, Vec(0, 1.5, 0))) then s = s - 1.0 end
			if speakerAgent then s = s - 0.5 end                      -- (villagers' own talk: butting in is rarer)
			if s > bs then best, bs = V, s end
		end
	end
	if not best or bs < VL_CFG.overhearMin then return end
	VB.overT = now + 8
	best.overT = now + 40
	best.butted = now
	local to = speakerAgent and "" or " near you"
	VlBrain.event(best, string.format('[You overheard %s say%s: "%s"] Butt in only if it really concerns you or you cannot help yourself; otherwise say nothing and carry on.',
		who, to, text:sub(1, 300)))
end

local function saidEvents()
	local last = GetInt("proxchat.said.last")
	if VB.seenSaid > last or VB.seenSaid == 0 then VB.seenSaid = last; return end
	while VB.seenSaid < last do
		VB.seenSaid = VB.seenSaid + 1
		local k = "proxchat.said." .. (VB.seenSaid % 16) .. "."
		local text = GetString(k .. "text"):lower()
		local pos = Vec(GetFloat(k .. "x"), GetFloat(k .. "y"), GetFloat(k .. "z"))
		local radius = GetFloat(k .. "radius")
		if radius <= 0 then radius = 25 end
		local agent = GetString(k .. "agent")
		if VlMemory and VlMemory.heard then
			local who = "Someone"
			if agent ~= "" then
				who = GetString("proxchat.agent." .. agent .. ".name")
				if who == "" then who = agent end
			else
				local p = GetInt(k .. "player")
				if p > 0 and IsPlayerValid(p) then who = GetPlayerName(p) end
			end
			local raw = GetString(k .. "text")
			for _, V in ipairs(VB.all) do
				if V.alive and not V.asleep and VecLength(VecSub(pos, V.w.pos)) < radius then
					pcall(VlMemory.heard, V.id, who, raw, V.place and V.place.name)
				end
			end
			-- (villagers' own lines: who answers or joins is VlBrain.pickListener's call, in the turns)
			if VlBrain.ready() and agent == "" and not GetBool("proxchat.agentscores") and VlBrain.groupAddress(raw) then
				-- (the faced villager hears it directly and answers; a named one hears its name and answers by itself;
				--  the rest in earshot and in sight are queued, nearest first)
				local first, list, cands = nil, {}, {}
				local sp = GetInt(k .. "player")
				local eye = (sp > 0 and IsPlayerValid(sp)) and GetPlayerEyeTransform(sp).pos or VecAdd(pos, Vec(0, 1.6, 0))
				for _, V in ipairs(VB.all) do
					local d = VecLength(VecSub(V.w.pos, pos))
					if V.alive and not V.asleep and not V.downed and not V.conv and d < math.min(radius, 15) then
						if V.attended then first = V
						elseif not VlBrain.saysName(raw, V.name) and VlPerceive.clear(eye, VecAdd(V.w.pos, Vec(0, 1.5, 0))) then
							cands[#cands + 1] = {V = V, d = d}
						end
					end
				end
				table.sort(cands, function(a, b) return a.d < b.d end)
				for _, cd in ipairs(cands) do if #list < VL_CFG.groupMax - 1 then list[#list + 1] = cd.V end end
				VlBrain.queueAnswers(who, raw, first, list)
			end
			if VlBrain.ready() and agent == "" and not GetBool("proxchat.agentscores") then
				pcall(VlBrain.overhear, raw, who, pos, radius, agent == "" and GetInt(k .. "player") or nil, agent ~= "" and agent or nil)
			end
		end
		if agent == "" then
			for _, V in ipairs(VB.all) do
				if V.alive and VlBrain.saysName(text, V.name) and VecLength(VecSub(pos, V.w.pos)) < radius then
					if not VlBrain.ready() and GetTime() > (V.fallbackT or 0) then
						V.fallbackT = GetTime() + 5
						local f = VlBrain.fallbackLine(V, "named")
						if f then SetString(reg(V) .. ".say", f) end
					end
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- attention: who a player is facing close by
-- who each player is talking to (the user, 2026-11-14: "detect who is the closest villager to the speaker ... distance
-- ranking and whether they're in my line of sight"): without a scoring Koetama this is the ONLY villager that hears a
-- player's everyday lines (the rest hear their name): the one the player faces within attendDist, else the one already
-- talking with them, else the closest one the player can see within 8 m
local function attention()
	for _, V in ipairs(VB.all) do V.attended = false end
	for _, p in ipairs(GetAllPlayers()) do
		local e = GetPlayerEyeTransform(p)
		local fwd = QuatRotateVec(e.rot, Vec(0, 0, -1))
		local faced, fc, talking, nearest, nd = nil, 0.9, nil, nil, 8
		for _, V in ipairs(VB.all) do
			if V.alive and not V.asleep then
				local head = VecAdd(V.w.pos, Vec(0, 1.5, 0))
				local to = VecSub(head, e.pos)
				local d = VecLength(to)
				if d < VL_CFG.attendDist and d > 0.1 then
					local c = VecDot(VecScale(to, 1 / d), fwd)
					if c > fc and VlPerceive.clear(e.pos, head) then faced, fc = V, c end
				end
				if V.engaged and V.engaged.player == p and GetTime() < V.engaged.untilT and d < 12 then talking = V end
				if d < nd and VlPerceive.clear(e.pos, head) then nearest, nd = V, d end
			end
		end
		local who = faced or talking or nearest
		if who then who.attended = true end
	end
end

-- ---------------------------------------------------------------- the conversation director
local function pairKey(a, b) if a.id < b.id then return a.id .. ":" .. b.id end return b.id .. ":" .. a.id end

local function free(V)
	local o = V.override
	local settled = not o or (o.kind == "goto" and o.phase == "there")            -- (at what they chose to do)
	return V.alive and not V.asleep and not V.conv and settled and V.mode ~= "engaged" and not V.thinkPending
		and GetTime() > (V.coolT or 0)
end

local function topic(A, B)
	local opts = {}
	for _, t in ipairs(A.p.ties or {}) do
		if t.who == B.id then opts[#opts + 1] = "how things stand between you two (" .. (t.kind or "") .. ": " .. (t.note or "") .. ")" end
	end
	if A.p.mission then opts[#opts + 1] = "something to do with what you are after (" .. A.p.mission .. ") - a hint, not all of it" end
	if VlMemory and VlMemory.topicFor then
		local ok, s = pcall(VlMemory.topicFor, A.id, B.id)
		if ok and s then opts[#opts + 1] = s; opts[#opts + 1] = s end
	end
	if VL_VILLAGE and VL_VILLAGE.rumours and #VL_VILLAGE.rumours > 0 then opts[#opts + 1] = VL_VILLAGE.rumours[VlRand(#VL_VILLAGE.rumours)] end
	local P = A.lastP
	for _, th in ipairs(P and P.things or {}) do
		if th.kind == "player" and th.sense == "seen" then opts[#opts + 1] = "the stranger " .. th.name .. " you can see" end
	end
	if #opts == 0 then return "whatever is on your mind" end
	return opts[VlRand(#opts)]
end

-- (the user, 2026-11-14: Mochi and Duchess "spoke too fast"; "make sure they can tell when to leave a conversation")
-- The brain runs villager conversations turn by turn (no agent-to-agent hearing): when one has spoken, the other is
-- asked after a reading pause (VlBrain.pause); every turn may be the last - a goodbye with end_conversation, an answer
-- without words, or the turn limit (by both talkers' talkativeness) ends it.
function VlBrain.pause(text)
	return math.max(VL_CFG.convPauseMin, math.min(VL_CFG.convPauseMax, 2.5 + #(text or "") * 0.055)) + VlRand() * 1.5
end

function VlBrain.convHas(c, agent)
	for _, M in ipairs(c.members) do if M.agent == agent then return true end end
	return false
end

local function speakerNum(V) return GetInt(reg(V) .. ".player") end

local function joinConv(c, V, S)
	if V.conv == c then return end
	c.members[#c.members + 1] = V
	V.conv = c
	c.maxTurns = c.maxTurns + 1
	c.maxSec = (c.maxSec or VL_CFG.convMax) + 15
	V.engaged = {pos = function() return (c.lastSpeaker or S).w.pos end, untilT = c.startT + c.maxSec}
	for _, M in ipairs(c.members) do if M.engaged then M.engaged.untilT = c.startT + c.maxSec end end
	VlBrain.keys(V)
end

function VlBrain.startConv(A, B, about)
	local scale = (VL_CFG.talkScale or {})[VL_CFG.talkLength or 2] or 1
	local turns = math.floor((1.5 + 2.2 * (VlBrain.chatty(A) + VlBrain.chatty(B)) / 2 + VlRand() * 1.5) * scale)
	local c = {members = {A, B}, a = A, b = B, startT = GetTime(), lastT = GetTime(), turn = 1,
		maxTurns = math.max(2, turns), asked = A, addressed = B}
	c.maxSec = math.max(VL_CFG.convMax, 30 + 15 * c.maxTurns)
	VB.convs[#VB.convs + 1] = c
	A.conv, B.conv = c, c
	VB.pairT[pairKey(A, B)] = GetTime()
	A.engaged = {pos = function() return (c.lastSpeaker ~= A and c.lastSpeaker or B).w.pos end, untilT = GetTime() + c.maxSec}
	B.engaged = {pos = function() return (c.lastSpeaker or A).w.pos end, untilT = GetTime() + c.maxSec}
	VlBrain.keys(A); VlBrain.keys(B)
	c.askedN = GetInt(reg(A) .. ".replyn")
	local where = A.place and (" at " .. A.place.name) or ""
	VlBrain.event(A, string.format(VlBrain.TALK.open, B.name, where, B.name, about or topic(A, B)))
end

-- who answers villager S's line (the same rules as for a player's line): the line's relevance to each villager in
-- earshot (the model's scores when Koetama scores, else words they care about), a name said, being in the talk,
-- the distance rank from S and a clear line from S's eyes. Members of the talk are favoured; another villager joins
-- only when named or really concerned.
function VlBrain.pickListener(S, text, c)
	local now = GetTime()
	local R = VL_RUBRIC
	local sn = speakerNum(S)
	local eye = VecAdd(S.w.pos, Vec(0, 1.6, 0))
	local cands = {}
	for _, V in ipairs(VB.all) do
		local member = c and V.conv == c and not (c.passed and c.passed[V])
		local free = not V.conv and not V.downed and not (V.engaged and V.engaged.player) and not V.thinkPending
			and now > (V.coolT or 0)
		if V ~= S and V.alive and not V.asleep and (member or free) then
			local d = VecLength(VecSub(V.w.pos, S.w.pos))
			if d < VL_CFG.convHear then
				local named = VlBrain.saysName(text, V.name)
				local rel
				local hs = V.heardScore
				if hs and hs.from == sn and now - hs.t < 8 then
					rel = hs.margin + R.answerAt                            -- (the model's relevance, the judge's sum)
					if hs.ended and member then rel = rel - 1.0 end
				else
					rel = 0
					local set = interests(V)
					for word in (text or ""):lower():gmatch("%a%a%a%a+") do rel = rel + (set[word] or 0) * 0.3 end
					if named then rel = rel + R.named + 0.5 end
				end
				cands[#cands + 1] = {V = V, d = d, member = member, named = named,
					score = rel + (member and VL_CFG.convMemberBonus or 0) + (named and 0.6 or 0)}
			end
		end
	end
	table.sort(cands, function(a, b) return a.d < b.d end)
	local best = nil
	for i, k in ipairs(cands) do
		if not k.named then
			local seen = VlPerceive.clear(eye, VecAdd(k.V.w.pos, Vec(0, 1.5, 0)))
			k.score = k.score + (R.rank[i] or R.rankLater) + (seen and R.seen or R.unseen)
		end
		if k.member or k.named or k.score >= VL_CFG.convJoinAt then
			if not best or k.score > best.score then best = k end
		end
	end
	return best and best.V or nil, best and not best.member
end

-- the conversations' turns (every tick)
function VlBrain.convTick()
	local now = GetTime()
	for i = #VB.convs, 1, -1 do
		local c = VB.convs[i]
		local S = c.asked
		local alive = 0
		for _, M in ipairs(c.members) do if M.alive and M.conv == c then alive = alive + 1 end end
		if alive < 2 or now - c.startT > (c.maxSec or VL_CFG.convMax) then VlBrain.endConv(c)
		elseif c.dueT then
			-- the pause is over: whoever the line concerns most answers (a player talking to a member holds it)
			local busy = false
			for _, M in ipairs(c.members) do if M.engaged and M.engaged.player then busy = true end end
			if busy then c.dueT = now + 2
			elseif now >= c.dueT then
				c.dueT = nil
				local L, joins = VlBrain.pickListener(c.lastSpeaker or S, c.lastText, c)
				if not L then VlBrain.endConv(c)
				else
					if joins then joinConv(c, L, S) end
					c.turn = c.turn + 1
					c.asked = L
					c.askedN = GetInt(reg(L) .. ".replyn")
					c.lastT = now
					local last = c.turn >= c.maxTurns
					local others = #c.members > 2
					local intro = (joins and ('[%s says nearby: "%s"] It concerns you - you may join in. '):format(S.name, c.lastText or "..."))
						or (others and ('[%s says: "%s"] '):format(S.name, c.lastText or "..."))
						or ('[%s says to you: "%s"] '):format(S.name, c.lastText or "...")
					VlBrain.event(L, intro .. (last and VlBrain.TALK.last or VlBrain.TALK.answer))
				end
			end
		else
			-- waiting for the asked one's line
			local n = GetInt(reg(S) .. ".replyn")
			if n ~= c.askedN then
				c.askedN = n
				local text = GetString(reg(S) .. ".reply")
				if c.ended or c.turn >= c.maxTurns then VlBrain.endConv(c)
				elseif text == "" then
					-- (passed: in a group the turn goes on to someone else; between two it is over)
					c.passed = c.passed or {}
					c.passed[S] = true
					local left = 0
					for _, M in ipairs(c.members) do if M ~= c.lastSpeaker and not c.passed[M] then left = left + 1 end end
					if #c.members <= 2 or left == 0 then VlBrain.endConv(c) else c.dueT = now + 1.0 end
				else
					c.lastText, c.lastSpeaker = text, S
					c.passed = nil
					c.dueT = now + VlBrain.pause(text)
				end
			elseif now - c.lastT > 30 then
				VlBrain.endConv(c)                              -- (no answer: the moment has passed)
			end
		end
	end
end

-- one member leaves (end_conversation); two left: the talk is over
function VlBrain.leaveConv(V)
	local c = V.conv
	if not c then return end
	if #c.members <= 2 then c.ended = true; return VlBrain.endConv(c) end
	for i, M in ipairs(c.members) do if M == V then table.remove(c.members, i) break end end
	V.conv, V.engaged = nil, nil
	V.coolT = GetTime() + 30
	V.thinkDue = true
	VlBrain.keys(V)
	if c.asked == V then c.asked = c.lastSpeaker ~= V and c.lastSpeaker or c.members[1]; c.dueT = GetTime() + 1 end
end

function VlBrain.endConv(c)
	for i, x in ipairs(VB.convs) do if x == c then table.remove(VB.convs, i) break end end
	for _, V in ipairs(c.members) do
		if V.conv == c then
			V.conv = nil
			V.engaged = nil
			V.coolT = GetTime() + 30
			V.thinkDue = true
			VlBrain.keys(V)
		end
	end
	if VlMemory and VlMemory.meet and c.lastT > c.startT + 1 then
		local where = c.members[1].place and c.members[1].place.name
		for _, A in ipairs(c.members) do
			for _, B in ipairs(c.members) do
				if A ~= B then pcall(VlMemory.meet, A.id, B.name, where, "villager") end
			end
		end
	end
end

-- ---------------------------------------------------------------- their own time: the villager decides what next
local function thinkText(V)
	local h = VlLife.hour()
	local routine = VlLife.want(V, h)
	local l = {"[Your own time - nobody asked you anything.] You are " .. VlLife.doingText(V) .. "."}
	local gt = VlBrain.goalsText(V)
	if gt ~= "" then l[#l + 1] = gt end
	local dil = (VL_CFG.diligence or {})[V.id] or 0.6
	if routine and routine.label then
		if dil >= 0.75 then l[#l + 1] = "Duty first: at this hour you would be " .. routine.label .. "."
		elseif dil <= 0.45 then l[#l + 1] = "At this hour you are supposed to be " .. routine.label .. ", but you would rather slack off if you can get away with it."
		else l[#l + 1] = "Usually at this hour you would be " .. routine.label .. "." end
	end
	if V.goals and V.goals.day ~= VlLife.day() then
		l[#l + 1] = "A new day: first decide what you mean to get done today (call set_goals), then what you do now."
	end
	if routine and routine.kind == "sleep" then l[#l + 1] = "It is late and you are tired." end
	if V.p.mission and VlRand() < 0.35 then l[#l + 1] = "On your mind: " .. V.p.mission end
	if VlMemory and VlMemory.topicFor and VlRand() < 0.35 then
		local ok, s = pcall(VlMemory.topicFor, V.id)
		if ok and s then l[#l + 1] = "You keep thinking about: " .. s end
	end
	l[#l + 1] = "What do you do next? Act with a function (do_activity, go_to, talk_to someone, or stay). Say nothing aloud unless you speak to someone near you."
	return table.concat(l, " ")
end

local function thinker()
	local now = GetTime()
	if VL_CFG.thinkPerMinute <= 0 then return end                      -- (Quiet: lives by routine)
	if GetString("proxchat.agents") ~= "ready" or not ambientOk() then return end
	if now < (VB.nextThinkT or 0) then return end
	local pick, pickT = nil, math.huge
	for _, V in ipairs(VB.all) do
		if V.thinkPending and now - V.thinkPending > 40 then V.thinkPending = nil end
		local busy = not V.alive or V.asleep or V.conv or V.thinkPending or (V.engaged and V.engaged.player and now < V.engaged.untilT)
			or (V.override and (V.override.kind == "fire" or V.override.kind == "fetch" or V.override.kind == "flee"))
		if not busy then
			V.nextThink = V.nextThink or (now + 4 + V.k * 6)
			local due = V.thinkDue and now or V.nextThink
			if due <= now and due < pickT then pick, pickT = V, due end
		end
	end
	if not pick then return end
	VB.nextThinkT = now + 60 / VL_CFG.thinkPerMinute
	pick.thinkPending = now
	pick.thinkDue = false
	pick.nextThink = now + VL_CFG.thinkEvery * (0.7 + 0.6 * VlRand())
	VlBrain.event(pick, thinkText(pick))
end

local function director()
	local now = GetTime()
	for i = #VB.convs, 1, -1 do
		local c = VB.convs[i]
		if not c.a.alive or not c.b.alive then VlBrain.endConv(c) end
	end
	-- a villager who asked to talk to someone (talk_to) and got there
	for _, V in ipairs(VB.all) do
		local t = V.pendingTalk
		if t and (now - t.t > 40 or not t.who.alive) then V.pendingTalk = nil
		elseif t and VecLength(VecSub(t.who.w.pos, V.w.pos)) < 3 and not t.who.conv and not t.who.asleep then
			V.pendingTalk = nil
			V.override = nil
			VlBrain.startConv(V, t.who, t.about)
		end
	end
	if VL_CFG.convPerMinute <= 0 or now < (VB.nextConv or 0) or not ambientOk() then return end
	VB.nextConv = now + 60 / VL_CFG.convPerMinute
	-- pairs close together, with a player in earshot, not too soon again
	local cands = {}
	for i, A in ipairs(VB.all) do
		if free(A) then
			for j, B in ipairs(VB.all) do
				if j ~= i and free(B) then
					local d = VecLength(VecSub(A.w.pos, B.w.pos))
					local same = A.place and A.place == B.place and A.mode == "at" and B.mode == "at"
					if d < 3.5 or (same and d < 10) then
						if now - (VB.pairT[pairKey(A, B)] or -1e9) > VL_CFG.pairCooldown then cands[#cands + 1] = {A, B} end
					end
				end
			end
		end
	end
	if #cands == 0 then return end
	local pick = cands[VlRand(#cands)]
	VlBrain.startConv(pick[1], pick[2])
end

-- off-screen social life, no LLM: villagers together with no player near pass on news (VlMemory.gossip)
local function gossip()
	local now = GetTime()
	if now < (VB.nextGossip or 0) then return end
	VB.nextGossip = now + 20
	if not (VlMemory and VlMemory.gossip) then return end
	for i, A in ipairs(VB.all) do
		for j, B in ipairs(VB.all) do
			if j > i and A.alive and B.alive and not A.asleep and not B.asleep and A.place and A.place == B.place
				and not ambientOk() then
				local k = "g" .. pairKey(A, B)
				if now - (VB.pairT[k] or -1e9) > 180 then
					VB.pairT[k] = now
					pcall(VlMemory.gossip, A.id, B.id, A.place.name)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- memory: the scribe at night, a fresh window by day
local function scribeKeys()
	if not (VlMemory and VlMemory.SCRIBE_PERSONA) then return end
	local r = "proxchat.agent." .. SCRIBE
	put(r .. ".persona", VlMemory.SCRIBE_PERSONA)
	put(r .. ".name", "Scribe")
	put(r .. ".character", "false")
	put(r .. ".hears", "none")
	put(r .. ".stream", "false")
	put(r .. ".max_words", "500")
	local sf = VlMemory.SCRIBE_FUNCTIONS
	if type(sf) == "table" then sf = "[" .. table.concat(sf, ",\n") .. "]" end
	put(r .. ".functions", sf or "[]")
end

function VlBrain.scribeCall(name, argsJson)
	local id = VB.scribe.busy
	VB.scribe.busy = nil
	if not id then return "error: no job" end
	if VlMemory and VlMemory.sleepResult then
		local ok, r = pcall(VlMemory.sleepResult, nil, argsJson)
		if ok then return r or "ok" end
		return "error: " .. tostring(r)
	end
	return "ok"
end

-- the night: villagers asleep for a while are planned once a night (VlMemory.nightPlan: at most JOBS_PER_NIGHT get a
-- scribe job, the LLM's output budget); the rest are done locally. One job at a time: .forget, then the job as an
-- event; no consolidate call within 30 s -> done locally.
local function nightKey() local h = VlLife.hour(); return VlLife.day() - (h < 12 and 1 or 0) end

local function scribeTick()
	if not VlMemory or not VlMemory.sleepJob then return end
	local now = GetTime()
	local sc = VB.scribe
	if sc.busy then
		if now - sc.sentT < 30 then return end
		pcall(VlMemory.sleepLocal, sc.busy)                      -- (no answer: the night without the LLM)
		sc.busy = nil
	end
	if now < (sc.planT or 0) then return end
	sc.planT = now + 5
	local nk = nightKey()
	local due = {}
	for _, V in ipairs(VB.all) do
		if V.alive and V.asleep and V.nightDone ~= nk and now - (V.asleepSince or now) > 20 then due[#due + 1] = V end
	end
	if #due > 0 then
		local ids = {}
		for _, V in ipairs(due) do ids[#ids + 1] = V.id; V.nightDone = nk end
		local llm = {}
		if VlBrain.ready() and VlMemory.nightPlan then
			sc.used = sc.used or {}
			local left = VlMemory.JOBS_PER_NIGHT - (sc.used[nk] or 0)
			if left > 0 then
				local ok, plan = pcall(VlMemory.nightPlan, ids, left)
				for _, id in ipairs(ok and plan or {}) do llm[id] = true end
			end
		end
		sc.queue = sc.queue or {}
		for _, id in ipairs(ids) do
			if llm[id] then sc.queue[#sc.queue + 1] = id; sc.used[nk] = (sc.used[nk] or 0) + 1
			else pcall(VlMemory.sleepLocal, id) end
		end
	end
	local id = sc.queue and table.remove(sc.queue, 1)
	if id then
		local ok, job = pcall(VlMemory.sleepJob, id)
		if ok and job and job ~= "" and VlBrain.ready() then
			sc.busy, sc.sentT = id, now
			SetBool("proxchat.agent." .. SCRIBE .. ".forget", true)
			SetString("proxchat.agent." .. SCRIBE .. ".event", job)
			noteReq()
		end
	end
end

-- ---------------------------------------------------------------- damage
function VlBrain.hurt(V, dmg, by, from, point)
	if not V.alive then return end
	V.hp = V.hp - dmg
	V.hitN = (V.hitN or 0) + 1                                   -- (every machine spurts blood at lastHit)
	V.lastHit = point and VecCopy(point) or VecAdd(V.w.pos, Vec(0, 1.1, 0))
	-- (the user, 2026-11-15: "I don't think they get knock back either") a shove away from where the hit came from,
	-- by the damage (or the weapon's own knockback, VlBrain.knockNext), applied in main.lua's server.update
	local src = from or point
	if src and not V.downed and V.posture ~= "lie" then
		local away = VecSub(V.w.pos, src)
		away[2] = 0
		if VecLength(away) < 0.05 then away = VecScale(V.w.fwd, -1) end
		local speed = VlBrain.knockNext or math.max(1.0, math.min(7, dmg * 0.13))
		VlBrain.knockNext = nil
		V.knock = {vel = VecScale(VecNormalize(away), speed), untilT = GetTime() + 0.35}
		if V.posture == "sit" then V.posture = "stand"; V.mode = "go"; V.planKey = nil end
	end
	-- (the user, 2026-11-14: "when they're hurt (low health), blood should show and they should look weak") too weak to
	-- stand: they collapse where they are until someone bandages them back over downAbove
	if V.hp > 0 and V.hp < VL_CFG.downBelow and not V.downed then VlBrain.collapse(V) end
	V.lastThreat = from and VecCopy(from) or V.lastThreat
	V.hurtT = GetTime()
	if V.asleep then VlBrain.wake(V, by) end
	if V.hp <= 0 then
		V.hp = 0
		V.alive = false
		V.diedT = GetTime()
		V.goneT = GetTime() + 25
		VlNav.stop(V.w)
		VlPlaces.release(V.id)
		VlBrain.happen(V, string.format("%s has killed you. You are dying: say your last words.", by or "Something"), true)
		VlBrain.witness("death:" .. V.id, VecAdd(V.w.pos, Vec(0, 0.8, 0)), {skip = {[V] = true}, alarm = true,
			seen = "", heard = "You HEAR a dying scream nearby, {d} m away.", hearRange = 30})
		-- the others who saw it (together, as one incident: two speak, the rest go quiet and decide)
		local seers = {}
		for _, O in ipairs(VB.all) do
			if O ~= V and O.alive and not O.asleep and VlBrain.sees(O, VecAdd(V.w.pos, Vec(0, 0.8, 0))) then
				seers[#seers + 1] = {O = O, seen = true, d = VecLength(VecSub(O.w.pos, V.w.pos)),
					text = string.format("You just saw %s die%s, %s!", V.name, by and (", killed by " .. by) or "", VlBrain.whereWords(O, V.w.pos)),
					mem = {text = string.format("Saw %s die%s", V.name, by and (", killed by " .. by) or ""), who = {V.name, by}, importance = 5, kind = "event"}}
				if by and VlMemory and VlMemory.feel then pcall(VlMemory.feel, O.id, by, -4, "killed " .. V.name) end
				VlLife.setOverride(O, {kind = "flee", from = VecCopy(V.w.pos), dist = 25, untilT = GetTime() + 14})
			end
		end
		VlBrain.incident(seers)
		return
	end
	local skip = {[V] = true}
	local att = by and VlBrain.villagerByName(by)
	if att then skip[att] = true end
	VlBrain.witness("hit:" .. V.id, VecAdd(V.w.pos, Vec(0, 1.1, 0)), {skip = skip, alarm = true,
		seen = string.format("You SEE %s hit %s%s, {d} m away!", by or "something", V.name, V.hp < VL_CFG.bleedBelow and " - who is badly hurt" or ""),
		heard = "You HEAR someone cry out in pain nearby, {d} m away.",
		mem = {text = string.format("Saw %s hit %s", by or "something", V.name), who = {by, V.name}, importance = 3, kind = "event"}})
	local how = string.format("%s hurt you (health now %d%%). Fight back, run, plead or shout - as you would.", by or "Something", math.floor(V.hp))
	VlBrain.happen(V, how, true, {text = (by or "Something") .. " hurt me", who = {by}, importance = 5, kind = "event"})
	if by and VlMemory and VlMemory.feel then pcall(VlMemory.feel, V.id, by, -3, "hurt me") end
	if not VlBrain.ready() then
		local f = VlBrain.fallbackLine(V, "hurt")
		if f then SetString(reg(V) .. ".say", f) end
	end
	-- (the user, 2026-11-15: fight back, run or chase "depending on their personality (let the LLM decide)") with the
	-- AI the event above lets it choose (attack, flee, plead, shout); without it, temper does: the hot-headed hit back
	-- at whoever it was, the rest run
	if not VlBrain.ready() and from and not V.downed then
		local o = V.override
		if not (o and (o.kind == "fight" or o.kind == "flee")) then
			local temper = (VL_CFG.temper or {})[V.id] or 0.4
			local w = by and whom(by)
			if temper >= 0.6 and w and VecLength(VecSub(w.pos(), V.w.pos)) < 15 then
				VlLife.setOverride(V, {kind = "fight", who = w.name, pos = w.pos, villager = w.villager, player = w.player,
					untilT = GetTime() + VL_CFG.fightFor})
			else
				VlLife.setOverride(V, {kind = "flee", from = VecCopy(from), dist = 16, untilT = GetTime() + 8})
			end
		end
	end
end

-- ---------------------------------------------------------------- witnesses (the user, 2026-11-15: "they should be able
-- to see important events like someone getting hit or someone dying, etc. if they are able to sense it")
-- An event at pos goes to every villager who can sense it: in sight (range, a clear line from its eyes) it hears
-- what happened; out of sight but within earshot only the sound of it. Each villager hears of the same thing (key)
-- at most once in VL_CFG.witnessEvery s. opts: seen = text for those who see it, heard = text for those who only hear
-- it (nil: they don't), hearRange, mem = memory for those who saw it, skip = {villagers not to tell}, alarm = they yell
-- (the user, 2026-11-15: villagers "sense things that are happening outside walls that they should not be able to
-- sense ... They don't seem to have a good idea of where they are relative to the event") Where pos is from O, in
-- words: inside / outside / upstairs, in front / behind / left / right, how far.
function VlBrain.whereWords(O, pos)
	local d = VecSub(pos, O.w.pos)
	local flat = Vec(d[1], 0, d[3])
	local L = VecLength(flat)
	local bits = {}
	local bO = VlPlaces.buildingAt and VlPlaces.buildingAt(O.w.pos)
	local bP = VlPlaces.buildingAt and VlPlaces.buildingAt(pos)
	if bO and bO ~= bP then bits[#bits + 1] = bP and "in another building" or "outside"
	elseif bP and not bO then bits[#bits + 1] = "inside a building"
	elseif bO and bO == bP and math.abs(d[2]) > 2 then bits[#bits + 1] = d[2] > 0 and "upstairs" or "downstairs" end
	if L > 1.5 then
		local f = O.w.fwd
		local u = VecScale(flat, 1 / L)
		local ahead = u[1] * f[1] + u[3] * f[3]
		local side = u[1] * -f[3] + u[3] * f[1]
		bits[#bits + 1] = ahead > 0.7 and "in front of you" or (ahead < -0.7 and "behind you" or (side > 0 and "to your right" or "to your left"))
	end
	bits[#bits + 1] = L < 3 and "right next to you" or string.format("about %d m away", math.floor(L + 0.5))
	return table.concat(bits, ", ")
end

-- does O see pos: in range, within their view (unless right beside it), nothing in the way
function VlBrain.sees(O, pos)
	local eye = VecAdd(O.w.pos, Vec(0, 1.6, 0))
	local d = VecLength(VecSub(pos, eye))
	if d >= VL_CFG.seeRange then return false end
	local fl = Vec(pos[1] - O.w.pos[1], 0, pos[3] - O.w.pos[3])
	local L = VecLength(fl)
	if L > 2.5 and (fl[1] * O.w.fwd[1] + fl[3] * O.w.fwd[3]) / L < -0.35 then return false end   -- (behind them)
	return VlPerceive.clear(eye, pos)
end

-- an event to everyone who senses it: SEEN (in view, nothing in the way) or HEARD (within opts.hearRange, only 40 % as
-- far through walls, and then muffled). Texts take {d} / {where}; a heard one is told they can't see it. Only those
-- who see it are alarmed (yelling): a cry through a wall is no reason to shout instructions.
-- (the user, 2026-11-15: "when someone screams, villagers should stop talking and listen and decide what to do rather
-- than yapping ... it's kinda dizzy when everyone talks at once") An incident reaches its witnesses together: every one
-- of them stops talking (their conversation ends); the two who saw it best (seen first, then nearest) are asked at once,
-- told to act first and keep words few; the rest take it in quietly (a note and a memory) and decide in their own time
-- (the thinker: silent unless they speak to someone near them).
function VlBrain.incident(list)
	table.sort(list, function(a, b)
		if (a.seen and 1 or 0) ~= (b.seen and 1 or 0) then return a.seen end
		return a.d < b.d
	end)
	for i, h in ipairs(list) do
		local O = h.O
		if O.conv then VlBrain.endConv(O.conv) end
		if i <= 2 then
			VlBrain.happen(O, h.text .. " Take it in and act first; if you say anything, a few words.", true, h.mem)
		else
			VlBrain.happen(O, h.text, false, h.mem)
			O.thinkDue = true
		end
	end
end

function VlBrain.witness(key, pos, opts)
	local now = GetTime()
	local list = {}
	for _, O in ipairs(VB.all or {}) do
		if O.alive and not O.asleep and not (opts.skip and opts.skip[O]) then
			O.witnessed = O.witnessed or {}
			if now - (O.witnessed[key] or -1e9) > VL_CFG.witnessEvery then
				local eye = VecAdd(O.w.pos, Vec(0, 1.6, 0))
				local d = VecLength(VecSub(pos, eye))
				local seen = VlBrain.sees(O, pos)
				local open = seen or VlPerceive.clear(eye, pos)
				local range = (opts.hearRange or 20) * (open and 1 or 0.4)
				if seen or (opts.heard and d < range) then
					O.witnessed[key] = now
					local text = seen and opts.seen or opts.heard
					if text and text ~= "" then
						local where = VlBrain.whereWords(O, pos)
						if not seen and not open then where = "muffled, through the walls, " .. where end
						text = text:gsub("nearby, {d} m away", where):gsub("{d} m away", where):gsub("{where}", where):gsub("{d}", tostring(math.floor(d)))
						if not seen then text = text .. " You can't see what is happening." end
						list[#list + 1] = {O = O, text = text, mem = seen and opts.mem or nil, seen = seen, d = d}
						if opts.alarm and seen then O.alarmUntil = now + 12 end
					end
				end
			end
		end
	end
	VlBrain.incident(list)
end

function VlBrain.collapse(V)
	V.downed = true
	VlBrain.witness("down:" .. V.id, VecAdd(V.w.pos, Vec(0, 0.6, 0)), {skip = {[V] = true},
		seen = "You SEE " .. V.name .. " collapse to the ground, {d} m away.",
		mem = {text = "Saw " .. V.name .. " collapse", who = {V.name}, importance = 3, kind = "event"}})
	V.override = nil
	V.conv = V.conv and (VlBrain.endConv(V.conv) or nil)
	VlNav.stop(V.w)
	VlPlaces.release(V.id)
	V.asleep = false
	V.posture = "lie"
	V.lie = {pos = VecCopy(V.w.pos), head = VecCopy(V.w.fwd), floor = VecCopy(V.w.pos)}
	VlBrain.happen(V, "You collapse: you are too weak to stand. You need someone to bandage your wounds.", true)
end

function VlBrain.recover(V)
	V.downed = false
	V.posture = "stand"
	if V.lie and V.lie.floor then VlNav.warp(V.w, V.lie.floor) end
	V.lie = nil
	V.planKey = nil
	V.thinkDue = true
end

-- (each tick) players hurt or killed, as their witnesses see or hear it
function VlBrain.playerEvents()
	local n = GetEventCount("playerhurt")
	for i = 1, n do
		local p, before, after, att = GetEvent("playerhurt", i)
		if p and IsPlayerValid(p) and before and after and before - after > 0.02 and after > 0 then
			local by = (att and att > 0 and IsPlayerValid(att) and att ~= p) and GetPlayerName(att) or nil
			local pos = VecAdd(GetPlayerTransform(p).pos, Vec(0, 1.1, 0))
			VlBrain.witness("phit:" .. p, pos, {alarm = true,
				seen = string.format("You SEE %s get hurt%s, {d} m away.", GetPlayerName(p), by and (" by " .. by) or ""),
				heard = "You HEAR someone yell in pain nearby, {d} m away.",
				mem = {text = string.format("Saw %s get hurt%s", GetPlayerName(p), by and (" by " .. by) or ""), who = {GetPlayerName(p), by}, importance = 2, kind = "event"}})
		end
	end
	n = GetEventCount("playerdied")
	for i = 1, n do
		local p, att = GetEvent("playerdied", i)
		if p and IsPlayerValid(p) then
			local by = (att and att > 0 and IsPlayerValid(att) and att ~= p) and GetPlayerName(att) or nil
			local pos = VecAdd(GetPlayerTransform(p).pos, Vec(0, 0.8, 0))
			VlBrain.witness("pdie:" .. p, pos, {alarm = true,
				seen = string.format("You SEE %s fall dead%s, {d} m away!", GetPlayerName(p), by and (", killed by " .. by) or ""),
				heard = "You HEAR a scream nearby, then silence. {d} m away.",
				mem = {text = string.format("Saw %s die%s", GetPlayerName(p), by and (", killed by " .. by) or ""), who = {GetPlayerName(p), by}, importance = 5, kind = "event"}})
		end
	end
end

-- ---------------------------------------------------------------- senses -> events
local SOUND_MEM = {gunshot = "Heard gunshots", explosion = "Heard an explosion"}

-- another mod's creature / thing sensed (vl_api.lua): an event with the villager's feeling and the kind's note (once
-- a minute per creature), a memory, and the reflexes that need no AI: fear of a dangerous kind runs (closer than its
-- flee distance), hate in a hot temper attacks one that is not too dangerous when the AI is off
function VlBrain.creatureSeen(V, th, d)
	local now = GetTime()
	local t = th.thing
	local K = VlApi.kinds[t.kind] or {}
	local danger = K.danger or 0
	local fear = VlApi.fear(V, t.kind)                     -- (their own: the baseline danger x their multiplier + bonus, feel_about)
	local feel = th.feel
	local k = "c:" .. t.id
	local fresh = now - (V.sensed[k] or -1e9) > 60
	if th.sense == "seen" then
		if fear >= 0.3 or (danger >= 0.5 and feel ~= "love" and feel ~= "revere" and feel ~= "like") then V.lastThreat = VecCopy(th.pos) end
		local fleeAt = (K.flee and K.flee > 0) and K.flee or (8 + 20 * danger)
		fleeAt = fleeAt * (0.5 + fear)                          -- (the more afraid, the sooner they run)
		local temper = (VL_CFG.temper or {})[V.id] or 0.4
		local o = V.override
		local busy = o and (o.kind == "flee" or o.kind == "fight" or o.kind == "tend")
		if fear >= 0.3 and feel ~= "love" and feel ~= "revere" and d < fleeAt and not busy and not V.downed and not V.asleep then
			VlLife.setOverride(V, {kind = "flee", from = VecCopy(th.pos), dist = fleeAt + 12, untilT = now + 15})
			fresh = fresh or now - (V.sensed[k .. "f"] or -1e9) > 20
			V.sensed[k .. "f"] = now
		elseif feel == "hate" and not VlBrain.ready() and temper >= 0.6 and fear < 0.5 and d < 15 and not busy and fresh then
			CALLS.attack(V, {person = t.name, how = "fight"})
		end
	end
	if not fresh then return end
	V.sensed[k] = now
	local ft = VlApi.feelText(feel)
	local text
	local mine = VlApi.appraisal(V, t.kind)
	V.askedFeel = V.askedFeel or {}
	if th.sense == "seen" and not mine and now - (V.askedFeel[t.kind] or -1e9) > 120 then
		-- the first meeting: what it is (the other mod's description and baseline), and they decide for themselves
		V.askedFeel[t.kind] = now
		text = string.format("You SEE %s for the first time, %d m away%s.%s%s It is known to be %s. React as you would, and " ..
			"decide how YOU feel about it: call %s \"%s\", your feeling, and how much its danger " ..
			"frightens you (fear_multiplier, fear_bonus).", t.name, math.floor(d), th.doing and (", " .. th.doing) or "",
			(K.note or "") ~= "" and (" " .. K.note .. ".") or "", K.feel ~= "" and (" People say: " .. K.feel .. ".") or "",
			danger >= 0.8 and "deadly" or (danger >= 0.5 and "dangerous" or (danger >= 0.2 and "somewhat dangerous" or "harmless")),
			VlBrain.maxFunctions() >= 17 and "feel_about_creature with creature" or "feel_about with person", t.name)
		if V.override and V.override.kind == "flee" then text = text .. " You are already running." end
		VlBrain.happen(V, text, false, {text = "Saw " .. t.name .. " for the first time", importance = danger >= 0.5 and 4 or 3, kind = "event"})
		if VlBrain.ready() then VlBrain.event(V, text) end           -- (asked whether or not a player is near: it matters to how they live)
		return
	end
	if th.sense == "seen" then
		text = string.format("You SEE %s, %d m away%s%s.%s", t.name, math.floor(d), th.doing and (", " .. th.doing) or "",
			ft and (" - " .. ft .. (VlApi.why(V, t.kind) and (": " .. VlApi.why(V, t.kind)) or "")) or "",
			(K.note or "") ~= "" and (" (" .. K.note .. ")") or "")
		if V.override and V.override.kind == "flee" then text = text .. " You run!" end
	else
		text = string.format("You HEAR %s nearby, %d m away, but can't see it.", th.name, math.floor(d))
	end
	local urgent = fear >= 0.3 or danger >= 0.3 or (feel and feel ~= "ignore" and feel ~= "like")
	VlBrain.happen(V, text, urgent, {text = (th.sense == "seen" and "Saw " or "Heard ") .. t.name, importance = danger >= 0.5 and 4 or 2,
		kind = "event", feel = feel == "fear" and -2 or (feel == "hate" and -2 or ((feel == "love" or feel == "revere") and 2 or nil))})
	if not VlBrain.ready() and th.sense == "seen" and fear >= 0.5 then
		local f = VlBrain.fallbackLine(V, "scared")
		if f then SetString(reg(V) .. ".say", f) end
	end
end

local function senseEvents(V, P)
	local now = GetTime()
	V.sensed = V.sensed or {}
	for _, th in ipairs(P.things) do
		local d = VecLength(VecSub(th.pos, V.w.pos))
		if th.kind == "fire" then
			if now - (V.sensed.fire or -1e9) > 60 then
				V.sensed.fire = now
				local text = th.sense == "seen" and string.format("You SEE %s %d m away!", th.name, math.floor(d))
					or "You SMELL smoke: something is burning nearby, you can't see where."
				VlBrain.happen(V, text, true, {text = th.sense == "seen" and "Saw a fire" or "Smelled smoke", importance = 3, kind = "event"})
				if not VlBrain.ready() and th.sense == "seen" then
					local f = VlBrain.fallbackLine(V, "fire")
					if f then SetString(reg(V) .. ".say", f) end
					if V.p.extinguisher or V.p.brave then VlLife.putOutFire(V, th.pos) end
				end
			end
		elseif th.kind == "sound" and (th.loud or 0) > 0.5 then
			local key = th.name
			if now - (V.sensed[key] or -1e9) > 20 then
				V.sensed[key] = now
				VlBrain.happen(V, string.format("You HEARD %s, %d m away.", th.name, math.floor(d)), d < 40,
					{text = SOUND_MEM[th.name == "a gunshot" and "gunshot" or "explosion"] or "Heard a loud noise", importance = d < 25 and 3 or 2, kind = "event"})
				V.lastThreat = VecCopy(th.pos)
			end
		elseif th.kind == "villager" and th.sense == "seen" and th.hurt then
			-- (the user: "if they have low health, other villagers should be concerned for them and take care of them")
			local O = VB.byId and VB.byId[th.id]
			local k = "hurt:" .. tostring(th.id)
			if O and now - (V.sensed[k] or -1e9) > 60 then
				V.sensed[k] = now
				VlBrain.happen(V, string.format("You SEE %s %s, %s.", O.name,
					O.downed and "collapsed on the ground, bleeding badly" or "hurt and bleeding", VlBrain.whereWords(V, O.w.pos)), true,
					{text = "Saw " .. O.name .. " badly hurt", who = {O.name}, importance = 3, kind = "event"})
				-- without the AI (or a caring soul): they go and bandage them
				local care = (VL_CFG.caring or {})[V.id] or 0.3
				if (not VlBrain.ready() and care >= 0.5 or care >= 0.9) and O.downed and not V.tending and not V.downed then
					CALLS.bandage(V, {person = O.name})
				end
			end
		elseif th.kind == "creature" then
			VlBrain.creatureSeen(V, th, d)
		elseif th.kind == "player" and th.sense == "seen" then
			-- a stranger seen for the first time this day: a memory (not an event: no request)
			local k = "p:" .. th.name
			if not VB.knownPlayers then VB.knownPlayers = {} end
			if not VB.knownPlayers[th.name] and VlMemory and VlMemory.player then VB.knownPlayers[th.name] = true; pcall(VlMemory.player, th.name) end
			if V.sensed[k] ~= VlLife.day() then
				V.sensed[k] = VlLife.day()
				if VlMemory and VlMemory.add then
					pcall(VlMemory.add, V.id, {text = string.format("Saw %s%s%s", th.name, th.holding and (" carrying " .. th.holding) or "",
						V.place and (" near " .. V.place.name) or ""), who = {th.name}, importance = th.holding and 2 or 1, kind = "event"})
				end
			end
		end
	end
end

-- ---------------------------------------------------------------- the tick
function VlBrain.init(all)
	VB.all = all
	VB.byAgent = {}
	for _, V in ipairs(all) do VB.byAgent[V.agent] = V end
	VB.byId = {}
	for _, V in ipairs(all) do VB.byId[V.id] = V end
	if VlMemory and VlMemory.setProfile then
		for _, V in ipairs(all) do
			local blurb = string.format("%s, %s, %s. %s", V.p.title or V.name, V.p.job or "villager", V.p.faith or "",
				(V.p.persona or ""):sub(1, 260))
			pcall(VlMemory.setProfile, V.id, V.name, blurb)
			for _, t in ipairs(V.p.ties or {}) do
				local o = VlBrain.personById(t.who)
				if o then
					local kd = (t.kind or ""):lower()
					local op = 0
					if kd:find("rival") or kd:find("suspic") or kd:find("enem") or kd:find("grudge") or kd:find("hate") or kd:find("feud") then op = -2
					elseif kd:find("famil") or kd:find("friend") or kd:find("love") or kd:find("roman") or kd:find("brother") or kd:find("sister")
						or kd:find("uncle") or kd:find("nephew") or kd:find("lodger") or kd:find("apprentice") then op = 2 end
					pcall(VlMemory.setRel, V.id, o.name, op, t.note, t.kind)
				end
			end
			-- everyone else in the village: a neighbour they know (setRel keeps a tie set above)
			for _, O in ipairs(all) do
				if O ~= V then pcall(VlMemory.setRel, V.id, O.name, 0, "a neighbour, " .. (O.p.job or "villager"), "villager") end
			end
		end
	end
end

function VlBrain.tick(dt)
	local now = GetTime()
	local on = VB.api() >= 17
	VlBrain.calls()
	saidEvents()
	if now > (VB.attT or 0) then VB.attT = now + 0.25; attention() end
	pcall(VlBrain.playerEvents)
	VlBrain.judgeTick()
	for _, V in ipairs(VB.all) do
		local e = V.engaged
		if e and e.player and IsPlayerValid(e.player) then
			local d = VecLength(VecSub(GetPlayerTransform(e.player).pos, V.w.pos))
			if d > VL_CFG.leaveDist then
				V.awayT = V.awayT or now
				if now - V.awayT > 6 then V.engaged = nil; V.awayT = nil; V.thinkDue = true end
			else V.awayT = nil end
		end
	end
	for _, V in ipairs(VB.all) do
		if on then
			if now > (V.keysT or 0) then V.keysT = now + 0.5; VlBrain.keys(V) end
			VlBrain.replies(V)
		end
		-- perception and state: often where a player is near, seldom elsewhere
		local near = VB.playerNear(V, VL_CFG.talkRange + 10)
		if V.alive and now > (V.stateT or 0) then
			V.stateT = now + (near and 1.0 or 8.0) + V.k * 0.03
			local P = VlPerceive.build(V, VB.all)
			V.lastP = P
			senseEvents(V, P)
			if on then put(reg(V) .. ".state", VlBrain.stateText(V, P)) end
		end
		-- asleep -> awake by the clock: a fresh conversation window, the persona with last night's memories
		if V.asleep and not V.asleepSince then V.asleepSince = now end
		if not V.asleep and V.asleepSince then
			V.asleepSince = nil
			if on and V.plan and V.plan.kind ~= "sleep" then
				SetBool(reg(V) .. ".forget", true)
				V.personaDirty = true
			end
		end
	end
	if VlMemory and VlMemory.tick then pcall(VlMemory.tick, dt) end
	-- a new day for the memory once, in the small hours (before the first villager wakes)
	if VlMemory and VlMemory.newDay and VlLife.hour() >= 3.5 and VlLife.hour() < 12 and VB.memDay ~= VlLife.day() then
		VB.memDay = VlLife.day()
		if VB.memStarted then pcall(VlMemory.newDay) end
		VB.memStarted = true
	end
	if on then
		scribeKeys()
		director()
		VlBrain.convTick()
		VlBrain.queueTick()
		thinker()
	end
	scribeTick()
	gossip()
end

function VlBrain.destroy()
	for _, V in ipairs(VB.all or {}) do ClearKey(reg(V)) end
	ClearKey("proxchat.agent." .. SCRIBE)
end
