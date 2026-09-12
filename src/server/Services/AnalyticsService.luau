--!strict
-- Enumerated analytics with config/build version stamping, high-frequency sampling, and a strict
-- field policy: numbers and booleans always; strings only for allowlisted enumerated keys.
-- Free text and personal data are rejected before reaching any adapter.

local AnalyticsService = {}
AnalyticsService.__index = AnalyticsService

export type AnalyticsService = typeof(setmetatable(
	{} :: {
		_adapter: any,
		_config: { [string]: any },
		_buildInfo: { [string]: any },
		_rng: () -> number,
		_allowed: { [string]: boolean },
		_sampled: { [string]: number },
		stats: { sent: number, sampledOut: number, rejected: number },
	},
	AnalyticsService
))

-- Keys whose string values are enumerated identifiers (never free text).
AnalyticsService.ENUM_STRING_KEYS = table.freeze({
	chapter = true,
	difficulty = true,
	platformClass = true,
	step = true,
	tool = true,
	class = true,
	upgradeId = true,
	productKey = true,
	reason = true,
	phase = true,
	buildLabel = true,
})

local MAX_ENUM_LENGTH = 48

function AnalyticsService.new(
	options: { adapter: any, config: { [string]: any }, buildInfo: { [string]: any }, rng: (() -> number)? }
): AnalyticsService
	local allowed = {}
	for _, name in ipairs(options.config.analytics.events) do
		allowed[name] = true
	end
	local sampled = { feather_collected = options.config.analytics.sampledCollectionEventRate }
	return setmetatable({
		_adapter = options.adapter,
		_config = options.config,
		_buildInfo = options.buildInfo,
		_rng = options.rng or function()
			return math.random()
		end,
		_allowed = allowed,
		_sampled = sampled,
		stats = { sent = 0, sampledOut = 0, rejected = 0 },
	}, AnalyticsService)
end

local function sanitizeFields(fields: { [string]: any }?): ({ [string]: any }?, string?)
	local out = {}
	for key, value in pairs(fields or {}) do
		if type(key) ~= "string" then
			return nil, "non_string_key"
		end
		local kind = type(value)
		if kind == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return nil, "non_finite"
			end
			out[key] = value
		elseif kind == "boolean" then
			out[key] = value
		elseif kind == "string" then
			if not AnalyticsService.ENUM_STRING_KEYS[key] then
				return nil, "free_text:" .. key
			end
			if #value > MAX_ENUM_LENGTH or string.find(value, "%s") then
				return nil, "free_text:" .. key
			end
			out[key] = value
		else
			return nil, "unsupported_type:" .. key
		end
	end
	return out, nil
end

-- Returns true when the event was sent, false with a reason otherwise.
function AnalyticsService.track(self: AnalyticsService, name: string, fields: { [string]: any }?, userId: number?): (boolean, string?)
	if not self._allowed[name] then
		self.stats.rejected += 1
		return false, "unknown_event"
	end
	local clean, reason = sanitizeFields(fields)
	if not clean then
		self.stats.rejected += 1
		return false, reason
	end
	local sampleRate = self._sampled[name]
	if sampleRate ~= nil and self._rng() >= sampleRate then
		self.stats.sampledOut += 1
		return false, "sampled_out"
	end
	clean.configVersion = self._config.configVersion
	clean.buildLabel = self._buildInfo.buildLabel
	if sampleRate ~= nil then
		clean.sampleRate = sampleRate
	end
	self._adapter:send({ name = name, userId = userId, fields = clean })
	self.stats.sent += 1
	return true, nil
end

function AnalyticsService.isKnownEvent(self: AnalyticsService, name: string): boolean
	return self._allowed[name] == true
end

return AnalyticsService
