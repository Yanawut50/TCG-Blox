--!strict
-- Union Arena rules (Asia/EN Official Rule Manual, 2023-11-22): phases, playing
-- cards, AP/energy, moving, Raid, attacks, blocks, keywords, damage, Life
-- triggers, win conditions, and card effects through EffectRegistry (cards
-- without handlers fall back to the manual tools).
--
-- How decisions work: flows that need a player's answer run inside a coroutine.
-- ask() yields a Decision; the game stores it in state.pending and waits. The
-- player answers with { type = "Respond", choice = {...} }, which resumes the flow.
-- The server later turns state.pending into a prompt for that player's client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Game.Types)
local Constants = require(ReplicatedStorage.Shared.Game.Constants)
local GameState = require(script.Parent.GameState)
local TriggerResolver = require(script.Parent.TriggerResolver)
local EffectRegistry = require(script.Parent.EffectRegistry)

type GameState = Types.GameState
type Decision = Types.Decision
type Action = Types.Action

local RulesEngine = {}

local other = GameState.other
local log = GameState.log

--------------------------------------------------------------------------------
-- Coroutine plumbing
--------------------------------------------------------------------------------

local function stepFlow(state: GameState, value: any)
	local co = state.co :: thread
	local ok, res = coroutine.resume(co, value)
	if not ok then
		state.co = nil
		state.pending = nil
		error(debug.traceback(co, tostring(res)), 0)
	end
	if coroutine.status(co) == "dead" then
		state.co = nil
		state.pending = nil
		-- Start the next waiting flow (e.g. an On Retire effect queued meanwhile).
		local nextFn = table.remove(state.flowQueue, 1)
		if nextFn and not state.winner then
			state.co = coroutine.create(nextFn)
			stepFlow(state, nil)
		end
	else
		state.pending = res :: Decision
	end
end

-- Runs fn as a flow. Inside the current flow it just runs; if another flow is
-- waiting on a player, fn waits its turn in the queue.
local function runFlow(state: GameState, fn: () -> ())
	if state.co then
		if coroutine.running() == state.co then
			fn()
		else
			table.insert(state.flowQueue, fn)
		end
		return
	end
	state.co = coroutine.create(fn)
	stepFlow(state, nil)
end

local function ask(state: GameState, d: Decision): any
	state.nextDecisionId += 1
	d.id = state.nextDecisionId
	return coroutine.yield(d)
end

local function yesNo(state: GameState, p: number, kind: string, prompt: string): boolean
	local choice = ask(state, {
		id = 0,
		player = p,
		kind = kind,
		prompt = prompt,
		options = { "Yes", "No" },
		validate = function(c: any)
			if type(c) == "table" and (c.option == "Yes" or c.option == "No") then
				return true
			end
			return false, "answer Yes or No"
		end,
	})
	return choice.option == "Yes"
end

local function chooseOption(state: GameState, p: number, kind: string, prompt: string, options: { string }): string
	local choice = ask(state, {
		id = 0,
		player = p,
		kind = kind,
		prompt = prompt,
		options = options,
		validate = function(c: any)
			if type(c) == "table" and type(c.option) == "string" and table.find(options, c.option) then
				return true
			end
			return false, "pick one of: " .. table.concat(options, ", ")
		end,
	})
	return choice.option
end

-- candidates are uids or positions; returns the chosen subset in the order given.
local function chooseCards(state: GameState, p: number, kind: string, prompt: string, candidates: { number }, min: number, max: number): { number }
	if #candidates == 0 or max == 0 then
		return {}
	end
	local choice = ask(state, {
		id = 0,
		player = p,
		kind = kind,
		prompt = prompt,
		candidates = candidates,
		min = min,
		max = max,
		validate = function(c: any)
			if type(c) ~= "table" or type(c.pick) ~= "table" then
				return false, "send { pick = {...} }"
			end
			local seen = {}
			for _, v in c.pick do
				if not table.find(candidates, v) then
					return false, "not a valid choice: " .. tostring(v)
				end
				if seen[v] then
					return false, "picked twice: " .. tostring(v)
				end
				seen[v] = true
			end
			if #c.pick < min or #c.pick > max then
				return false, ("pick %d to %d"):format(min, max)
			end
			return true
		end,
	})
	return choice.pick
end

--------------------------------------------------------------------------------
-- Game end
--------------------------------------------------------------------------------

local function lose(state: GameState, p: number, reason: string)
	if state.winner then
		return
	end
	state.winner = other(p)
	state.winReason = reason
	state.phase = "GameOver"
	log(state, ("P%d wins: %s"):format(other(p), reason))
end

--------------------------------------------------------------------------------
-- Field helpers
--------------------------------------------------------------------------------

local function lineList(state: GameState, p: number, line: string): { number }
	return if line == "Front" then state.players[p].front else state.players[p].energy
end

-- Rule: when a line is full, one of its cards goes to the Remove Area first
-- (manual p.08-10). Returns false if a choice was required but not given/valid.
local function makeRoom(state: GameState, p: number, line: string, replaceUid: number?): (boolean, string?)
	local list = lineList(state, p, line)
	if #list < Constants.LINE_SIZE then
		if replaceUid then
			return false, "line is not full; you cannot remove a card to make room"
		end
		return true
	end
	if not replaceUid or not table.find(list, replaceUid) then
		return false, line .. " Line is full: pick a card on it (replaceUid) to send to the Remove Area"
	end
	return true
end

--------------------------------------------------------------------------------
-- Card effects (EffectRegistry)
--------------------------------------------------------------------------------

local runAbilities: (state: GameState, uid: number, timing: string, p: number) -> ()

-- "Remove from the field" (退場): to the Outside Area, then its On Retire effects.
local function removeFromField(state: GameState, uid: number, why: string)
	log(state, ("%s removed from the field (%s)"):format(GameState.name(state, uid), why))
	local owner = GameState.inst(state, uid).owner
	GameState.moveCard(state, uid, "Outside")
	runFlow(state, function()
		runAbilities(state, uid, "OnRetire", owner)
	end)
end

local function effectCtx(state: GameState, p: number, source: number): EffectRegistry.Ctx
	return {
		state = state,
		p = p,
		source = source,
		looked = {},
		did = true,
		failed = false,
		addedToHand = false,
		chosen = {},
		yesNo = function(player, prompt)
			return yesNo(state, player, "UseEffect", prompt)
		end,
		chooseCards = function(player, prompt, cands, min, max)
			return chooseCards(state, player, "ChooseCards", prompt, cands, min, max)
		end,
		chooseOption = function(player, prompt, options)
			return chooseOption(state, player, "ChooseOption", prompt, options)
		end,
		retire = function(uid, why)
			if GameState.isOnField(state, uid) then
				removeFromField(state, uid, why)
			end
		end,
		delay = function(whenKey, fn)
			table.insert(state.delayed, { when = whenKey, fn = fn })
		end,
	}
end

-- Runs every ability of `uid` with this timing whose conditions hold. Abilities
-- without handlers are logged for the players to resolve by hand. Must run in a flow.
runAbilities = function(state: GameState, uid: number, timing: string, p: number)
	local def = GameState.def(state, uid)
	local manual = false
	for _, a in EffectRegistry.abilitiesOf(def) do
		if a.timing == timing and EffectRegistry.condsHold(state, uid, a.conds) then
			if EffectRegistry.isSupported(a) then
				log(state, ("%s: %s effect"):format(GameState.name(state, uid), timing))
				EffectRegistry.run(effectCtx(state, p, uid), a)
				if state.winner then
					return
				end
			else
				manual = true
			end
		end
	end
	if manual then
		log(state, ("  MANUAL %s [%s]: %s"):format(GameState.name(state, uid), timing, def.effectEn))
	end
end

local function runDelayed(state: GameState, whenKey: string)
	local keep = {}
	local due = {}
	for _, d in state.delayed do
		table.insert(if d.when == whenKey then due else keep, d)
	end
	state.delayed = keep
	for _, d in due do
		d.fn()
	end
end

-- Characters whose BP is 0 or less leave the field (manual p.13).
local function checkStateRules(state: GameState)
	for p = 1, 2 do
		local ps = state.players[p]
		for _, line in { ps.front, ps.energy } do
			for i = #line, 1, -1 do
				local uid = line[i]
				if GameState.isCharacter(state, uid) and GameState.bp(state, uid) <= 0 then
					removeFromField(state, uid, "BP 0 or less")
				end
			end
		end
	end
end

local function raidTargets(state: GameState, p: number, uid: number): { number }
	local spec = GameState.def(state, uid).raid
	if not spec then
		return {}
	end
	local out = {}
	local ps = state.players[p]
	for _, line in { ps.front, ps.energy } do
		for _, t in line do
			local td = GameState.def(state, t)
			if td.cardType == "Character" and not td.raid then
				local match = if spec.kind == "name" then EffectRegistry.hasName(state, t, spec.value) else table.find(td.traits, spec.value) ~= nil
				if match then
					table.insert(out, t)
				end
			end
		end
	end
	return out
end

-- Raid (manual p.09-10). Asia manual step 4 moves the stack to the Front Line;
-- card text says it "can" move, so moveToFront = false keeps it on the Energy Line.
local function doRaid(state: GameState, p: number, uid: number, targetUid: number, moveToFront: boolean?, replaceUid: number?)
	local target = GameState.inst(state, targetUid)
	local line = target.zone
	local list = lineList(state, p, line)
	local pos = table.find(list, targetUid) :: number

	-- 1. place on top; 2. effects on the card below stop applying.
	local c = GameState.inst(state, uid)
	local fromZoneList = GameState.zoneList(state, c.owner, c.zone)
	if fromZoneList then
		local i = table.find(fromZoneList, uid)
		if i then
			table.remove(fromZoneList, i)
		end
	end
	local under = target.under
	target.under = {}
	table.insert(under, targetUid)
	target.zone = "Under"
	target.bpTurn, target.bpManual, target.granted = 0, 0, {}
	list[pos] = uid
	c.zone = line :: any
	c.under = under
	c.bpTurn, c.bpManual, c.granted = 0, 0, {}
	c.attacksThisTurn, c.blocksThisTurn = 0, 0
	c.playedTurn = state.turnNumber
	-- 3. becomes Active.
	c.rested = false
	log(state, ("P%d Raid: %s onto %s"):format(p, GameState.name(state, uid), GameState.name(state, targetUid)))

	-- 4. Energy Line -> Front Line.
	if line == "Energy" and moveToFront ~= false then
		local front = state.players[p].front
		if #front >= Constants.LINE_SIZE then
			local pick = if replaceUid and table.find(front, replaceUid)
				then { replaceUid }
				else chooseCards(state, p, "ChooseCards", "Front Line is full: choose a card to send to the Remove Area", table.clone(front), 1, 1)
			GameState.moveCard(state, pick[1], "Remove")
		end
		local e = state.players[p].energy
		table.remove(e, table.find(e, uid) :: number)
		table.insert(front, uid)
		c.zone = "Front"
	end
	-- 5. "When Played" effects of the Raid card.
	runAbilities(state, uid, "OnPlay", p)
end

local function trigCtx(state: GameState): TriggerResolver.Ctx
	return {
		state = state,
		yesNo = function(p, kind, prompt)
			return yesNo(state, p, kind, prompt)
		end,
		chooseCards = function(p, kind, prompt, cands, min, max)
			return chooseCards(state, p, kind, prompt, cands, min, max)
		end,
		chooseOption = function(p, kind, prompt, options)
			return chooseOption(state, p, kind, prompt, options)
		end,
		raidTargets = function(p, uid)
			return raidTargets(state, p, uid)
		end,
		raid = function(p, uid, targetUid)
			doRaid(state, p, uid, targetUid, nil, nil)
		end,
		retire = function(uid, why)
			removeFromField(state, uid, why)
		end,
	}
end

--------------------------------------------------------------------------------
-- Damage and battle (manual p.12)
--------------------------------------------------------------------------------

local function dealDamage(state: GameState, attackerP: number, amount: number)
	local defP = other(attackerP)
	local life = state.players[defP].life
	local n = math.min(amount, #life)
	if n <= 0 then
		return
	end
	log(state, ("P%d takes %d damage"):format(defP, n))
	-- The attacking player picks which Life cards (by position).
	local positions = {}
	for i = 1, #life do
		table.insert(positions, i)
	end
	local picked = chooseCards(state, attackerP, "ChooseLife", ("Choose %d of P%d's Life cards"):format(n, defP), positions, n, n)
	local uids = {}
	for _, pos in picked do
		table.insert(uids, life[pos])
	end
	for _, uid in uids do
		GameState.moveCard(state, uid, "Resolving")
	end
	local ctx = trigCtx(state)
	for _, uid in uids do
		TriggerResolver.check(ctx, defP, uid)
		if state.winner then
			return
		end
	end
	checkStateRules(state)
	if #state.players[defP].life == 0 then
		lose(state, defP, "no Life left")
	end
end

local function impactDamage(state: GameState, atkUid: number, defUid: number): number
	if GameState.keyword(state, defUid, "nullifyImpact") then
		return 0
	end
	local impact = GameState.keyword(state, atkUid, "impact")
	local plus = GameState.keyword(state, atkUid, "impactPlus")
	if impact and plus then
		return 2
	elseif impact or plus then
		return 1
	end
	return 0
end

local function battle(state: GameState, atkUid: number, defUid: number)
	local atkP = GameState.inst(state, atkUid).owner
	local a, d = GameState.bp(state, atkUid), GameState.bp(state, defUid)
	log(state, ("Battle: %s %d vs %s %d"):format(GameState.name(state, atkUid), a, GameState.name(state, defUid), d))
	if a >= d then
		local impact = impactDamage(state, atkUid, defUid)
		removeFromField(state, defUid, "lost battle")
		if impact > 0 then
			log(state, ("Impact %d"):format(impact))
			dealDamage(state, atkP, impact)
		end
	else
		log(state, "Attacker loses the battle (stays on the field)")
	end
end

local function attackFlow(state: GameState, p: number, atkUid: number, targetUid: number?)
	local atk = GameState.inst(state, atkUid)
	atk.rested = true
	atk.attacksThisTurn += 1
	if atk.attacksThisTurn == 1 and GameState.keyword(state, atkUid, "doubleAttack") then
		atk.rested = false
		log(state, GameState.name(state, atkUid) .. " Double Attack: back to Active")
	end
	local defP = other(p)
	runAbilities(state, atkUid, "WhenAttacking", p)
	if state.winner or not GameState.isOnField(state, atkUid) then
		return
	end
	if targetUid and not GameState.isOnField(state, targetUid) then
		return
	end

	if targetUid then
		log(state, ("P%d attacks %s with %s (Called Strike)"):format(p, GameState.name(state, targetUid), GameState.name(state, atkUid)))
		battle(state, atkUid, targetUid)
		return
	end

	log(state, ("P%d attacks with %s"):format(p, GameState.name(state, atkUid)))
	local blockers = {}
	for _, uid in state.players[defP].front do
		local c = GameState.inst(state, uid)
		if GameState.isCharacter(state, uid) and not c.rested and EffectRegistry.canBlock(state, atkUid, uid) then
			table.insert(blockers, uid)
		end
	end
	local pick = chooseCards(state, defP, "Block", ("Block %s (BP %d)?"):format(GameState.name(state, atkUid), GameState.bp(state, atkUid)), blockers, 0, 1)
	local blocker = pick[1]
	if blocker then
		local b = GameState.inst(state, blocker)
		b.rested = true
		b.blocksThisTurn += 1
		if b.blocksThisTurn == 1 and GameState.keyword(state, blocker, "doubleBlock") then
			b.rested = false
			log(state, GameState.name(state, blocker) .. " Double Block: back to Active")
		end
		log(state, ("P%d blocks with %s"):format(defP, GameState.name(state, blocker)))
		runAbilities(state, blocker, "WhenBlocking", defP)
		if state.winner or not GameState.isOnField(state, blocker) or not GameState.isOnField(state, atkUid) then
			return
		end
		battle(state, atkUid, blocker)
	else
		local dmg = (if GameState.keyword(state, atkUid, "damage") then 2 else 1)
			+ (if GameState.keyword(state, atkUid, "damagePlus") then 1 else 0)
		dealDamage(state, p, dmg)
	end
end

--------------------------------------------------------------------------------
-- Turn flow (manual p.07-08, p.13)
--------------------------------------------------------------------------------

local function beginTurn(state: GameState, p: number)
	state.turnPlayer = p
	state.turnNumber += 1
	state.phase = "Start"
	local ps = state.players[p]
	ps.turnsTaken += 1
	ps.extraDrawUsed = false
	log(state, ("P%d turn %d"):format(p, ps.turnsTaken))

	-- 1. "until the start of your next turn" effects end (none tracked yet).
	-- 2. Everything Active, including AP cards.
	for _, line in { ps.front, ps.energy } do
		for _, uid in line do
			GameState.untap(state, uid)
		end
	end
	for _, a in ps.ap do
		a.rested = false
	end
	state.limits = {}
	for _, c in state.cards do
		c.attacksThisTurn = 0
		c.blocksThisTurn = 0
		c.usedOnce = {}
	end
	-- 3. AP cards for this turn.
	local want = GameState.apTarget(state, p)
	while #ps.ap < want do
		table.insert(ps.ap, { rested = false })
	end
	-- 4. Draw (first player skips their first turn). Can't draw -> lose.
	if not (p == state.firstPlayer and ps.turnsTaken == 1) then
		if #ps.deck == 0 then
			lose(state, p, "no cards left to draw in the Start Phase")
			return
		end
		GameState.draw(state, p, 1)
	end
	-- 5. Extra draw is an action the player may take now (ExtraDraw).
end

local function endTurnFlow(state: GameState)
	local p = state.turnPlayer
	local ps = state.players[p]
	state.phase = "End"
	-- 1. start-of-End-Phase effects: step 5.
	-- 2. Characters and Fields Active (AP cards stay rested).
	for _, line in { ps.front, ps.energy } do
		for _, uid in line do
			GameState.untap(state, uid)
		end
	end
	-- 3. Hand limit.
	local extra = #ps.hand - Constants.HAND_LIMIT
	if extra > 0 then
		local pick = chooseCards(state, p, "Discard", ("Hand has %d cards: choose %d to send to the Remove Area"):format(#ps.hand, extra), table.clone(ps.hand), extra, extra)
		for _, uid in pick do
			GameState.moveCard(state, uid, "Remove")
		end
	end
	-- 4. "for the turn" effects end, for both players' cards.
	for _, c in state.cards do
		c.bpTurn = 0
		c.granted = {}
		c.energyTurn = {}
	end
	checkStateRules(state)
	beginTurn(state, other(p))
end

local function setupFlow(state: GameState)
	for p = 1, 2 do
		GameState.shuffle(state, state.players[p].deck)
	end
	for p = 1, 2 do
		GameState.draw(state, p, Constants.STARTING_HAND)
	end
	-- Mulligan once, first player decides first (manual p.05).
	for _, p in { state.firstPlayer, other(state.firstPlayer) } do
		if yesNo(state, p, "Mulligan", "Redraw your starting hand?") then
			local ps = state.players[p]
			local old = table.clone(ps.hand)
			for _, uid in old do
				GameState.moveCard(state, uid, "Resolving") -- set aside
			end
			GameState.draw(state, p, Constants.STARTING_HAND)
			for _, uid in old do
				GameState.moveCard(state, uid, "Deck")
			end
			GameState.shuffle(state, ps.deck)
			log(state, ("P%d mulligans"):format(p))
		end
	end
	for p = 1, 2 do
		local ps = state.players[p]
		for _ = 1, Constants.STARTING_LIFE do
			if ps.deck[1] then
				GameState.moveCard(state, ps.deck[1], "Life")
			end
		end
	end
	beginTurn(state, state.firstPlayer)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

type Handler = (state: GameState, p: number, a: Action) -> (boolean, string?)
local handlers: { [string]: Handler } = {}

local NEXT_PHASE = { Start = "Move", Move = "Main", Main = "Attack" }

handlers.NextPhase = function(state, p, _a)
	if state.phase == "Attack" then
		runFlow(state, function()
			endTurnFlow(state)
		end)
		return true
	end
	local nextPhase = NEXT_PHASE[state.phase]
	if not nextPhase then
		return false, "cannot leave phase " .. state.phase
	end
	if state.phase == "Main" then
		runFlow(state, function()
			runDelayed(state, "EndOfMain")
			if not state.winner then
				state.phase = "Attack"
				log(state, "-> Attack")
			end
		end)
		return true
	end
	state.phase = nextPhase :: any
	log(state, "-> " .. nextPhase)
	return true
end

handlers.ExtraDraw = function(state, p, _a)
	local ps = state.players[p]
	if state.phase ~= "Start" then
		return false, "Extra Draw is only in your Start Phase"
	end
	if ps.extraDrawUsed then
		return false, "Extra Draw already used this turn"
	end
	if GameState.activeAP(state, p) < Constants.EXTRA_DRAW_COST then
		return false, "not enough AP"
	end
	if #ps.deck == 0 then
		return false, "deck is empty"
	end
	GameState.payAP(state, p, Constants.EXTRA_DRAW_COST)
	GameState.draw(state, p, 1)
	ps.extraDrawUsed = true
	log(state, ("P%d Extra Draw"):format(p))
	return true
end

-- a.moves = { { uid = n, to = "Front" | "Energy" } }, a.remove = { uid... } for full lines.
-- All moves happen at once (manual p.08).
handlers.Move = function(state, p, a)
	if state.phase ~= "Move" then
		return false, "moving is only in your Move Phase"
	end
	local moves = a.moves
	if type(moves) ~= "table" or #moves == 0 then
		return false, "no moves"
	end
	local ps = state.players[p]
	local count: { [string]: number } = { Front = #ps.front, Energy = #ps.energy }
	local moving: { [number]: boolean } = {}
	for _, m in moves do
		local uid, to = m.uid, m.to
		if type(uid) ~= "number" or (to ~= "Front" and to ~= "Energy") then
			return false, "bad move"
		end
		local c = state.cards[uid]
		if not c or c.owner ~= p or (c.zone ~= "Front" and c.zone ~= "Energy") or c.zone == to then
			return false, "cannot move card " .. tostring(uid)
		end
		if not GameState.isCharacter(state, uid) then
			return false, "Field cards cannot move"
		end
		if to == "Energy" and not GameState.keyword(state, uid, "step") then
			return false, GameState.name(state, uid) .. " has no Step"
		end
		if moving[uid] then
			return false, "moved twice"
		end
		moving[uid] = true
		count[c.zone] -= 1
		count[to] += 1
	end
	local removals = a.remove or {}
	for _, r in removals do
		local c = state.cards[r]
		if not c or c.owner ~= p or moving[r] or (c.zone ~= "Front" and c.zone ~= "Energy") then
			return false, "cannot remove card " .. tostring(r)
		end
		count[c.zone] -= 1
	end
	for line, n in count do
		if n > Constants.LINE_SIZE then
			return false, line .. " Line would hold " .. n .. " cards: list cards to remove"
		end
	end
	for _, r in removals do
		GameState.moveCard(state, r, "Remove")
	end
	-- Detach all first, then place, so swaps work.
	for _, m in moves do
		local c = GameState.inst(state, m.uid)
		local from = lineList(state, p, c.zone)
		table.remove(from, table.find(from, m.uid) :: number)
	end
	for _, m in moves do
		local c = GameState.inst(state, m.uid)
		table.insert(lineList(state, p, m.to), m.uid)
		c.zone = m.to
		log(state, ("P%d moves %s to %s Line"):format(p, GameState.name(state, m.uid), m.to))
	end
	return true
end

local function canUseFromHand(state: GameState, p: number, uid: number): (boolean, string?)
	local c = state.cards[uid]
	if not c or c.owner ~= p or c.zone ~= "Hand" then
		return false, "card is not in your hand"
	end
	if not GameState.meetsEnergy(state, p, uid) then
		return false, "not enough energy"
	end
	local ap = GameState.def(state, uid).ap or 0
	if GameState.activeAP(state, p) < ap then
		return false, "not enough AP"
	end
	return true
end

-- a.uid, a.line ("Front" | "Energy", not for Events), a.replaceUid when the line is full.
handlers.Play = function(state, p, a)
	if state.phase ~= "Main" then
		return false, "cards are used in your Main Phase"
	end
	local uid = a.uid
	if type(uid) ~= "number" then
		return false, "missing uid"
	end
	local ok, err = canUseFromHand(state, p, uid)
	if not ok then
		return false, err
	end
	local def = GameState.def(state, uid)
	local ap = def.ap or 0

	if def.cardType == "Event" then
		GameState.payAP(state, p, ap)
		GameState.moveCard(state, uid, "Resolving")
		log(state, ("P%d uses Event %s"):format(p, GameState.name(state, uid)))
		runFlow(state, function()
			runAbilities(state, uid, "Event", p)
			if GameState.inst(state, uid).zone == "Resolving" then
				GameState.moveCard(state, uid, "Outside")
			end
		end)
		return true
	end

	local line = a.line
	if def.cardType == "Field" then
		line = "Energy"
	elseif def.cardType ~= "Character" then
		return false, "this card cannot be played"
	end
	if line ~= "Front" and line ~= "Energy" then
		return false, "choose Front or Energy line"
	end
	local roomOk, roomErr = makeRoom(state, p, line, a.replaceUid)
	if not roomOk then
		return false, roomErr
	end
	GameState.payAP(state, p, ap)
	if a.replaceUid then
		GameState.moveCard(state, a.replaceUid, "Remove")
	end
	GameState.moveCard(state, uid, line)
	GameState.inst(state, uid).rested = not EffectRegistry.entersActive(def)
	log(state, ("P%d plays %s to %s Line"):format(p, GameState.name(state, uid), line))
	runFlow(state, function()
		runAbilities(state, uid, "OnPlay", p)
	end)
	return true
end

-- Activate: Main. a.uid = your card, a.index = which of its abilities.
-- Costs are paid here even when the effect itself is resolved by hand.
handlers.Activate = function(state, p, a)
	if state.phase ~= "Main" then
		return false, "Activate: Main abilities are used in your Main Phase"
	end
	local uid, index = a.uid, a.index
	local c = type(uid) == "number" and state.cards[uid] or nil
	if not c or c.owner ~= p then
		return false, "not your card"
	end
	local ability = type(index) == "number" and EffectRegistry.abilitiesOf(GameState.def(state, uid))[index] or nil
	if not ability or ability.timing ~= "ActivateMain" then
		return false, "that card has no such Activate: Main ability"
	end
	if not EffectRegistry.condsHold(state, uid, ability.conds) then
		return false, "the ability's condition is not met (e.g. it must be on the Front Line)"
	end
	local onField = c.zone == "Front" or c.zone == "Energy"
	if not onField and #ability.conds == 0 then
		return false, "the card must be on your field"
	end
	if ability.once and c.usedOnce[index] then
		return false, "Once Per Turn: already used this turn"
	end
	local costs = ability.costs
	if costs.rest and (c.rested or not onField) then
		return false, "the card must be Active to rest it"
	end
	if costs.ap and GameState.activeAP(state, p) < costs.ap then
		return false, "not enough AP"
	end
	if costs.discard and #state.players[p].hand < costs.discard then
		return false, "not enough cards in hand"
	end
	if costs.retireSelf and not onField then
		return false, "the card must be on your field"
	end

	if ability.once then
		c.usedOnce[index] = true
	end
	if costs.rest then
		c.rested = true
	end
	if costs.ap then
		GameState.payAP(state, p, costs.ap)
	end
	log(state, ("P%d activates %s"):format(p, GameState.name(state, uid)))
	runFlow(state, function()
		if costs.discard then
			local pick = chooseCards(state, p, "ChooseCards", ("Cost: put %d card(s) from your hand into your Outside Area"):format(costs.discard), table.clone(state.players[p].hand), costs.discard, costs.discard)
			for _, h in pick do
				GameState.moveCard(state, h, "Outside")
			end
		end
		if costs.retireSelf then
			removeFromField(state, uid, "ability cost")
		end
		if EffectRegistry.isSupported(ability) then
			EffectRegistry.run(effectCtx(state, p, uid), ability)
		else
			log(state, ("  MANUAL %s [Activate: Main]: %s"):format(GameState.name(state, uid), GameState.def(state, uid).effectEn))
		end
	end)
	return true
end

-- a.uid (in hand), a.targetUid, a.moveToFront (default true), a.replaceUid (Front full).
handlers.Raid = function(state, p, a)
	if state.phase ~= "Main" then
		return false, "Raid is used in your Main Phase"
	end
	local uid, target = a.uid, a.targetUid
	if type(uid) ~= "number" or type(target) ~= "number" then
		return false, "missing uid or targetUid"
	end
	local ok, err = canUseFromHand(state, p, uid)
	if not ok then
		return false, err
	end
	if not table.find(raidTargets(state, p, uid), target) then
		return false, "that character cannot be Raided by this card"
	end
	GameState.payAP(state, p, GameState.def(state, uid).ap or 0)
	runFlow(state, function()
		doRaid(state, p, uid, target, a.moveToFront, a.replaceUid)
	end)
	return true
end

-- a.uid = attacker on your Front Line; a.targetUid = opponent's Front character (Called Strike only).
handlers.Attack = function(state, p, a)
	if state.phase ~= "Attack" then
		return false, "attacks are in your Attack Phase"
	end
	local uid = a.uid
	local c = type(uid) == "number" and state.cards[uid] or nil
	if not c or c.owner ~= p or c.zone ~= "Front" or not GameState.isCharacter(state, uid) then
		return false, "attack with a character on your Front Line"
	end
	if c.rested then
		return false, "only Active characters can attack"
	end
	local target = a.targetUid
	if target ~= nil then
		local t = state.cards[target]
		if not GameState.keyword(state, uid, "calledStrike") then
			return false, "only characters with Called Strike can attack a character"
		end
		if not t or t.owner == p or t.zone ~= "Front" or not GameState.isCharacter(state, target) then
			return false, "target must be on the opponent's Front Line"
		end
	end
	runFlow(state, function()
		attackFlow(state, p, uid, target)
	end)
	return true
end

--------------------------------------------------------------------------------
-- Manual tools: for effects without a handler yet. Logged so both players see them.
--------------------------------------------------------------------------------

local MANUAL_DESTS = { Hand = true, Outside = true, Remove = true, DeckTop = true, DeckBottom = true, Front = true, Energy = true, Life = true }

local function manual(state: GameState, p: number, a: Action): (boolean, string?)
	local t = a.type
	if t == "ManualDraw" then
		local n = GameState.draw(state, p, 1)
		log(state, ("P%d MANUAL draws %d"):format(p, n))
		return true
	end
	local uid = a.uid
	local c = type(uid) == "number" and state.cards[uid] or nil
	if not c then
		return false, "unknown card"
	end
	local onField = c.zone == "Front" or c.zone == "Energy"
	-- Your own cards anywhere visible to you; opponent's cards only on the field.
	if c.owner ~= p and not onField then
		return false, "you can only move the opponent's cards that are on the field"
	end
	if t == "ManualMove" then
		local to = a.to
		if not MANUAL_DESTS[to] then
			return false, "bad destination"
		end
		if to == "Front" or to == "Energy" then
			if #lineList(state, c.owner, to) >= Constants.LINE_SIZE then
				return false, to .. " Line is full"
			end
		end
		if to == "DeckTop" then
			GameState.moveCard(state, uid, "Deck")
		elseif to == "DeckBottom" then
			GameState.moveCard(state, uid, "Deck", { bottom = true })
		else
			GameState.moveCard(state, uid, to)
		end
		log(state, ("P%d MANUAL moves %s to %s"):format(p, GameState.name(state, uid), to))
	elseif t == "ManualBP" then
		if not onField or type(a.delta) ~= "number" then
			return false, "ManualBP needs a field character and a delta"
		end
		c.bpManual += a.delta
		log(state, ("P%d MANUAL BP %+d on %s"):format(p, a.delta, GameState.name(state, uid)))
	elseif t == "ManualRest" then
		if not onField then
			return false, "not on the field"
		end
		c.rested = a.rested == true
		log(state, ("P%d MANUAL %s %s"):format(p, if c.rested then "rests" else "activates", GameState.name(state, uid)))
	else
		return false, "unknown manual action"
	end
	checkStateRules(state)
	if #state.players[1].life == 0 then
		lose(state, 1, "no Life left")
	elseif #state.players[2].life == 0 then
		lose(state, 2, "no Life left")
	end
	return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- decks: card keys (50 each, already validated by DeckRules). opts.firstPlayer, opts.seed.
function RulesEngine.new(deck1: { string }, deck2: { string }, opts: { firstPlayer: number?, seed: number? }?): GameState
	local state = GameState.new(opts and opts.seed)
	state.firstPlayer = (opts and opts.firstPlayer) or state.rng:NextInteger(1, 2)
	state.turnPlayer = state.firstPlayer
	for _, key in deck1 do
		GameState.createCard(state, key, 1)
	end
	for _, key in deck2 do
		GameState.createCard(state, key, 2)
	end
	log(state, ("P%d goes first"):format(state.firstPlayer))
	runFlow(state, function()
		setupFlow(state)
	end)
	return state
end

-- Every player input goes through here. Returns ok, error message.
function RulesEngine.act(state: GameState, p: number, action: Action): (boolean, string?)
	if p ~= 1 and p ~= 2 then
		return false, "bad player"
	end
	if type(action) ~= "table" or type(action.type) ~= "string" then
		return false, "bad action"
	end
	if state.phase == "GameOver" then
		return false, "the game is over"
	end
	local t = action.type
	if t == "Concede" then
		if state.co then
			state.co = nil
			state.pending = nil
		end
		lose(state, p, "conceded")
		return true
	end
	if state.pending then
		if t ~= "Respond" then
			return false, "waiting for: " .. state.pending.prompt
		end
		if state.pending.player ~= p then
			return false, "it is the other player's decision"
		end
		local ok, err = state.pending.validate(action.choice)
		if not ok then
			return false, err
		end
		stepFlow(state, action.choice)
		checkStateRules(state)
		return true
	end
	if t == "Respond" then
		return false, "nothing to respond to"
	end
	if t:sub(1, 6) == "Manual" then
		return manual(state, p, action)
	end
	if p ~= state.turnPlayer then
		return false, "not your turn"
	end
	local handler = handlers[t]
	if not handler then
		return false, "unknown action " .. t
	end
	local ok, err = handler(state, p, action)
	if ok then
		checkStateRules(state)
	end
	return ok, err
end

-- Exposed for the tests and the server.
RulesEngine.raidTargets = raidTargets

return RulesEngine
