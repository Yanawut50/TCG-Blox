--!strict
-- Step 2 test: two simple bots play full games with random legal HTR decks.
-- Checks rule invariants after every action and prints a summary to Output.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData"))
local DeckRules = require(Shared:WaitForChild("Game"):WaitForChild("DeckRules"))
local Constants = require(Shared.Game:WaitForChild("Constants"))
local GameDir = script.Parent.Parent:WaitForChild("Game")
local RulesEngine = require(GameDir:WaitForChild("RulesEngine"))
local GameState = require(GameDir:WaitForChild("GameState"))

-- Off by default. To run: set RUN = true here, or give this script the
-- attribute RunAutoPlay = true in Studio before pressing Play.
local RUN = false
if not (RUN or script:GetAttribute("RunAutoPlay") == true) then
	return
end

local GAMES = 30
local SERIES = "HTR"
local MAX_ACTIONS = 5000

local function buildDeck(rng: Random): { string }
	local pool: { string } = {}
	local seenNumber: { [string]: boolean } = {}
	for _, set in CardData.getSets() do
		if DeckRules.seriesCode(set.id) == SERIES then
			local cards = CardData.getSet(set.id)
			for key, card in cards or {} do
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
	-- Like a real deck: two colors, cheap cards first so the Energy Line can start.
	local colors = { "Red", "Blue", "Yellow", "Green", "Purple" }
	local c1 = table.remove(colors, rng:NextInteger(1, #colors)) :: string
	local c2 = table.remove(colors, rng:NextInteger(1, #colors)) :: string
	local function inColors(key: string): boolean
		for _, c in (CardData.get(key) :: CardData.Card).colors do
			if c ~= c1 and c ~= c2 then
				return false
			end
		end
		return true
	end
	local cheap, rest, offColor = {}, {}, {}
	for _, key in pool do
		if not inColors(key) then
			table.insert(offColor, key)
		elseif ((CardData.get(key) :: CardData.Card).needEnergy or 0) <= 1 then
			table.insert(cheap, key)
		else
			table.insert(rest, key)
		end
	end
	pool = {}
	for _, list in { cheap, rest, offColor } do
		for _, key in list do
			table.insert(pool, key)
		end
	end
	local deck: { string } = {}
	local triggers: { [string]: number } = {}
	for _, key in pool do
		local card = CardData.get(key) :: CardData.Card
		local limited = table.find(Constants.LIMITED_TRIGGERS, card.triggerType) ~= nil
		local n = if ((card.needEnergy or 0) <= 1) then 4 else rng:NextInteger(2, 4)
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
		if #deck >= Constants.DECK_SIZE then
			break
		end
	end
	return deck
end

-- Every card is in exactly one place; lines hold at most 4.
local function checkInvariants(state: any)
	local seen: { [number]: string } = {}
	local function mark(uid: number, where: string)
		assert(not seen[uid], ("card %d in %s and %s"):format(uid, where, seen[uid] or "?"))
		seen[uid] = where
		local c = state.cards[uid]
		for _, u in c.under do
			mark(u, "under " .. uid)
		end
	end
	for p, ps in state.players do
		for _, zone in { "deck", "hand", "life", "front", "energy", "outside", "remove" } do
			for _, uid in ps[zone] do
				mark(uid, ("P%d %s"):format(p, zone))
				assert(state.cards[uid].owner == p, "card in the wrong player's zone")
			end
		end
		assert(#ps.front <= Constants.LINE_SIZE, "Front Line over 4")
		assert(#ps.energy <= Constants.LINE_SIZE, "Energy Line over 4")
		assert(#ps.ap <= Constants.AP_CARDS, "more than 3 AP")
	end
	for uid, c in state.cards do
		if c.zone ~= "Resolving" then
			assert(seen[uid], ("card %d (%s) is nowhere"):format(uid, c.zone))
		end
	end
end

local function botAnswer(state: any, d: any): any
	if d.kind == "Mulligan" then
		-- Redraw when the hand has nothing that can start the Energy Line.
		for _, uid in state.players[d.player].hand do
			if (GameState.def(state, uid).needEnergy or 0) == 0 then
				return { option = "No" }
			end
		end
		return { option = "Yes" }
	elseif d.options then
		return { option = d.options[#d.options] == "No" and "Yes" or d.options[#d.options] }
	elseif d.kind == "Block" then
		local best, bestBp = nil, -1
		for _, uid in d.candidates do
			local bp = GameState.bp(state, uid)
			if bp > bestBp then
				best, bestBp = uid, bp
			end
		end
		if best and bestBp >= 3000 then
			return { pick = { best } }
		end
		return { pick = {} }
	else
		local pick = {}
		for i = 1, math.max(d.min or 0, 1) do
			if d.candidates[i] and #pick < (d.max or 1) then
				table.insert(pick, d.candidates[i])
			end
		end
		return { pick = pick }
	end
end

local stats = { actions = 0, rejected = 0 }
local rejectReasons: { [string]: number } = {}

local function act(state: any, p: number, a: any): boolean
	stats.actions += 1
	if stats.actions > MAX_ACTIONS then
		error("too many actions, the game looks stuck")
	end
	local ok, err = RulesEngine.act(state, p, a)
	if not ok then
		stats.rejected += 1
		local reason = (a.type .. ": " .. tostring(err)):gsub("%d+", "#")
		rejectReasons[reason] = (rejectReasons[reason] or 0) + 1
	end
	checkInvariants(state)
	while state.pending and state.phase ~= "GameOver" do
		local d = state.pending
		local answer = botAnswer(state, d)
		local ok2, err2 = RulesEngine.act(state, d.player, { type = "Respond", choice = answer })
		assert(ok2, ("bot answer rejected for %s: %s"):format(d.kind, tostring(err2)))
		checkInvariants(state)
	end
	return ok, err
end

local function botTurn(state: any)
	local p = state.turnPlayer
	local ps = state.players[p]
	-- Start: extra draw when the hand is small.
	if #ps.hand < 4 and GameState.activeAP(state, p) >= 2 then
		act(state, p, { type = "ExtraDraw" })
	end
	act(state, p, { type = "NextPhase" }) -- -> Move
	-- Move: if the Energy Line is full, send one character forward.
	if #ps.energy >= Constants.LINE_SIZE and #ps.front < Constants.LINE_SIZE then
		for _, uid in ps.energy do
			if GameState.isCharacter(state, uid) then
				act(state, p, { type = "Move", moves = { { uid = uid, to = "Front" } } })
				break
			end
		end
	end
	act(state, p, { type = "NextPhase" }) -- -> Main
	-- Main: Raid when possible, then build the Energy Line, then the Front Line.
	local progress = true
	while progress and state.phase == "Main" do
		progress = false
		local hand = table.clone(ps.hand)
		table.sort(hand, function(a, b)
			return (GameState.def(state, a).needEnergy or 0) > (GameState.def(state, b).needEnergy or 0)
		end)
		for _, uid in hand do
			local def = GameState.def(state, uid)
			local targets = RulesEngine.raidTargets(state, p, uid)
			local ok = false
			if #targets > 0 then
				ok = act(state, p, { type = "Raid", uid = uid, targetUid = targets[1] })
			end
			if not ok and def.cardType == "Event" then
				ok = act(state, p, { type = "Play", uid = uid })
			elseif not ok then
				local line = if #ps.energy < Constants.LINE_SIZE then "Energy" else "Front"
				if def.cardType == "Field" then
					line = "Energy"
				end
				if #(if line == "Front" then ps.front else ps.energy) < Constants.LINE_SIZE then
					ok = act(state, p, { type = "Play", uid = uid, line = line })
				end
			end
			if ok then
				progress = true
				break
			end
		end
	end
	if state.phase == "GameOver" then
		return
	end
	-- Use Activate: Main abilities that run automatically.
	local EffectRegistry = require(GameDir:WaitForChild("EffectRegistry"))
	for _, uid in table.clone(ps.front) do
		if state.phase ~= "Main" then
			break
		end
		if state.cards[uid].zone == "Front" then
			for i, a in EffectRegistry.abilitiesOf(GameState.def(state, uid)) do
				if a.timing == "ActivateMain" and EffectRegistry.isSupported(a) then
					act(state, p, { type = "Activate", uid = uid, index = i })
				end
			end
		end
	end
	if state.phase == "GameOver" then
		return
	end
	act(state, p, { type = "NextPhase" }) -- -> Attack
	for _, uid in table.clone(ps.front) do
		if state.phase ~= "Attack" then
			break
		end
		local c = state.cards[uid]
		if c and c.zone == "Front" and not c.rested and GameState.isCharacter(state, uid) then
			local target = nil
			if GameState.keyword(state, uid, "calledStrike") then
				for _, t in state.players[GameState.other(p)].front do
					if GameState.isCharacter(state, t) and GameState.bp(state, t) <= GameState.bp(state, uid) then
						target = t
						break
					end
				end
			end
			act(state, p, { type = "Attack", uid = uid, targetUid = target })
		end
	end
	if state.phase == "Attack" then
		act(state, p, { type = "NextPhase" }) -- -> End -> next turn
	end
end

-- How often each rule came up, to see what the bots actually exercised.
local COVERAGE_TAGS = {
	"Raid:", "blocks with", "Battle:", "Attacker loses", "lost battle", "Impact", "Double Attack", "Double Block",
	"Called Strike", "Extra Draw", "moves", "[Draw]", "[Get]", "[Active]", "[Special]", "[Final]", "[Raid]", "[Color]",
	"MANUAL", "effect", "activates", "Event", "mulligans", "Remove Area",
}
local coverage: { [string]: number } = {}
local battleSamples: { string } = {}
local results = { [1] = 0, [2] = 0 }
local reasons: { [string]: number } = {}
local failures = 0
local totalTurns = 0
local lastState: any = nil

for g = 1, GAMES do
	local ok, err = pcall(function()
		local rng = Random.new(1000 + g)
		local d1, d2 = buildDeck(rng), buildDeck(rng)
		local ok1, e1 = DeckRules.validate(d1)
		local ok2, e2 = DeckRules.validate(d2)
		assert(ok1, "deck 1 invalid: " .. table.concat(e1, "; "))
		assert(ok2, "deck 2 invalid: " .. table.concat(e2, "; "))
		local state: any = RulesEngine.new(d1, d2, { seed = g, firstPlayer = (g % 2) + 1 })
		lastState = state
		while state.pending do
			local d = state.pending
			assert(RulesEngine.act(state, d.player, { type = "Respond", choice = botAnswer(state, d) }))
		end
		checkInvariants(state)
		while state.phase ~= "GameOver" do
			botTurn(state)
		end
		for _, line in state.log do
			if line:find("Battle:", 1, true) and #battleSamples < 8 then
				table.insert(battleSamples, line)
			end
			for _, tag in COVERAGE_TAGS do
				if line:find(tag, 1, true) then
					coverage[tag] = (coverage[tag] or 0) + 1
				end
			end
		end
		results[state.winner] += 1
		reasons[state.winReason] = (reasons[state.winReason] or 0) + 1
		totalTurns += state.turnNumber
		print(("[AutoPlay] game %d: P%d wins on turn %d (%s), life %d-%d"):format(
			g, state.winner, state.turnNumber, state.winReason,
			#state.players[1].life, #state.players[2].life))
	end)
	if not ok then
		failures += 1
		warn(("[AutoPlay] game %d FAILED: %s"):format(g, tostring(err)))
		if lastState then
			local log = lastState.log
			for i = math.max(1, #log - 15), #log do
				warn("   " .. log[i])
			end
		end
	end
end

print(("[AutoPlay] %d games: P1 %d, P2 %d, failed %d, avg turns %.1f, actions %d (rejected %d)"):format(
	GAMES, results[1], results[2], failures, totalTurns / math.max(1, GAMES - failures), stats.actions, stats.rejected))
for reason, n in reasons do
	print(("[AutoPlay]   %s: %d"):format(reason, n))
end
local covLine = {}
for _, tag in COVERAGE_TAGS do
	table.insert(covLine, ("%s=%d"):format(tag, coverage[tag] or 0))
end
print("[AutoPlay] coverage: " .. table.concat(covLine, "  "))
for _, line in battleSamples do
	print("[AutoPlay]   sample " .. line)
end
for reason, n in rejectReasons do
	print(("[AutoPlay]   rejected %s x%d"):format(reason, n))
end
if lastState then
	print("[AutoPlay] last game, final log lines:")
	local log = lastState.log
	for i = math.max(1, #log - 25), #log do
		print("   " .. log[i])
	end
end
