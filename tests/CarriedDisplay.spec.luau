--!nocheck
-- Carried stack display model: the handless bundle grows one feather at a time with bag fullness,
-- logarithmically for an infinite bag, and never shows more than the cap.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local CarriedDisplay = require(Shared.Domain.CarriedDisplay)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local maxVisible = cfg.hud.carriedStack.maxVisibleFeathers

	describe("CarriedDisplay", function()
		it("caps the visible bundle at 10..12 feathers", function()
			expect(maxVisible).toBeGreaterThanOrEqual(10)
			expect(maxVisible).toBeLessThanOrEqual(12)
		end)

		it("scales a finite bag by fullness: empty shows nothing, one feather shows one, full shows the cap", function()
			expect(CarriedDisplay.count(cfg, 0, 20, false)).toBe(0)
			expect(CarriedDisplay.count(cfg, 1, 20, false)).toBe(1)
			expect(CarriedDisplay.count(cfg, 10, 20, false)).toBe(maxVisible / 2)
			expect(CarriedDisplay.count(cfg, 20, 20, false)).toBe(maxVisible)
			expect(CarriedDisplay.count(cfg, 25, 20, false)).toBe(maxVisible)
		end)

		it("grows progressively (never skips backwards, never stops early) as a finite bag fills", function()
			for _, capacity in ipairs({ 5, 20, 40, 100 }) do
				local last = 0
				local steps = 0
				for carried = 1, capacity do
					local count = CarriedDisplay.count(cfg, carried, capacity, false)
					expect(count).toBeGreaterThanOrEqual(last)
					expect(count - last).toBeLessThanOrEqual(math.max(1, math.ceil(maxVisible / capacity)))
					if count > last then
						steps += 1
					end
					last = count
				end
				expect(last).toBe(maxVisible)
				expect(steps).toBe(math.min(maxVisible, capacity))
			end
		end)

		it("grows logarithmically for an infinite bag and caps the visuals while the count keeps rising", function()
			local cap = cfg.hud.carriedStack.infiniteCapCount
			expect(CarriedDisplay.count(cfg, 0, 0, true)).toBe(0)
			expect(CarriedDisplay.count(cfg, 1, 0, true)).toBe(1)
			local early = CarriedDisplay.count(cfg, 10, 0, true)
			local mid = CarriedDisplay.count(cfg, 50, 0, true)
			expect(early).toBeGreaterThan(1)
			expect(mid).toBeGreaterThan(early)
			expect(mid).toBeLessThan(maxVisible)
			-- Front-loaded: the first ten feathers add more than the next forty.
			expect(early - 1).toBeGreaterThanOrEqual(mid - early)
			expect(CarriedDisplay.count(cfg, cap, 0, true)).toBe(maxVisible)
			expect(CarriedDisplay.count(cfg, cap * 50, 0, true)).toBe(maxVisible)
			local last = 0
			for carried = 1, cap * 2 do
				local count = CarriedDisplay.count(cfg, carried, 0, true)
				expect(count).toBeGreaterThanOrEqual(last)
				expect(count - last).toBeLessThanOrEqual(1)
				last = count
			end
		end)

		it("labels the bundle for reports", function()
			expect(CarriedDisplay.tier(0, maxVisible)).toBe("empty")
			expect(CarriedDisplay.tier(3, maxVisible)).toBe("partial")
			expect(CarriedDisplay.tier(maxVisible, maxVisible)).toBe("full")
		end)
	end)
end
