--!strict
-- Minimal board UI (step 3). Rebuilt from scratch on every server update.
-- The client never decides rules: it only shows the view and sends actions;
-- the server says no with a reason when something is not allowed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData"))
local Net = require(Shared:WaitForChild("Net"))

local actionEvent = Net.event("GameAction")
local updateEvent = Net.event("GameUpdate")
local errorEvent = Net.event("GameError")

local COLORS: { [string]: Color3 } = {
	Red = Color3.fromRGB(176, 52, 52),
	Blue = Color3.fromRGB(48, 96, 190),
	Yellow = Color3.fromRGB(190, 160, 30),
	Green = Color3.fromRGB(46, 140, 70),
	Purple = Color3.fromRGB(120, 66, 170),
}
local BG = Color3.fromRGB(22, 24, 30)
local PANEL = Color3.fromRGB(34, 37, 46)
local TEXT = Color3.fromRGB(235, 235, 240)
local MUTED = Color3.fromRGB(150, 155, 170)
local FONT = Enum.Font.GothamMedium

local KW_SHORT = {
	{ "step", "Step" },
	{ "calledStrike", "Called Strike" },
	{ "doubleAttack", "2x Attack" },
	{ "doubleBlock", "2x Block" },
	{ "impact", "Impact" },
	{ "impactPlus", "Impact+1" },
	{ "damage", "Damage 2" },
	{ "damagePlus", "Damage+1" },
	{ "nullifyImpact", "No Impact" },
}

local NEXT_LABEL = { Start = "To Move ▶", Move = "To Main ▶", Main = "To Attack ▶", Attack = "End Turn ▶" }

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local payload: any = nil
local viewSeat = 1
local autoFollow = true
local selected: number? = nil
local picks: { number } = {}
local pickDecisionId: number? = nil
-- Local click modes: choose a card to send to the Remove Area, or a Called Strike target.
local mode: { kind: string, candidates: { number }, prompt: string, onPick: (number) -> () }? = nil
local decisionShownAt = 0
local countdown: (() -> ())? = nil -- updates the open decision's timer text in place

local gui: ScreenGui
local root: Frame
local toast: TextLabel

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local nextOrder = 0
local function new(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		nextOrder += 1
		inst.LayoutOrder = nextOrder
	end
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function label(parent: Instance, text: string, props: { [string]: any }?): TextLabel
	local p = {
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = TEXT,
		Font = FONT,
		TextScaled = true,
		TextWrapped = true,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	}
	local maxText = 16
	for k, v in props or {} do
		if k == "MaxText" then
			maxText = v
		else
			p[k] = v
		end
	end
	local l = new("TextLabel", p)
	new("UITextSizeConstraint", { MaxTextSize = maxText, Parent = l })
	return l
end

local function button(parent: Instance, text: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local p = {
		Name = "Btn_" .. text:gsub("[^%w]", ""),
		BackgroundColor3 = Color3.fromRGB(64, 70, 88),
		Text = text,
		TextColor3 = TEXT,
		Font = FONT,
		TextScaled = true,
		AutoButtonColor = true,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = parent,
	}
	for k, v in props or {} do
		p[k] = v
	end
	local b = new("TextButton", p)
	new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = b })
	new("UITextSizeConstraint", { MaxTextSize = 15, Parent = b })
	new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4), Parent = b })
	b.MouseButton1Click:Connect(onClick)
	return b
end

local function cardName(def: CardData.Card): string
	return if def.nameEn ~= "" then def.nameEn else def.nameJp
end

local function view(): any
	return payload and payload.views[tostring(viewSeat)]
end

local function send(action: { [string]: any })
	actionEvent:FireServer(viewSeat, action)
end

local function showToast(msg: string)
	toast.Text = msg
	toast.Visible = true
	local stamp = os.clock()
	toast:SetAttribute("Stamp", stamp)
	task.delay(3.5, function()
		if toast:GetAttribute("Stamp") == stamp then
			toast.Visible = false
		end
	end)
end

-- Finds a card view anywhere in the current view.
local function findCard(uid: number): (any, number?, string?)
	local v = view()
	if not v then
		return nil
	end
	for p, ps in v.players do
		for _, zone in { "hand", "front", "energy", "outside", "remove" } do
			for _, cv in ps[zone] do
				if cv.uid == uid then
					return cv, p, zone
				end
			end
		end
	end
	for _, cv in v.resolving do
		if cv.uid == uid then
			return cv, cv.owner, "resolving"
		end
	end
	return nil
end

local function myDecision(): any
	local v = view()
	local d = v and v.pending
	if d and d.player == viewSeat then
		return d
	end
	return nil
end

--------------------------------------------------------------------------------
-- Cards
--------------------------------------------------------------------------------

local render: () -> ()

local function onCardClicked(uid: number)
	local d = myDecision()
	if d and d.candidates and d.kind ~= "ChooseLife" and table.find(d.candidates, uid) then
		local i = table.find(picks, uid)
		if i then
			table.remove(picks, i)
		elseif #picks < (d.max or 1) then
			table.insert(picks, uid)
		end
		selected = uid
		render()
		return
	end
	if mode and table.find(mode.candidates, uid) then
		local m = mode
		mode = nil
		m.onPick(uid)
		render()
		return
	end
	selected = uid
	render()
end

local function makeCard(parent: Instance, cv: any, order: number)
	local frame = new("TextButton", {
		Name = "Card_" .. cv.uid,
		LayoutOrder = order,
		Size = UDim2.new(0, 96, 1, -6),
		BackgroundColor3 = Color3.fromRGB(70, 70, 80),
		Text = "",
		AutoButtonColor = true,
		Parent = parent,
	})
	new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = frame })
	new("UIAspectRatioConstraint", { AspectRatio = 0.72, DominantAxis = Enum.DominantAxis.Height, Parent = frame })

	if cv.hidden then
		frame.BackgroundColor3 = Color3.fromRGB(60, 30, 50)
		label(frame, "UNION\nARENA", { TextColor3 = MUTED })
		return
	end

	local def = CardData.get(cv.key)
	if not def then
		label(frame, cv.key)
		return
	end
	local color = COLORS[def.colors[1] or ""] or Color3.fromRGB(90, 90, 100)
	frame.BackgroundColor3 = if cv.rested then color:Lerp(Color3.new(0, 0, 0), 0.55) else color

	local d = myDecision()
	local isCandidate = (d and d.candidates and d.kind ~= "ChooseLife" and table.find(d.candidates, cv.uid))
		or (mode and table.find(mode.candidates, cv.uid))
	local stroke = new("UIStroke", { Thickness = 0, Color = Color3.new(1, 1, 1), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = frame })
	if table.find(picks, cv.uid) then
		stroke.Thickness, stroke.Color = 4, Color3.fromRGB(255, 220, 60)
	elseif isCandidate then
		stroke.Thickness, stroke.Color = 3, Color3.fromRGB(90, 255, 140)
	elseif selected == cv.uid then
		stroke.Thickness, stroke.Color = 3, Color3.fromRGB(255, 255, 255)
	end

	local cost = def.cardType == "Action Point" and "" or ("⚡%d  AP%d"):format(def.needEnergy or 0, def.ap or 0)
	label(frame, cost, { Size = UDim2.new(1, -4, 0.16, 0), Position = UDim2.fromOffset(2, 1), TextXAlignment = Enum.TextXAlignment.Left, MaxText = 12 })
	label(frame, cardName(def), { Size = UDim2.new(1, -4, 0.34, 0), Position = UDim2.new(0, 2, 0.16, 0), MaxText = 13 })
	local kws = {}
	for _, pair in KW_SHORT do
		if def.keywords[pair[1]] then
			table.insert(kws, pair[2])
		end
	end
	if def.raid then
		table.insert(kws, "Raid")
	end
	label(frame, table.concat(kws, " · "), { Size = UDim2.new(1, -4, 0.16, 0), Position = UDim2.new(0, 2, 0.5, 0), TextColor3 = Color3.fromRGB(255, 235, 150), MaxText = 10 })
	local bottom = ""
	if def.cardType == "Character" then
		bottom = tostring(cv.bp or def.bp or 0) .. " BP"
	else
		bottom = def.cardType
	end
	if def.triggerType ~= "" then
		bottom ..= "  [" .. def.triggerType .. "]"
	end
	label(frame, bottom, { Size = UDim2.new(1, -4, 0.18, 0), Position = UDim2.new(0, 2, 0.8, 0), MaxText = 12 })
	if cv.rested then
		label(frame, "REST", { Size = UDim2.new(1, 0, 0.14, 0), Position = UDim2.new(0, 0, 0.66, 0), TextColor3 = Color3.fromRGB(255, 180, 180), MaxText = 11 })
	end
	if cv.under and cv.under > 0 then
		label(frame, "+" .. cv.under, { Size = UDim2.new(0.3, 0, 0.14, 0), Position = UDim2.new(0.7, 0, 0.66, 0), MaxText = 11 })
	end
	frame.MouseButton1Click:Connect(function()
		onCardClicked(cv.uid)
	end)
end

local function row(parent: Instance, title: string, cards: { any }, pos: UDim2, size: UDim2)
	local f = new("Frame", { Name = "Row_" .. title:gsub("%s", ""), Position = pos, Size = size, BackgroundColor3 = PANEL, Parent = parent })
	new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = f })
	label(f, title, { Size = UDim2.new(0, 70, 1, 0), TextColor3 = MUTED, MaxText = 13 })
	local holder = new("Frame", { Name = "Cards", Position = UDim2.fromOffset(74, 3), Size = UDim2.new(1, -78, 1, 0), BackgroundTransparency = 1, Parent = f })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = holder })
	for i, cv in cards do
		makeCard(holder, cv, i)
	end
end

--------------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------------

local function infoText(ps: any, seatNo: number): string
	local e = {}
	for _, c in { "Red", "Blue", "Yellow", "Green", "Purple" } do
		if (ps.energyByColor[c] or 0) > 0 then
			table.insert(e, c:sub(1, 1) .. ps.energyByColor[c])
		end
	end
	return ("P%d   Life %d   Deck %d   Hand %d   AP %d/%d   Energy %s   Outside %d   Remove %d"):format(
		seatNo, ps.lifeCount, ps.deckCount, #ps.hand, ps.ap.active, ps.ap.total,
		if #e > 0 then table.concat(e, " ") else "-", #ps.outside, #ps.remove)
end

local function cardActions(list: Frame, v: any, uid: number)
	local cv, owner, zone = findCard(uid)
	if not cv or cv.hidden then
		return
	end
	local def = CardData.get(cv.key) :: CardData.Card
	local me = viewSeat
	local mine = owner == me
	local myTurn = v.turnPlayer == me and not v.pending
	local phase = v.phase
	local ps = v.players[me]

	local function lineFull(line: string): boolean
		return #ps[string.lower(line)] >= 4
	end
	local function lineUids(line: string): { number }
		local out = {}
		for _, c in ps[string.lower(line)] do
			table.insert(out, c.uid)
		end
		return out
	end
	-- Play to a line, asking which card to remove when it is full.
	local function playTo(line: string, extra: { [string]: any })
		if lineFull(line) then
			mode = {
				kind = "replace",
				candidates = lineUids(line),
				prompt = line .. " Line is full: click one of your cards there to send it to the Remove Area",
				onPick = function(r)
					extra.replaceUid = r
					send(extra)
				end,
			}
			render()
		else
			send(extra)
		end
	end

	if mine and zone == "hand" and myTurn and phase == "Main" then
		local hint = v.hints[tostring(uid)] or {}
		local warnTxt = ""
		if hint.energyOk == false then
			warnTxt ..= " (energy!)"
		end
		if hint.apOk == false then
			warnTxt ..= " (AP!)"
		end
		if def.cardType == "Character" then
			button(list, "Play → Front Line" .. warnTxt, function()
				playTo("Front", { type = "Play", uid = uid, line = "Front" })
			end)
			button(list, "Play → Energy Line" .. warnTxt, function()
				playTo("Energy", { type = "Play", uid = uid, line = "Energy" })
			end)
			for _, t in hint.raidTargets or {} do
				local tcv = findCard(t)
				local tdef = tcv and CardData.get(tcv.key)
				button(list, "Raid onto " .. (if tdef then cardName(tdef) else "#" .. t) .. warnTxt, function()
					send({ type = "Raid", uid = uid, targetUid = t })
				end, { BackgroundColor3 = Color3.fromRGB(150, 60, 60) })
			end
		elseif def.cardType == "Field" then
			button(list, "Play → Energy Line" .. warnTxt, function()
				playTo("Energy", { type = "Play", uid = uid, line = "Energy" })
			end)
		elseif def.cardType == "Event" then
			button(list, "Use Event" .. warnTxt, function()
				send({ type = "Play", uid = uid })
			end)
		end
	end
	-- Activate: Main abilities of your cards on the field.
	if mine and myTurn and phase == "Main" and (zone == "front" or zone == "energy") then
		local hint = v.hints[tostring(uid)] or {}
		for n, act in hint.activate or {} do
			local parts = {}
			if act.costs.rest then
				table.insert(parts, "rest")
			end
			if act.costs.ap then
				table.insert(parts, act.costs.ap .. " AP")
			end
			if act.costs.discard then
				table.insert(parts, "discard " .. act.costs.discard)
			end
			if act.costs.retireSelf then
				table.insert(parts, "remove this")
			end
			local text = ("Activate %d%s%s%s"):format(
				n,
				if #parts > 0 then " (" .. table.concat(parts, ", ") .. ")" else "",
				if act.auto then " · auto" else " · manual",
				if act.used then " · used" elseif not act.condsOk then " · condition!" else ""
			)
			button(list, text, function()
				send({ type = "Activate", uid = uid, index = act.index })
			end, { BackgroundColor3 = if act.auto then Color3.fromRGB(70, 90, 150) else Color3.fromRGB(90, 80, 60) })
		end
	end
	if mine and myTurn and phase == "Move" and def.cardType == "Character" then
		if zone == "energy" then
			button(list, "Move → Front Line", function()
				if lineFull("Front") then
					mode = {
						kind = "replace",
						candidates = lineUids("Front"),
						prompt = "Front Line is full: click a card there to send it to the Remove Area",
						onPick = function(r)
							send({ type = "Move", moves = { { uid = uid, to = "Front" } }, remove = { r } })
						end,
					}
					render()
				else
					send({ type = "Move", moves = { { uid = uid, to = "Front" } } })
				end
			end)
		elseif zone == "front" and def.keywords.step then
			button(list, "Step → Energy Line", function()
				send({ type = "Move", moves = { { uid = uid, to = "Energy" } } })
			end)
		end
	end
	if mine and myTurn and phase == "Attack" and zone == "front" and def.cardType == "Character" and not cv.rested then
		button(list, "Attack the player", function()
			send({ type = "Attack", uid = uid })
		end, { BackgroundColor3 = Color3.fromRGB(160, 50, 50) })
		if def.keywords.calledStrike then
			button(list, "Called Strike: pick a target", function()
				local cands = {}
				for _, c in v.players[3 - me].front do
					table.insert(cands, c.uid)
				end
				mode = {
					kind = "target",
					candidates = cands,
					prompt = "Click a character on the opponent's Front Line",
					onPick = function(t)
						send({ type = "Attack", uid = uid, targetUid = t })
					end,
				}
				render()
			end)
		end
	end

	-- Manual tools: always available when no decision is pending.
	if not v.pending and v.phase ~= "GameOver" and (mine or zone == "front" or zone == "energy") then
		label(list, "Manual (for card effects)", { Size = UDim2.new(1, 0, 0, 18), TextColor3 = MUTED, MaxText = 12 })
		local dests = { "Outside", "Hand", "Remove", "DeckBottom" }
		for _, dest in dests do
			button(list, "→ " .. dest, function()
				send({ type = "ManualMove", uid = uid, to = dest })
			end, { BackgroundColor3 = Color3.fromRGB(52, 56, 70), Size = UDim2.new(1, 0, 0, 24) })
		end
		if zone == "front" or zone == "energy" then
			button(list, "BP +1000", function()
				send({ type = "ManualBP", uid = uid, delta = 1000 })
			end, { BackgroundColor3 = Color3.fromRGB(52, 56, 70), Size = UDim2.new(1, 0, 0, 24) })
			button(list, "BP -1000", function()
				send({ type = "ManualBP", uid = uid, delta = -1000 })
			end, { BackgroundColor3 = Color3.fromRGB(52, 56, 70), Size = UDim2.new(1, 0, 0, 24) })
			button(list, if cv.rested then "Set Active" else "Set Rest", function()
				send({ type = "ManualRest", uid = uid, rested = not cv.rested })
			end, { BackgroundColor3 = Color3.fromRGB(52, 56, 70), Size = UDim2.new(1, 0, 0, 24) })
		end
	end
end

local function detailPanel(parent: Instance, v: any)
	local f = new("ScrollingFrame", {
		Name = "Detail",
		Position = UDim2.fromScale(0, 0),
		Size = UDim2.fromScale(1, 0.5),
		BackgroundColor3 = PANEL,
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 6), Parent = f })
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	local cv = selected and findCard(selected)
	if not cv or cv.hidden then
		label(f, "Click a card to see it and what you can do with it.", { Size = UDim2.new(1, 0, 0, 40), TextColor3 = MUTED })
		return
	end
	local def = CardData.get(cv.key) :: CardData.Card
	local function para(text: string, color: Color3?)
		if text == "" then
			return
		end
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = text,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = color or TEXT,
			Font = FONT,
			TextSize = 14,
			Parent = f,
		})
	end
	para(("%s  /  %s"):format(def.nameEn, def.nameJp))
	para(("%s · %s · %s · %s"):format(def.key, def.cardType, table.concat(def.colors, "/"), def.rarity), MUTED)
	if def.cardType ~= "Action Point" then
		para(("Required energy %d · AP %d%s"):format(def.needEnergy or 0, def.ap or 0, if def.bp then (" · BP %d%s"):format(cv.bp or def.bp, def.bpMark) else ""))
	end
	if #def.traits > 0 then
		para("Traits: " .. table.concat(def.traits, ", "), MUTED)
	end
	para(def.effectEn)
	local hint = v.hints and v.hints[tostring(cv.uid)]
	if hint and hint.abilities and #hint.abilities > 0 then
		local parts = {}
		for _, a in hint.abilities do
			table.insert(parts, a.timing .. ": " .. (if a.auto then "auto" else "manual"))
		end
		para("Effects — " .. table.concat(parts, " · "), Color3.fromRGB(150, 190, 255))
	end
	if def.triggerEn ~= "" then
		para(def.triggerEn, Color3.fromRGB(255, 220, 140))
	end
	cardActions(f, v, cv.uid)
end

local function decisionPanel(parent: Instance, v: any)
	local f = new("Frame", { Name = "Decision", Position = UDim2.fromScale(0, 0.51), Size = UDim2.fromScale(1, 0.24), BackgroundColor3 = Color3.fromRGB(44, 40, 30), Parent = parent })
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), Parent = f })
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })

	for _, r in v.resolving do
		local def = CardData.get(r.key)
		if def then
			label(f, ("Revealed: %s %s"):format(cardName(def), if def.triggerType ~= "" then "[" .. def.triggerType .. "]" else ""), { Size = UDim2.new(1, 0, 0, 18), TextColor3 = Color3.fromRGB(255, 220, 140), MaxText = 13 })
		end
	end

	if mode then
		label(f, mode.prompt, { Size = UDim2.new(1, 0, 0, 40), MaxText = 14 })
		button(f, "Cancel", function()
			mode = nil
			render()
		end)
		return
	end

	local d = v.pending
	if not d then
		if v.phase == "GameOver" then
			label(f, ("Game over: P%d wins (%s)"):format(v.winner or 0, v.winReason or ""), { Size = UDim2.new(1, 0, 0, 40), MaxText = 16 })
			button(f, "Back to lobby", function()
				Net.event("LobbyAction"):FireServer({ type = "Leave" })
			end)
		else
			label(f, "No decision waiting.", { Size = UDim2.new(1, 0, 0, 20), TextColor3 = MUTED, MaxText = 13 })
		end
		return
	end
	if d.player ~= viewSeat then
		label(f, ("Waiting for P%d: %s"):format(d.player, d.prompt), { Size = UDim2.new(1, 0, 0, 40), TextColor3 = MUTED, MaxText = 14 })
		return
	end
	if pickDecisionId ~= d.id then
		pickDecisionId = d.id
		picks = {}
		decisionShownAt = os.clock()
	end
	local promptLabel = label(f, "", { Size = UDim2.new(1, 0, 0, 40), MaxText = 15 })
	countdown = function()
		local left = math.max(0, math.floor((payload.timeout or 90) - (os.clock() - decisionShownAt)))
		promptLabel.Text = ("P%d: %s  (%ds)"):format(d.player, d.prompt, left)
	end
	countdown()

	local function respond(choice: { [string]: any })
		send({ type = "Respond", choice = choice })
	end
	if d.options then
		local holder = new("Frame", { Name = "Options", Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Parent = f })
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = holder })
		for _, opt in d.options do
			button(holder, opt, function()
				respond({ option = opt })
			end, { Size = UDim2.new(1 / #d.options, -6, 1, 0) })
		end
		return
	end
	if d.kind == "ChooseLife" then
		local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Parent = f })
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = holder })
		for _, pos in d.candidates do
			local on = table.find(picks, pos) ~= nil
			button(holder, tostring(pos), function()
				local i = table.find(picks, pos)
				if i then
					table.remove(picks, i)
				elseif #picks < d.max then
					table.insert(picks, pos)
				end
				render()
			end, { Size = UDim2.new(0, 30, 1, 0), BackgroundColor3 = if on then Color3.fromRGB(200, 170, 40) else Color3.fromRGB(64, 70, 88) })
		end
	else
		label(f, "Click the highlighted cards to choose.", { Size = UDim2.new(1, 0, 0, 18), TextColor3 = MUTED, MaxText = 12 })
	end
	label(f, ("Chosen %d (need %d-%d)"):format(#picks, d.min or 0, d.max or 0), { Size = UDim2.new(1, 0, 0, 18), TextColor3 = MUTED, MaxText = 12 })
	button(f, if #picks == 0 and (d.min or 0) == 0 then (if d.kind == "Block" then "Don't block" else "Choose none") else "Confirm", function()
		respond({ pick = table.clone(picks) })
	end, { BackgroundColor3 = Color3.fromRGB(60, 120, 70) })
end

local function logPanel(parent: Instance)
	local f = new("Frame", { Position = UDim2.fromScale(0, 0.76), Size = UDim2.fromScale(1, 0.24), BackgroundColor3 = PANEL, ClipsDescendants = true, Parent = parent })
	new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 4), Parent = f })
	new("UIListLayout", { VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	for _, line in payload.log do
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = line,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = if line:find("MANUAL", 1, true) then Color3.fromRGB(255, 200, 120) else MUTED,
			Font = Enum.Font.Gotham,
			TextSize = 12,
			Parent = f,
		})
	end
end

local function middleBar(parent: Instance, v: any)
	local f = new("Frame", { Name = "Bar", Position = UDim2.fromScale(0, 0.4), Size = UDim2.fromScale(1, 0.07), BackgroundColor3 = Color3.fromRGB(40, 44, 56), Parent = parent })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = f })
	local whose = if v.turnPlayer == viewSeat then "YOUR turn" else ("P%d's turn"):format(v.turnPlayer)
	label(f, ("Turn %d · %s · %s   (you are P%d)"):format(v.turnNumber, whose, v.phase, viewSeat), { Size = UDim2.new(0.36, 0, 0.8, 0), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1 })
	local myTurn = v.turnPlayer == viewSeat and not v.pending
	if myTurn and NEXT_LABEL[v.phase] then
		button(f, NEXT_LABEL[v.phase], function()
			send({ type = "NextPhase" })
		end, { Size = UDim2.new(0.12, 0, 0.8, 0), BackgroundColor3 = Color3.fromRGB(60, 120, 70), LayoutOrder = 2 })
	end
	if myTurn and v.phase == "Start" then
		button(f, "Extra Draw (1 AP)", function()
			send({ type = "ExtraDraw" })
		end, { Size = UDim2.new(0.12, 0, 0.8, 0), LayoutOrder = 3 })
	end
	if not v.pending and v.phase ~= "GameOver" then
		button(f, "Manual Draw", function()
			send({ type = "ManualDraw" })
		end, { Size = UDim2.new(0.09, 0, 0.8, 0), BackgroundColor3 = Color3.fromRGB(52, 56, 70), LayoutOrder = 4 })
	end
	if payload and #payload.seats == 2 then
		button(f, "Switch to P" .. (3 - viewSeat), function()
			viewSeat = 3 - viewSeat
			autoFollow = false
			selected = nil
			render()
		end, { Size = UDim2.new(0.1, 0, 0.8, 0), LayoutOrder = 5 })
		button(f, if autoFollow then "Auto-follow: on" else "Auto-follow: off", function()
			autoFollow = not autoFollow
			render()
		end, { Size = UDim2.new(0.11, 0, 0.8, 0), LayoutOrder = 6 })
	end
	if v.phase ~= "GameOver" then
		button(f, "Concede", function()
			send({ type = "Concede" })
		end, { Size = UDim2.new(0.07, 0, 0.8, 0), BackgroundColor3 = Color3.fromRGB(110, 40, 40), LayoutOrder = 7 })
	end
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

render = function()
	countdown = nil
	for _, c in root:GetChildren() do
		c:Destroy()
	end
	local v = view()
	if not v then
		label(root, "Waiting for the game…", { MaxText = 22 })
		return
	end
	local me, opp = viewSeat, 3 - viewSeat
	local mine, theirs = v.players[me], v.players[opp]

	local board = new("Frame", { Name = "Board", Size = UDim2.new(0.74, -6, 1, 0), BackgroundTransparency = 1, Parent = root })
	label(board, infoText(theirs, opp), { Size = UDim2.fromScale(1, 0.04), TextXAlignment = Enum.TextXAlignment.Left, MaxText = 14 })
	row(board, "Opp\nEnergy", theirs.energy, UDim2.fromScale(0, 0.045), UDim2.fromScale(1, 0.17))
	row(board, "Opp\nFront", theirs.front, UDim2.fromScale(0, 0.22), UDim2.fromScale(1, 0.17))
	middleBar(board, v)
	row(board, "Your\nFront", mine.front, UDim2.fromScale(0, 0.48), UDim2.fromScale(1, 0.17))
	row(board, "Your\nEnergy", mine.energy, UDim2.fromScale(0, 0.655), UDim2.fromScale(1, 0.17))
	label(board, infoText(mine, me), { Size = UDim2.fromScale(1, 0.035), Position = UDim2.fromScale(0, 0.825), TextXAlignment = Enum.TextXAlignment.Left, MaxText = 14 })
	row(board, "Hand", mine.hand, UDim2.fromScale(0, 0.86), UDim2.fromScale(1, 0.14))

	local side = new("Frame", { Name = "Side", Position = UDim2.fromScale(0.74, 0), Size = UDim2.fromScale(0.26, 1), BackgroundTransparency = 1, Parent = root })
	detailPanel(side, v)
	decisionPanel(side, v)
	logPanel(side)
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

local BoardUI = {}

function BoardUI.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = new("ScreenGui", { Name = "UnionArena", Enabled = false, DisplayOrder = 2, ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui })
	new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = BG, Parent = gui })
	root = new("Frame", { Name = "Root", Size = UDim2.new(1, -12, 1, -12), Position = UDim2.fromOffset(6, 6), BackgroundTransparency = 1, Parent = gui })
	toast = new("TextLabel", {
		Size = UDim2.new(0.5, 0, 0, 36),
		Position = UDim2.new(0.25, 0, 0, 8),
		BackgroundColor3 = Color3.fromRGB(150, 40, 40),
		TextColor3 = TEXT,
		Font = FONT,
		TextSize = 16,
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	})
	new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = toast })

	updateEvent.OnClientEvent:Connect(function(p: any)
		payload = p
		if not table.find(p.seats, viewSeat) then
			viewSeat = p.seats[1]
		end
		-- Hot-seat: follow whoever has to act.
		if autoFollow and #p.seats == 2 then
			local v = p.views[tostring(viewSeat)]
			local actor = if v.pending then v.pending.player else v.turnPlayer
			if actor ~= viewSeat then
				viewSeat = actor
				selected = nil
			end
		end
		mode = nil
		gui.Enabled = true
		render()
	end)
	errorEvent.OnClientEvent:Connect(function(msg: string)
		showToast(msg)
	end)
	-- Back in the lobby: hide the board and forget the old game.
	Net.event("LobbyUpdate").OnClientEvent:Connect(function(p: any)
		if p.status ~= "playing" then
			gui.Enabled = false
			payload = nil
			selected = nil
			mode = nil
			autoFollow = true
		end
	end)
	-- Countdown refresh while a decision is open.
	task.spawn(function()
		while true do
			task.wait(1)
			if countdown then
				countdown()
			end
		end
	end)
	render()
end

return BoardUI
