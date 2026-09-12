--!strict
-- Instance-free core of the remote registry. Validates every inbound request through the same
-- pipeline (known name -> size bounds -> rate limit -> schema -> handler -> envelope) and every
-- outbound event against its schema. The Roblox binding (RemoteRegistry) is a thin wrapper.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Schema = require(Shared.Net.Schema)
local Envelope = require(Shared.Net.Envelope)
local RateLimiter = require(Shared.Net.RateLimiter)
local NetSchema = require(Shared.Net.NetSchema)

local RemoteRegistryCore = {}
RemoteRegistryCore.__index = RemoteRegistryCore

export type Handler = (player: any, payload: any) -> Envelope.Envelope<any>

export type RemoteRegistryCore = typeof(setmetatable(
	{} :: {
		schema: { list: { NetSchema.MessageDef }, byName: { [string]: NetSchema.MessageDef } },
		_handlers: { [string]: Handler },
		_limiter: RateLimiter.RateLimiter,
		_security: any,
		_log: any,
		stats: { accepted: number, rejected: number, handlerErrors: number },
	},
	RemoteRegistryCore
))

function RemoteRegistryCore.new(
	options: { config: { [string]: any }, monotonic: () -> number, security: any?, log: any? }
): RemoteRegistryCore
	return setmetatable({
		schema = NetSchema.build(options.config),
		_handlers = {},
		_limiter = RateLimiter.new(options.monotonic),
		_security = options.security,
		_log = options.log,
		stats = { accepted = 0, rejected = 0, handlerErrors = 0 },
	}, RemoteRegistryCore)
end

function RemoteRegistryCore.registerHandler(self: RemoteRegistryCore, name: string, handler: Handler)
	local def = self.schema.byName[name]
	assert(def, "RemoteRegistryCore: unknown message " .. tostring(name))
	assert(def.direction == "clientToServer", "RemoteRegistryCore: " .. name .. " is not a client request")
	assert(self._handlers[name] == nil, "RemoteRegistryCore: handler already registered for " .. name)
	self._handlers[name] = handler
end

function RemoteRegistryCore.hasHandler(self: RemoteRegistryCore, name: string): boolean
	return self._handlers[name] ~= nil
end

local function reject(self: RemoteRegistryCore, player: any, name: string, code: string): Envelope.Envelope<any>
	self.stats.rejected += 1
	if self._security then
		self._security:recordRejection(player.UserId, name, code)
	end
	return Envelope.fail(code)
end

-- Full inbound pipeline. Never throws; always returns a sanitized envelope.
function RemoteRegistryCore.handleRequest(self: RemoteRegistryCore, name: any, player: any, payload: any): Envelope.Envelope<any>
	if type(name) ~= "string" then
		return reject(self, player, "?", Envelope.Codes.UNKNOWN_MESSAGE)
	end
	local def = self.schema.byName[name]
	if not def or def.direction ~= "clientToServer" then
		return reject(self, player, name, Envelope.Codes.UNKNOWN_MESSAGE)
	end
	-- Size/depth bounds before anything else so giant tables are dropped cheaply.
	if payload ~= nil then
		local _, _, exceeded = Schema.measure(payload, def.maxBytes, def.maxDepth)
		if exceeded then
			return reject(self, player, name, Envelope.Codes.PAYLOAD_TOO_LARGE)
		end
	end
	local rateKey = tostring(player.UserId) .. ":" .. name
	if not self._limiter:tryConsume(rateKey, def.rate :: any) then
		return reject(self, player, name, Envelope.Codes.RATE_LIMITED)
	end
	local validation = Schema.validate(def.payload, payload)
	if not validation.ok then
		return reject(self, player, name, Envelope.Codes.INVALID_PAYLOAD)
	end
	local handler = self._handlers[name]
	if not handler then
		return reject(self, player, name, Envelope.Codes.UNAVAILABLE)
	end
	local ok, result = pcall(handler, player, payload)
	if not ok then
		self.stats.handlerErrors += 1
		if self._log then
			self._log:error("remote_handler_error", { message = name, userId = player.UserId })
			-- Full error text stays server-side (Output) for debugging; it never reaches the client.
			warn("[SFE][RemoteRegistry] handler error in " .. name .. ": " .. tostring(result))
		end
		return reject(self, player, name, Envelope.Codes.INTERNAL)
	end
	if not Envelope.isEnvelope(result) then
		self.stats.handlerErrors += 1
		return reject(self, player, name, Envelope.Codes.INTERNAL)
	end
	if result.ok then
		self.stats.accepted += 1
	else
		self.stats.rejected += 1
	end
	return result
end

-- Outbound validation for server->client events.
function RemoteRegistryCore.validateOutgoing(self: RemoteRegistryCore, name: string, payload: any): (boolean, string?)
	local def = self.schema.byName[name]
	if not def or def.direction ~= "serverToClient" then
		return false, "unknown_event"
	end
	local _, _, exceeded = Schema.measure(payload, def.maxBytes, def.maxDepth)
	if exceeded then
		return false, "payload_too_large"
	end
	if type(payload) ~= "table" then
		return false, "expected_table"
	end
	return true, nil
end

function RemoteRegistryCore.forgetPlayer(self: RemoteRegistryCore, userId: number)
	self._limiter:clearPrefix(tostring(userId) .. ":")
end

function RemoteRegistryCore.sweep(self: RemoteRegistryCore, idleSeconds: number): number
	return self._limiter:sweep(idleSeconds)
end

return RemoteRegistryCore
