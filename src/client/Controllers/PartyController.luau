--!strict
-- Client party state: the latest PartyProjection for the local player's party, the open party list,
-- and typed requests for create/join/leave/destination/start/cancel. The session projection is the
-- source of truth for "am I in a party" (partyId), so a stale projection can never linger.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local PartyController = {}
PartyController.__index = PartyController

export type PartyController = typeof(setmetatable(
	{} :: {
		_net: any,
		_profile: any,
		party: { [string]: any }?,
		list: { { [string]: any } },
		_receivedAt: number,
		changed: any,
		listChanged: any,
		_trove: Trove.Trove,
		stats: { requests: number, rejected: number },
	},
	PartyController
))

function PartyController.new(deps: { net: any, profile: any }): PartyController
	local self = setmetatable({
		_net = deps.net,
		_profile = deps.profile,
		party = nil,
		list = {},
		_receivedAt = 0,
		changed = Signal.new(),
		listChanged = Signal.new(),
		_trove = Trove.new(),
		stats = { requests = 0, rejected = 0 },
	}, PartyController)
	self._trove:add(deps.net:on("PartyProjection", function(payload)
		self:_apply(payload)
	end))
	self._trove:add(deps.net:on("PartyListProjection", function(payload)
		self.list = payload.parties or {}
		self.listChanged:Fire(self.list)
	end))
	self._trove:add(deps.profile.sessionChanged:Connect(function(session)
		if self.party and (session.partyId == nil or session.partyId ~= self.party.partyId) then
			self.party = nil
			self.changed:Fire(nil)
		end
	end))
	return self
end

function PartyController._apply(self: PartyController, projection: { [string]: any }?)
	if projection and projection.phase ~= "Closed" then
		local session = self._profile.session
		if session and session.partyId and session.partyId ~= projection.partyId then
			return -- projection for a party we already left
		end
		self.party = projection
		self._receivedAt = os.clock()
	else
		self.party = nil
	end
	self.changed:Fire(self.party)
end

function PartyController._request(self: PartyController, name: string, payload: any): any
	self.stats.requests += 1
	local result = self._net:request(name, payload)
	if result.ok then
		if name == "PartyLeave" then
			self:_apply(nil)
		elseif result.data and result.data.partyId then
			self:_apply(result.data)
		end
	else
		self.stats.rejected += 1
	end
	return result
end

function PartyController.create(self: PartyController, chapter: string, difficulty: string, size: number?): any
	return self:_request("PartyCreate", { chapter = chapter, difficulty = difficulty, size = size })
end

function PartyController.join(self: PartyController, partyId: string): any
	return self:_request("PartyJoin", { partyId = partyId })
end

function PartyController.leave(self: PartyController): any
	return self:_request("PartyLeave", nil)
end

function PartyController.setDestination(self: PartyController, chapter: string, difficulty: string): any
	return self:_request("PartySetDestination", { chapter = chapter, difficulty = difficulty })
end

function PartyController.start(self: PartyController): any
	local party = self.party
	if not party then
		return { ok = false, code = "invalid_state", message = "no_party" }
	end
	return self:_request("PartyStart", { partyId = party.partyId })
end

function PartyController.cancel(self: PartyController): any
	local party = self.party
	if not party then
		return { ok = false, code = "invalid_state", message = "no_party" }
	end
	return self:_request("PartyCancel", { partyId = party.partyId })
end

-- Countdown seconds remaining, extrapolated from the last projection.
function PartyController.countdownRemaining(self: PartyController): number?
	local party = self.party
	if not party or party.phase ~= "Countdown" or not party.countdownRemaining then
		return nil
	end
	return math.max(0, party.countdownRemaining - (os.clock() - self._receivedAt))
end

function PartyController.isLeader(self: PartyController): boolean
	local party = self.party
	local player = game:GetService("Players").LocalPlayer
	return party ~= nil and party.leaderUserId == player.UserId
end

function PartyController.destroy(self: PartyController)
	self._trove:destroy()
	self.changed:Destroy()
	self.listChanged:Destroy()
end

return PartyController
