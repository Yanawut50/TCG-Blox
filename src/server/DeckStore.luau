--!strict
-- Saved decks per player (DataStore "UADecks_v1", key "u_<UserId>").
-- If DataStores are not available (Studio without API access), decks are kept
-- in memory for the session and a warning is printed once.
--
-- Stored shape: { decks = { [name] = { series = "HTR", cards = { "HTR-1-001", ... } } } }

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData"))
local DeckRules = require(Shared:WaitForChild("Game"):WaitForChild("DeckRules"))

local MAX_DECKS = 20
local MAX_NAME = 30
local MAX_CARDS = 60

export type Deck = { series: string, cards: { string } }
type Data = { decks: { [string]: Deck } }

local DeckStore = {}

local store: DataStore? = nil
local storeOk, storeErr = pcall(function()
	store = DataStoreService:GetDataStore("UADecks_v1")
end)
if not storeOk then
	warn("[DeckStore] DataStore unavailable, decks are kept in memory only: " .. tostring(storeErr))
end

local cache: { [number]: Data } = {}
local warnedMemory = false

local function key(userId: number): string
	return "u_" .. userId
end

function DeckStore.load(player: Player): Data
	local id = player.UserId
	if cache[id] then
		return cache[id]
	end
	local data: Data = { decks = {} }
	if store then
		local ok, res = pcall(function()
			return (store :: DataStore):GetAsync(key(id))
		end)
		if ok and type(res) == "table" and type(res.decks) == "table" then
			data = res :: any
		elseif not ok and not warnedMemory then
			warnedMemory = true
			warn("[DeckStore] could not load decks (keeping them in memory this session): " .. tostring(res))
		end
	end
	cache[id] = data
	return data
end

local function persist(player: Player)
	if not store then
		return
	end
	local data = cache[player.UserId]
	local ok, err = pcall(function()
		(store :: DataStore):SetAsync(key(player.UserId), data)
	end)
	if not ok and not warnedMemory then
		warnedMemory = true
		warn("[DeckStore] could not save decks (keeping them in memory this session): " .. tostring(err))
	end
end

-- Summary for the client: name -> { series, count, valid, errors }.
function DeckStore.summary(player: Player): { [string]: any }
	local out = {}
	for name, deck in DeckStore.load(player).decks do
		local ok, errors = DeckRules.validate(deck.cards)
		out[name] = { series = deck.series, count = #deck.cards, valid = ok, errors = errors, cards = deck.cards }
	end
	return out
end

function DeckStore.get(player: Player, name: string): Deck?
	return DeckStore.load(player).decks[name]
end

-- Saves a deck even if it is not legal yet (a draft); returns the rule problems.
function DeckStore.save(player: Player, name: any, series: any, cards: any): (boolean, { string })
	if type(name) ~= "string" or #name == 0 or #name > MAX_NAME then
		return false, { ("Deck name must be 1-%d characters"):format(MAX_NAME) }
	end
	if type(series) ~= "string" or type(cards) ~= "table" or #cards > MAX_CARDS then
		return false, { "Bad deck data" }
	end
	local clean: { string } = {}
	for _, k in cards do
		if type(k) ~= "string" or not CardData.get(k) then
			return false, { "Unknown card " .. tostring(k) }
		end
		table.insert(clean, k)
	end
	local data = DeckStore.load(player)
	if not data.decks[name] then
		local n = 0
		for _ in data.decks do
			n += 1
		end
		if n >= MAX_DECKS then
			return false, { ("You can save up to %d decks"):format(MAX_DECKS) }
		end
	end
	data.decks[name] = { series = series, cards = clean }
	persist(player)
	local _, errors = DeckRules.validate(clean)
	return true, errors
end

function DeckStore.delete(player: Player, name: any): boolean
	local data = DeckStore.load(player)
	if type(name) ~= "string" or not data.decks[name] then
		return false
	end
	data.decks[name] = nil
	persist(player)
	return true
end

function DeckStore.forget(player: Player)
	cache[player.UserId] = nil
end

return DeckStore
