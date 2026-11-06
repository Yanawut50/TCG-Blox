--!strict
-- Remotes between server and clients. The server creates them; clients wait.
--
--   GameAction   RemoteEvent     client -> server  (seat: number, action: Action)
--   GameUpdate   RemoteEvent     server -> client  (payload: see server/Match.luau)
--   GameError    RemoteEvent     server -> client  (message: string)
--   LobbyAction  RemoteEvent     client -> server  (action: { type = "Queue" | "Cancel" | "Solo" | "Leave", deck = name? })
--   LobbyUpdate  RemoteEvent     server -> client  (payload: see server/init.server.luau)
--   DeckCall     RemoteFunction  client -> server  (op: "list" | "save" | "delete", args) -> result

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local REMOTES: { [string]: string } = {
	GameAction = "RemoteEvent",
	GameUpdate = "RemoteEvent",
	GameError = "RemoteEvent",
	LobbyAction = "RemoteEvent",
	LobbyUpdate = "RemoteEvent",
	DeckCall = "RemoteFunction",
}

local Net = {}

local function folder(): Folder
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("Remotes")
		if not f then
			f = Instance.new("Folder")
			f.Name = "Remotes"
			f.Parent = ReplicatedStorage
		end
		for name, className in REMOTES do
			if not f:FindFirstChild(name) then
				local e = Instance.new(className)
				e.Name = name
				e.Parent = f
			end
		end
		return f :: Folder
	end
	return ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Net.event(name: string): RemoteEvent
	assert(REMOTES[name] == "RemoteEvent", "unknown remote event " .. name)
	return folder():WaitForChild(name) :: RemoteEvent
end

function Net.func(name: string): RemoteFunction
	assert(REMOTES[name] == "RemoteFunction", "unknown remote function " .. name)
	return folder():WaitForChild(name) :: RemoteFunction
end

return Net
