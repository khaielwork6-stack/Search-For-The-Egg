--!nocheck
-- Remote registry pipeline: unknown messages, oversized/malformed payloads, rate limits,
-- handler errors, envelope sanitization, and security sampling.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local Envelope = require(Shared.Net.Envelope)
	local RemoteRegistryCore = require(Server.Net.RemoteRegistryCore)
	local SecurityService = require(Server.Services.SecurityService)
	local Log = require(Server.Log)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	local function harness()
		local now = 0
		local log, lines = Log.capture("net")
		local security = SecurityService.new({ log = log, sampleRate = 1 })
		local core = RemoteRegistryCore.new({
			config = cfg,
			monotonic = function()
				return now
			end,
			security = security,
			log = log,
		})
		return {
			core = core,
			security = security,
			lines = lines,
			advance = function(seconds)
				now += seconds
			end,
			player = { UserId = 100, Name = "TestPlayer" },
		}
	end

	describe("handleRequest", function()
		it("rejects unknown message names and non-string names", function()
			local h = harness()
			expect(h.core:handleRequest("DoAnything", h.player, {}).code).toBe(Envelope.Codes.UNKNOWN_MESSAGE)
			expect(h.core:handleRequest(nil, h.player, {}).code).toBe(Envelope.Codes.UNKNOWN_MESSAGE)
			expect(h.core:handleRequest("ProfileProjection", h.player, {}).code).toBe(Envelope.Codes.UNKNOWN_MESSAGE)
			expect(h.security:countFor(100)).toBe(3)
		end)

		it("rejects oversized and deeply nested payloads before schema validation", function()
			local h = harness()
			h.core:registerHandler("PartyJoin", function()
				return Envelope.ok()
			end)
			local huge = { partyId = string.rep("a", 10000) }
			expect(h.core:handleRequest("PartyJoin", h.player, huge).code).toBe(Envelope.Codes.PAYLOAD_TOO_LARGE)
			local deep = { partyId = "abcdefgh" }
			local cursor = deep
			for _ = 1, 20 do
				cursor.n = {}
				cursor = cursor.n
			end
			expect(h.core:handleRequest("PartyJoin", h.player, deep).code).toBe(Envelope.Codes.PAYLOAD_TOO_LARGE)
		end)

		it("rejects malformed payloads: wrong types, NaN, unknown keys, bad enums", function()
			local h = harness()
			local calls = 0
			h.core:registerHandler("PartyCreate", function()
				calls += 1
				return Envelope.ok()
			end)
			local bad = {
				"string",
				{ chapter = 5, difficulty = "normal" },
				{ chapter = "chapter1", difficulty = "impossible" },
				{ chapter = "chapter1", difficulty = "normal", gems = 1e9 },
				{ chapter = "chapter1" },
				{ chapter = "chapter1", difficulty = "normal", [1] = 0 / 0 },
			}
			for _, payload in ipairs(bad) do
				expect(h.core:handleRequest("PartyCreate", h.player, payload).code).toBe(Envelope.Codes.INVALID_PAYLOAD)
				h.advance(1) -- rate limiting runs before schema validation by design; keep tokens available
			end
			expect(calls).toBe(0)
			expect(h.core:handleRequest("PartyCreate", h.player, { chapter = "chapter1", difficulty = "normal" }).ok).toBe(true)
			expect(calls).toBe(1)
		end)

		it("rate-limits per player per message using configured rates and samples to telemetry", function()
			local h = harness()
			h.core:registerHandler("SellRequest", function()
				return Envelope.ok()
			end)
			local payload = { sessionToken = "abcdefgh" }
			local burst = cfg.interaction.remoteBurstAllowance
			local accepted, limited = 0, 0
			for _ = 1, burst * 3 do
				local result = h.core:handleRequest("SellRequest", h.player, payload)
				if result.ok then
					accepted += 1
				elseif result.code == Envelope.Codes.RATE_LIMITED then
					limited += 1
				end
			end
			expect(accepted).toBe(burst)
			expect(limited).toBe(burst * 2)
			expect(h.security:countFor(100, "SellRequest", Envelope.Codes.RATE_LIMITED)).toBe(burst * 2)
			expect(#h.lines).toBeGreaterThanOrEqual(burst * 2)
			-- another player has an independent bucket
			expect(h.core:handleRequest("SellRequest", { UserId = 200 }, payload).ok).toBe(true)
			-- refills over time
			h.advance(1 / cfg.interaction.purchaseRequestRatePerSecond)
			expect(h.core:handleRequest("SellRequest", h.player, payload).ok).toBe(true)
		end)

		it("returns UNAVAILABLE for validated requests with no handler yet", function()
			local h = harness()
			local result = h.core:handleRequest("EggClaim", h.player, { sessionToken = "abcdefgh" })
			expect(result.ok).toBe(false)
			expect(result.code).toBe(Envelope.Codes.UNAVAILABLE)
		end)

		it("sanitizes handler errors and non-envelope returns", function()
			local h = harness()
			h.core:registerHandler("PartyLeave", function()
				error("secret internal stack detail")
			end)
			local result = h.core:handleRequest("PartyLeave", h.player, nil)
			expect(result.ok).toBe(false)
			expect(result.code).toBe(Envelope.Codes.INTERNAL)
			expect(result.message).toBeNil()
			expect(h.core.stats.handlerErrors).toBe(1)

			h.core:registerHandler("DailyClaim", function()
				return { gems = 100 }
			end)
			local raw = h.core:handleRequest("DailyClaim", h.player, nil)
			expect(raw.code).toBe(Envelope.Codes.INTERNAL)
		end)

		it("refuses duplicate or server-event handler registration", function()
			local h = harness()
			h.core:registerHandler("PartyLeave", function()
				return Envelope.ok()
			end)
			expect(function()
				h.core:registerHandler("PartyLeave", function()
					return Envelope.ok()
				end)
			end).toThrow()
			expect(function()
				h.core:registerHandler("Toast", function()
					return Envelope.ok()
				end)
			end).toThrow()
			expect(function()
				h.core:registerHandler("NotAMessage", function()
					return Envelope.ok()
				end)
			end).toThrow()
		end)

		it("validates outgoing events", function()
			local h = harness()
			expect(h.core:validateOutgoing("Toast", { key = "hello", tone = "info" })).toBe(true)
			expect(h.core:validateOutgoing("PartyCreate", {})).toBe(false)
			expect(h.core:validateOutgoing("Toast", "text")).toBe(false)
			local ok = h.core:validateOutgoing("ProfileProjection", { projection = { s = string.rep("x", 70000) } })
			expect(ok).toBe(false)
		end)

		it("forgetPlayer clears rate buckets", function()
			local h = harness()
			h.core:registerHandler("PartyLeave", function()
				return Envelope.ok()
			end)
			for _ = 1, cfg.interaction.remoteBurstAllowance do
				h.core:handleRequest("PartyLeave", h.player, nil)
			end
			expect(h.core:handleRequest("PartyLeave", h.player, nil).code).toBe(Envelope.Codes.RATE_LIMITED)
			h.core:forgetPlayer(100)
			expect(h.core:handleRequest("PartyLeave", h.player, nil).ok).toBe(true)
		end)
	end)
end
