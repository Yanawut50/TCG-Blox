--!strict
-- Match service (step 3). Pairs players as they join; a player who is alone after
-- SOLO_WAIT seconds gets a hot-seat game controlling both seats, so a single
-- Studio play test can play both sides. Step 4 replaces this with a lobby.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local Match = require(script:WaitForChild("Match"))
local SampleDecks = require(script:WaitForChild("Game"):WaitForChild("SampleDecks"))

local SOLO_WAIT = 3
local SERIES = "HTR"

local actionEvent = Net.event("GameAction")
local errorEvent = Net.event("GameError")

local matchOf: { [Player]: Match.Match } = {}
local waiting: { Player } = {}

local function startMatch(p1: Player, p2: Player)
	local rng = Random.new(os.time())
	local m = Match.new(p1, p2, SampleDecks.build(SERIES, rng), SampleDecks.build(SERIES, rng))
	matchOf[p1] = m
	matchOf[p2] = m
	print(("[Match] started: %s vs %s%s"):format(p1.Name, p2.Name, if p1 == p2 then " (hot-seat)" else ""))
end

local function enqueue(player: Player)
	if matchOf[player] or table.find(waiting, player) then
		return
	end
	table.insert(waiting, player)
	if #waiting >= 2 then
		local a = table.remove(waiting, 1) :: Player
		local b = table.remove(waiting, 1) :: Player
		startMatch(a, b)
		return
	end
	task.delay(SOLO_WAIT, function()
		local i = table.find(waiting, player)
		if i and player.Parent == Players then
			table.remove(waiting, i)
			startMatch(player, player)
		end
	end)
end

Players.PlayerAdded:Connect(enqueue)
for _, p in Players:GetPlayers() do
	enqueue(p)
end

Players.PlayerRemoving:Connect(function(player)
	local i = table.find(waiting, player)
	if i then
		table.remove(waiting, i)
	end
	local m = matchOf[player]
	if m then
		m:onPlayerLeft(player)
		for p, mm in matchOf do
			if mm == m then
				matchOf[p] = nil
			end
		end
	end
end)

actionEvent.OnServerEvent:Connect(function(player: Player, seat: any, action: any)
	if type(action) == "table" and action.type == "Rematch" then
		local m = matchOf[player]
		if m and not m.finished then
			errorEvent:FireClient(player, "the game is still running")
			return
		end
		local others = {}
		for p, mm in matchOf do
			if mm == m then
				matchOf[p] = nil
				if p ~= player then
					table.insert(others, p)
				end
			end
		end
		enqueue(player)
		for _, p in others do
			enqueue(p)
		end
		return
	end
	local m = matchOf[player]
	if not m then
		errorEvent:FireClient(player, "you are not in a game yet")
		return
	end
	m:onAction(player, seat, action)
end)
