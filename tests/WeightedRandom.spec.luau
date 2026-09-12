--!nocheck
-- Weighted RNG boundaries, determinism, and the ASSUMED luck transform.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local WeightedRandom = require(Shared.WeightedRandom)
	local Config = require(Shared.Config)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))
	local classWeights = Config.classWeights(cfg)

	describe("deterministic rng", function()
		it("same seed produces the same sequence", function()
			local a = WeightedRandom.fromSeed(12345)
			local b = WeightedRandom.fromSeed(12345)
			for _ = 1, 50 do
				expect(a:next()).toBe(b:next())
			end
		end)

		it("different seeds diverge and stay within [0,1)", function()
			local a = WeightedRandom.fromSeed(1)
			local b = WeightedRandom.fromSeed(2)
			local same = 0
			for _ = 1, 100 do
				local x, y = a:next(), b:next()
				expect(x).toBeGreaterThanOrEqual(0)
				expect(x).toBeLessThan(1)
				if x == y then
					same += 1
				end
			end
			expect(same).toBeLessThan(5)
		end)

		it("nextInteger stays within bounds", function()
			local rng = WeightedRandom.fromSeed(99)
			for _ = 1, 200 do
				local v = rng:nextInteger(3, 7)
				expect(v).toBeGreaterThanOrEqual(3)
				expect(v).toBeLessThanOrEqual(7)
				expect(v % 1).toBe(0)
			end
		end)
	end)

	describe("selection boundaries", function()
		it("selects every class interval at its exact start and just before its end", function()
			local intervals = WeightedRandom.intervals(classWeights)
			for _, entry in ipairs(classWeights) do
				local interval = intervals[entry.id]
				expect(WeightedRandom.selectByRoll(classWeights, interval.start).id).toBe(entry.id)
				expect(WeightedRandom.selectByRoll(classWeights, interval.finish - 1e-12).id).toBe(entry.id)
			end
		end)

		it("roll 0 picks the first entry and roll just below 1 picks the last", function()
			expect(WeightedRandom.selectByRoll(classWeights, 0).id).toBe(classWeights[1].id)
			expect(WeightedRandom.selectByRoll(classWeights, 1 - 1e-12).id).toBe(classWeights[#classWeights].id)
		end)

		it("never selects zero-weight entries", function()
			local entries = { { id = "a", weight = 0 }, { id = "b", weight = 1 }, { id = "c", weight = 0 } }
			for roll = 0, 0.99, 0.01 do
				expect(WeightedRandom.selectByRoll(entries, roll).id).toBe("b")
			end
		end)

		it("rejects rolls outside [0,1) and negative weights", function()
			expect(function()
				WeightedRandom.selectByRoll(classWeights, 1)
			end).toThrow()
			expect(function()
				WeightedRandom.selectByRoll({ { id = "x", weight = -1 } }, 0.5)
			end).toThrow()
		end)

		it("event chest intervals cover the whole line", function()
			local rewards = {}
			for _, reward in ipairs(cfg.monetization.eventChest.rewards) do
				table.insert(rewards, { id = reward.id, weight = reward.weight })
			end
			local intervals = WeightedRandom.intervals(rewards)
			expect(intervals[rewards[#rewards].id].finish).toBeCloseTo(1, 1e-9)
		end)
	end)

	describe("statistical smoke", function()
		it("100,000 seeded rolls land within a generous tolerance of configured odds", function()
			local rng = WeightedRandom.fromSeed(2026)
			local counts = {}
			local n = 100000
			for _ = 1, n do
				local picked = WeightedRandom.select(classWeights, rng)
				counts[picked.id] = (counts[picked.id] or 0) + 1
			end
			for _, entry in ipairs(classWeights) do
				local observed = (counts[entry.id] or 0) / n * 100
				local tolerance = math.max(0.35, entry.weight * 0.2)
				expect(math.abs(observed - entry.weight)).toBeLessThanOrEqual(tolerance)
			end
		end)
	end)

	describe("luck transform (ASSUMED A-CLS-01)", function()
		it("doubles rare classes, keeps weights non-negative, and totals exactly 100", function()
			local transformed = WeightedRandom.applyLuckTransform(classWeights, cfg.classes.luckTransform)
			local total = 0
			local byId = {}
			for _, entry in ipairs(transformed) do
				expect(entry.weight).toBeGreaterThanOrEqual(0)
				total += entry.weight
				byId[entry.id] = entry.weight
			end
			expect(total).toBeCloseTo(100, 1e-9)
			for _, entry in ipairs(classWeights) do
				if entry.id ~= "newcomer" and entry.weight <= cfg.classes.luckTransform.rareWeightThreshold then
					expect(byId[entry.id]).toBeCloseTo(entry.weight * 2, 1e-9)
				elseif entry.id ~= "newcomer" then
					expect(byId[entry.id]).toBeCloseTo(entry.weight, 1e-9)
				end
			end
			expect(byId.newcomer).toBeLessThan(Config.class(cfg, "newcomer").weight)
		end)

		it("does not mutate the input weights", function()
			local before = classWeights[1].weight
			WeightedRandom.applyLuckTransform(classWeights, cfg.classes.luckTransform)
			expect(classWeights[1].weight).toBe(before)
		end)

		it("refuses to drive the baseline negative", function()
			local entries = { { id = "newcomer", weight = 5 }, { id = "rare", weight = 9 }, { id = "common", weight = 86 } }
			expect(function()
				WeightedRandom.applyLuckTransform(entries, cfg.classes.luckTransform)
			end).toThrow("negative")
		end)

		it("rejects unknown modes", function()
			expect(function()
				WeightedRandom.applyLuckTransform(classWeights, { mode = "something_else", rareWeightThreshold = 9 })
			end).toThrow()
		end)
	end)
end
