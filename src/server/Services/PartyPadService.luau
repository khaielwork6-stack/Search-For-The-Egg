--!strict
-- Party nest pads (ASSUMED A-LOBBY-06): the lobby map's four "Join Match" nests are physical party
-- slots. The server checks each pad's zone on a tick: a lobby player standing inside joins that pad's
-- party (created on first entry), a member who steps off leaves it, a full pad sets off by itself
-- after the configured delay, and the leader can set off early from the sign post. The pad sign is
-- the party's status display. Parties formed through the modal keep their own rules (no zone
-- semantics), so both paths coexist through the one PartyService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local ChapterLayout = require(Shared.Domain.ChapterLayout)
local Signal = require(Shared.Util.Signal)

local PartyPadService = {}
PartyPadService.__index = PartyPadService

export type PartyPadService = typeof(setmetatable(
	{} :: {
		_config: { [string]: any },
		_parties: any,
		_sessions: any,
		_clock: any,
		_getCharacterPosition: (userId: number) -> Vector3?,
		_players: () -> { number },
		_setSign: (index: number, text: string) -> (),
		_pads: { any },
		_padParty: { [number]: string? }, -- pad index -> partyId
		_partyPad: { [string]: number }, -- partyId -> pad index
		_fullSince: { [number]: number? },
		_signText: { [number]: string },
		_prompted: { [number]: number? }, -- userId -> pad index the party screen was offered for
		padPrompt: any, -- (userId, padIndex)
		stats: { joins: number, leaves: number, autoStarts: number, creates: number, prompts: number },
	},
	PartyPadService
))

function PartyPadService.new(options: {
	config: { [string]: any },
	parties: any,
	sessions: any,
	clock: any,
	getCharacterPosition: (userId: number) -> Vector3?,
	players: () -> { number },
	setSign: ((index: number, text: string) -> ())?,
}): PartyPadService
	return setmetatable({
		_config = options.config,
		_parties = options.parties,
		_sessions = options.sessions,
		_clock = options.clock,
		_getCharacterPosition = options.getCharacterPosition,
		_players = options.players,
		_setSign = options.setSign or function() end,
		_pads = ChapterLayout.lobby.pads,
		_padParty = {},
		_partyPad = {},
		_fullSince = {},
		_signText = {},
		_prompted = {},
		padPrompt = Signal.new(),
		stats = { joins = 0, leaves = 0, autoStarts = 0, creates = 0, prompts = 0 },
	}, PartyPadService)
end

function PartyPadService.padOf(self: PartyPadService, partyId: string): number?
	return self._partyPad[partyId]
end

function PartyPadService.partyAt(self: PartyPadService, index: number): any?
	local partyId = self._padParty[index]
	local party = partyId and self._parties:get(partyId)
	if not party or party.phase == "Closed" then
		if partyId then
			self._partyPad[partyId] = nil
		end
		self._padParty[index] = nil
		return nil
	end
	return party
end

local function inside(pad: any, position: Vector3, height: number): boolean
	local half = pad.zoneSize / 2
	local dx, dz = position.X - pad.center.X, position.Z - pad.center.Z
	return math.abs(dx) <= half.X and math.abs(dz) <= half.Z and math.abs(position.Y - pad.center.Y) <= height
end

-- Which pad (if any) a player is standing in.
function PartyPadService.padUnder(self: PartyPadService, userId: number): number?
	local position = self._getCharacterPosition(userId)
	if not position then
		return nil
	end
	for _, pad in ipairs(self._pads) do
		if inside(pad, position, self._config.lobby.padZoneHeightStuds) then
			return pad.index
		end
	end
	return nil
end

local function signTextFor(party: any?, remaining: number?, maxPlayers: number): string
	if not party then
		return string.format("0/%d\nTouch to create a party", maxPlayers)
	end
	local count = #party.members
	local max = party.maxMembers or maxPlayers
	if party.phase == "Countdown" then
		return string.format("Setting off in %d", math.max(1, math.ceil(remaining or 0)))
	elseif party.phase == "Reserving" or party.phase == "Teleporting" then
		return "Good luck!"
	end
	local chapterName = party.chapter == "chapter2" and "Cellar" or "Henhouse"
	local suffix = if party.difficulty == "hard" then " (Hard)" else ""
	return string.format("%d/%d\n%s%s  -  waiting for %d more", count, max, chapterName, suffix, math.max(0, max - count))
end

-- One pass over every pad and lobby player. Returns the number of membership changes.
function PartyPadService.tick(self: PartyPadService): number
	local changes = 0
	local now = self._clock:monotonic()
	local standing: { [number]: number } = {} -- pad index -> count
	local padOf: { [number]: number? } = {}
	for _, userId in ipairs(self._players()) do
		local session = self._sessions:get(userId)
		if session and (session.phase == "Lobby" or session.phase == "Party") then
			local index = self:padUnder(userId)
			padOf[userId] = index
			if index then
				standing[index] = (standing[index] or 0) + 1
			end
		end
	end

	for _, userId in ipairs(self._players()) do
		local session = self._sessions:get(userId)
		if not session or (session.phase ~= "Lobby" and session.phase ~= "Party") then
			continue
		end
		local index = padOf[userId]
		local current = self._parties:partyOf(userId)
		if current and self._partyPad[current.partyId] then
			-- Member of a pad party: stepping off leaves it (any phase; a leaving member cancels a countdown).
			if index ~= self._partyPad[current.partyId] then
				local left = self._parties:leave(userId)
				if left ~= nil or self._parties:partyOf(userId) == nil then
					self.stats.leaves += 1
					changes += 1
				end
			end
		elseif index and not current then
			-- Lobby player on a pad: join the pad's party, or get the party screen to found one.
			local party = self:partyAt(index)
			if party then
				if party.phase == "Forming" or party.phase == "Ready" then
					local joined = self._parties:join(userId, party.partyId)
					if joined then
						self.stats.joins += 1
						changes += 1
					end
				end
			elseif self._prompted[userId] ~= index then
				self._prompted[userId] = index
				self.stats.prompts += 1
				self.padPrompt:Fire(userId, index)
			end
		elseif index and current and not self._partyPad[current.partyId] and current.leaderUserId == userId then
			-- The leader founded a party from the screen while standing on an empty pad: the pad is theirs.
			if not self:partyAt(index) then
				self._padParty[index] = current.partyId
				self._partyPad[current.partyId] = index
				self.stats.creates += 1
				changes += 1
			end
		end
		if not index then
			self._prompted[userId] = nil
		end
	end

	-- Full pads set off by themselves; signs mirror the party.
	for _, pad in ipairs(self._pads) do
		local party = self:partyAt(pad.index)
		local remaining: number? = nil
		if party then
			if party.phase == "Ready" and #party.members >= (party.maxMembers or 4) then
				if not self._fullSince[pad.index] then
					self._fullSince[pad.index] = now
				elseif now - (self._fullSince[pad.index] :: number) >= self._config.lobby.padFullAutoStartSeconds then
					local started = self._parties:start(party.leaderUserId, party.partyId)
					if started then
						self.stats.autoStarts += 1
						changes += 1
						party = started
					end
					self._fullSince[pad.index] = nil
				end
			else
				self._fullSince[pad.index] = nil
			end
			if party.phase == "Countdown" and party.countdownDeadline then
				remaining = party.countdownDeadline - now
			end
		else
			self._fullSince[pad.index] = nil
		end
		local text = signTextFor(party, remaining, self._config.project.maxPartyPlayers)
		if self._signText[pad.index] ~= text then
			self._signText[pad.index] = text
			self._setSign(pad.index, text)
		end
	end
	return changes
end

function PartyPadService.signText(self: PartyPadService, index: number): string
	return self._signText[index] or "Join Match\n0/4"
end

return PartyPadService
