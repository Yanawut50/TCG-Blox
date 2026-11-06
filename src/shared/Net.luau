--!strict
-- RemoteEvents between server and clients. The server creates them; clients wait.
--
--   GameAction  client -> server  (seat: number, action: Action)
--   GameUpdate  server -> client  (payload: see server/Match.luau)
--   GameError   server -> client  (message: string)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMES = { "GameAction", "GameUpdate", "GameError" }

local Net = {}

local function folder(): Folder
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("Remotes")
		if not f then
			f = Instance.new("Folder")
			f.Name = "Remotes"
			f.Parent = ReplicatedStorage
		end
		for _, name in NAMES do
			if not f:FindFirstChild(name) then
				local e = Instance.new("RemoteEvent")
				e.Name = name
				e.Parent = f
			end
		end
		return f :: Folder
	end
	return ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

function Net.event(name: string): RemoteEvent
	assert(table.find(NAMES, name), "unknown remote " .. name)
	return folder():WaitForChild(name) :: RemoteEvent
end

return Net
