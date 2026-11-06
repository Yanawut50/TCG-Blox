--!strict
-- Lobby and match service (step 4).
--
-- Players land in the lobby. They build decks (DeckCall), then either queue with a
-- legal deck (two queued players are paired) or start a solo test where they
-- control both seats. When a game ends they go back to the lobby with "Leave".
--
-- Deck choice "#sample:<SERIES>" picks a random legal sample deck of that series.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local DeckRules = require(Shared:WaitForChild("Game"):WaitForChild("DeckRules"))
local Match = require(script:WaitForChild("Match"))
local DeckStore = require(script:WaitForChild("DeckStore"))
local SampleDecks = require(script:WaitForChild("Game"):WaitForChild("SampleDecks"))

local gameAction = Net.event("GameAction")
local gameError = Net.event("GameError")
local lobbyAction = Net.event("LobbyAction")
local lobbyUpdate = Net.event("LobbyUpdate")
local deckCall = Net.func("DeckCall")

type QueueEntry = { player: Player, deck: { string }, deckName: string }

local matchOf: { [Player]: Match.Match } = {}
local queue: { QueueEntry } = {}
local rng = Random.new()

local function queueIndex(player: Player): number?
	for i, e in queue do
		if e.player == player then
			return i
		end
	end
	return nil
end

local function statusOf(player: Player): string
	if matchOf[player] then
		return "playing"
	elseif queueIndex(player) then
		return "queued"
	end
	return "menu"
end

local function pushLobby(player: Player, message: string?)
	if player.Parent ~= Players then
		return
	end
	lobbyUpdate:FireClient(player, {
		status = statusOf(player),
		decks = DeckStore.summary(player),
		queueSize = #queue,
		message = message,
	})
end

local function pushAllInMenu()
	for _, p in Players:GetPlayers() do
		if not matchOf[p] then
			pushLobby(p)
		end
	end
end

-- Resolves a deck choice to card keys. Returns nil + reason when it can't be used.
local function resolveDeck(player: Player, choice: any): ({ string }?, string)
	if type(choice) ~= "string" then
		return nil, "choose a deck"
	end
	local sample = choice:match("^#sample:(%w+)$")
	if sample then
		return SampleDecks.build(sample, rng), "Sample " .. sample
	end
	local deck = DeckStore.get(player, choice)
	if not deck then
		return nil, "no deck named " .. choice
	end
	local ok, errors = DeckRules.validate(deck.cards)
	if not ok then
		return nil, "deck is not legal yet: " .. (errors[1] or "?")
	end
	return table.clone(deck.cards), choice
end

local function startMatch(a: QueueEntry, b: QueueEntry)
	local m = Match.new(a.player, b.player, a.deck, b.deck)
	matchOf[a.player] = m
	matchOf[b.player] = m
	print(("[Lobby] match: %s (%s) vs %s (%s)%s"):format(a.player.Name, a.deckName, b.player.Name, b.deckName, if a.player == b.player then " solo" else ""))
end

local function leaveMatch(player: Player)
	local m = matchOf[player]
	if not m then
		return
	end
	if not m.finished then
		m:onPlayerLeft(player)
	end
	matchOf[player] = nil
end

lobbyAction.OnServerEvent:Connect(function(player: Player, action: any)
	if type(action) ~= "table" then
		return
	end
	local t = action.type
	if t == "Refresh" then
		pushLobby(player)
	elseif t == "Queue" or t == "Solo" then
		if matchOf[player] then
			pushLobby(player, "you are already in a game")
			return
		end
		local deck, nameOrErr = resolveDeck(player, action.deck)
		if not deck then
			pushLobby(player, nameOrErr)
			return
		end
		local i = queueIndex(player)
		if i then
			table.remove(queue, i)
		end
		local entry = { player = player, deck = deck, deckName = nameOrErr }
		if t == "Solo" then
			-- Your deck on seat 1, a sample deck of the same series on seat 2.
			local series = DeckRules.seriesCode(deck[1])
			startMatch(entry, { player = player, deck = SampleDecks.build(series, rng), deckName = "Sample " .. series })
		else
			table.insert(queue, entry)
			if #queue >= 2 then
				local a = table.remove(queue, 1) :: QueueEntry
				local b = table.remove(queue, 1) :: QueueEntry
				startMatch(a, b)
			end
		end
		pushAllInMenu()
	elseif t == "Cancel" then
		local i = queueIndex(player)
		if i then
			table.remove(queue, i)
		end
		pushAllInMenu()
	elseif t == "Leave" then
		leaveMatch(player)
		pushLobby(player)
	end
end)

deckCall.OnServerInvoke = function(player: Player, op: any, args: any): any
	if op == "list" then
		return DeckStore.summary(player)
	elseif op == "save" and type(args) == "table" then
		local ok, errors = DeckStore.save(player, args.name, args.series, args.cards)
		pushLobby(player)
		return { ok = ok, errors = errors }
	elseif op == "delete" and type(args) == "table" then
		local ok = DeckStore.delete(player, args.name)
		pushLobby(player)
		return { ok = ok }
	end
	return { ok = false, errors = { "bad request" } }
end

gameAction.OnServerEvent:Connect(function(player: Player, seat: any, action: any)
	local m = matchOf[player]
	if not m then
		gameError:FireClient(player, "you are not in a game")
		return
	end
	m:onAction(player, seat, action)
end)

Players.PlayerAdded:Connect(function(player)
	task.defer(pushLobby, player)
end)
for _, p in Players:GetPlayers() do
	task.defer(pushLobby, p)
end

Players.PlayerRemoving:Connect(function(player)
	local i = queueIndex(player)
	if i then
		table.remove(queue, i)
	end
	local m = matchOf[player]
	if m then
		m:onPlayerLeft(player)
		for p, mm in matchOf do
			if mm == m then
				matchOf[p] = nil
				if p ~= player then
					pushLobby(p, "your opponent left")
				end
			end
		end
	end
	DeckStore.forget(player)
	pushAllInMenu()
end)
