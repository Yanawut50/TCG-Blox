--!strict
-- Card effects (step 5). Each card's effect text is split into abilities by
-- tools/effect_parse.py; each ability is a list of steps whose `key` is a
-- sentence template (names ⟨n0⟩, traits ⟦t0⟧, numbers {0} numbered per step).
--
-- A handler is registered per template key. An ability runs automatically only
-- if every one of its steps has a handler; otherwise the players resolve it with
-- the manual tools, as before. Handlers run inside the engine's decision
-- coroutine, so they may ask players to choose.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CardData = require(ReplicatedStorage.Shared.CardData)
local GameState = require(script.Parent.GameState)

type GameState = any

export type Step = { key: string, nums: { number }, names: { string }, traits: { string }, bullet: boolean? }
export type Ability = {
	timing: string,
	conds: { string },
	costs: { rest: boolean?, ap: number?, discard: number?, retireSelf: boolean? },
	once: boolean?,
	steps: { Step },
	unknownTags: { string }?,
}

-- What a handler gets. The engine fills in the functions.
export type Ctx = {
	state: GameState,
	p: number, -- player controlling the effect
	source: number, -- card uid whose ability this is
	looked: { number }, -- cards looked at / revealed from the deck, in "Resolving"
	did: boolean, -- result of the previous step ("If you do")
	failed: boolean, -- "If you can't"
	addedToHand: boolean,
	yesNo: (player: number, prompt: string) -> boolean,
	chooseCards: (player: number, prompt: string, candidates: { number }, min: number, max: number) -> { number },
	chooseOption: (player: number, prompt: string, options: { string }) -> string,
	retire: (uid: number, why: string) -> (),
	delay: (whenKey: string, fn: () -> ()) -> (),
}

type Handler = (ctx: Ctx, step: Step) -> boolean?

local EffectRegistry = {}
local handlers: { [string]: Handler } = {}

local AUTO_TIMINGS = { OnPlay = true, WhenAttacking = true, WhenBlocking = true, OnRetire = true, ActivateMain = true, Event = true }

-- Prefixes that make a step depend on the step before it.
local PREFIXES: { { prefix: string, test: (Ctx) -> boolean } } = {
	{ prefix = "そうした場合、", test = function(ctx)
		return ctx.did
	end },
	{ prefix = "手札に加えた場合、", test = function(ctx)
		return ctx.addedToHand
	end },
	{ prefix = "戻せない場合、", test = function(ctx)
		return ctx.failed
	end },
}

local function register(keys: { string } | string, fn: Handler)
	if type(keys) == "string" then
		handlers[keys] = fn
	else
		for _, k in keys do
			handlers[k] = fn
		end
	end
end

local function resolveHandler(key: string): (Handler?, ((Ctx) -> boolean)?)
	local h = handlers[key]
	if h then
		return h, nil
	end
	for _, pre in PREFIXES do
		if key:sub(1, #pre.prefix) == pre.prefix then
			local inner = handlers[key:sub(#pre.prefix + 1)]
			if inner then
				return inner, pre.test
			end
		end
	end
	return nil, nil
end

--------------------------------------------------------------------------------
-- Helpers for handlers
--------------------------------------------------------------------------------

local function fieldChars(state: GameState, p: number, lines: { string }?): { number }
	local out = {}
	local ps = state.players[p]
	for _, line in lines or { "Front", "Energy" } do
		for _, uid in (if line == "Front" then ps.front else ps.energy) do
			if GameState.isCharacter(state, uid) then
				table.insert(out, uid)
			end
		end
	end
	return out
end

local function filter(list: { number }, pred: (number) -> boolean): { number }
	local out = {}
	for _, uid in list do
		if pred(uid) then
			table.insert(out, uid)
		end
	end
	return out
end

local function hasTrait(state: GameState, uid: number, trait: string): boolean
	return table.find(GameState.def(state, uid).traits, trait) ~= nil
end

local function hasName(state: GameState, uid: number, name: string): boolean
	return GameState.def(state, uid).nameJp == name
end

local function discard(ctx: Ctx, n: number)
	local hand = ctx.state.players[ctx.p].hand
	n = math.min(n, #hand)
	if n <= 0 then
		return
	end
	local pick = ctx.chooseCards(ctx.p, ("Choose %d card(s) from your hand to put into your Outside Area"):format(n), table.clone(hand), n, n)
	for _, uid in pick do
		GameState.moveCard(ctx.state, uid, "Outside")
	end
end

local function lookTop(ctx: Ctx, n: number, reveal: boolean)
	local deck = ctx.state.players[ctx.p].deck
	for _ = 1, n do
		local top = deck[1]
		if not top then
			break
		end
		GameState.moveCard(ctx.state, top, "Resolving")
		table.insert(ctx.looked, top)
		if reveal then
			GameState.log(ctx.state, "  revealed " .. GameState.name(ctx.state, top))
		end
	end
end

local function takeFromLooked(ctx: Ctx, pred: (number) -> boolean, max: number, what: string)
	local cands = filter(ctx.looked, pred)
	local pick = ctx.chooseCards(ctx.p, ("Choose up to %d %s to reveal and add to your hand"):format(max, what), cands, 0, max)
	for _, uid in pick do
		table.remove(ctx.looked, table.find(ctx.looked, uid) :: number)
		GameState.moveCard(ctx.state, uid, "Hand")
		GameState.log(ctx.state, ("  P%d adds %s to hand"):format(ctx.p, GameState.name(ctx.state, uid)))
	end
	ctx.addedToHand = #pick > 0
end

local function bpTurn(ctx: Ctx, uids: { number }, delta: number)
	for _, uid in uids do
		GameState.inst(ctx.state, uid).bpTurn += delta
		GameState.log(ctx.state, ("  %s BP%+d this turn"):format(GameState.name(ctx.state, uid), delta))
	end
end

-- Choose `count` (exactly, as many as possible) or up to `count` cards.
local function choose(ctx: Ctx, player: number, prompt: string, cands: { number }, count: number, upTo: boolean): { number }
	local min = if upTo then 0 else math.min(count, #cands)
	return ctx.chooseCards(player, prompt, cands, min, count)
end

--------------------------------------------------------------------------------
-- Handlers (most common templates in HTR-1 / HTR-2 first)
--------------------------------------------------------------------------------

register("カードを{0}枚引く", function(ctx, s)
	GameState.draw(ctx.state, ctx.p, s.nums[1])
	return true
end)

register("相手はカードを{0}枚引く", function(ctx, s)
	GameState.draw(ctx.state, GameState.other(ctx.p), s.nums[1])
	return true
end)

register("カードを{0}枚引き、自分の手札を{1}枚場外に置く", function(ctx, s)
	GameState.draw(ctx.state, ctx.p, s.nums[1])
	discard(ctx, s.nums[2])
	return true
end)

register("自分の手札を{0}枚場外に置く", function(ctx, s)
	discard(ctx, s.nums[1])
	return true
end)

register("自分の山札の上から{0}枚見る", function(ctx, s)
	lookTop(ctx, s.nums[1], false)
	return true
end)

register("自分の山札の上から{0}枚を公開する", function(ctx, s)
	lookTop(ctx, s.nums[1], true)
	return true
end)

register("残りを望む順で自分の山札の下に置く", function(ctx, _s)
	for _, uid in ctx.looked do
		GameState.moveCard(ctx.state, uid, "Deck", { bottom = true })
	end
	ctx.looked = {}
	return true
end)

register({ "そのカードを自分の山札の上か下に置く", "公開したカードを自分の山札の上か下に置く" }, function(ctx, _s)
	for _, uid in table.clone(ctx.looked) do
		local where = ctx.chooseOption(ctx.p, ("Put %s on the top or bottom of your deck?"):format(GameState.name(ctx.state, uid)), { "Top", "Bottom" })
		GameState.moveCard(ctx.state, uid, "Deck", { bottom = where == "Bottom" })
	end
	ctx.looked = {}
	return true
end)

register("その中から⟦t0⟧を{0}枚まで公開し手札に加える", function(ctx, s)
	takeFromLooked(ctx, function(uid)
		return hasTrait(ctx.state, uid, s.traits[1])
	end, s.nums[1], "[" .. s.traits[1] .. "]")
	return true
end)

register("その中から⟨n0⟩を{0}枚まで公開し手札に加える", function(ctx, s)
	takeFromLooked(ctx, function(uid)
		return hasName(ctx.state, uid, s.names[1])
	end, s.nums[1], "<" .. s.names[1] .. ">")
	return true
end)

register("その中から⟦t0⟧か⟨n0⟩を{0}枚まで公開し手札に加える", function(ctx, s)
	takeFromLooked(ctx, function(uid)
		return hasTrait(ctx.state, uid, s.traits[1]) or hasName(ctx.state, uid, s.names[1])
	end, s.nums[1], "[" .. s.traits[1] .. "] or <" .. s.names[1] .. ">")
	return true
end)

register("その中からキャラカードを{0}枚まで公開し手札に加える", function(ctx, s)
	takeFromLooked(ctx, function(uid)
		return GameState.isCharacter(ctx.state, uid)
	end, s.nums[1], "character card(s)")
	return true
end)

register("自分のAPカードを{0}枚まで選び、アクティブにする", function(ctx, s)
	local left = s.nums[1]
	for _, a in ctx.state.players[ctx.p].ap do
		if left > 0 and a.rested then
			a.rested = false
			left -= 1
		end
	end
	GameState.log(ctx.state, ("  P%d sets %d AP card(s) active"):format(ctx.p, s.nums[1] - left))
	return true
end)

register("必要エナジーが{0}以下の自分の場の他のキャラを{1}枚手札に戻す", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, ctx.p), function(uid)
		return uid ~= ctx.source and (GameState.def(ctx.state, uid).needEnergy or 0) <= s.nums[1]
	end)
	if #cands == 0 then
		ctx.failed = true
		return false
	end
	for _, uid in choose(ctx, ctx.p, ("Return %d of your other characters (required energy %d or less) to your hand"):format(s.nums[2], s.nums[1]), cands, s.nums[2], false) do
		GameState.moveCard(ctx.state, uid, "Hand")
		GameState.log(ctx.state, "  returned to hand: " .. GameState.name(ctx.state, uid))
	end
	ctx.failed = false
	return true
end)

register("このキャラを手札に戻す", function(ctx, _s)
	if GameState.isOnField(ctx.state, ctx.source) then
		GameState.moveCard(ctx.state, ctx.source, "Hand")
		GameState.log(ctx.state, "  returned to hand: " .. GameState.name(ctx.state, ctx.source))
	end
	return true
end)

register("メインフェイズ終了時、このキャラを退場させる", function(ctx, _s)
	local uid = ctx.source
	ctx.delay("EndOfMain", function()
		if GameState.isOnField(ctx.state, uid) then
			ctx.retire(uid, "end of Main Phase")
		end
	end)
	return true
end)

register("自分の場のキャラ全ては、このターン中、BP+{0}", function(ctx, s)
	bpTurn(ctx, fieldChars(ctx.state, ctx.p), s.nums[1])
	return true
end)

register("このキャラはこのターン中、BP+{0}", function(ctx, s)
	if GameState.isOnField(ctx.state, ctx.source) then
		bpTurn(ctx, { ctx.source }, s.nums[1])
	end
	return true
end)

register({ "自分の場の他のキャラを{0}枚まで選び、このターン中、BP+{1}", "自分の場の他のキャラを{0}枚選び、このターン中、BP+{1}" }, function(ctx, s)
	local upTo = s.key:find("枚まで", 1, true) ~= nil
	local cands = filter(fieldChars(ctx.state, ctx.p), function(uid)
		return uid ~= ctx.source
	end)
	bpTurn(ctx, choose(ctx, ctx.p, ("Choose %d other character(s): BP+%d this turn"):format(s.nums[1], s.nums[2]), cands, s.nums[1], upTo), s.nums[2])
	return true
end)

register({ "相手のフロントLのキャラを{0}枚まで選び、このターン中、BP-{1}", "相手のフロントLのキャラを{0}枚選び、このターン中、BP-{1}" }, function(ctx, s)
	local upTo = s.key:find("枚まで", 1, true) ~= nil
	local cands = fieldChars(ctx.state, GameState.other(ctx.p), { "Front" })
	bpTurn(ctx, choose(ctx, ctx.p, ("Choose %d opponent Front Line character(s): BP-%d this turn"):format(s.nums[1], s.nums[2]), cands, s.nums[1], upTo), -s.nums[2])
	return true
end)

register("BP{0}以上の相手の場のキャラを{1}枚まで選び、このターン中、BP-{2}", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, GameState.other(ctx.p)), function(uid)
		return GameState.bp(ctx.state, uid) >= s.nums[1]
	end)
	bpTurn(ctx, choose(ctx, ctx.p, ("Choose up to %d opponent character(s) with BP %d or more: BP-%d this turn"):format(s.nums[2], s.nums[1], s.nums[3]), cands, s.nums[2], true), -s.nums[3])
	return true
end)

register({ "『BP{0}以下』の相手のフロントLのキャラを{1}枚選び、退場させる", "BP{0}以下の相手のフロントLのキャラを{1}枚選び、退場させる" }, function(ctx, s)
	local cands = filter(fieldChars(ctx.state, GameState.other(ctx.p), { "Front" }), function(uid)
		return GameState.bp(ctx.state, uid) <= s.nums[1]
	end)
	for _, uid in choose(ctx, ctx.p, ("Choose %d opponent Front Line character(s) with BP %d or less to remove"):format(s.nums[2], s.nums[1]), cands, s.nums[2], false) do
		ctx.retire(uid, "effect")
	end
	return true
end)

register({ "BP{0}以下の相手のフロントLのキャラを{1}枚まで選び、退場させる" }, function(ctx, s)
	local cands = filter(fieldChars(ctx.state, GameState.other(ctx.p), { "Front" }), function(uid)
		return GameState.bp(ctx.state, uid) <= s.nums[1]
	end)
	for _, uid in choose(ctx, ctx.p, ("Choose up to %d opponent Front Line character(s) with BP %d or less to remove"):format(s.nums[2], s.nums[1]), cands, s.nums[2], true) do
		ctx.retire(uid, "effect")
	end
	return true
end)

register("相手のフロントLのキャラを{0}枚まで選び、レストにする", function(ctx, s)
	local cands = fieldChars(ctx.state, GameState.other(ctx.p), { "Front" })
	for _, uid in choose(ctx, ctx.p, ("Choose up to %d opponent Front Line character(s) to rest"):format(s.nums[1]), cands, s.nums[1], true) do
		GameState.inst(ctx.state, uid).rested = true
		GameState.log(ctx.state, "  rested: " .. GameState.name(ctx.state, uid))
	end
	return true
end)

register("このキャラはこのターン中、[Snipe]を得る", function(ctx, _s)
	GameState.inst(ctx.state, ctx.source).granted.calledStrike = true
	GameState.log(ctx.state, "  " .. GameState.name(ctx.state, ctx.source) .. " gains Called Strike this turn")
	return true
end)

register("自分の場の⟦t0⟧を{0}枚退場させてもよい", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, ctx.p), function(uid)
		return hasTrait(ctx.state, uid, s.traits[1])
	end)
	if #cands < s.nums[1] or not ctx.yesNo(ctx.p, ("Remove %d [%s] from your field?"):format(s.nums[1], s.traits[1])) then
		return false
	end
	for _, uid in ctx.chooseCards(ctx.p, ("Choose %d [%s] to remove"):format(s.nums[1], s.traits[1]), cands, s.nums[1], s.nums[1]) do
		ctx.retire(uid, "effect cost")
	end
	return true
end)

register("カードを{0}枚引き、このキャラはこのターン中、BP+{1}", function(ctx, s)
	GameState.draw(ctx.state, ctx.p, s.nums[1])
	if GameState.isOnField(ctx.state, ctx.source) then
		bpTurn(ctx, { ctx.source }, s.nums[2])
	end
	return true
end)

register("相手は自身の場外にあるカードを{0}枚リムーブエリアに置く", function(ctx, s)
	local opp = GameState.other(ctx.p)
	local outside = ctx.state.players[opp].outside
	local n = math.min(s.nums[1], #outside)
	for _, uid in ctx.chooseCards(opp, ("Put %d card(s) from your Outside Area into the Remove Area"):format(n), table.clone(outside), n, n) do
		GameState.moveCard(ctx.state, uid, "Remove")
	end
	return true
end)

register({ "自分の場のキャラを{0}枚まで選び、このターン中、BP+{1}", "自分の場のキャラを{0}枚選び、このターン中、BP+{1}" }, function(ctx, s)
	local upTo = s.key:find("枚まで", 1, true) ~= nil
	bpTurn(ctx, choose(ctx, ctx.p, ("Choose %d of your characters: BP+%d this turn"):format(s.nums[1], s.nums[2]), fieldChars(ctx.state, ctx.p), s.nums[1], upTo), s.nums[2])
	return true
end)

register("その中からフィールドカードを{0}枚まで公開し手札に加える", function(ctx, s)
	takeFromLooked(ctx, function(uid)
		return GameState.def(ctx.state, uid).cardType == "Field"
	end, s.nums[1], "Field card(s)")
	return true
end)

register("BP{0}以下の相手のフロントLのキャラを{1}枚まで選び、手札に戻す", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, GameState.other(ctx.p), { "Front" }), function(uid)
		return GameState.bp(ctx.state, uid) <= s.nums[1]
	end)
	for _, uid in choose(ctx, ctx.p, ("Choose up to %d opponent Front Line character(s) with BP %d or less to return to hand"):format(s.nums[2], s.nums[1]), cands, s.nums[2], true) do
		GameState.moveCard(ctx.state, uid, "Hand")
		GameState.log(ctx.state, "  returned to hand: " .. GameState.name(ctx.state, uid))
	end
	return true
end)

register("その中から望む枚数を望む順で自分の山札の上に置き、残りを望む順で下に置く", function(ctx, _s)
	local top = ctx.chooseCards(ctx.p, "Choose the cards to put on top of your deck (the rest go to the bottom)", table.clone(ctx.looked), 0, #ctx.looked)
	for i = #top, 1, -1 do
		GameState.moveCard(ctx.state, top[i], "Deck")
	end
	for _, uid in ctx.looked do
		if not table.find(top, uid) then
			GameState.moveCard(ctx.state, uid, "Deck", { bottom = true })
		end
	end
	ctx.looked = {}
	return true
end)

register("相手の場のフィールドを{0}枚まで選び、相手の山札の下に置く", function(ctx, s)
	local opp = GameState.other(ctx.p)
	local cands = filter(ctx.state.players[opp].energy, function(uid)
		return GameState.def(ctx.state, uid).cardType == "Field"
	end)
	for _, uid in choose(ctx, ctx.p, ("Choose up to %d opponent Field(s) to put on the bottom of their deck"):format(s.nums[1]), cands, s.nums[1], true) do
		GameState.moveCard(ctx.state, uid, "Deck", { bottom = true })
		GameState.log(ctx.state, "  to deck bottom: " .. GameState.name(ctx.state, uid))
	end
	return true
end)

-- Card-construction text: nothing to do in a game.
register({ "※このカードはデッキに{0}枚まで入れられる", "※このカードはデッキに{0}枚までしか入れられない" }, function(_ctx, _s)
	return true
end)

--------------------------------------------------------------------------------
-- Static abilities (always on while their conditions hold)
--------------------------------------------------------------------------------

local STATIC_BP = "このキャラはBP+{0}"
local ENTERS_ACTIVE = { ["このフィールドはアクティブで場に登場させる"] = true, ["このキャラはアクティブで場に登場させる"] = true }
local STATIC_KEYS: { [string]: boolean } = { [STATIC_BP] = true }
for k in ENTERS_ACTIVE do
	STATIC_KEYS[k] = true
end
STATIC_KEYS["※このカードはデッキに{0}枚まで入れられる"] = true
STATIC_KEYS["※このカードはデッキに{0}枚までしか入れられない"] = true
-- "While this character is Active, it generates +[Color] energy."
local STATIC_ENERGY: { [string]: string } = {}
for _, color in { "Red", "Blue", "Yellow", "Green", "Purple" } do
	local k = "このキャラがアクティブの場合、このキャラの発生エナジー+[" .. color .. "]"
	STATIC_ENERGY[k] = color
	STATIC_KEYS[k] = true
end

local function condsHold(state: GameState, uid: number, conds: { string }): boolean
	local c = GameState.inst(state, uid)
	for _, cond in conds do
		if cond == "yourTurn" and state.turnPlayer ~= c.owner then
			return false
		elseif cond == "oppTurn" and state.turnPlayer == c.owner then
			return false
		elseif cond == "front" and c.zone ~= "Front" then
			return false
		elseif cond == "energy" and c.zone ~= "Energy" then
			return false
		elseif cond == "outside" and c.zone ~= "Outside" then
			return false
		elseif cond == "remove" and c.zone ~= "Remove" then
			return false
		end
	end
	return true
end
EffectRegistry.condsHold = condsHold

local function abilitiesOf(def: any): { Ability }
	return def.abilities or {}
end
EffectRegistry.abilitiesOf = abilitiesOf

-- BP from static "this character gets BP+X" abilities whose conditions hold.
function EffectRegistry.staticBP(state: GameState, uid: number): number
	local c = state.cards[uid]
	if not c or (c.zone ~= "Front" and c.zone ~= "Energy") then
		return 0
	end
	local total = 0
	for _, a in abilitiesOf(GameState.def(state, uid)) do
		if a.timing == "Static" and #a.steps == 1 and a.steps[1].key == STATIC_BP and condsHold(state, uid, a.conds) then
			total += a.steps[1].nums[1]
		end
	end
	return total
end

-- Extra energy from static abilities of a card on the Energy Line.
function EffectRegistry.staticEnergy(state: GameState, uid: number): { [string]: number }?
	local c = state.cards[uid]
	local out: { [string]: number }? = nil
	for _, a in abilitiesOf(GameState.def(state, uid)) do
		if a.timing == "Static" and #a.steps == 1 and condsHold(state, uid, a.conds) then
			local color = STATIC_ENERGY[a.steps[1].key]
			if color and not c.rested then
				out = out or {}
				local o = out :: { [string]: number }
				o[color] = (o[color] or 0) + 1
			end
		end
	end
	return out
end

function EffectRegistry.entersActive(def: any): boolean
	for _, a in abilitiesOf(def) do
		for _, s in a.steps do
			if ENTERS_ACTIVE[s.key] then
				return true
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Support check and running
--------------------------------------------------------------------------------

function EffectRegistry.isSupported(a: Ability): boolean
	if a.unknownTags and #a.unknownTags > 0 then
		return false
	end
	if a.timing == "Static" then
		for _, s in a.steps do
			if not STATIC_KEYS[s.key] then
				return false
			end
		end
		return true
	end
	if not AUTO_TIMINGS[a.timing] then
		return false
	end
	for _, s in a.steps do
		if s.bullet then
			return false -- "choose one of the following" lists: manual for now
		end
		local h = resolveHandler(s.key)
		if not h then
			return false
		end
	end
	return true
end

function EffectRegistry.run(ctx: Ctx, a: Ability)
	for _, s in a.steps do
		local h, test = resolveHandler(s.key)
		assert(h, "no handler for " .. s.key)
		if test and not test(ctx) then
			ctx.did = false
		else
			local res = h(ctx, s)
			ctx.did = res ~= false
		end
		if ctx.state.winner then
			break
		end
	end
	-- Anything still being looked at goes to the bottom of the deck.
	for _, uid in ctx.looked do
		GameState.moveCard(ctx.state, uid, "Deck", { bottom = true })
	end
	ctx.looked = {}
end

-- Coverage for a list of set ids: how many abilities / cards run automatically.
function EffectRegistry.coverage(setIds: { string }): { [string]: any }
	local out = { abilities = 0, autoAbilities = 0, cards = 0, autoCards = 0, missing = {} :: { [string]: number }, manualCards = {} :: { string } }
	for _, setId in setIds do
		for key, card in CardData.getSet(setId) or {} do
			local abilities = abilitiesOf(card)
			if #abilities > 0 then
				out.cards += 1
				local allAuto = true
				for _, a in abilities do
					out.abilities += 1
					if EffectRegistry.isSupported(a) then
						out.autoAbilities += 1
					else
						allAuto = false
						for _, s in a.steps do
							local ok = if a.timing == "Static" then STATIC_KEYS[s.key] else resolveHandler(s.key) ~= nil
							if not ok or s.bullet then
								out.missing[s.key] = (out.missing[s.key] or 0) + 1
							end
						end
					end
				end
				if allAuto then
					out.autoCards += 1
				else
					table.insert(out.manualCards, key)
				end
			end
		end
	end
	table.sort(out.manualCards)
	return out
end

-- GameState.bp asks this for static BP (set here to avoid a require cycle).
local GS: any = GameState
GS.staticBP = EffectRegistry.staticBP
GS.staticEnergy = EffectRegistry.staticEnergy

return EffectRegistry
