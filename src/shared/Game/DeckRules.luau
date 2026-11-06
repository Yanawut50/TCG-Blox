--!strict
-- Deck construction rules (Asia manual p.05). Shared so the deck builder can show
-- errors before the server checks the same thing.

local Shared = script.Parent.Parent
local CardData = require(Shared:WaitForChild("CardData"))
local Constants = require(script.Parent:WaitForChild("Constants"))

local DeckRules = {}

-- "HTR-1-030★" -> "HTR-1-030": parallel art shares the card number.
function DeckRules.cardNumber(key: string): string
	return (key:gsub("[^%w%-]+$", ""))
end

-- Series code: "HTR-1-030" -> "HTR".
function DeckRules.seriesCode(key: string): string
	return key:match("^([^%-_]+)") or key
end

-- Returns ok plus a list of human-readable problems.
function DeckRules.validate(keys: { string }): (boolean, { string })
	local errors: { string } = {}
	if #keys ~= Constants.DECK_SIZE then
		table.insert(errors, ("Deck has %d cards, needs exactly %d"):format(#keys, Constants.DECK_SIZE))
	end

	local series: string? = nil
	local copies: { [string]: number } = {}
	local limits: { [string]: number } = {}
	local triggerCounts: { [string]: number } = {}

	for _, key in keys do
		local card = CardData.get(key)
		if not card then
			table.insert(errors, "Unknown card " .. key)
			continue
		end
		if card.cardType == "Action Point" then
			table.insert(errors, key .. " is an AP card; AP cards are not part of the 50-card deck")
			continue
		end
		local code = DeckRules.seriesCode(key)
		if series == nil then
			series = code
		elseif code ~= series then
			table.insert(errors, ("%s is from series %s, deck is %s"):format(key, code, series :: string))
		end
		local number = DeckRules.cardNumber(key)
		copies[number] = (copies[number] or 0) + 1
		limits[number] = card.deckLimit or Constants.MAX_COPIES
		if table.find(Constants.LIMITED_TRIGGERS, card.triggerType) then
			triggerCounts[card.triggerType] = (triggerCounts[card.triggerType] or 0) + 1
		end
	end

	for number, n in copies do
		if n > limits[number] then
			table.insert(errors, ("%d copies of %s (max %d)"):format(n, number, limits[number]))
		end
	end
	for trigger, n in triggerCounts do
		if n > Constants.MAX_PER_SPECIAL_TRIGGER then
			table.insert(errors, ("%d cards with [%s] trigger (max %d)"):format(n, trigger, Constants.MAX_PER_SPECIAL_TRIGGER))
		end
	end
	return #errors == 0, errors
end

return DeckRules
