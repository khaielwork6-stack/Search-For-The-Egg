--!strict
-- The one server path for big centre-top announcements (the client's AnnouncementBanner). Rare,
-- round-wide moments only: the Egg uncovered, who has it, the Egg returned, a first Rainbow Feather.
-- Everyday feedback stays on Components/Toast and UI/Feedback.deny.
--
-- `announce` sanitises the payload into exactly the `Announcement` schema, and holds an identical
-- kind + text quiet for REPEAT_SECONDS, so two systems reporting the same moment (or a retried path)
-- still reach each player once. Recipients default to `getPlayers()`; round callers pass the round's
-- present players.

local AnnouncementService = {}
AnnouncementService.__index = AnnouncementService

export type Tone = "gold" | "rainbow" | "info" | "success"

export type Payload = {
	kind: string,
	text: string,
	sub: string?,
	tone: Tone?,
	userId: number?,
	position: Vector3?,
}

export type AnnouncementService = typeof(setmetatable(
	{} :: {
		_send: (player: any, remoteName: string, payload: { [string]: any }) -> (),
		_getPlayers: () -> { any },
		_clock: any,
		_lastSent: { [string]: number },
		stats: { sent: number, suppressed: number, deliveries: number },
	},
	AnnouncementService
))

AnnouncementService.REMOTE = "Announcement"
AnnouncementService.REPEAT_SECONDS = 2
AnnouncementService.MAX_TEXT = 80
AnnouncementService.MAX_SUB = 120
AnnouncementService.TONES = table.freeze({ gold = true, rainbow = true, info = true, success = true })

function AnnouncementService.new(options: {
	send: (player: any, remoteName: string, payload: { [string]: any }) -> (),
	getPlayers: () -> { any },
	clock: any,
}): AnnouncementService
	return setmetatable({
		_send = options.send,
		_getPlayers = options.getPlayers,
		_clock = options.clock,
		_lastSent = {},
		stats = { sent = 0, suppressed = 0, deliveries = 0 },
	}, AnnouncementService)
end

local function clip(text: string, max: number): string
	if #text <= max then
		return text
	end
	-- Bytes, cut on a UTF-8 boundary so a display name never ends in half a character.
	local cut = max - 3
	while cut > 0 do
		local byte = string.byte(text, cut + 1)
		if byte == nil or byte < 0x80 or byte >= 0xC0 then
			break
		end
		cut -= 1
	end
	return string.sub(text, 1, cut) .. "..."
end

-- The wire payload for `payload`, or nil when it is not announceable (no kind or no text).
function AnnouncementService.sanitize(payload: { [string]: any }): { [string]: any }?
	local kind = payload.kind
	local text = payload.text
	if type(kind) ~= "string" or not string.match(kind, "^[%w_%-]+$") or #kind > 32 then
		return nil
	end
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local out: { [string]: any } = {
		kind = kind,
		text = clip(text, AnnouncementService.MAX_TEXT),
		tone = if type(payload.tone) == "string" and AnnouncementService.TONES[payload.tone] then payload.tone else "info",
	}
	if type(payload.sub) == "string" and payload.sub ~= "" then
		out.sub = clip(payload.sub, AnnouncementService.MAX_SUB)
	end
	if type(payload.userId) == "number" and payload.userId == payload.userId then
		out.userId = math.floor(payload.userId)
	end
	if typeof(payload.position) == "Vector3" then
		local p = payload.position :: Vector3
		if p.X == p.X and p.Y == p.Y and p.Z == p.Z and p.Magnitude < 5000 then
			out.position = p
		end
	end
	return out
end

-- Sends `payload` to `recipients` (nil = everyone from getPlayers). Returns the number of players it
-- reached; 0 when the payload was invalid or an identical kind + text went out within REPEAT_SECONDS.
function AnnouncementService.announce(self: AnnouncementService, recipients: { any }?, payload: Payload | { [string]: any }): number
	local wire = AnnouncementService.sanitize(payload :: any)
	if not wire then
		return 0
	end
	local now = self._clock:monotonic()
	local key = wire.kind .. "\0" .. wire.text
	local last = self._lastSent[key]
	if last and now - last < AnnouncementService.REPEAT_SECONDS then
		self.stats.suppressed += 1
		return 0
	end
	self._lastSent[key] = now
	self.stats.sent += 1
	if self.stats.sent % 32 == 0 then
		self:sweep()
	end
	local list = recipients or self._getPlayers()
	local reached = 0
	local seen = {}
	for _, player in ipairs(list) do
		if seen[player] then
			continue
		end
		seen[player] = true
		-- One table per player: the transport may keep a reference.
		self._send(player, AnnouncementService.REMOTE, table.clone(wire))
		reached += 1
	end
	self.stats.deliveries += reached
	return reached
end

-- Drops expired dedupe keys.
function AnnouncementService.sweep(self: AnnouncementService)
	local now = self._clock:monotonic()
	for key, at in pairs(self._lastSent) do
		if now - at >= AnnouncementService.REPEAT_SECONDS then
			self._lastSent[key] = nil
		end
	end
end

return AnnouncementService
