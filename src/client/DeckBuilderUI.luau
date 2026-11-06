--!strict
-- Deck builder: pick a series, filter its cards, click to add (right-click to
-- remove), see the rule check live, save to the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData"))
local DeckRules = require(Shared:WaitForChild("Game"):WaitForChild("DeckRules"))
local Constants = require(Shared.Game:WaitForChild("Constants"))
local Net = require(Shared:WaitForChild("Net"))
local UI = require(script.Parent:WaitForChild("UIKit"))

local deckCall = Net.func("DeckCall")

local MAX_SHOWN = 150
local TYPES = { "Character", "Event", "Field" }
local COLOR_ORDER = { "Red", "Blue", "Yellow", "Green", "Purple" }

local DeckBuilderUI = {}

export type DeckInput = { name: string, series: string, cards: { string } }

-- Series codes with playable cards, sorted, with the JP series name.
local seriesList: { { code: string, name: string } }? = nil
local function getSeries(): { { code: string, name: string } }
	if seriesList then
		return seriesList
	end
	local seen: { [string]: string } = {}
	for _, set in CardData.getSets() do
		if not set.id:match("^AP%-") then
			local code = DeckRules.seriesCode(set.id)
			seen[code] = seen[code] or set.series
		end
	end
	local out = {}
	for code, name in seen do
		table.insert(out, { code = code, name = name })
	end
	table.sort(out, function(a, b)
		return a.code < b.code
	end)
	seriesList = out
	return out
end

local poolCache: { [string]: { CardData.Card } } = {}
local function poolFor(code: string): { CardData.Card }
	if poolCache[code] then
		return poolCache[code]
	end
	local out = {}
	for _, set in CardData.getSets() do
		if DeckRules.seriesCode(set.id) == code then
			for _, card in CardData.getSet(set.id) or {} do
				if card.cardType ~= "Action Point" then
					table.insert(out, card)
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	poolCache[code] = out
	return out
end

local function cardName(c: CardData.Card): string
	return if c.nameEn ~= "" then c.nameEn else c.nameJp
end

function DeckBuilderUI.open(parent: Instance, input: DeckInput?, onClose: () -> ())
	local series = getSeries()
	local state = {
		name = if input then input.name else "",
		series = if input then input.series else (series[1] and series[1].code or "HTR"),
		cards = if input then table.clone(input.cards) else {},
		text = "",
		colors = {} :: { [string]: boolean },
		types = {} :: { [string]: boolean },
		detail = nil :: string?,
		message = "",
	}

	local root = UI.new("Frame", { Name = "DeckBuilder", Size = UDim2.fromScale(1, 1), BackgroundColor3 = UI.BG, Parent = parent })
	UI.pad(root, 8)

	-- Top bar
	local top = UI.panel(root, { Size = UDim2.new(1, 0, 0, 44) })
	UI.pad(top, 6)
	UI.list(top, true)
	UI.label(top, "Deck name", { Size = UDim2.new(0, 80, 1, 0), TextColor3 = UI.MUTED })
	local nameBox: TextBox = UI.new("TextBox", {
		Name = "DeckName",
		Size = UDim2.new(0, 200, 1, 0),
		BackgroundColor3 = Color3.fromRGB(50, 54, 66),
		TextColor3 = UI.TEXT,
		Font = UI.FONT,
		TextSize = 14,
		Text = state.name,
		PlaceholderText = "My deck",
		ClearTextOnFocus = false,
		Parent = top,
	})
	local seriesLabel: TextLabel
	local renderGrid: () -> ()
	local renderDeck: () -> ()
	local function seriesIndex(): number
		for i, s in series do
			if s.code == state.series then
				return i
			end
		end
		return 1
	end
	local function setSeries(delta: number)
		if #state.cards > 0 then
			state.message = "Clear the deck before changing series (a deck uses one series)"
			renderDeck()
			return
		end
		local i = ((seriesIndex() - 1 + delta) % #series) + 1
		state.series = series[i].code
		seriesLabel.Text = ("%s  %s"):format(series[i].code, series[i].name)
		renderGrid()
		renderDeck()
	end
	UI.button(top, "◀", function()
		setSeries(-1)
	end, { Name = "SeriesPrev", Size = UDim2.new(0, 30, 1, 0) })
	seriesLabel = UI.label(top, "", { Size = UDim2.new(0, 260, 1, 0), TextXAlignment = Enum.TextXAlignment.Center })
	seriesLabel.Text = ("%s  %s"):format(state.series, series[seriesIndex()] and series[seriesIndex()].name or "")
	UI.button(top, "▶", function()
		setSeries(1)
	end, { Name = "SeriesNext", Size = UDim2.new(0, 30, 1, 0) })
	UI.button(top, "Save", function()
		state.name = nameBox.Text
		local res = deckCall:InvokeServer("save", { name = state.name, series = state.series, cards = state.cards })
		if res and res.ok then
			state.message = if #res.errors == 0 then "Saved: deck is legal" else "Saved as draft (not legal yet)"
		else
			state.message = "Not saved: " .. ((res and res.errors and res.errors[1]) or "error")
		end
		renderDeck()
	end, { Size = UDim2.new(0, 90, 1, 0), BackgroundColor3 = UI.GOOD })
	UI.button(top, "Clear", function()
		state.cards = {}
		renderGrid()
		renderDeck()
	end, { Size = UDim2.new(0, 70, 1, 0) })
	UI.button(top, "Back", function()
		root:Destroy()
		onClose()
	end, { Size = UDim2.new(0, 70, 1, 0) })

	-- Filters
	local filters = UI.panel(root, { Size = UDim2.new(0.66, -6, 0, 40), Position = UDim2.fromOffset(0, 52) })
	UI.pad(filters, 5)
	UI.list(filters, true, 4)
	local search: TextBox = UI.new("TextBox", {
		Name = "Search",
		Size = UDim2.new(0, 180, 1, 0),
		BackgroundColor3 = Color3.fromRGB(50, 54, 66),
		TextColor3 = UI.TEXT,
		Font = UI.FONT,
		TextSize = 14,
		Text = "",
		PlaceholderText = "Search name / effect / trait",
		ClearTextOnFocus = false,
		Parent = filters,
	})
	local toggles: { [string]: TextButton } = {}
	local function toggleButton(key: string, set: { [string]: boolean }, color: Color3?)
		local b = UI.button(filters, key, function()
			set[key] = not set[key] or nil
			renderGrid()
		end, { Size = UDim2.new(0, if color then 58 else 76, 1, 0), BackgroundColor3 = color or UI.BUTTON })
		toggles[key] = b
	end
	for _, c in COLOR_ORDER do
		toggleButton(c, state.colors, UI.COLORS[c])
	end
	for _, t in TYPES do
		toggleButton(t, state.types)
	end

	-- Card grid
	local grid = UI.new("ScrollingFrame", {
		Name = "Grid",
		Size = UDim2.new(0.66, -6, 1, -100),
		Position = UDim2.fromOffset(0, 100),
		BackgroundColor3 = UI.PANEL,
		ScrollBarThickness = 8,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	UI.pad(grid, 6)

	-- Deck panel (right)
	local side = UI.new("Frame", { Size = UDim2.new(0.34, 0, 1, -52), Position = UDim2.new(0.66, 0, 0, 52), BackgroundTransparency = 1, Parent = root })
	local deckPanel = UI.new("ScrollingFrame", {
		Name = "DeckList",
		Size = UDim2.new(1, 0, 0.62, -4),
		BackgroundColor3 = UI.PANEL,
		ScrollBarThickness = 8,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = side,
	})
	UI.pad(deckPanel, 8)
	local detail = UI.new("ScrollingFrame", {
		Name = "Detail",
		Size = UDim2.new(1, 0, 0.38, 0),
		Position = UDim2.fromScale(0, 0.62),
		BackgroundColor3 = UI.PANEL,
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = side,
	})
	UI.pad(detail, 8)

	local function countOf(key: string): number
		local n = 0
		for _, k in state.cards do
			if k == key then
				n += 1
			end
		end
		return n
	end
	local function add(key: string)
		if #state.cards >= Constants.DECK_SIZE then
			state.message = "Deck already has 50 cards"
		else
			table.insert(state.cards, key)
			state.message = ""
		end
	end
	local function remove(key: string)
		local i = table.find(state.cards, key)
		if i then
			table.remove(state.cards, i)
		end
	end
	local function renderDetail()
		UI.clear(detail)
		UI.list(detail, false, 4)
		local c = state.detail and CardData.get(state.detail)
		if not c then
			UI.label(detail, "Left-click a card to add it, right-click to remove it.", { TextColor3 = UI.MUTED, AutomaticSize = Enum.AutomaticSize.Y })
			return
		end
		local function para(t: string, color: Color3?)
			if t ~= "" then
				UI.label(detail, t, { AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), TextColor3 = color or UI.TEXT })
			end
		end
		para(("%s / %s"):format(c.nameEn, c.nameJp))
		para(("%s · %s · %s · %s"):format(c.key, c.cardType, table.concat(c.colors, "/"), c.rarity), UI.MUTED)
		para(("Required energy %d · AP %d%s"):format(c.needEnergy or 0, c.ap or 0, if c.bp then " · BP " .. c.bp .. c.bpMark else ""))
		if #c.traits > 0 then
			para("Traits: " .. table.concat(c.traits, ", "), UI.MUTED)
		end
		para(c.effectEn)
		para(c.triggerEn, Color3.fromRGB(255, 220, 140))
	end

	renderDeck = function()
		UI.clear(deckPanel)
		UI.list(deckPanel, false, 3)
		local ok, errors = DeckRules.validate(state.cards)
		UI.label(deckPanel, ("%d / %d cards   %s"):format(#state.cards, Constants.DECK_SIZE, if ok then "(legal)" else "(not legal yet)"), {
			TextSize = 16,
			TextColor3 = if ok then Color3.fromRGB(120, 230, 140) else Color3.fromRGB(255, 160, 160),
		})
		if state.message ~= "" then
			UI.label(deckPanel, state.message, { TextColor3 = Color3.fromRGB(255, 220, 140), AutomaticSize = Enum.AutomaticSize.Y })
		end
		for i = 1, math.min(#errors, 4) do
			UI.label(deckPanel, "• " .. errors[i], { TextColor3 = UI.MUTED, TextSize = 12, AutomaticSize = Enum.AutomaticSize.Y })
		end
		-- Group by card key, ordered by required energy then name.
		local counts: { [string]: number } = {}
		local keys: { string } = {}
		for _, k in state.cards do
			if not counts[k] then
				counts[k] = 0
				table.insert(keys, k)
			end
			counts[k] += 1
		end
		table.sort(keys, function(a, b)
			local ca, cb = CardData.get(a) :: CardData.Card, CardData.get(b) :: CardData.Card
			if (ca.needEnergy or 0) ~= (cb.needEnergy or 0) then
				return (ca.needEnergy or 0) < (cb.needEnergy or 0)
			end
			return a < b
		end)
		for _, k in keys do
			local c = CardData.get(k) :: CardData.Card
			local rowF = UI.new("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, Parent = deckPanel })
			UI.list(rowF, true, 4)
			UI.button(rowF, "−", function()
				remove(k)
				renderGrid()
				renderDeck()
			end, { Name = "Minus_" .. k, Size = UDim2.new(0, 24, 1, 0) })
			UI.button(rowF, "+", function()
				add(k)
				renderGrid()
				renderDeck()
			end, { Name = "Plus_" .. k, Size = UDim2.new(0, 24, 1, 0) })
			local nameBtn = UI.button(rowF, ("%dx  ⚡%d  %s"):format(counts[k], c.needEnergy or 0, cardName(c)), function()
				state.detail = k
				renderDetail()
			end, { Size = UDim2.new(1, -60, 1, 0), BackgroundColor3 = UI.COLORS[c.colors[1] or ""] or UI.BUTTON, TextXAlignment = Enum.TextXAlignment.Left, TextSize = 13 })
			UI.pad(nameBtn, 2)
		end
	end

	local function matches(c: CardData.Card): boolean
		if next(state.types) and not state.types[c.cardType] then
			return false
		end
		if next(state.colors) then
			local any = false
			for _, col in c.colors do
				if state.colors[col] then
					any = true
				end
			end
			if not any then
				return false
			end
		end
		local q = string.lower(state.text)
		if q ~= "" then
			local hay = string.lower(c.nameEn .. " " .. c.nameJp .. " " .. c.key .. " " .. c.effectEn .. " " .. table.concat(c.traits, " "))
			if not hay:find(q, 1, true) then
				return false
			end
		end
		return true
	end

	renderGrid = function()
		UI.clear(grid)
		UI.new("UIGridLayout", { CellSize = UDim2.fromOffset(104, 138), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
		for key, b in toggles do
			local on = state.colors[key] or state.types[key]
			local stroke = b:FindFirstChildOfClass("UIStroke") or UI.new("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b })
			stroke.Thickness = if on then 3 else 0
			stroke.Color = Color3.new(1, 1, 1)
		end
		local shown = 0
		local total = 0
		for _, c in poolFor(state.series) do
			if matches(c) then
				total += 1
				if shown < MAX_SHOWN then
					shown += 1
					local n = countOf(c.key)
					local tile = UI.new("TextButton", {
						Name = "Card_" .. c.key,
						BackgroundColor3 = UI.COLORS[c.colors[1] or ""] or UI.BUTTON,
						Text = "",
						AutoButtonColor = true,
						Parent = grid,
					})
					UI.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = tile })
					UI.pad(tile, 4)
					UI.list(tile, false, 2)
					UI.label(tile, ("⚡%d  AP%d"):format(c.needEnergy or 0, c.ap or 0), { TextSize = 12, Size = UDim2.new(1, 0, 0, 14) })
					UI.label(tile, cardName(c), { TextSize = 13, Size = UDim2.new(1, 0, 0, 48), TextXAlignment = Enum.TextXAlignment.Center })
					UI.label(tile, if c.bp then c.bp .. " BP" else c.cardType, { TextSize = 12, Size = UDim2.new(1, 0, 0, 14), TextXAlignment = Enum.TextXAlignment.Center })
					UI.label(tile, if c.triggerType ~= "" then "[" .. c.triggerType .. "]" else "", { TextSize = 11, Size = UDim2.new(1, 0, 0, 13), TextColor3 = Color3.fromRGB(255, 235, 150), TextXAlignment = Enum.TextXAlignment.Center })
					UI.label(tile, if n > 0 then ("in deck: %d"):format(n) else c.key, { TextSize = 11, Size = UDim2.new(1, 0, 0, 13), TextColor3 = if n > 0 then Color3.fromRGB(255, 255, 255) else UI.MUTED, TextXAlignment = Enum.TextXAlignment.Center })
					tile.MouseButton1Click:Connect(function()
						state.detail = c.key
						add(c.key)
						renderGrid()
						renderDeck()
						renderDetail()
					end)
					tile.MouseButton2Click:Connect(function()
						state.detail = c.key
						remove(c.key)
						renderGrid()
						renderDeck()
						renderDetail()
					end)
				end
			end
		end
		if total > shown then
			UI.label(grid, ("Showing %d of %d — use search or filters"):format(shown, total), { TextColor3 = UI.MUTED })
		end
	end

	local searchToken = 0
	search:GetPropertyChangedSignal("Text"):Connect(function()
		searchToken += 1
		local my = searchToken
		task.delay(0.25, function()
			if my == searchToken then
				state.text = search.Text
				renderGrid()
			end
		end)
	end)

	renderGrid()
	renderDeck()
	renderDetail()
end

return DeckBuilderUI
