--!strict
-- One running game between two seats. Owns the GameState, checks that each
-- action comes from a player who controls that seat, runs it through
-- RulesEngine, and sends every controller a fresh view.
--
-- Hot-seat: one Roblox player can control both seats (Studio solo testing).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local GameDir = script.Parent:WaitForChild("Game")
local RulesEngine = require(GameDir:WaitForChild("RulesEngine"))
local GameState = require(GameDir:WaitForChild("GameState"))

local DECISION_TIMEOUT = 90 -- seconds before a pending decision gets a default answer
local LOG_TAIL = 14

local Match = {}
Match.__index = Match

export type Match = typeof(setmetatable(
	{} :: {
		state: any,
		seats: { [number]: Player? }, -- seat -> player controlling it
		updateEvent: RemoteEvent,
		errorEvent: RemoteEvent,
		timerDecisionId: number?,
		finished: boolean,
	},
	Match
))

function Match.new(seat1: Player, seat2: Player, deck1: { string }, deck2: { string }): Match
	local self = setmetatable({
		state = RulesEngine.new(deck1, deck2, { seed = os.time() }),
		seats = { seat1, seat2 },
		updateEvent = Net.event("GameUpdate"),
		errorEvent = Net.event("GameError"),
		timerDecisionId = nil,
		finished = false,
	}, Match)
	self:broadcast()
	return self
end

function Match.controls(self: Match, player: Player, seat: number): boolean
	return self.seats[seat] == player
end

function Match.hasPlayer(self: Match, player: Player): boolean
	return self.seats[1] == player or self.seats[2] == player
end

-- Safe default when a player runs out of time: decline / the minimum picks.
local function defaultChoice(d: any): any
	if d.options then
		return { option = if table.find(d.options, "No") then "No" else d.options[1] }
	end
	local pick = {}
	for i = 1, (d.min or 0) do
		pick[i] = d.candidates[i]
	end
	return { pick = pick }
end

-- Per-card hints for the viewer's hand: can it be paid for, which Raid targets exist.
local function handHints(state: any, seat: number): { [string]: any }
	local hints = {}
	for _, uid in state.players[seat].hand do
		local def = GameState.def(state, uid)
		hints[tostring(uid)] = {
			energyOk = GameState.meetsEnergy(state, seat, uid),
			apOk = GameState.activeAP(state, seat) >= (def.ap or 0),
			raidTargets = RulesEngine.raidTargets(state, seat, uid),
		}
	end
	return hints
end

function Match.payloadFor(self: Match, player: Player): { [string]: any }
	local views = {}
	local seatsControlled = {}
	for seat = 1, 2 do
		if self.seats[seat] == player then
			table.insert(seatsControlled, seat)
			local v = GameState.viewFor(self.state, seat)
			v.hints = handHints(self.state, seat)
			views[tostring(seat)] = v
		end
	end
	local log = self.state.log
	local tail = {}
	for i = math.max(1, #log - LOG_TAIL + 1), #log do
		table.insert(tail, log[i])
	end
	return {
		seats = seatsControlled,
		views = views,
		log = tail,
		timeout = DECISION_TIMEOUT,
	}
end

function Match.broadcast(self: Match)
	local sent: { [Player]: boolean } = {}
	for seat = 1, 2 do
		local p = self.seats[seat]
		if p and not sent[p] and p.Parent == Players then
			sent[p] = true
			self.updateEvent:FireClient(p, self:payloadFor(p))
		end
	end
	self:armTimer()
end

function Match.armTimer(self: Match)
	local pending = self.state.pending
	if not pending or self.timerDecisionId == pending.id then
		return
	end
	local id = pending.id
	self.timerDecisionId = id
	task.delay(DECISION_TIMEOUT, function()
		local now = self.state.pending
		if not self.finished and now and now.id == id then
			GameState.log(self.state, ("P%d ran out of time: default answer"):format(now.player))
			self:apply(now.player, { type = "Respond", choice = defaultChoice(now) })
		end
	end)
end

function Match.apply(self: Match, seat: number, action: any): (boolean, string?)
	local ok, res, err = pcall(RulesEngine.act, self.state, seat, action)
	if not ok then
		warn("[Match] engine error: " .. tostring(res))
		GameState.log(self.state, "ENGINE ERROR: " .. tostring(res):sub(1, 200))
		self:broadcast()
		return false, "engine error (see server output)"
	end
	if res then
		if self.state.phase == "GameOver" then
			self.finished = true
		end
		self:broadcast()
	end
	return res, err
end

-- Called for every GameAction from a client.
function Match.onAction(self: Match, player: Player, seat: any, action: any)
	if type(seat) ~= "number" or not self:controls(player, seat) then
		self.errorEvent:FireClient(player, "you do not control that seat")
		return
	end
	if type(action) ~= "table" then
		self.errorEvent:FireClient(player, "bad action")
		return
	end
	local ok, err = self:apply(seat, action)
	if not ok then
		self.errorEvent:FireClient(player, tostring(err))
	end
end

function Match.onPlayerLeft(self: Match, player: Player)
	for seat = 1, 2 do
		if self.seats[seat] == player and not self.finished then
			self:apply(seat, { type = "Concede" })
			break
		end
	end
	self.finished = true
end

return Match
