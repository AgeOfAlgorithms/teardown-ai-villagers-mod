-- Villagers: every tunable in one place, and the session's own dice.
-- (no #version line: included by main.lua)

VL_CFG = {
	-- perception
	senseFormat = "json",        -- the vision benchmark's winner (export/vision_report.md: 82 % vs 78 relational, 54-59 the ASCII maps)
	senseRange = 30,             -- m: things farther away are not described
	-- navigation
	walkSpeed = 1.4,
	runSpeed = 3.6,
	lodDist = 70,                -- m: no player nearer (and none seeing it): coarse movement
	-- the LLM
	hearAgents = 4,              -- villager-to-villager lines in a row after a start
	talkRange = 40,              -- m: villagers talk among themselves (LLM) only when a player is this near
	convPerMinute = 2,           -- the most director-started conversations a minute (anywhere: watched or not)
	thinkPerMinute = 6,          -- villagers deciding what to do next, a minute for the whole village (one request each)
	thinkEvery = 240,            -- s: a villager decides again after this at the latest (or when its activity ends)
	minActivitySec = 90,         -- s: an activity it chose lasts at least this long (a day is ~15 minutes)
	maxActivitySec = 420,
	maxWords = 28,
	-- the clock without Day & Night (its defaults: 9 min of daylight, 6 of night)
	ownDaySec = 540,
	ownNightSec = 360,
	-- places (vl_places.lua)
	placeCoarseStep = 4,         -- m: the first pass that finds the village
	placeCoarseHalf = 150,       -- m round the spawn
	placeStep = 1.0,             -- m: the fine grid
	placeRadius = 70,            -- m round the village centre
	placeRaysPerFrame = 400,
	minHouseArea = 8,            -- m2 of sheltered floor
	minEnclosure = 0.45,         -- share of a building's edge with walls (trees, bridges, porches have little)
	bedMinArea = 1.2,            -- m2 of soft (plastic) surface 0.25-1 m over a floor: a bed (or a sofa)
	bedMaxMass = 400,            -- kg (the game's beds: 100-160; benches that look like beds: 768)
	extinguisherIds = {brannoc = true, ruben = true, bett = true, silas = true},   -- they keep one at hand
	strikeDamage = 0.08,         -- a villager's punch on a player (of 1.0), x (0.7 + temper)
	punchDamage = 12,            -- a villager's punch on a villager (of 100), x (0.7 + temper)
	punchReach = 1.5,            -- m
	punchEvery = 1.1,            -- s between blows in a fight
	fightFor = 60,               -- s a fight lasts at most (the AI decides again then)
	fightLose = 30,              -- m: farther and they got away
	-- how easily talked into things (the user, 2026-11-15: "slightly suggestible generally, but also vary based on
	-- their personalities"); a line in the persona (VlBrain.persona); 0.5 when not listed
	suggestible = {wren = 0.85, ruben = 0.65, lucan = 0.65, bett = 0.55, marl = 0.55, ysolde = 0.5, silas = 0.5,
		nadia = 0.35, brannoc = 0.35, odette = 0.2, hesper = 0.15, eskil = 0.15},
	-- how hot-headed each is (without the AI: >= 0.6 hits back, the rest run; with it: harder blows)
	temper = {brannoc = 0.9, silas = 0.75, eskil = 0.7, wren = 0.6, hesper = 0.5, nadia = 0.45, odette = 0.4,
		ruben = 0.35, lucan = 0.3, ysolde = 0.3, bett = 0.3, marl = 0.2},
	bulletDamage = 25,           -- of a villager's 100 per bullet through them (a head shot twice that)
	bleedBelow = 45,             -- health under which they bleed, limp, look weak, and others worry
	downBelow = 20,              -- they collapse ...
	downAbove = 35,              -- ... and get up again once bandaged back over this
	healRate = 2.5,              -- health a second while someone bandages them (players: x 0.01)
	tendFor = 40,                -- s of bandaging at most
	sleepHeal = 0.05,            -- health a second while asleep
	-- who runs to bandage the hurt even without being asked (>= 0.9), or without the AI (>= 0.5)
	caring = {ysolde = 1.0, bett = 0.9, hesper = 0.7, marl = 0.7, nadia = 0.5, ruben = 0.5, brannoc = 0.4, wren = 0.6,
		lucan = 0.4, eskil = 0.2, odette = 0.1, silas = 0.1},
	attendDist = 6,              -- m: a player facing a villager this close is talking to them (hears = near)
	ambientPerMinute = 24,       -- requests a minute (all sources) above which no new thinking or villager talk starts
	-- (the user, 2026-11-15: "by default, there should only be 4 villagers. The tokens run out really fast ... at least 2
	-- friendly ones") the village a host gets until they pick in the options (savegame.mod.vill.<id> = "on" / "off")
	defaultVillagers = {bett = true, ruben = true, brannoc = true, silas = true},
	carHitSpeed = 4,             -- m/s: a vehicle at least this fast that drives into a villager hits them
	carDamage = 7,               -- health a m/s over carHitSpeed (x the vehicle's mass / 1500, 0.5 .. 2)
	ragdollFor = 2.5,            -- s a hit villager lies limp (a ragdoll on every machine), then gets up
	torchReach = 1.8,            -- m: a blowtorch's flame reaches a villager this far from the eyes
	torchDamage = 1,             -- health every 0.25 s of blowtorch on a villager (4 a second; the user, 2026-11-15: 8 was too fast)
	convMax = 90,                -- s: a villager conversation at most (or 30 + 15 s a turn when that is longer)
	-- the host's "Conversation length" option (options.lua, savegame.mod.talk 1-4): the turn limit of a villager
	-- conversation (1.5 + 2.2 x the pair's chattiness + up to 1.5) times this - Short / Normal / Long / Very long
	talkLength = 2,
	talkScale = {0.6, 1, 2, 3},
	groupMax = 3,                -- villagers who answer one line said to several (in turn)
	groupMargin = -0.35,         -- how little a group line may concern one for it to still add its answer
	convHear = 20,               -- m: villagers this near a villager's line may answer or join
	convMemberBonus = 0.6,       -- those already in the talk are favoured
	convJoinAt = 0.9,            -- an outsider joins only with this much (named, or the line concerns them)
	overhearMin = 1.8,           -- relevance (code-scored) for a villager to be told it overheard a line not meant for it
	convPauseMin = 4,            -- s between one line and the answer being asked for (+ up to 1.5 s): time to read it
	convPauseMax = 10,
	leaveDist = 9,               -- m: a player this far off for 6 s has left the conversation
	-- how much each one talks (the user: "brief and to the point, depending on their personality"): words a line
	-- 5 + 10 x this, turns of a conversation 1.5 + 2.2 x the pair's mean (+ up to 1.5)
	-- how seriously each takes their duties (the user: "depending on personalities, they can also slack off")
	diligence = {hesper = 0.95, bett = 0.9, brannoc = 0.85, odette = 0.85, eskil = 0.8, nadia = 0.7, marl = 0.6,
		ruben = 0.5, ysolde = 0.5, wren = 0.4, lucan = 0.35, silas = 0.3},
	chatty = {brannoc = 0.35, eskil = 0.4, silas = 0.6, odette = 0.6, hesper = 0.7, marl = 0.8, nadia = 0.9,
		ysolde = 1.0, bett = 1.1, wren = 1.2, lucan = 1.4, ruben = 1.5},
	pairCooldown = 300,          -- s before the same two are set talking again
	witnessEvery = 12,           -- s: the same event about the same person is told to a witness at most this often
	voiceFor = 40,               -- s a chosen whisper / yell lasts
	-- fire
	sprayRadius = 1.6,           -- m: the fires an extinguisher puts out round its aim, every 0.5 s
	smellRange = 45,             -- m: smoke reaches them
	-- senses
	seeRange = 35,
	nameRange = 30,              -- m: names over heads drawn this far (in sight only)
	seeClothes = 12,             -- m: what someone wears is made out this close (what they hold: whenever seen)
	hearShot = 80,               -- m: gunshots / explosions are heard
	hearStep = 8,                -- m: footsteps of someone moving, unseen
}

-- The session's own random numbers (Lua 5.1, no bitwise ops): Park-Miller minimal standard. The game starts every
-- script on the same math.random sequence (Day & Night 1.2.1 found it rained at every start), so session dice come
-- from a seed counted up in savegame.mod.vl.seed each session.
local vlSeed = 1
function VlSeed(n)
	vlSeed = (math.floor(n) % 2147483646) + 1
end
function VlRand(a, b)                                  -- VlRand() 0..1, VlRand(n) 1..n, VlRand(a, b) a..b
	vlSeed = (vlSeed * 16807) % 2147483647
	local r = (vlSeed - 1) / 2147483646
	if a == nil then return r end
	if b == nil then return math.floor(r * a) + 1 end
	return math.floor(r * (b - a + 1)) + a
end
