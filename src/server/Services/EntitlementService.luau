--!strict
-- Game-pass ownership through the Marketplace adapter. Ownership is canonical from Roblox; the
-- profile's entitlementsCache is a diagnostic snapshot only and never grants by itself.
-- Passes without a deployment ID are always "not owned" and never prompt.

local EntitlementService = {}
EntitlementService.__index = EntitlementService

export type EntitlementService = typeof(setmetatable(
	{} :: {
		_marketplace: any,
		_productMap: any,
		_clock: any,
		_cacheSeconds: number,
		_cache: { [number]: { checkedAt: number, passes: { [string]: boolean } } },
		_passKeys: { string },
		stats: { checks: number, failures: number },
	},
	EntitlementService
))

function EntitlementService.new(options: { marketplace: any, productMap: any, clock: any, cacheSeconds: number }): EntitlementService
	local passKeys = {}
	for key, entry in pairs((options.productMap :: any)._entries) do
		if entry.kind == "gamePass" then
			table.insert(passKeys, key)
		end
	end
	table.sort(passKeys)
	return setmetatable({
		_marketplace = options.marketplace,
		_productMap = options.productMap,
		_clock = options.clock,
		_cacheSeconds = options.cacheSeconds,
		_cache = {},
		_passKeys = passKeys,
		stats = { checks = 0, failures = 0 },
	}, EntitlementService)
end

-- Queries Roblox for every configured pass. Unconfigured passes are false. A failed query keeps
-- the previous cached value (or false) rather than granting.
function EntitlementService.refresh(self: EntitlementService, userId: number): { [string]: boolean }
	local previous = self._cache[userId]
	local passes: { [string]: boolean } = {}
	for _, key in ipairs(self._passKeys) do
		local entry = self._productMap:resolve(key)
		if entry and entry.id then
			self.stats.checks += 1
			local ok, owns = self._marketplace:userOwnsGamePassAsync(userId, entry.id)
			if ok then
				passes[key] = owns == true
			else
				self.stats.failures += 1
				passes[key] = previous ~= nil and previous.passes[key] == true
			end
		else
			passes[key] = false
		end
	end
	self._cache[userId] = { checkedAt = self._clock:now(), passes = passes }
	return table.clone(passes)
end

function EntitlementService.snapshot(self: EntitlementService, userId: number): { [string]: boolean }
	local cached = self._cache[userId]
	if not cached or (self._clock:now() - cached.checkedAt) > self._cacheSeconds then
		return self:refresh(userId)
	end
	return table.clone(cached.passes)
end

function EntitlementService.ownsPass(self: EntitlementService, userId: number, passKey: string): boolean
	if not self._productMap:isConfigured(passKey) then
		return false
	end
	return self:snapshot(userId)[passKey] == true
end

function EntitlementService.forget(self: EntitlementService, userId: number)
	self._cache[userId] = nil
end

function EntitlementService.passKeys(self: EntitlementService): { string }
	return table.clone(self._passKeys)
end

return EntitlementService
