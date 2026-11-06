--!strict
-- Lobby: your saved decks, sample decks, find a match, solo test, deck builder.
-- Hidden while you are in a game; the board (BoardUI) shows instead.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local UI = require(script.Parent:WaitForChild("UIKit"))
local DeckBuilderUI = require(script.Parent:WaitForChild("DeckBuilderUI"))

local lobbyAction = Net.event("LobbyAction")
local lobbyUpdate = Net.event("LobbyUpdate")
local deckCall = Net.func("DeckCall")

local SAMPLE_SERIES = { "HTR", "JJK", "KMY", "BLC", "AOT", "SAO" }

local LobbyUI = {}

function LobbyUI.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = UI.new("ScreenGui", { Name = "Lobby", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1, Parent = playerGui })
	local bg = UI.new("Frame", { Name = "Root", Size = UDim2.fromScale(1, 1), BackgroundColor3 = UI.BG, Parent = gui })
	UI.pad(bg, 16)

	local last: any = { status = "menu", decks = {}, queueSize = 0 }
	local sampleIndex = 1
	local building = false
	local render: () -> ()

	local function send(a: { [string]: any })
		lobbyAction:FireServer(a)
	end

	local function openBuilder(input: any)
		building = true
		DeckBuilderUI.open(gui, input, function()
			building = false
			render()
		end)
		render()
	end

	render = function()
		UI.clear(bg)
		bg.Visible = not building
		if building then
			return
		end
		local main = UI.new("Frame", { Name = "Main", Size = UDim2.new(0, 760, 1, 0), Position = UDim2.new(0.5, -380, 0, 0), BackgroundTransparency = 1, Parent = bg })
		UI.list(main, false, 8)
		UI.label(main, "UNION ARENA — Roblox", { TextSize = 26, Size = UDim2.new(1, 0, 0, 36) })

		local status = if last.status == "queued"
			then ("Looking for an opponent… (%d in queue)"):format(last.queueSize)
			else "Choose a deck, then Find match (2 players) or Solo test (you play both sides)."
		UI.label(main, status, { TextColor3 = UI.MUTED, Size = UDim2.new(1, 0, 0, 22) })
		if last.message then
			UI.label(main, last.message, { TextColor3 = Color3.fromRGB(255, 200, 120), Size = UDim2.new(1, 0, 0, 22) })
		end
		if last.status == "queued" then
			UI.button(main, "Cancel search", function()
				send({ type = "Cancel" })
			end, { BackgroundColor3 = UI.BAD, Size = UDim2.new(0, 180, 0, 34) })
		end

		-- Saved decks
		local decksPanel = UI.panel(main, { Name = "Decks", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.pad(decksPanel, 10)
		UI.list(decksPanel, false, 6)
		local head = UI.new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Parent = decksPanel })
		UI.list(head, true)
		UI.label(head, "Your decks", { TextSize = 18, Size = UDim2.new(0, 560, 1, 0) })
		UI.button(head, "New deck", function()
			openBuilder(nil)
		end, { BackgroundColor3 = UI.GOOD, Size = UDim2.new(0, 150, 1, 0) })

		local names = {}
		for name in last.decks do
			table.insert(names, name)
		end
		table.sort(names)
		if #names == 0 then
			UI.label(decksPanel, "No saved decks yet. Make one with New deck, or use a sample deck below.", { TextColor3 = UI.MUTED })
		end
		for _, name in names do
			local d = last.decks[name]
			local rowF = UI.new("Frame", { Name = "Deck_" .. name:gsub("[^%w]", ""), Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, Parent = decksPanel })
			UI.list(rowF, true, 6)
			UI.label(rowF, ("%s  ·  %s  ·  %d/50  %s"):format(name, d.series, d.count, if d.valid then "(legal)" else "(not legal: " .. (d.errors[1] or "?") .. ")"), {
				Size = UDim2.new(0, 360, 1, 0),
				TextColor3 = if d.valid then UI.TEXT else Color3.fromRGB(255, 170, 170),
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextWrapped = false,
			})
			UI.button(rowF, "Edit", function()
				openBuilder({ name = name, series = d.series, cards = d.cards })
			end, { Size = UDim2.new(0, 70, 1, 0) })
			if last.status == "menu" then
				UI.button(rowF, "Find match", function()
					send({ type = "Queue", deck = name })
				end, { Size = UDim2.new(0, 100, 1, 0), BackgroundColor3 = if d.valid then UI.GOOD else UI.BUTTON })
				UI.button(rowF, "Solo test", function()
					send({ type = "Solo", deck = name })
				end, { Size = UDim2.new(0, 90, 1, 0) })
			end
			UI.button(rowF, "Delete", function()
				deckCall:InvokeServer("delete", { name = name })
			end, { Size = UDim2.new(0, 70, 1, 0), BackgroundColor3 = UI.BAD })
		end

		-- Sample decks
		local sample = UI.panel(main, { Name = "Sample", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		UI.pad(sample, 10)
		UI.list(sample, false, 6)
		UI.label(sample, "Sample deck (random legal 2-color deck)", { TextSize = 18, Size = UDim2.new(1, 0, 0, 26) })
		local srow = UI.new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, Parent = sample })
		UI.list(srow, true, 6)
		UI.button(srow, "◀", function()
			sampleIndex = ((sampleIndex - 2) % #SAMPLE_SERIES) + 1
			render()
		end, { Name = "SamplePrev", Size = UDim2.new(0, 30, 1, 0) })
		UI.label(srow, SAMPLE_SERIES[sampleIndex], { Size = UDim2.new(0, 60, 1, 0), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 16 })
		UI.button(srow, "▶", function()
			sampleIndex = (sampleIndex % #SAMPLE_SERIES) + 1
			render()
		end, { Name = "SampleNext", Size = UDim2.new(0, 30, 1, 0) })
		if last.status == "menu" then
			UI.button(srow, "Find match", function()
				send({ type = "Queue", deck = "#sample:" .. SAMPLE_SERIES[sampleIndex] })
			end, { Name = "SampleQueue", Size = UDim2.new(0, 110, 1, 0), BackgroundColor3 = UI.GOOD })
			UI.button(srow, "Solo test", function()
				send({ type = "Solo", deck = "#sample:" .. SAMPLE_SERIES[sampleIndex] })
			end, { Name = "SampleSolo", Size = UDim2.new(0, 100, 1, 0) })
		end
	end

	lobbyUpdate.OnClientEvent:Connect(function(p: any)
		last = p
		gui.Enabled = p.status ~= "playing"
		render()
	end)
	render()
	lobbyAction:FireServer({ type = "Refresh" })
end

return LobbyUI
