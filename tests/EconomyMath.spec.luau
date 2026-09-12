--!nocheck
-- Integer-cents economy primitives. Values come from SYSTEM_CONFIG, never restated here.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local EconomyMath = require(Shared.EconomyMath)
	local Config = require(Shared.Config)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))

	local standardCents = EconomyMath.dollarsToCents(cfg.selling.cashPerStandardFeather)
	local neutral = {
		standardCents = standardCents,
		rainbowMultiplier = cfg.selling.rainbowFeatherMultiplier,
		classSellMultiplier = 1,
		perkSellMultiplier = 1,
	}

	describe("conversions", function()
		it("converts configured dollar prices to exact cents", function()
			expect(standardCents).toBe(1)
			expect(EconomyMath.dollarsToCents(cfg.tools.featherVac.softCashPrice)).toBe(6999)
			expect(EconomyMath.dollarsToCents(cfg.bags.levels[1].upgradeCash)).toBe(100)
			expect(EconomyMath.dollarsToCents(0.29)).toBe(29)
			expect(EconomyMath.dollarsToCents(1.005)).toBe(101)
		end)

		it("formats cents for display", function()
			expect(EconomyMath.formatCents(25)).toBe("$0.25")
			expect(EconomyMath.formatCents(6999)).toBe("$69.99")
			expect(EconomyMath.formatCents(0)).toBe("$0.00")
			expect(EconomyMath.formatCents(100000)).toBe("$1000.00")
		end)

		it("rounds half up deterministically", function()
			expect(EconomyMath.roundHalfUp(2.5)).toBe(3)
			expect(EconomyMath.roundHalfUp(2.4999)).toBe(2)
			expect(EconomyMath.applyMultiplierCents(25, 1.1)).toBe(28)
			expect(EconomyMath.applyMultiplierCents(25, 0.75)).toBe(19)
		end)

		it("rejects NaN and infinity", function()
			expect(function()
				EconomyMath.dollarsToCents(0 / 0)
			end).toThrow()
			expect(function()
				EconomyMath.applyMultiplierCents(10, math.huge)
			end).toThrow()
		end)
	end)

	describe("sale", function()
		it("sells the starting bag for the configured value (25 -> 25 cents, 50 -> 50 cents)", function()
			local start = cfg.collection.startingBagCapacity
			local sale = EconomyMath.computeSale({ standardCount = start, rainbowCount = 0 }, neutral)
			expect(sale.finalCents).toBe(start * standardCents)
			expect(sale.finalCents).toBe(25)
			local double = EconomyMath.computeSale({ standardCount = cfg.bags.levels[2].capacity, rainbowCount = 0 }, neutral)
			expect(double.finalCents).toBe(50)
		end)

		it("applies rainbow, class, and perk multipliers exactly once each", function()
			local sale = EconomyMath.computeSale({ standardCount = 10, rainbowCount = 2 }, {
				standardCents = standardCents,
				rainbowMultiplier = cfg.selling.rainbowFeatherMultiplier,
				classSellMultiplier = 1.2,
				perkSellMultiplier = 1.5,
			})
			-- base 10, rainbow 2*1*5 = 10, class (20*1.2)=24, perk 24*1.5 = 36
			expect(sale.baseCents).toBe(10)
			expect(sale.rainbowCents).toBe(10)
			expect(sale.classAdjustedCents).toBe(24)
			expect(sale.finalCents).toBe(36)
		end)

		it("never drifts across 10,000 transactions", function()
			local total = 0
			for _ = 1, 10000 do
				total += EconomyMath.computeSale({ standardCount = 3, rainbowCount = 1 }, neutral).finalCents
			end
			expect(total).toBe(10000 * 8)
			expect(total % 1).toBe(0)
		end)

		it("rejects fractional or negative counts", function()
			expect(function()
				EconomyMath.computeSale({ standardCount = 1.5, rainbowCount = 0 }, neutral)
			end).toThrow()
			expect(function()
				EconomyMath.computeSale({ standardCount = -1, rainbowCount = 0 }, neutral)
			end).toThrow()
		end)
	end)

	describe("bag", function()
		it("computes capacity in the specified order and floors", function()
			local cap = EconomyMath.bagCapacity({
				roundBagLevelCapacity = cfg.bags.levels[1].capacity,
				permanentBagPerkMultiplier = 1.1,
				classBagMultiplier = 1.5,
				infiniteBag = false,
			})
			expect(cap.infinite).toBe(false)
			expect(cap.capacity).toBe(math.floor(25 * 1.1 * 1.5))
		end)

		it("uses an explicit infinite state instead of a sentinel", function()
			local cap = EconomyMath.bagCapacity({
				roundBagLevelCapacity = 25,
				permanentBagPerkMultiplier = 1,
				classBagMultiplier = 1,
				infiniteBag = true,
			})
			expect(cap.infinite).toBe(true)
			local accepted, overflow = EconomyMath.clampToBag(1000000, 500, cap)
			expect(accepted).toBe(500)
			expect(overflow).toBe(0)
		end)

		it("clamps normal collection to free space", function()
			local cap = { infinite = false, capacity = 25 }
			local accepted, overflow = EconomyMath.clampToBag(20, 8, cap)
			expect(accepted).toBe(5)
			expect(overflow).toBe(3)
			local full, over = EconomyMath.clampToBag(25, 1, cap)
			expect(full).toBe(0)
			expect(over).toBe(1)
		end)
	end)

	describe("currency bounds", function()
		it("clamps to configured ranges", function()
			local gems = cfg.currencies.gems
			local v, clamped = EconomyMath.clampCurrency(gems.maximum + 5, gems.minimum, gems.maximum)
			expect(v).toBe(gems.maximum)
			expect(clamped).toBe(true)
			local nan = EconomyMath.clampCurrency(0 / 0, gems.minimum, gems.maximum)
			expect(nan).toBe(gems.minimum)
		end)

		it("addBounded saturates and reports the applied delta", function()
			local balance, applied = EconomyMath.addBounded(95, 10, 100)
			expect(balance).toBe(100)
			expect(applied).toBe(5)
			local neg, negApplied = EconomyMath.addBounded(3, -5, 100)
			expect(neg).toBe(0)
			expect(negApplied).toBe(-3)
		end)

		it("computes permanent perk cost curves from config", function()
			local perk = cfg.permanentPerks.bagSize
			expect(EconomyMath.perkCostGems(perk.baseGemCost, perk.costGrowth, 0)).toBe(perk.baseGemCost)
			expect(EconomyMath.perkCostGems(perk.baseGemCost, perk.costGrowth, 1)).toBe(
				EconomyMath.roundHalfUp(perk.baseGemCost * perk.costGrowth)
			)
		end)
	end)
end
