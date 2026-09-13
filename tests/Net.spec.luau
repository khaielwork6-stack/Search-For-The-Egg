--!nocheck
-- Schema combinators, envelopes, rate limiter, and the message registry contract.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Schema = require(Shared.Net.Schema)
	local Envelope = require(Shared.Net.Envelope)
	local RateLimiter = require(Shared.Net.RateLimiter)
	local NetSchema = require(Shared.Net.NetSchema)
	local Config = require(Shared.Config)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))

	describe("Schema", function()
		it("rejects NaN, infinity, wrong types, and out-of-range numbers", function()
			local n = Schema.number({ min = 0, max = 10, integer = true })
			expect(Schema.validate(n, 5).ok).toBe(true)
			expect(Schema.validate(n, 0 / 0).ok).toBe(false)
			expect(Schema.validate(n, math.huge).ok).toBe(false)
			expect(Schema.validate(n, -math.huge).ok).toBe(false)
			expect(Schema.validate(n, "5").ok).toBe(false)
			expect(Schema.validate(n, 11).ok).toBe(false)
			expect(Schema.validate(n, 2.5).ok).toBe(false)
		end)

		it("bounds strings and validates patterns", function()
			local s = Schema.string({ max = 4 })
			expect(Schema.validate(s, "abcd").ok).toBe(true)
			expect(Schema.validate(s, "abcde").ok).toBe(false)
			expect(Schema.validate(s, 4).ok).toBe(false)
			expect(Schema.validate(Schema.id(), "nestRake").ok).toBe(true)
			expect(Schema.validate(Schema.id(), "nest rake").ok).toBe(false)
			expect(Schema.validate(Schema.id(), "").ok).toBe(false)
		end)

		it("strict objects reject unknown keys and missing required keys", function()
			local o = Schema.object({ a = Schema.number(), b = Schema.optional(Schema.boolean()) })
			expect(Schema.validate(o, { a = 1 }).ok).toBe(true)
			expect(Schema.validate(o, { a = 1, b = true }).ok).toBe(true)
			expect(Schema.validate(o, { a = 1, c = 1 }).ok).toBe(false)
			expect(Schema.validate(o, { b = true }).ok).toBe(false)
			expect(Schema.validate(o, "x").ok).toBe(false)
			expect(Schema.validate(o, { [1] = 1, a = 1 }).ok).toBe(false)
		end)

		it("arrays reject sparse, oversized, and mistyped entries", function()
			local arr = Schema.array(Schema.number(), { max = 3 })
			expect(Schema.validate(arr, { 1, 2, 3 }).ok).toBe(true)
			expect(Schema.validate(arr, { 1, 2, 3, 4 }).ok).toBe(false)
			expect(Schema.validate(arr, { 1, nil, 3 }).ok).toBe(false)
			expect(Schema.validate(arr, { "a" }).ok).toBe(false)
			expect(Schema.validate(arr, { x = 1 }).ok).toBe(false)
		end)

		it("enums and literals", function()
			local e = Schema.enum({ "normal", "hard" })
			expect(Schema.validate(e, "hard").ok).toBe(true)
			expect(Schema.validate(e, "HARD").ok).toBe(false)
			expect(Schema.validate(Schema.literal(3), 3).ok).toBe(true)
			expect(Schema.validate(Schema.literal(3), 4).ok).toBe(false)
		end)

		it("none accepts only nil or empty tables", function()
			expect(Schema.validate(Schema.none(), nil).ok).toBe(true)
			expect(Schema.validate(Schema.none(), {}).ok).toBe(true)
			expect(Schema.validate(Schema.none(), { a = 1 }).ok).toBe(false)
		end)

		it("vector3 rejects non-finite and huge vectors", function()
			local v = Schema.vector3(100)
			expect(Schema.validate(v, Vector3.new(1, 2, 3)).ok).toBe(true)
			expect(Schema.validate(v, Vector3.new(1000, 0, 0)).ok).toBe(false)
			expect(Schema.validate(v, Vector3.new(0 / 0, 0, 0)).ok).toBe(false)
			expect(Schema.validate(v, { X = 1, Y = 2, Z = 3 }).ok).toBe(false)
		end)

		it("measure flags oversized and deep payloads", function()
			local big = string.rep("x", 5000)
			local _, _, exceeded = Schema.measure({ s = big }, 2048, 6)
			expect(exceeded).toBe(true)
			local deep = {}
			local cursor = deep
			for _ = 1, 12 do
				cursor.n = {}
				cursor = cursor.n
			end
			local _, depth, tooDeep = Schema.measure(deep, 100000, 6)
			expect(tooDeep).toBe(true)
			expect(depth).toBeGreaterThan(6)
			local size, _, fine = Schema.measure({ a = 1, b = "hi" }, 2048, 6)
			expect(fine).toBe(false)
			expect(size).toBeGreaterThan(0)
		end)
	end)

	describe("Envelope", function()
		it("builds ok and fail envelopes with enumerated codes", function()
			local ok = Envelope.ok({ x = 1 })
			expect(ok.ok).toBe(true)
			expect(ok.data.x).toBe(1)
			local fail = Envelope.fail(Envelope.Codes.RATE_LIMITED)
			expect(fail.ok).toBe(false)
			expect(fail.code).toBe("rate_limited")
			expect(Envelope.isEnvelope(fail)).toBe(true)
		end)

		it("refuses unknown codes and long free-text messages", function()
			expect(function()
				Envelope.fail("stack trace leaked")
			end).toThrow()
			expect(function()
				Envelope.fail(Envelope.Codes.INTERNAL, string.rep("x", 200))
			end).toThrow()
		end)
	end)

	describe("RateLimiter", function()
		it("allows burst then throttles and refills over time", function()
			local now = 0
			local limiter = RateLimiter.new(function()
				return now
			end)
			local limit = { perSecond = cfg.interaction.collectRequestRatePerSecond, burst = cfg.interaction.remoteBurstAllowance }
			local allowed = 0
			for _ = 1, limit.burst + 3 do
				if limiter:tryConsume("p1:CollectAction", limit) then
					allowed += 1
				end
			end
			expect(allowed).toBe(limit.burst)
			now += 1 / limit.perSecond
			expect(limiter:tryConsume("p1:CollectAction", limit)).toBe(true)
			expect(limiter:tryConsume("p1:CollectAction", limit)).toBe(false)
			now += 10
			expect(limiter:remaining("p1:CollectAction")).toBe(0)
			expect(limiter:tryConsume("p1:CollectAction", limit)).toBe(true)
			expect(limiter:remaining("p1:CollectAction")).toBe(limit.burst - 1)
		end)

		it("keys are independent and clearable by prefix", function()
			local limiter = RateLimiter.new(function()
				return 0
			end)
			local limit = { perSecond = 1, burst = 1 }
			expect(limiter:tryConsume("p1:A", limit)).toBe(true)
			expect(limiter:tryConsume("p1:A", limit)).toBe(false)
			expect(limiter:tryConsume("p2:A", limit)).toBe(true)
			expect(limiter:bucketCount()).toBe(2)
			limiter:clearPrefix("p1:")
			expect(limiter:bucketCount()).toBe(1)
			expect(limiter:tryConsume("p1:A", limit)).toBe(true)
		end)

		it("sweep evicts idle buckets", function()
			local now = 0
			local limiter = RateLimiter.new(function()
				return now
			end)
			limiter:tryConsume("k", { perSecond = 1, burst = 1 })
			now = 100
			expect(limiter:sweep(30)).toBe(1)
			expect(limiter:bucketCount()).toBe(0)
		end)
	end)

	describe("NetSchema", function()
		local registry = NetSchema.build(cfg)

		it("declares every logical message from MASTER_SPEC section 13", function()
			for _, name in ipairs({
				"PartyCreate",
				"PartyJoin",
				"PartyLeave",
				"PartySetDestination",
				"PartyStart",
				"PartyCancel",
				"TutorialAction",
				"CollectAction",
				"ToolEquip",
				"ToolActionBegin",
				"ToolActionEnd",
				"SellRequest",
				"UpgradePurchase",
				"EggClaim",
				"ClassRoll",
				"ClassEquip",
				"DailyClaim",
				"CodeRedeem",
				"GroupRewardClaim",
				"InventoryEquip",
				"PerkPurchase",
				"LeaderboardRequest",
				"ResultsAction",
				"SettingsUpdate",
				"PurchasePromptRequest",
				"ProfileProjection",
				"PartyProjection",
				"RoundSnapshot",
				"RoundDelta",
				"ObjectiveChanged",
				"ActionResult",
				"SaleResult",
				"UpgradeResult",
				"EggRevealed",
				"VictoryStarted",
				"RewardsCommitted",
				"ResultsProjection",
				"Toast",
				"ModalDirective",
				"EntitlementsProjection",
				"PartyListProjection",
				"LeaderboardProjection",
				"RewardGranted",
			}) do
				expect(registry.byName[name]).toBeTruthy()
			end
		end)

		it("UpgradePurchase accepts structured tool upgrade ids and rejects free text", function()
			local def = registry.byName.UpgradePurchase
			local token = "tok-12345678"
			for _, id in ipairs({ "bag", "handGrasp", "nestRake.sweep", "confettiCharge.luckyBlast", "tool:scoutChick" }) do
				expect(Schema.validate(def.payload, { sessionToken = token, upgradeId = id, expectedLevel = 0 }).ok).toBe(true)
			end
			for _, id in ipairs({ "", "tool:nest rake", "nestRake/sweep", string.rep("a", 49) }) do
				expect(Schema.validate(def.payload, { sessionToken = token, upgradeId = id, expectedLevel = 0 }).ok).toBe(false)
			end
		end)

		it("every client request has a direction, schema, bounds, and rate from config", function()
			for _, def in ipairs(registry.list) do
				if def.direction == "clientToServer" then
					expect(def.kind).toBe("request")
					expect(def.rate.perSecond).toBeGreaterThan(0)
					expect(def.rate.burst).toBeGreaterThanOrEqual(1)
					expect(def.maxBytes).toBeGreaterThan(0)
				else
					expect(def.kind).toBe("event")
				end
			end
			expect(registry.byName.CollectAction.rate.perSecond).toBe(cfg.interaction.collectRequestRatePerSecond)
			expect(registry.byName.SellRequest.rate.perSecond).toBe(cfg.interaction.purchaseRequestRatePerSecond)
			expect(registry.byName.CollectAction.rate.burst).toBe(cfg.interaction.remoteBurstAllowance)
		end)

		it("has no generic method-dispatch message", function()
			for _, def in ipairs(registry.list) do
				expect(def.payload.kind == "object" or def.payload.kind == "none").toBe(true)
				if def.payload.kind == "object" then
					expect(def.payload.fields.method).toBeNil()
					expect(def.payload.fields.args).toBeNil()
				end
			end
		end)

		it("validates representative payloads", function()
			local party = registry.byName.PartyCreate.payload
			expect(Schema.validate(party, { chapter = "chapter1", difficulty = "normal" }).ok).toBe(true)
			expect(Schema.validate(party, { chapter = "chapter1", difficulty = "insane" }).ok).toBe(false)
			expect(Schema.validate(party, { chapter = "chapter1", difficulty = "normal", cash = 1e9 }).ok).toBe(false)
			local upgrade = registry.byName.UpgradePurchase.payload
			expect(Schema.validate(upgrade, { sessionToken = "abcdefgh", upgradeId = "bag", expectedLevel = 1 }).ok).toBe(true)
			expect(Schema.validate(upgrade, { sessionToken = "abcdefgh", upgradeId = "bag", expectedLevel = 1, price = 0 }).ok).toBe(false)
		end)
	end)
end
