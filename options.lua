-- Villagers of Dunmarrow: options (Mod Manager). The host's choice counts: their AI budget pays for the villagers.

local PACES = {"Quiet", "Calm", "Lively", "Bustling"}
local WHAT = {
	"Lives by routine; the AI only answers when someone talks to a villager. Cheapest.",
	"Villagers decide their own days and talk among themselves now and then.",
	"Villagers decide their own days and talk among themselves often. (default)",
	"Busy village: frequent decisions and conversations. Uses the most AI tokens.",
}
local LENGTHS = {"Short", "Normal", "Long", "Very long"}
local LWHAT = {
	"Villagers talking to each other: a quick exchange, 2-3 lines.",
	"Villagers talking to each other: 2-6 lines, by how talkative they are. (default)",
	"Villagers talking to each other: 4-12 lines, by how talkative they are.",
	"Villagers talking to each other: 6-18 lines. Uses the most AI tokens.",
}
-- (the user, 2026-11-15: "we should be able to toggle each one from mod menu"; "by default, there should only be 4")
-- savegame.mod.vill.<id> = "on" / "off" (main.lua VlPicked); unset: the default four (vl_config.lua defaultVillagers,
-- marked true here). The ids and names are vl_people.lua's: keep this list in step with it.
local PEOPLE = {
	{"hesper", "Margaret", "chapel keeper"}, {"marl", "Tom", "gravedigger"}, {"brannoc", "Frank", "smith", true},
	{"wren", "Lucy", "apprentice"}, {"ruben", "Henry", "tavern keeper", true}, {"odette", "Diana", "shopkeeper"},
	{"silas", "Victor", "night watch", true}, {"lucan", "Luke", "tinker-preacher"}, {"nadia", "Helen", "the reeve"},
	{"bett", "Betty", "baker", true}, {"eskil", "Walter", "shepherd"}, {"ysolde", "Rose", "herb-woman"},
}

local function picked(pp)
	local v = GetString("savegame.mod.vill." .. pp[1])
	if v == "on" then return true elseif v == "off" then return false end
	return pp[4] == true
end

local function row(names, key, default)
	local v = GetInt(key)
	if v < 1 or v > #names then v = default end
	for i, name in ipairs(names) do
		UiPush()
		UiTranslate((i - 2.5) * 190, 0)
		if i == v then UiColor(0.75, 0.9, 1) else UiColor(0.55, 0.55, 0.55) end
		if UiTextButton(name, 170, 46) then SetInt(key, i) end
		UiPop()
	end
	return GetInt(key) >= 1 and GetInt(key) <= #names and GetInt(key) or default
end

local function villagerGrid()
	local on = 0
	for i, pp in ipairs(PEOPLE) do
		local off = not picked(pp)
		if not off then on = on + 1 end
		local col, line = (i - 1) % 4, math.floor((i - 1) / 4)
		UiPush()
		UiTranslate((col - 1.5) * 250, line * 62)
		if off then UiColor(0.45, 0.45, 0.45) else UiColor(0.7, 1, 0.75) end
		UiFont("bold.ttf", 24)
		if UiTextButton(pp[2] .. (off and "  (off)" or ""), 235, 40) then SetString("savegame.mod.vill." .. pp[1], off and "on" or "off") end
		UiTranslate(0, 24)
		UiFont("regular.ttf", 17)
		UiColor(0.75, 0.75, 0.75, off and 0.5 or 1)
		UiText(pp[3])
		UiPop()
	end
	return on
end

function draw()
	local p
	UiTranslate(UiCenter(), 60)
	UiAlign("center middle")
	UiFont("bold.ttf", 44)
	UiColor(1, 1, 1)
	UiText("Villagers of Dunmarrow")
	UiTranslate(0, 70)
	UiFont("regular.ttf", 26)
	UiText("Village life")
	UiTranslate(0, 48)
	UiFont("bold.ttf", 30)
	p = row(PACES, "savegame.mod.pace", 3)
	UiTranslate(0, 50)
	UiFont("regular.ttf", 21)
	UiColor(0.85, 0.85, 0.85)
	UiText(WHAT[p])
	UiTranslate(0, 55)
	UiFont("regular.ttf", 26)
	UiColor(1, 1, 1)
	UiText("Conversation length")
	UiTranslate(0, 48)
	UiFont("bold.ttf", 30)
	local l = row(LENGTHS, "savegame.mod.talk", 2)
	UiTranslate(0, 50)
	UiFont("regular.ttf", 21)
	UiColor(0.85, 0.85, 0.85)
	UiText(LWHAT[l])
	UiTranslate(0, 55)
	UiFont("regular.ttf", 26)
	UiColor(1, 1, 1)
	UiText("Villagers")
	UiTranslate(0, 45)
	local on = villagerGrid()
	UiTranslate(0, 3 * 62 + 10)
	UiFont("regular.ttf", 21)
	UiColor(0.85, 0.85, 0.85)
	UiText(on .. " of " .. #PEOPLE .. " in the village (4 by default). Each one uses AI tokens all the time: fewer last longer. Applies when a map starts.")
	UiTranslate(0, 45)
	UiText("The villagers live and talk through Proximity Comms and the host's Koetama (its Large Language Models card).")
	UiTranslate(0, 28)
	UiText("Without Koetama, or when its monthly AI limit runs out, they stand still with the reason over their heads.")
	UiTranslate(0, 60)
	UiFont("bold.ttf", 28)
	UiColor(1, 1, 1)
	if UiTextButton("Close", 200, 46) then Menu() end
end
