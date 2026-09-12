--!strict
-- Records remote rejections per player and code, samples them into structured logs, and exposes
-- counters for tests and the Studio debug panel. Never auto-bans from one heuristic.

local SecurityService = {}
SecurityService.__index = SecurityService

export type SecurityService = typeof(setmetatable(
	{} :: {
		_log: any,
		_rng: () -> number,
		_sampleRate: number,
		_byUser: { [number]: { [string]: number } },
		total: number,
		logged: number,
	},
	SecurityService
))

function SecurityService.new(options: { log: any, sampleRate: number, rng: (() -> number)? }): SecurityService
	return setmetatable({
		_log = options.log,
		_rng = options.rng or function()
			return math.random()
		end,
		_sampleRate = options.sampleRate,
		_byUser = {},
		total = 0,
		logged = 0,
	}, SecurityService)
end

function SecurityService.recordRejection(self: SecurityService, userId: number, messageName: string, code: string)
	self.total += 1
	local user = self._byUser[userId]
	if not user then
		user = {}
		self._byUser[userId] = user
	end
	local key = messageName .. ":" .. code
	user[key] = (user[key] or 0) + 1
	if self._rng() < self._sampleRate then
		self.logged += 1
		if self._log then
			self._log:warn("remote_rejected", { userId = userId, message = messageName, code = code, count = user[key] })
		end
	end
end

function SecurityService.countFor(self: SecurityService, userId: number, messageName: string?, code: string?): number
	local user = self._byUser[userId]
	if not user then
		return 0
	end
	local n = 0
	for key, count in pairs(user) do
		local message, rejectionCode = string.match(key, "^(.-):(.*)$")
		if (messageName == nil or message == messageName) and (code == nil or rejectionCode == code) then
			n += count
		end
	end
	return n
end

function SecurityService.forget(self: SecurityService, userId: number)
	self._byUser[userId] = nil
end

return SecurityService
