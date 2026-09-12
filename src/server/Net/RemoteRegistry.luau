--!strict
-- Roblox binding for the remote registry: creates one RemoteFunction per client request and one
-- RemoteEvent per server event under ReplicatedStorage.SFE_Runtime.Remotes, wiring each to the
-- instance-free core. No generic dispatch remote exists.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local RemoteRegistryCore = require(script.Parent.RemoteRegistryCore)

local RemoteRegistry = {}
RemoteRegistry.__index = RemoteRegistry

RemoteRegistry.REMOTES_FOLDER_NAME = "Remotes"

export type RemoteRegistry = typeof(setmetatable(
	{} :: {
		core: RemoteRegistryCore.RemoteRegistryCore,
		folder: Folder,
		_functions: { [string]: RemoteFunction },
		_events: { [string]: RemoteEvent },
		_log: any,
	},
	RemoteRegistry
))

function RemoteRegistry.new(core: RemoteRegistryCore.RemoteRegistryCore, runtimeFolder: Instance, log: any?): RemoteRegistry
	local existing = runtimeFolder:FindFirstChild(RemoteRegistry.REMOTES_FOLDER_NAME)
	local folder: Folder
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = RemoteRegistry.REMOTES_FOLDER_NAME
		folder.Parent = runtimeFolder
	end
	local self = setmetatable({ core = core, folder = folder, _functions = {}, _events = {}, _log = log }, RemoteRegistry)

	for _, def in ipairs(core.schema.list) do
		if def.direction == "clientToServer" then
			local remote = Instance.new("RemoteFunction")
			remote.Name = def.name
			remote.Parent = folder
			remote.OnServerInvoke = function(player, payload)
				return core:handleRequest(def.name, player, payload)
			end
			self._functions[def.name] = remote
		else
			local remote = Instance.new("RemoteEvent")
			remote.Name = def.name
			remote.Parent = folder
			self._events[def.name] = remote
		end
	end
	return self
end

function RemoteRegistry.onRequest(self: RemoteRegistry, name: string, handler: RemoteRegistryCore.Handler)
	self.core:registerHandler(name, handler)
end

function RemoteRegistry.fireClient(self: RemoteRegistry, name: string, player: Player, payload: { [string]: any })
	local ok, reason = self.core:validateOutgoing(name, payload)
	if not ok then
		error("RemoteRegistry.fireClient(" .. name .. "): " .. tostring(reason))
	end
	self._events[name]:FireClient(player, payload)
end

function RemoteRegistry.fireAllClients(self: RemoteRegistry, name: string, payload: { [string]: any })
	local ok, reason = self.core:validateOutgoing(name, payload)
	if not ok then
		error("RemoteRegistry.fireAllClients(" .. name .. "): " .. tostring(reason))
	end
	self._events[name]:FireAllClients(payload)
end

function RemoteRegistry.remoteCount(self: RemoteRegistry): number
	local n = 0
	for _ in pairs(self._functions) do
		n += 1
	end
	for _ in pairs(self._events) do
		n += 1
	end
	return n
end

RemoteRegistry.RUNTIME_FOLDER_NAME = Config.RUNTIME_FOLDER_NAME

return RemoteRegistry
