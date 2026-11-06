--!strict
-- Random legal decks for testing until the deck builder exists (step 4):
-- one series, two colors, cheap cards first so the Energy Line can start.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData"))
local DeckRules = require(Shared:WaitForChild("Game"):WaitForChild("DeckRules"))
local Constants = require(Shared.Game:WaitForChild("Constants"))

local SampleDecks = {}

function SampleDecks.build(series: string, rng: Random): { string }
	local pool: { string } = {}
	local seenNumber: { [string]: boolean } = {}
	for _, set in CardData.getSets() do
		if DeckRules.seriesCode(set.id) == series then
			for key, card in CardData.getSet(set.id) or {} do
				local number = DeckRules.cardNumber(key)
				if card.cardType ~= "Action Point" and not seenNumber[number] then
					seenNumber[number] = true
					table.insert(pool, key)
				end
			end
		end
	end
	table.sort(pool)
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end

	local colors = { "Red", "Blue", "Yellow", "Green", "Purple" }
	local c1 = table.remove(colors, rng:NextInteger(1, #colors)) :: string
	local c2 = table.remove(colors, rng:NextInteger(1, #colors)) :: string
	local cheap, rest, offColor = {}, {}, {}
	for _, key in pool do
		local card = CardData.get(key) :: CardData.Card
		local inColors = true
		for _, c in card.colors do
			if c ~= c1 and c ~= c2 then
				inColors = false
			end
		end
		if not inColors then
			table.insert(offColor, key)
		elseif (card.needEnergy or 0) <= 1 then
			table.insert(cheap, key)
		else
			table.insert(rest, key)
		end
	end

	local deck: { string } = {}
	local triggers: { [string]: number } = {}
	for _, list in { cheap, rest, offColor } do
		for _, key in list do
			local card = CardData.get(key) :: CardData.Card
			local limited = table.find(Constants.LIMITED_TRIGGERS, card.triggerType) ~= nil
			local n = if (card.needEnergy or 0) <= 1 then 4 else rng:NextInteger(2, 4)
			for _ = 1, n do
				if #deck >= Constants.DECK_SIZE then
					break
				end
				if limited then
					if (triggers[card.triggerType] or 0) >= Constants.MAX_PER_SPECIAL_TRIGGER then
						break
					end
					triggers[card.triggerType] = (triggers[card.triggerType] or 0) + 1
				end
				table.insert(deck, key)
			end
		end
	end
	return deck
end

return SampleDecks
