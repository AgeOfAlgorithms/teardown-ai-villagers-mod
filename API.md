# AI Villagers: API for other mods

The villagers read and write ordinary **registry keys on the host**. Any mod can use them: a creature mod, a map, a
game mode or a quest mod. You don't need to include or require anything. If the Villagers mod isn't running, nothing
reads your keys, so writing them is always safe. To check whether it's running, read `villagers.present` (true once
the villagers exist) and `villagers.version` (currently 1).

Every key below is a host key: write and read them in `server.*` callbacks.

## Quick start: put your creature in front of the villagers in three steps

1. **Describe the kind once** (in `server.init`): a name, a one-line description, and how dangerous it is.
2. **Say where each one is**: tag its body `vlkind=<your kind id>`, or write its position as a "thing".
3. **Leave the feelings to the villagers.** Each of them sees it, reads your description, and decides with their own
   AI what they feel and how much they fear it: one runs, one grabs a hammer, one wants to pet it. You don't set
   feelings for individual villagers, and you shouldn't.

```lua
-- 1. once
function server.init()
	SetString("villagers.kind.wolf.name", "a grey wolf")
	SetString("villagers.kind.wolf.note", "a big hungry wolf that came down from the hills; it goes for sheep and children")
	SetFloat("villagers.kind.wolf.danger", 0.6)         -- the baseline (see "Picking the danger" below)
	SetString("villagers.kind.wolf.feel", "fear")         -- optional: its general reputation
	SetString("villagers.kind.wolf.sound", "a low growl"); SetFloat("villagers.kind.wolf.hear", 20)
end
```
```xml
<!-- 2. on the wolf's body in your prefab (or SetTag(body, "vlkind", "wolf") from the script) -->
<body tags="vlkind=wolf"> ... </body>
```
That's it. Villagers who see the wolf read "a grey wolf ... it goes for sheep and children", decide how they feel
about it, react, and remember it. From then on they run from it, fight it or ignore it, each as their nature says.

## Recipes

Pick the one closest to your creature. All of them work alongside each other.

### A monster villagers should be afraid of
The quick start above. Give `danger` 0.5 or more and a note that says what it does to people. A villager whose own
fear comes out at 0.3 or more runs when it comes close, even before their AI has spoken.

### A friendly animal or pet
```lua
SetString("villagers.kind.goat.name", "a goat")
SetString("villagers.kind.goat.note", "a friendly nanny goat that follows people around and eats washing off the line")
SetFloat("villagers.kind.goat.danger", 0)
SetString("villagers.kind.goat.feel", "like")             -- its reputation; each villager still makes up their own mind
-- each goat, with its own name (when it has one):
SetString("villagers.thing.goat1.kind", "goat")
SetInt("villagers.thing.goat1.body", goatBody)
SetString("villagers.thing.goat1.name", "Hilda")
SetString("villagers.thing.goat1.doing", "chewing on a fence post")   -- keep it up to date if you like
```
A talking pet that's also a Proximity Comms agent: register the same body as the agent's `.at`, and villagers see it
once, by name, with their feelings.

### Something invisible, or a creature without one body (a ghost, a swarm, a voice in the walls)
```lua
-- every half second or so, while it exists
SetString("villagers.thing.ghost.kind", "ghost")
SetFloat("villagers.thing.ghost.x", p[1]); SetFloat("villagers.thing.ghost.y", p[2]); SetFloat("villagers.thing.ghost.z", p[3])
SetBool("villagers.thing.ghost.hidden", not visible)     -- hidden: only heard (the kind's .sound within .hear m)
-- when it goes away:
SetBool("villagers.thing.ghost.gone", true)              -- or ClearKey("villagers.thing.ghost")
```
Put the point in its middle. A sight line that stops on the creature within 1.5 m of the point still counts as seeing
it.

### A predator that hunts villagers the way it hunts players
Treat villagers as one more kind of prey: the same senses, the same choice of target, the same attacks.
```lua
-- pick prey: players and villagers alike
for id in string.gmatch(GetString("villagers.list"), "[^,]+") do
	local b = "villagers.v." .. id .. "."
	if GetBool(b .. "alive") and not GetBool(b .. "carried") then
		local feet = Vec(GetFloat(b .. "x"), GetFloat(b .. "y"), GetFloat(b .. "z"))
		local loud = GetFloat(b .. "noise")              -- 0..1: asleep 0.02, walking 0.3, running 0.7, yelling 1
		-- ... your own rules: sight (their head is ~1.6 m above the feet), hearing, the weakest, the loneliest
	end
end
-- bite: health is 100 (a player hit of 0.25 is 25 here)
local n = GetInt("villagers.hurt.last") + 1
local h = "villagers.hurt." .. (n % 16) .. "."
SetString(h .. "target", id); SetFloat(h .. "amount", 25); SetString(h .. "by", "a grey wolf")
SetFloat(h .. "x", myPos[1]); SetFloat(h .. "y", myPos[2]); SetFloat(h .. "z", myPos[3]); SetFloat(h .. "knock", 4)
SetInt("villagers.hurt.last", n)
-- grab and drag off: write the hold point every tick, ClearKey to drop them
SetFloat("villagers.carry." .. id .. ".x", jaw[1]); SetFloat("villagers.carry." .. id .. ".y", jaw[2])
SetFloat("villagers.carry." .. id .. ".z", jaw[3]); SetString("villagers.carry." .. id .. ".by", "a grey wolf")
-- slow them (webs, mud, a bitten leg) for 5 s
SetFloat("villagers.slow." .. id .. ".factor", 0.3); SetFloat("villagers.slow." .. id .. ".until", GetTime() + 5)
```
Villagers bleed, collapse, die, scream while dragged, and their neighbours see it and react. Villagers fight back too:
read `villagers.strike.*` (section 1) and hurt your creature as you would for a player's hit. If your creature hunts
by raycast, its rays can hit the villagers' hitboxes: collision layer 64, shape handle in `villagers.v.<id>.shape`.

### An item with a reputation (a relic, a cursed doll, a gun)
```lua
SetString("villagers.item.holy_relic.feel", "revere")     -- a tool id, or an Inventory item / garment id
```
A villager seeing a player hold it reads "holding a holy relic (you revere it)".

### Events, rumours and quests
Something happened somewhere (a roar, a collapse, a scream): the news ring, section 3. Something only one villager
knows ("a stranger paid you to leave the door open tonight"): `villagers.tell.<villager id>`, section 3. They react,
remember it and talk about it.

## Picking the danger, and writing the note

| danger | means | examples |
|---|---|---|
| 0 | harmless | a pet, a goat, a friendly machine |
| 0.2 - 0.3 | can hurt you if you're careless | a nipping dog, a small centipede, a ghost that only plays tricks |
| 0.5 - 0.6 | dangerous: most people keep clear | a wolf, a bear |
| 0.8 - 1 | deadly: most people run | a giant spider, a man-eating centipede, a hunting ghost |

Change it live when your creature changes (calm → hunting, friendly → hurt and hostile). Each villager's fear is your
danger × their own multiplier + their own bonus, so a brave one still fears a deadly thing less.

**The note is what villagers judge it by.** Write it as the villagers would know it, in plain words, in a sentence:
what it looks like, what it does, and what people say about it. "A brass machine as long as a house that hunts the
other giant centipedes and protects people; it only turns on people if they hurt it" gets you villagers who like it,
and a few who don't trust it. "Mech unit, faction 2" gets you nothing.

## Checklist

- Write the kind in `server.init` (writing it again every few seconds is harmless, in case Villagers starts later).
- Keep each thing's position and `.doing` fresh, about twice a second; set `.gone` or `ClearKey` when it's dead or
  removed.
- No per-villager feelings. Describe it; the villagers judge.
- Testing: a `teardown_modtest` window runs only the first mod named on its command line, so a joint test needs both
  mods bundled into one test copy (Villagers' `tools/make_test.py --inv` shows how two mods' callbacks are chained).
  Or install both and play.

## 1. Creatures and things: what they are, and how villagers come to feel about them

You describe the creature. You don't decide how each villager feels about it: **every villager decides that for
themselves, with their own AI.** On first meeting one, a villager reads your description and its baseline danger,
reacts in character, and records their own feeling (fear, hate, love...), a multiplier on your baseline danger and a
small bonus. A brave smith may fear it at half the baseline, a nervous child at one and a half times. They keep that
view for the session and can change it whenever they like: it saved them, it killed a neighbour, they got used to it.
So give them a good description and an honest baseline, and leave the rest to them.

### Describe a kind once, in `server.init`

| key | type | meaning |
|---|---|---|
| `villagers.kind.<k>.name` | string, **required** | What villagers call it, with an article or as a name: `"a giant centipede"`, `"Lily"` |
| `villagers.kind.<k>.note` | string | What it is and does, as villagers would know it: `"as long as a cart, it drags people into holes"`. This is what they judge it by |
| `villagers.kind.<k>.danger` | 0..1 | The baseline: how dangerous it is in general. Each villager's fear is this × their own multiplier + their bonus. You may update it live (Lily: 0.2 while she plays, 0.7 while she hunts) |
| `villagers.kind.<k>.feel` | string | Optional: its general reputation ("people say: fear"), one word from the list below. It's what villagers go by until they've judged it themselves, and it's a hint to their judgement |
| `villagers.kind.<k>.flee` | metres | How close it must come before a frightened villager runs (default 8 + 20 × danger, scaled by how afraid they are) |
| `villagers.kind.<k>.doing` | string | What it seems to be doing, shown to villagers who see it (`"crawling"`) |
| `villagers.kind.<k>.sound` | string | What villagers hear when they can't see it (`"a dry clicking"`) |
| `villagers.kind.<k>.hear` | metres | How far away that sound carries (0 means it's silent) |

`<k>` is your own id. Use lowercase with no dots (`centipede`, `spider`, `lilyghost`). **Don't set feelings for
individual villagers.** Villagers come and go, other villager mods may follow, and judging is the villagers' own job.

**Feelings villagers can have:** `fear`, `hate`, `love`, `like`, `wary`, `curious`, `revere`, `disgust`, `pity`,
`covet`, `ignore` (it's hidden from that villager).

**Before a villager has judged it** (in the first seconds, or with no AI): your reputation word, or one from the
danger (0.5 or more: fear; 0.2 or more: wary; less: curious), and fear = danger (× 0.6 for a hot-tempered villager).

**Reactions without the AI:** a villager whose own fear is 0.3 or more runs when it comes within the flee distance
(not if they love or revere it). With the AI off, a hot-tempered villager who hates it attacks it if their fear is
under 0.5. Everything else is the villager's AI deciding, by personality: a smith may pick up a hammer, a child may
follow it, a priest may pray.

**What you can read back:** `villagers.feel.<villager id>.<k>` (their feeling) and `villagers.fear.<villager id>.<k>`
(their fear, 0..1), twice a second.

### Say where they are: tag a body, or write a thing

Tag a body (simplest; the villagers find it every half second):

```xml
<body tags="vlkind=centipede"> ... </body>
```
or from a script: `SetTag(body, "vlkind", "centipede")`. The villagers see the centre of the body's bounds.

Or write a thing yourself, for creatures without one body: an invisible ghost, a swarm, or a point in the air.

| key | meaning |
|---|---|
| `villagers.thing.<id>.kind` | the kind `<k>` (required) |
| `villagers.thing.<id>.body` | a body handle to follow... |
| `villagers.thing.<id>.x / .y / .z` | ...or a position you keep up to date (put it in the creature's middle: a ray that stops on the creature within 1.5 m of the point still counts as seeing it) |
| `villagers.thing.<id>.name` | this one's own name (default: the kind's) |
| `villagers.thing.<id>.doing` | what it is doing now (`"hunting"`, `"asleep"`) |
| `villagers.thing.<id>.hidden` | true: it can't be seen, only heard (`.sound` within `.hear` m) |
| `villagers.thing.<id>.sound / .hear` | override the kind's sound |
| `villagers.thing.<id>.gone` | true: no longer there (or `ClearKey("villagers.thing.<id>")`) |

Villagers only see what is in their sight. They have no eyes in the back of their heads, walls block their view,
and at night or in fog they see less far. Without a line of sight they only hear it, and only if it has a sound. A
villager can name a creature in its functions: `flee` from it, `follow` it, or `attack` it.

### When villagers fight back: `villagers.strike.*` (out)

When a villager hits one of your creatures, it writes a ring of 16 entries. Read it from your server tick:

```lua
local seen = GetInt("villagers.strike.last")
function server.tick()
	local last = GetInt("villagers.strike.last")
	while seen < last do
		seen = seen + 1
		local b = "villagers.strike." .. (seen % 16) .. "."
		-- .by (villager id), .name (their name), .thing (the thing id: "b<handle>" for a tagged body),
		-- .kind, .body (handle or 0), .amount (about 8-20 for a punch; 100 = a villager's whole health), .x .y .z (from)
		if GetString(b .. "kind") == "centipede" then hurtMyCentipede(GetInt(b .. "body"), GetFloat(b .. "amount")) end
	end
end
```
Whether a punch hurts your creature is your choice; you can ignore the ring.

## 2. Items: feelings about what players hold or wear

| key | meaning |
|---|---|
| `villagers.item.<id>.feel` | how villagers feel about the item `<id>`: a tool id (`shotgun`), or an Inventory item or garment id |

A villager who sees a player holding the item reads `holding a shotgun (you fear it)`. Worn items show up close by
(Inventory mod). For example, a relic mod writes `SetString("villagers.item.holy_relic.feel", "revere")`.

## 3. Telling villagers that something happened

### News: `villagers.news.<n % 16>.*`, then `villagers.news.last = n`

| key | meaning |
|---|---|
| `.text` | what happened, as they would put it: `"a deep roar from the woods"`, `"the bridge collapsed"` |
| `.sense` | `seen` (needs a clear line from their eyes to the point), `heard`, `smelled`, or `told` (village-wide news, as if word got round) |
| `.x .y .z` | where it happened (leave these out for `told` news everyone hears) |
| `.range` | metres (default 40; `told` without a range reaches everyone) |
| `.importance` | 1-5 (default 2). At 3 or more, nearby villagers react at once; at 4 or more, it counts as a threat when they decide to flee |

Write the fields first and `.last` last:
```lua
local n = GetInt("villagers.news.last") + 1
local b = "villagers.news." .. (n % 16) .. "."
SetString(b .. "text", "a deep roar from the woods"); SetString(b .. "sense", "heard")
SetFloat(b .. "x", p[1]); SetFloat(b .. "y", p[2]); SetFloat(b .. "z", p[3])
SetFloat(b .. "range", 80); SetInt(b .. "importance", 4)
SetInt("villagers.news.last", n)
```
It reaches each villager as an event and a memory. They may talk about it later.

### A private word: `villagers.tell.<villager id>` (or `villagers.tell.all`)

`SetString("villagers.tell.silas", "A stranger paid you to look the other way at midnight.")` reaches that villager
as something they were told: an event, an important memory, and a fresh decision about what to do. The key is
cleared once it's read. This is how quest mods and game modes can give villagers missions.

## 4. Hurting villagers: `villagers.hurt.<n % 16>.*`, then `villagers.hurt.last = n`

| key | meaning |
|---|---|
| `.target` | a villager id or name... |
| `.shape` | ...or the villager's hitbox shape that your ray or claw hit (`villagers.v.<id>.shape`) |
| `.amount` | health to take: each villager has 100. A punch is about 12, a sledge 60, a shot 25 |
| `.by` | who or what did it, as villagers would say it (`"a giant centipede"`) |
| `.x .y .z` | where the blow came from (for the knockback direction) |
| `.knock` | knockback speed in m/s (0: none) |

The villagers bleed, collapse below 20 health, die at 0, and witnesses see who did it. Hitboxes are invisible
static shapes on collision layer 64 with the tags `invisible unbreakable vlhit nohole`. Creatures that hunt by
raycast can include layer 64 in their mask and look up the hit shape in `villagers.v.<id>.shape`.

### Dragging and slowing villagers, as you do players

| key | meaning |
|---|---|
| `villagers.carry.<villager id>.x / .y / .z` | You hold the villager: write the point every tick (in your claws or jaws, along the drag). They lie limp, can't act, scream for help, and witnesses see it. `ClearKey("villagers.carry.<id>")` lets go: they scramble up (if they still can) |
| `villagers.carry.<villager id>.by` | who holds them, as villagers would say it (`"a giant centipede"`) |
| `villagers.slow.<villager id>.factor` | 0.05..1: their walking speed is multiplied by this (webs, mud, a grip on the leg) ... |
| `villagers.slow.<villager id>.until` | ... until this host time (`GetTime()` + seconds) |

## 5. Where the villagers are (out, twice a second)

| key | meaning |
|---|---|
| `villagers.present` | true |
| `villagers.version` | 1 |
| `villagers.list` | `"hesper,marl,..."`: every villager id |
| `villagers.v.<id>.name` | their name ("Margaret") |
| `villagers.v.<id>.x / .y / .z` | where their feet are (or the body, when lying down) |
| `villagers.v.<id>.hp` | 0-100 |
| `villagers.v.<id>.alive / .asleep / .downed` | booleans (downed: collapsed and bleeding) |
| `villagers.v.<id>.doing` | what they're doing, in words ("working at the smithy", "asleep", "dead") |
| `villagers.v.<id>.shape` | the hitbox shape handle |
| `villagers.v.<id>.noise` | 0..1, how much noise they're making (for creatures that hunt by sound): asleep 0.02, standing 0.05, walking 0.3, running 0.7, talking 0.6, yelling, fighting or being dragged 0.8-1, whispering 0.15 |
| `villagers.v.<id>.carried` | true while a creature holds them |
| `villagers.feel.<id>.<k>` / `villagers.fear.<id>.<k>` | how that villager feels about your kind `<k>`, and how much they fear it (0..1) |

A predator can use this to pick prey: the sleeping, those walking alone at night, the wounded, the noisy. Hunt them
the way you hunt players: the same senses, the same attacks (damage through `villagers.hurt.*`, grabs through
`villagers.carry.*`, webs through `villagers.slow.*`). Read `villagers.strike.*` so that villagers can fight back.

## Talking villagers and Proximity Comms

The villagers are Proximity Comms agents named `vl_<id>`. Your mod can hear what they say through Proximity Comms'
own `proxchat.said.*` ring, and its agents (talking pets, for example) appear to the villagers as characters. A
body set as an agent's `.at` is seen by name.

A talking pet that wants feelings attached registers its body as a thing:
`villagers.thing.<agent id>.kind = "corgi"`, `.body = <the body>`, `.name = "Mochi"`. Villagers then see it once,
with the feeling, instead of as a plain character.
