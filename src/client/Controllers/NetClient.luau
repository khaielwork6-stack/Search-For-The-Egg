--!strict
-- Client side of the typed remote registry. Validates outgoing payloads against the shared
-- schema before invoking (so obviously-bad requests never leave the client) and dispatches
-- server events by name. Only messages declared in NetSchema exist.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local NetSchema = require(Shared.Net.NetSchema)
local Schema = require(Shared.Net.Schema)
local Envelope = require(Shared.Net.Envelope)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local NetClient = {}
NetClient.__index = NetClient

export type NetClient = typeof(setmetatable(
	{} :: {
		_schema: any,
		_folder: Instance,
		_signals: { [string]: any },
		_trove: Trove.Trove,
		_inflight: { [string]: boolean },
	},
	NetClient
))

function NetClient.new(runtimeFolder: Instance, config: { [string]: any }): NetClient
	local folder = runtimeFolder:WaitForChild("Remotes", 30)
	assert(folder, "Remotes folder never replicated")
	local self = setmetatable({
		_schema = NetSchema.build(config),
		_folder = folder,
		_signals = {},
		_trove = Trove.new(),
		_inflight = {},
	}, NetClient)
	for _, def in ipairs(self._schema.list) do
		if def.direction == "serverToClient" then
			local signal = Signal.new()
			self._signals[def.name] = signal
			local remote = folder:WaitForChild(def.name, 30) :: RemoteEvent?
			if remote then
				self._trove:add(remote.OnClientEvent:Connect(function(payload)
					signal:Fire(payload)
				end))
			end
		end
	end
	return self
end

-- Sends a request; returns the server envelope. Never throws for server rejections.
function NetClient.request(self: NetClient, name: string, payload: any): Envelope.Envelope<any>
	local def = self._schema.byName[name]
	if not def or def.direction ~= "clientToServer" then
		return Envelope.fail(Envelope.Codes.UNKNOWN_MESSAGE)
	end
	local validation = Schema.validate(def.payload, payload)
	if not validation.ok then
		return Envelope.fail(Envelope.Codes.INVALID_PAYLOAD)
	end
	if self._inflight[name] then
		return Envelope.fail(Envelope.Codes.RATE_LIMITED) -- one in-flight request per message
	end
	local remote = self._folder:FindFirstChild(name) :: RemoteFunction?
	if not remote then
		return Envelope.fail(Envelope.Codes.UNAVAILABLE)
	end
	self._inflight[name] = true
	local ok, result = pcall(function()
		return remote:InvokeServer(payload)
	end)
	self._inflight[name] = nil
	if not ok or not Envelope.isEnvelope(result) then
		return Envelope.fail(Envelope.Codes.UNAVAILABLE)
	end
	return result
end

function NetClient.on(self: NetClient, name: string, handler: (payload: any) -> ()): Signal.Connection
	local signal = self._signals[name]
	assert(signal, "unknown server event " .. tostring(name))
	return signal:Connect(handler)
end

function NetClient.destroy(self: NetClient)
	self._trove:destroy()
	for _, signal in pairs(self._signals) do
		signal:Destroy()
	end
end

return NetClient
