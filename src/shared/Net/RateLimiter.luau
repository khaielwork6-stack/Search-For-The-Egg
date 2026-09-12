--!strict
-- Token-bucket rate limiter keyed by an arbitrary string (player:message). Uses the injected
-- monotonic clock so tests are deterministic. Buckets for idle keys are evicted on sweep.

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type Limit = { perSecond: number, burst: number }

type Bucket = { tokens: number, updatedAt: number }

export type RateLimiter = typeof(setmetatable({} :: { _buckets: { [string]: Bucket }, _monotonic: () -> number }, RateLimiter))

function RateLimiter.new(monotonic: () -> number): RateLimiter
	return setmetatable({ _buckets = {}, _monotonic = monotonic }, RateLimiter)
end

-- Attempts to consume one token. Returns true when allowed.
function RateLimiter.tryConsume(self: RateLimiter, key: string, limit: Limit): boolean
	assert(limit.perSecond > 0 and limit.burst >= 1, "invalid rate limit")
	local now = self._monotonic()
	local bucket = self._buckets[key]
	if not bucket then
		bucket = { tokens = limit.burst, updatedAt = now }
		self._buckets[key] = bucket
	else
		local elapsed = math.max(0, now - bucket.updatedAt)
		bucket.tokens = math.min(limit.burst, bucket.tokens + elapsed * limit.perSecond)
		bucket.updatedAt = now
	end
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

function RateLimiter.remaining(self: RateLimiter, key: string): number?
	local bucket = self._buckets[key]
	return bucket and bucket.tokens or nil
end

-- Removes every bucket whose key starts with the prefix (e.g. on player leave).
function RateLimiter.clearPrefix(self: RateLimiter, prefix: string)
	for key in pairs(self._buckets) do
		if string.sub(key, 1, #prefix) == prefix then
			self._buckets[key] = nil
		end
	end
end

-- Evicts buckets idle longer than `idleSeconds`.
function RateLimiter.sweep(self: RateLimiter, idleSeconds: number): number
	local now = self._monotonic()
	local removed = 0
	for key, bucket in pairs(self._buckets) do
		if now - bucket.updatedAt > idleSeconds then
			self._buckets[key] = nil
			removed += 1
		end
	end
	return removed
end

function RateLimiter.bucketCount(self: RateLimiter): number
	local n = 0
	for _ in pairs(self._buckets) do
		n += 1
	end
	return n
end

return RateLimiter
