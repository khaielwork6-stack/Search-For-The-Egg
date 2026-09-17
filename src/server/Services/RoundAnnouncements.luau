--!strict
-- Which round moments earn a big announcement, and who hears them. Reads round state and fires
-- AnnouncementService; it never writes to the round, the pile or the Egg.
--
--   Rainbow Feathers (once per player per round each):
--     * the player's first accepted Rainbow Feather     "Soryn found a Rainbow Feather!"  rainbow
--     * the carried count first reaches plume.rainbowCost  "Soryn can visit Plume!"         gold
--       (not after they have already used Plume, not once the Egg is out, only where Plume stands)
--   The Egg (the round's present players):
--     * first exposure   "THE EGG IS UNCOVERED!"   gold, with the Egg's position for the client ripple
--     * picked up        "Soryn has the Egg!"      gold, with the carrier's userId
--     * delivered / won  "EGG RETURNED!"           gold, with the finder's userId and the hand-over point

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local RoundReducer = require(Shared.Reducers.RoundReducer)
local ChapterLayout = require(Shared.Domain.ChapterLayout)

local RoundAnnouncements = {}
RoundAnnouncements.__index = RoundAnnouncements

export type RoundAnnouncements = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_announcements: any,
		_playerOf: (userId: number) -> any,
		_nameOf: (userId: number) -> string,
		-- runtime -> userId -> { first = true, ready = true }; weak so a finished round is collected.
		_seen: { [any]: { [number]: { [string]: boolean } } },
		_connections: { any },
	},
	RoundAnnouncements
))

RoundAnnouncements.TEXT = table.freeze({
	firstRainbow = "%s found a Rainbow Feather!",
	plumeReady = "%s can visit Plume!",
	eggUncovered = "THE EGG IS UNCOVERED!",
	eggUncoveredSub = "Grab it before anyone else",
	eggCarried = "%s has the Egg!",
	eggCarriedSub = "Bring it to the Farmer",
	eggReturned = "EGG RETURNED!",
	eggFound = "%s found the Egg!",
})

function RoundAnnouncements.new(options: {
	config: { [string]: any },
	announcements: any,
	playerOf: (userId: number) -> any,
	nameOf: (userId: number) -> string,
}): RoundAnnouncements
	return setmetatable({
		_config = options.config,
		_announcements = options.announcements,
		_playerOf = options.playerOf,
		_nameOf = options.nameOf,
		_seen = setmetatable({}, { __mode = "k" }) :: any,
		_connections = {},
	}, RoundAnnouncements)
end

-- The round's present players (only those the transport can reach).
function RoundAnnouncements.recipients(self: RoundAnnouncements, runtime: any): { any }
	local out = {}
	for _, userId in ipairs(RoundReducer.presentMembers(runtime.state)) do
		local player = self._playerOf(userId)
		if player then
			table.insert(out, player)
		end
	end
	return out
end

local function flags(self: RoundAnnouncements, runtime: any, userId: number): { [string]: boolean }
	local byUser = self._seen[runtime]
	if not byUser then
		byUser = {}
		self._seen[runtime] = byUser
	end
	local entry = byUser[userId]
	if not entry then
		entry = {}
		byUser[userId] = entry
	end
	return entry
end

-- The Rainbow Feather milestones an award crossed, as announcement payloads (pure: marks them seen).
-- `result` is a collection/tool award (`rainbow` = Rainbow Feathers accepted into the bag).
function RoundAnnouncements.rainbowMilestones(self: RoundAnnouncements, userId: number, runtime: any, result: any): { { [string]: any } }
	local out = {}
	local state = runtime and runtime.players and runtime.players[userId]
	if not state or type(result) ~= "table" then
		return out
	end
	local phase = runtime.state.phase
	if phase ~= "Searching" and phase ~= "EggRevealed" then
		return out
	end
	local seen = flags(self, runtime, userId)
	if (tonumber(result.rainbow) or 0) > 0 and not seen.first then
		seen.first = true
		table.insert(out, {
			kind = "rainbow_first",
			text = string.format(RoundAnnouncements.TEXT.firstRainbow, self._nameOf(userId)),
			tone = "rainbow",
			userId = userId,
		})
	end
	local layout = ChapterLayout[runtime.state.chapter]
	local cost = self._config.plume.rainbowCost
	local eggOut = phase == "EggRevealed" or runtime.eggCarrier ~= nil
	if
		not seen.ready
		and layout ~= nil
		and layout.clueStation ~= nil
		and not eggOut
		and state.plumeClue == nil
		and (state.carriedRainbow or 0) >= cost
	then
		seen.ready = true
		table.insert(out, {
			kind = "plume_ready",
			text = string.format(RoundAnnouncements.TEXT.plumeReady, self._nameOf(userId)),
			tone = "gold",
			userId = userId,
		})
	end
	return out
end

-- Award hook (CollectionService.collected / ToolService.awarded). Returns how many were announced.
function RoundAnnouncements.onAwarded(self: RoundAnnouncements, userId: number, runtime: any, result: any): number
	local milestones = self:rainbowMilestones(userId, runtime, result)
	if #milestones == 0 then
		return 0
	end
	local recipients = self:recipients(runtime)
	for _, payload in ipairs(milestones) do
		self._announcements:announce(recipients, payload)
	end
	return #milestones
end

function RoundAnnouncements.onEggRevealed(self: RoundAnnouncements, runtime: any, position: Vector3)
	self._announcements:announce(self:recipients(runtime), {
		kind = "egg_uncovered",
		text = RoundAnnouncements.TEXT.eggUncovered,
		sub = RoundAnnouncements.TEXT.eggUncoveredSub,
		tone = "gold",
		position = position,
	})
end

function RoundAnnouncements.onEggCarried(self: RoundAnnouncements, runtime: any, userId: number)
	self._announcements:announce(self:recipients(runtime), {
		kind = "egg_carried",
		text = string.format(RoundAnnouncements.TEXT.eggCarried, self._nameOf(userId)),
		sub = RoundAnnouncements.TEXT.eggCarriedSub,
		tone = "gold",
		userId = userId,
	})
end

-- The win: with a Farmer in the chapter it was a hand-over; without one the claim itself won.
function RoundAnnouncements.onEggClaimed(self: RoundAnnouncements, runtime: any, userId: number, farmer: Vector3?)
	local name = self._nameOf(userId)
	self._announcements:announce(self:recipients(runtime), {
		kind = "egg_returned",
		text = if farmer then RoundAnnouncements.TEXT.eggReturned else string.format(RoundAnnouncements.TEXT.eggFound, name),
		sub = if farmer then string.format("%s brought it home", name) else nil,
		tone = "gold",
		userId = userId,
		position = farmer,
	})
end

-- Connects the Egg service's signals. Call once.
function RoundAnnouncements.bindEgg(self: RoundAnnouncements, egg: any)
	table.insert(
		self._connections,
		egg.revealed:Connect(function(runtime, position)
			self:onEggRevealed(runtime, position)
		end)
	)
	table.insert(
		self._connections,
		egg.carried:Connect(function(runtime, userId)
			self:onEggCarried(runtime, userId)
		end)
	)
	table.insert(
		self._connections,
		egg.claimed:Connect(function(runtime, userId)
			self:onEggClaimed(runtime, userId, egg:farmerPosition(runtime))
		end)
	)
end

function RoundAnnouncements.destroy(self: RoundAnnouncements)
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

return RoundAnnouncements
