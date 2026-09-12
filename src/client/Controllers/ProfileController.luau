--!strict
-- Holds the latest sanitized profile and session projections and exposes change signals.
-- The client never mutates these; every change originates from a server event.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local ProfileController = {}
ProfileController.__index = ProfileController

export type ProfileController = typeof(setmetatable(
	{} :: {
		projection: { [string]: any }?,
		session: { [string]: any }?,
		changed: any,
		sessionChanged: any,
		_trove: Trove.Trove,
	},
	ProfileController
))

function ProfileController.new(net: any): ProfileController
	local self = setmetatable({
		projection = nil,
		session = nil,
		changed = Signal.new(),
		sessionChanged = Signal.new(),
		_trove = Trove.new(),
	}, ProfileController)
	self._trove:add(net:on("ProfileProjection", function(payload)
		self.projection = payload.projection
		self.changed:Fire(self.projection)
	end))
	self._trove:add(net:on("SessionProjection", function(payload)
		self.session = payload
		self.sessionChanged:Fire(payload)
	end))
	return self
end

function ProfileController.settings(self: ProfileController): { [string]: any }?
	return self.projection and self.projection.settings or nil
end

function ProfileController.currency(self: ProfileController, name: string): number
	local projection = self.projection
	return projection and projection.currencies[name] or 0
end

function ProfileController.destroy(self: ProfileController)
	self._trove:destroy()
	self.changed:Destroy()
	self.sessionChanged:Destroy()
end

return ProfileController
