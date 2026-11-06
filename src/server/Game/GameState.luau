--!strict
-- Game state container and low-level helpers: zones, card moves, energy, BP.
-- No rules decisions live here; RulesEngine calls these after validating.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData"))
local Types = require(Shared:WaitForChild("Game"):WaitForChild("Types"))
local Constants = require(Shared.Game:WaitForChild("Constants"))

type GameState = Types.GameState
type PlayerState = Types.PlayerState
type CardInst = Types.CardInst
type ZoneName = Types.ZoneName
type Card = CardData.Card

local GameState = {}

local LIST_ZONES: { [string]: string } = {
	Deck = "deck",
	Hand = "hand",
	Life = "life",
	Front = "front",
	Energy = "energy",
	Outside = "outside",
	Remove = "remove",
}

local function newPlayer(id: number): PlayerState
	return {
		id = id,
		deck = {},
		hand = {},
		life = {},
		front = {},
		energy = {},
		outside = {},
		remove = {},
		ap = {},
		turnsTaken = 0,
		extraDrawUsed = false,
	}
end

function GameState.new(seed: number?): GameState
	return {
		players = { newPlayer(1), newPlayer(2) },
		cards = {},
		firstPlayer = 1,
		turnPlayer = 1,
		turnNumber = 0,
		phase = "Setup",
		winner = nil,
		winReason = nil,
		pending = nil,
		log = {},
		rng = Random.new(seed or os.clock() * 1e6),
		nextUid = 0,
		nextDecisionId = 0,
		co = nil,
	}
end

function GameState.other(p: number): number
	return 3 - p
end

function GameState.log(state: GameState, msg: string)
	table.insert(state.log, ("[T%d %s] %s"):format(state.turnNumber, state.phase, msg))
end

function GameState.inst(state: GameState, uid: number): CardInst
	local c = state.cards[uid]
	assert(c, "unknown card uid " .. tostring(uid))
	return c
end

function GameState.def(state: GameState, uid: number): Card
	local c = GameState.inst(state, uid)
	local d = CardData.get(c.key)
	assert(d, "unknown card key " .. c.key)
	return d
end

function GameState.name(state: GameState, uid: number): string
	local d = GameState.def(state, uid)
	return ("%s(%s#%d)"):format(d.nameEn ~= "" and d.nameEn or d.nameJp, d.key, uid)
end

-- Creates a card in the owner's deck (bottom).
function GameState.createCard(state: GameState, key: string, owner: number): number
	assert(CardData.get(key), "unknown card key " .. key)
	state.nextUid += 1
	local uid = state.nextUid
	state.cards[uid] = {
		uid = uid,
		key = key,
		owner = owner,
		zone = "Deck",
		rested = false,
		under = {},
		bpTurn = 0,
		bpManual = 0,
		granted = {},
		attacksThisTurn = 0,
		blocksThisTurn = 0,
	}
	table.insert(state.players[owner].deck, uid)
	return uid
end

function GameState.zoneList(state: GameState, owner: number, zone: ZoneName): { number }?
	local field = LIST_ZONES[zone]
	if not field then
		return nil
	end
	return (state.players[owner] :: any)[field]
end

function GameState.isOnField(state: GameState, uid: number): boolean
	local z = GameState.inst(state, uid).zone
	return z == "Front" or z == "Energy"
end

function GameState.shuffle(state: GameState, list: { number })
	for i = #list, 2, -1 do
		local j = state.rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

local function detach(state: GameState, c: CardInst)
	local list = GameState.zoneList(state, c.owner, c.zone)
	if list then
		local i = table.find(list, c.uid)
		if i then
			table.remove(list, i)
		end
	end
end

local function resetFieldState(c: CardInst)
	c.rested = false
	c.bpTurn = 0
	c.bpManual = 0
	c.granted = {}
	c.attacksThisTurn = 0
	c.blocksThisTurn = 0
end

-- Moves a card to a zone. Leaving the field: Raid cards underneath go to the
-- Outside Area (Asia manual p.13) and per-field state is reset.
-- opts.bottom puts it at the bottom of the deck/list; opts.index inserts at a position.
function GameState.moveCard(state: GameState, uid: number, to: ZoneName, opts: { bottom: boolean?, index: number? }?)
	local c = GameState.inst(state, uid)
	local wasOnField = c.zone == "Front" or c.zone == "Energy"
	local toField = to == "Front" or to == "Energy"
	detach(state, c)

	if wasOnField and not toField then
		for _, underUid in c.under do
			local u = GameState.inst(state, underUid)
			u.zone = "Outside"
			table.insert(state.players[u.owner].outside, underUid)
		end
		c.under = {}
		resetFieldState(c)
	elseif not wasOnField and toField then
		resetFieldState(c)
	end

	c.zone = to
	local list = GameState.zoneList(state, c.owner, to)
	if list then
		if opts and opts.index then
			table.insert(list, math.clamp(opts.index, 1, #list + 1), uid)
		elseif to == "Deck" and not (opts and opts.bottom) then
			table.insert(list, 1, uid) -- deck top
		else
			table.insert(list, uid)
		end
	end
end

-- Draws n cards. Returns how many were actually drawn.
function GameState.draw(state: GameState, p: number, n: number): number
	local ps = state.players[p]
	local drawn = 0
	for _ = 1, n do
		local top = ps.deck[1]
		if not top then
			break
		end
		GameState.moveCard(state, top, "Hand")
		drawn += 1
	end
	return drawn
end

-- Keywords: printed (top card only) or granted until end of turn.
function GameState.keyword(state: GameState, uid: number, name: string): any
	local c = GameState.inst(state, uid)
	local granted = c.granted[name]
	if granted ~= nil then
		return granted
	end
	local d = GameState.def(state, uid)
	local kw = (d :: any).keywords
	return kw and kw[name]
end

function GameState.bp(state: GameState, uid: number): number
	local c = GameState.inst(state, uid)
	local d = GameState.def(state, uid)
	return (d.bp or 0) + c.bpTurn + c.bpManual
end

function GameState.isCharacter(state: GameState, uid: number): boolean
	return GameState.def(state, uid).cardType == "Character"
end

-- Energy generated by the Energy Line, by color (Asia manual p.04, p.09).
-- Rest/Active does not matter; Front Line cards never count.
function GameState.energy(state: GameState, p: number): { [string]: number }
	local out: { [string]: number } = {}
	for _, uid in state.players[p].energy do
		local d = GameState.def(state, uid)
		for _, e in d.generatedEnergy do
			out[e.color] = (out[e.color] or 0) + e.count
		end
	end
	return out
end

-- Required energy check. Multi-color cards add up every color they have
-- (the manual does not cover multi-color cards; this is our assumption).
function GameState.meetsEnergy(state: GameState, p: number, uid: number): boolean
	local d = GameState.def(state, uid)
	local need = d.needEnergy or 0
	if need <= 0 then
		return true
	end
	local have = GameState.energy(state, p)
	local total = 0
	for _, color in d.colors do
		total += have[color] or 0
	end
	return total >= need
end

function GameState.activeAP(state: GameState, p: number): number
	local n = 0
	for _, a in state.players[p].ap do
		if not a.rested then
			n += 1
		end
	end
	return n
end

function GameState.payAP(state: GameState, p: number, n: number)
	assert(GameState.activeAP(state, p) >= n, "not enough AP")
	local left = n
	for _, a in state.players[p].ap do
		if left == 0 then
			break
		end
		if not a.rested then
			a.rested = true
			left -= 1
		end
	end
end

function GameState.apTarget(state: GameState, p: number): number
	local tbl = if p == state.firstPlayer then Constants.AP_BY_TURN_FIRST else Constants.AP_BY_TURN_SECOND
	local turns = state.players[p].turnsTaken
	return tbl[math.clamp(turns, 1, #tbl)]
end

-- A view of the state for one player: hidden zones show counts only.
function GameState.viewFor(state: GameState, viewer: number): { [string]: any }
	local function cardView(uid: number, hidden: boolean): { [string]: any }
		local c = state.cards[uid]
		if hidden then
			return { uid = uid, hidden = true }
		end
		return {
			uid = uid,
			key = c.key,
			owner = c.owner,
			rested = c.rested,
			bp = GameState.isCharacter(state, uid) and GameState.bp(state, uid) or nil,
			under = #c.under,
		}
	end
	local players = {}
	for p, ps in state.players do
		local function list(ids: { number }, hidden: boolean)
			local out = {}
			for _, uid in ids do
				table.insert(out, cardView(uid, hidden))
			end
			return out
		end
		players[p] = {
			hand = list(ps.hand, p ~= viewer),
			deckCount = #ps.deck,
			lifeCount = #ps.life,
			front = list(ps.front, false),
			energy = list(ps.energy, false),
			outside = list(ps.outside, false),
			remove = list(ps.remove, false),
			ap = { total = #ps.ap, active = GameState.activeAP(state, p) },
			energyByColor = GameState.energy(state, p),
		}
	end
	local pending = nil
	if state.pending then
		local d = state.pending
		pending = {
			id = d.id,
			player = d.player,
			kind = d.kind,
			prompt = d.prompt,
			candidates = d.candidates,
			min = d.min,
			max = d.max,
			options = d.options,
		}
	end
	return {
		you = viewer,
		players = players,
		firstPlayer = state.firstPlayer,
		turnPlayer = state.turnPlayer,
		turnNumber = state.turnNumber,
		phase = state.phase,
		winner = state.winner,
		winReason = state.winReason,
		pending = pending,
	}
end

return GameState
