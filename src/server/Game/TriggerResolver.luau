--!strict
-- Life-card triggers (Asia manual p.12 "Trigger check"). The trigger texts are the
-- same on every card for Draw, Get, Active, Raid, Special and Final (checked in
-- the card data). Color triggers differ per card, so they are logged for the
-- players to resolve with the manual tools until step 5 adds handlers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Game.Types)
local Constants = require(ReplicatedStorage.Shared.Game.Constants)
local GameState = require(script.Parent.GameState)

type GameState = Types.GameState

-- Decision helpers and Raid, provided by RulesEngine (avoids a require cycle).
export type Ctx = {
	state: GameState,
	yesNo: (player: number, kind: string, prompt: string) -> boolean,
	chooseCards: (player: number, kind: string, prompt: string, candidates: { number }, min: number, max: number) -> { number },
	chooseOption: (player: number, kind: string, prompt: string, options: { string }) -> string,
	raidTargets: (player: number, uid: number) -> { number },
	raid: (player: number, uid: number, targetUid: number) -> (),
}

local TriggerResolver = {}

local function fieldCharacters(state: GameState, p: number, lines: { string }): { number }
	local out = {}
	local ps = state.players[p]
	for _, line in lines do
		for _, uid in (if line == "Front" then ps.front else ps.energy) do
			if GameState.isCharacter(state, uid) then
				table.insert(out, uid)
			end
		end
	end
	return out
end

-- Called for a revealed Life card (zone "Resolving"). Moves it to where it ends up.
function TriggerResolver.check(ctx: Ctx, p: number, uid: number)
	local state = ctx.state
	local def = GameState.def(state, uid)
	local trigger = def.triggerType
	GameState.log(state, ("P%d Life: %s%s"):format(p, GameState.name(state, uid), if trigger ~= "" then " [" .. trigger .. "]" else ""))

	local function toOutside()
		GameState.moveCard(state, uid, "Outside")
	end

	if trigger == "" then
		toOutside()
		return
	end

	local use = ctx.yesNo(p, "UseTrigger", ("Use trigger: %s"):format(def.triggerEn))
	if not use then
		toOutside()
		return
	end

	if trigger == "Draw" then
		GameState.draw(state, p, 1)
		toOutside()
	elseif trigger == "Get" then
		GameState.moveCard(state, uid, "Hand")
	elseif trigger == "Active" then
		local cands = fieldCharacters(state, p, { "Front", "Energy" })
		local pick = ctx.chooseCards(p, "ChooseCards", "[Active] Choose 1 of your characters: Active, BP+3000 this turn", cands, math.min(1, #cands), 1)
		for _, target in pick do
			local c = GameState.inst(state, target)
			c.rested = false
			c.bpTurn += Constants.ACTIVE_TRIGGER_BP
			GameState.log(state, ("  %s -> Active, BP+%d"):format(GameState.name(state, target), Constants.ACTIVE_TRIGGER_BP))
		end
		toOutside()
	elseif trigger == "Special" then
		local opp = GameState.other(p)
		local cands = fieldCharacters(state, opp, { "Front" })
		local pick = ctx.chooseCards(p, "ChooseCards", "[Special] Choose 1 character on the opponent's Front Line to remove", cands, math.min(1, #cands), 1)
		for _, target in pick do
			GameState.log(state, ("  %s removed from the field"):format(GameState.name(state, target)))
			GameState.moveCard(state, target, "Outside")
		end
		toOutside()
	elseif trigger == "Final" then
		local ps = state.players[p]
		if #ps.life == 0 and #ps.deck > 0 then
			GameState.moveCard(state, ps.deck[1], "Life")
			GameState.log(state, "  top card of deck -> Life")
		end
		toOutside()
	elseif trigger == "Raid" then
		local targets = if GameState.meetsEnergy(state, p, uid) then ctx.raidTargets(p, uid) else {}
		local choice = "Hand"
		if #targets > 0 then
			choice = ctx.chooseOption(p, "ChooseOption", "[Raid] Add to hand or Raid?", { "Hand", "Raid" })
		end
		if choice == "Raid" then
			local pick = ctx.chooseCards(p, "ChooseCards", "[Raid] Choose the character to Raid onto", targets, 1, 1)
			ctx.raid(p, uid, pick[1])
		else
			GameState.moveCard(state, uid, "Hand")
		end
	else
		-- Color and anything unknown: players resolve it by hand.
		GameState.log(state, ("  MANUAL [%s]: %s"):format(trigger, def.triggerEn))
		toOutside()
	end
end

return TriggerResolver
