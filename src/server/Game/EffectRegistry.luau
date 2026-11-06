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

export type Step = { key: string, nums: { number }, names: { string }, traits: { string }, bullet: boolean?, en: string? }
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
	chosen: { number }, -- cards chosen by the last choosing step ("it", "that character")
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

-- The key without a dependency prefix ("そうした場合、..." -> "...").
local function innerKey(key: string): string
	for _, pre in PREFIXES do
		if key:sub(1, #pre.prefix) == pre.prefix then
			return key:sub(#pre.prefix + 1)
		end
	end
	return key
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

local ALIAS = "このカードは⟨n0⟩としても扱う"

-- Card name check, including "this card is also treated as <name>".
local function hasName(state: GameState, uid: number, name: string): boolean
	local def = GameState.def(state, uid)
	if def.nameJp == name then
		return true
	end
	for _, a in (def :: any).abilities or {} do
		for _, st in a.steps do
			if st.key == ALIAS and st.names[1] == name then
				return true
			end
		end
	end
	return false
end
EffectRegistry.hasName = hasName

local function fieldHasName(state: GameState, p: number, name: string): boolean
	local ps = state.players[p]
	for _, line in { ps.front, ps.energy } do
		for _, uid in line do
			if hasName(state, uid, name) then
				return true
			end
		end
	end
	return false
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
	local pick = ctx.chooseCards(player, prompt, cands, min, count)
	ctx.chosen = pick
	return pick
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

--------------------------------------------------------------------------------
-- Step 6: templates common across all series
--------------------------------------------------------------------------------

-- Markers handled before the ability runs (see EffectRegistry.run).
local LIMIT_KEYS = { ["⟨n0⟩のこの効果は{0}ターンに{1}回のみ発動できる"] = true, ["⟨n0⟩のこの効果は{0}ターンに{1}回のみ発動する"] = true }
local PLAYED_THIS_TURN = "このキャラが登場したターン中のみ発動できる"
local BP_SUBST = "自分の場に⟨n0⟩がある場合、『BP{0}以下』に代わる"
local CHOOSE_KEYS = { ["以下から{0}つ選ぶ"] = true, ["以下から{0}つまで選ぶ"] = true }
local PRE_KEYS: { [string]: boolean } = { [PLAYED_THIS_TURN] = true, [BP_SUBST] = true }
for k in LIMIT_KEYS do
	PRE_KEYS[k] = true
end
for k in PRE_KEYS do
	register(k, function(_ctx, _s)
		return true
	end)
end
for k in CHOOSE_KEYS do
	register(k, function(_ctx, _s)
		return true
	end)
end

register("残りを望む順で山札の下に置く", function(ctx, _s)
	for _, uid in ctx.looked do
		GameState.moveCard(ctx.state, uid, "Deck", { bottom = true })
	end
	ctx.looked = {}
	return true
end)

register("残りを望む順で山札の上に置く", function(ctx, _s)
	for i = #ctx.looked, 1, -1 do
		GameState.moveCard(ctx.state, ctx.looked[i], "Deck")
	end
	ctx.looked = {}
	return true
end)

register("自分の山札の上から{0}枚見て、⟦t0⟧を{1}枚まで公開し手札に加える", function(ctx, s)
	lookTop(ctx, s.nums[1], false)
	takeFromLooked(ctx, function(uid)
		return hasTrait(ctx.state, uid, s.traits[1])
	end, s.nums[2], "[" .. s.traits[1] .. "]")
	return true
end)

register("自分の山札の上から{0}枚見て、山札の上か場外に置く", function(ctx, s)
	lookTop(ctx, s.nums[1], false)
	for _, uid in table.clone(ctx.looked) do
		local where = ctx.chooseOption(ctx.p, ("Put %s on top of your deck or into your Outside Area?"):format(GameState.name(ctx.state, uid)), { "Top", "Outside" })
		GameState.moveCard(ctx.state, uid, if where == "Top" then "Deck" else "Outside")
	end
	ctx.looked = {}
	return true
end)

-- "その中から<A>か<B>(か<C>...)を N 枚まで公開し手札に加える" for 2-4 names.
for n = 2, 4 do
	local parts = {}
	for i = 0, n - 1 do
		table.insert(parts, "⟨n" .. i .. "⟩")
	end
	register("その中から" .. table.concat(parts, "か") .. "を{0}枚まで公開し手札に加える", function(ctx, s)
		takeFromLooked(ctx, function(uid)
			for _, name in s.names do
				if hasName(ctx.state, uid, name) then
					return true
				end
			end
			return false
		end, s.nums[1], "<" .. table.concat(s.names, "> or <") .. ">")
		return true
	end)
end

register("その中から望む枚数を望む順で自分の山札の上に置き、残りを場外に置く", function(ctx, _s)
	local top = ctx.chooseCards(ctx.p, "Choose the cards to put on top of your deck (the rest go to your Outside Area)", table.clone(ctx.looked), 0, #ctx.looked)
	for i = #top, 1, -1 do
		GameState.moveCard(ctx.state, top[i], "Deck")
	end
	for _, uid in ctx.looked do
		if not table.find(top, uid) then
			GameState.moveCard(ctx.state, uid, "Outside")
		end
	end
	ctx.looked = {}
	return true
end)

register("このキャラをアクティブにする", function(ctx, _s)
	if GameState.isOnField(ctx.state, ctx.source) then
		GameState.inst(ctx.state, ctx.source).rested = false
		GameState.log(ctx.state, "  " .. GameState.name(ctx.state, ctx.source) .. " -> Active")
	end
	return true
end)

register("自分の場に⟨n0⟩がある場合、カードを{0}枚引く", function(ctx, s)
	if fieldHasName(ctx.state, ctx.p, s.names[1]) then
		GameState.draw(ctx.state, ctx.p, s.nums[1])
		return true
	end
	return false
end)

register("自分の手札を{0}枚場外に置いてもよい", function(ctx, s)
	local hand = ctx.state.players[ctx.p].hand
	if #hand < s.nums[1] or not ctx.yesNo(ctx.p, ("Put %d card(s) from your hand into your Outside Area?"):format(s.nums[1])) then
		return false
	end
	discard(ctx, s.nums[1])
	return true
end)

register("APを{0}支払ってもよい", function(ctx, s)
	if GameState.activeAP(ctx.state, ctx.p) < s.nums[1] or not ctx.yesNo(ctx.p, ("Pay %d AP?"):format(s.nums[1])) then
		return false
	end
	GameState.payAP(ctx.state, ctx.p, s.nums[1])
	return true
end)

register("このキャラはこのターン中、[Impact {0}]を得る", function(ctx, _s)
	if GameState.isOnField(ctx.state, ctx.source) then
		GameState.inst(ctx.state, ctx.source).granted.impact = 1
		GameState.log(ctx.state, "  " .. GameState.name(ctx.state, ctx.source) .. " gains Impact 1 this turn")
	end
	return true
end)

register("自分の山札の上から{0}枚を場外に置く", function(ctx, s)
	local deck = ctx.state.players[ctx.p].deck
	for _ = 1, s.nums[1] do
		if deck[1] then
			GameState.moveCard(ctx.state, deck[1], "Outside")
		end
	end
	return true
end)

register("自分の山札の上から{0}枚まで場外に置く", function(ctx, s)
	local options = {}
	for i = 0, math.min(s.nums[1], #ctx.state.players[ctx.p].deck) do
		table.insert(options, tostring(i))
	end
	local n = tonumber(ctx.chooseOption(ctx.p, "How many cards from the top of your deck to put into your Outside Area?", options)) or 0
	local deck = ctx.state.players[ctx.p].deck
	for _ = 1, n do
		if deck[1] then
			GameState.moveCard(ctx.state, deck[1], "Outside")
		end
	end
	return n > 0
end)

register("『BP{0}以下』の相手のフロントLのキャラを{1}枚まで選び、退場させる", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, GameState.other(ctx.p), { "Front" }), function(uid)
		return GameState.bp(ctx.state, uid) <= s.nums[1]
	end)
	for _, uid in choose(ctx, ctx.p, ("Choose up to %d opponent Front Line character(s) with BP %d or less to remove"):format(s.nums[2], s.nums[1]), cands, s.nums[2], true) do
		ctx.retire(uid, "effect")
	end
	return true
end)

register("BP{0}以上の相手のフロントLのキャラを{1}枚まで選び、このターン中、BP-{2}", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, GameState.other(ctx.p), { "Front" }), function(uid)
		return GameState.bp(ctx.state, uid) >= s.nums[1]
	end)
	bpTurn(ctx, choose(ctx, ctx.p, ("Choose up to %d opponent Front Line character(s) with BP %d or more: BP-%d this turn"):format(s.nums[2], s.nums[1], s.nums[3]), cands, s.nums[2], true), -s.nums[3])
	return true
end)

register("それは次の{0}回アクティブにならない", function(ctx, s)
	for _, uid in ctx.chosen do
		if GameState.isOnField(ctx.state, uid) then
			GameState.inst(ctx.state, uid).frozen += s.nums[1]
			GameState.log(ctx.state, ("  %s stays Rested the next %d time(s)"):format(GameState.name(ctx.state, uid), s.nums[1]))
		end
	end
	return true
end)

register("このカードの色と必要エナジーは、全ての色として扱う", function(_ctx, _s)
	return true -- its colors list already has all five
end)

register("自分の場外から⟨n0⟩を{0}枚まで手札に加える", function(ctx, s)
	local cands = filter(ctx.state.players[ctx.p].outside, function(uid)
		return hasName(ctx.state, uid, s.names[1])
	end)
	local pick = choose(ctx, ctx.p, ("Add up to %d <%s> from your Outside Area to your hand"):format(s.nums[1], s.names[1]), cands, s.nums[1], true)
	for _, uid in pick do
		GameState.moveCard(ctx.state, uid, "Hand")
	end
	ctx.addedToHand = #pick > 0
	return #pick > 0
end)

register("自分のフロントLのアクティブのキャラを{0}枚レストにする", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, ctx.p, { "Front" }), function(uid)
		return not GameState.inst(ctx.state, uid).rested
	end)
	if #cands < s.nums[1] then
		return false
	end
	for _, uid in choose(ctx, ctx.p, ("Rest %d Active character(s) on your Front Line"):format(s.nums[1]), cands, s.nums[1], false) do
		GameState.inst(ctx.state, uid).rested = true
	end
	return true
end)

register("そのカードを自分の山札の上か場外に置く", function(ctx, _s)
	for _, uid in table.clone(ctx.looked) do
		local where = ctx.chooseOption(ctx.p, ("Put %s on top of your deck or into your Outside Area?"):format(GameState.name(ctx.state, uid)), { "Top", "Outside" })
		GameState.moveCard(ctx.state, uid, if where == "Top" then "Deck" else "Outside")
	end
	ctx.looked = {}
	return true
end)

register("自分の場の他の⟦t0⟧を{0}枚まで選び、このターン中、BP+{1}", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, ctx.p), function(uid)
		return uid ~= ctx.source and hasTrait(ctx.state, uid, s.traits[1])
	end)
	bpTurn(ctx, choose(ctx, ctx.p, ("Choose up to %d other [%s]: BP+%d this turn"):format(s.nums[1], s.traits[1], s.nums[2]), cands, s.nums[1], true), s.nums[2])
	return true
end)

register("自分の場の⟦t0⟧全ては、このターン中、BP+{0}", function(ctx, s)
	bpTurn(ctx, filter(fieldChars(ctx.state, ctx.p), function(uid)
		return hasTrait(ctx.state, uid, s.traits[1])
	end), s.nums[1])
	return true
end)

register("相手のフロントLのキャラを{0}枚選び、レストにする", function(ctx, s)
	local cands = fieldChars(ctx.state, GameState.other(ctx.p), { "Front" })
	for _, uid in choose(ctx, ctx.p, ("Choose %d opponent Front Line character(s) to rest"):format(s.nums[1]), cands, s.nums[1], false) do
		GameState.inst(ctx.state, uid).rested = true
		GameState.log(ctx.state, "  rested: " .. GameState.name(ctx.state, uid))
	end
	return true
end)

register("『BP{0}』以下の相手のフロントLのキャラを{1}枚選び、退場させる", function(ctx, s)
	local cands = filter(fieldChars(ctx.state, GameState.other(ctx.p), { "Front" }), function(uid)
		return GameState.bp(ctx.state, uid) <= s.nums[1]
	end)
	for _, uid in choose(ctx, ctx.p, ("Choose %d opponent Front Line character(s) with BP %d or less to remove"):format(s.nums[2], s.nums[1]), cands, s.nums[2], false) do
		ctx.retire(uid, "effect")
	end
	return true
end)

-- "This turn, this character generates +[Color] energy."
for _, color in { "Red", "Blue", "Yellow", "Green", "Purple" } do
	register("このターン中、このキャラの発生エナジー+[" .. color .. "]", function(ctx, _s)
		if GameState.isOnField(ctx.state, ctx.source) then
			local c = GameState.inst(ctx.state, ctx.source)
			c.energyTurn[color] = (c.energyTurn[color] or 0) + 1
			GameState.log(ctx.state, ("  %s generates +%s energy this turn"):format(GameState.name(ctx.state, ctx.source), color))
		end
		return true
	end)
end

-- Card-construction text: nothing to do in a game.
register({ "※このカードはデッキに{0}枚まで入れられる", "※このカードはデッキに{0}枚までしか入れられない" }, function(_ctx, _s)
	return true
end)

--------------------------------------------------------------------------------
-- Static abilities (always on while their conditions hold)
--------------------------------------------------------------------------------

local STATIC_BP = "このキャラはBP+{0}"
local ENTERS_ACTIVE = { ["このフィールドはアクティブで場に登場させる"] = true, ["このキャラはアクティブで場に登場させる"] = true, ["このキャラはアクティブで登場させる"] = true }
local STATIC_BP_IF_NAME = "自分の場に⟨n0⟩がある場合、このキャラはBP+{0}"
local NO_BLOCK_BY_BP = "このキャラはBP{0}以下のキャラにブロックされない"
local NO_BLOCK_BY_BP_UP = "このキャラはBP{0}以上のキャラにブロックされない"
local STATIC_BP_IF_TRAITS = "自分の場に他の⟦t0⟧が{0}枚以上ある場合、このキャラはBP+{1}"
local STATIC_IMPACT_IF_BP = "このキャラのBPが{0}以上の場合、このキャラは[Impact {1}]を得る"
local STATIC_KEYS: { [string]: boolean } = { [STATIC_BP] = true }
for k in ENTERS_ACTIVE do
	STATIC_KEYS[k] = true
end
STATIC_KEYS["※このカードはデッキに{0}枚まで入れられる"] = true
STATIC_KEYS["※このカードはデッキに{0}枚までしか入れられない"] = true
STATIC_KEYS[ALIAS] = true
STATIC_KEYS[STATIC_BP_IF_NAME] = true
STATIC_KEYS[NO_BLOCK_BY_BP] = true
STATIC_KEYS[NO_BLOCK_BY_BP_UP] = true
STATIC_KEYS[STATIC_BP_IF_TRAITS] = true
STATIC_KEYS[STATIC_IMPACT_IF_BP] = true
STATIC_KEYS["このカードの色と必要エナジーは、全ての色として扱う"] = true -- its colors list already has all five
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
		if a.timing == "Static" and #a.steps == 1 and condsHold(state, uid, a.conds) then
			local st = a.steps[1]
			if st.key == STATIC_BP then
				total += st.nums[1]
			elseif st.key == STATIC_BP_IF_NAME and fieldHasName(state, c.owner, st.names[1]) then
				total += st.nums[1]
			elseif st.key == STATIC_BP_IF_TRAITS then
				local n = #filter(fieldChars(state, c.owner), function(other)
					return other ~= uid and hasTrait(state, other, st.traits[1])
				end)
				if n >= st.nums[1] then
					total += st.nums[2]
				end
			end
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

-- "This character can't be blocked by characters with BP X or less."
function EffectRegistry.canBlock(state: GameState, attacker: number, blocker: number): boolean
	for _, a in abilitiesOf(GameState.def(state, attacker)) do
		if a.timing == "Static" and #a.steps == 1 and a.steps[1].key == NO_BLOCK_BY_BP and condsHold(state, attacker, a.conds) then
			if GameState.bp(state, blocker) <= a.steps[1].nums[1] then
				return false
			end
		end
		if a.timing == "Static" and #a.steps == 1 and a.steps[1].key == NO_BLOCK_BY_BP_UP and condsHold(state, attacker, a.conds) then
			if GameState.bp(state, blocker) >= a.steps[1].nums[1] then
				return false
			end
		end
	end
	return true
end

-- Keywords from static abilities ("if this character has BP X or more, it has Impact 1").
function EffectRegistry.staticKeyword(state: GameState, uid: number, name: string): any
	if name ~= "impact" then
		return nil
	end
	local c = state.cards[uid]
	if not c or (c.zone ~= "Front" and c.zone ~= "Energy") then
		return nil
	end
	for _, a in abilitiesOf(GameState.def(state, uid)) do
		if a.timing == "Static" and #a.steps == 1 and a.steps[1].key == STATIC_IMPACT_IF_BP and condsHold(state, uid, a.conds) then
			local base = (GameState.def(state, uid).bp or 0) + c.bpTurn + c.bpManual
			if base >= a.steps[1].nums[1] then
				return 1
			end
		end
	end
	return nil
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
	local seenChoose = false
	for _, s in a.steps do
		if s.bullet and not seenChoose then
			return false -- a bullet without "choose N of the following" before it
		end
		if CHOOSE_KEYS[innerKey(s.key)] then
			seenChoose = true
		end
		if not resolveHandler(s.key) then
			return false
		end
	end
	return true
end

local function runStep(ctx: Ctx, s: Step)
	local h, test = resolveHandler(s.key)
	assert(h, "no handler for " .. s.key)
	if test and not test(ctx) then
		ctx.did = false
	else
		local res = h(ctx, s)
		ctx.did = res ~= false
	end
end

local function cloneStep(s: Step): Step
	return { key = s.key, nums = table.clone(s.nums), names = s.names, traits = s.traits, bullet = s.bullet, en = s.en }
end

function EffectRegistry.run(ctx: Ctx, a: Ability)
	local state = ctx.state
	local steps = table.clone(a.steps)
	-- Before anything happens: limits, "only on the turn it was played", BP substitution.
	for i, s in a.steps do
		if LIMIT_KEYS[s.key] then
			local key = "limit:" .. s.names[1]
			local used = state.limits[key] or 0
			if used >= s.nums[2] then
				GameState.log(state, ("  <%s> effect already used %d time(s) this turn"):format(s.names[1], used))
				return
			end
			state.limits[key] = used + 1
		elseif s.key == PLAYED_THIS_TURN then
			if GameState.inst(state, ctx.source).playedTurn ~= state.turnNumber then
				GameState.log(state, "  only on the turn this character was played")
				return
			end
		elseif s.key == BP_SUBST and fieldHasName(state, ctx.p, s.names[1]) then
			for j = i - 1, 1, -1 do
				if steps[j].key:find("『BP{0}以下』", 1, true) then
					local c = cloneStep(steps[j])
					c.nums[1] = s.nums[1]
					steps[j] = c
					break
				end
			end
		end
	end

	local i = 1
	while i <= #steps do
		local s = steps[i]
		if PRE_KEYS[s.key] then
			i += 1
		elseif CHOOSE_KEYS[innerKey(s.key)] then
			-- Gather the options: each bullet plus any "If you do" steps right after it.
			local groups: { { Step } } = {}
			local j = i + 1
			while j <= #steps and steps[j].bullet do
				local g = { steps[j] }
				j += 1
				while j <= #steps and not steps[j].bullet and steps[j].key:sub(1, #"そうした場合、") == "そうした場合、" do
					table.insert(g, steps[j])
					j += 1
				end
				table.insert(groups, g)
			end
			local _, test = resolveHandler(s.key)
			if test and not test(ctx) then
				ctx.did = false
			else
				local count = s.nums[1] or 1
				local upTo = innerKey(s.key):find("つまで", 1, true) ~= nil
				local remaining = table.clone(groups)
				for _ = 1, count do
					if #remaining == 0 then
						break
					end
					local options = {}
					for n, g in remaining do
						table.insert(options, ("%d. %s"):format(n, if g[1].en and g[1].en ~= "" then g[1].en else g[1].key))
					end
					if upTo then
						table.insert(options, "None")
					end
					local pick = ctx.chooseOption(ctx.p, "Choose one:", options)
					local idx = table.find(options, pick)
					if not idx or pick == "None" then
						break
					end
					local g = table.remove(remaining, idx) :: { Step }
					ctx.did = true
					for _, gs in g do
						runStep(ctx, gs)
						if state.winner then
							return
						end
					end
				end
			end
			i = j
		else
			runStep(ctx, s)
			i += 1
		end
		if state.winner then
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
GS.staticKeyword = EffectRegistry.staticKeyword

return EffectRegistry
