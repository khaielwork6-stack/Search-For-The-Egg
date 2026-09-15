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
		it("caps the visible bundle at a fixed number of feathers, never one per feather carried", function()
			expect(maxVisible).toBeGreaterThanOrEqual(10)
			expect(maxVisible).toBeLessThanOrEqual(24)
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

		it("shows the bag composition, and any rainbow at all is visible", function()
			local capacity = 20
			local total, rainbow = CarriedDisplay.split(cfg, 0, 0, capacity, false)
			expect(total).toBe(0)
			expect(rainbow).toBe(0)
			-- All ordinary: no rainbow feather in the bundle.
			local allStandard, noRainbow = CarriedDisplay.split(cfg, capacity, 0, capacity, false)
			expect(allStandard).toBe(maxVisible)
			expect(noRainbow).toBe(0)
			-- One Rainbow Feather in a full bag rounds to nothing by proportion, and still shows.
			local mixedTotal, mixedRainbow = CarriedDisplay.split(cfg, capacity - 1, 1, capacity, false)
			expect(mixedTotal).toBe(maxVisible)
			expect(mixedRainbow).toBe(1)
			-- A bag that is all rainbow shows a bundle that is all rainbow.
			local pureTotal, pureRainbow = CarriedDisplay.split(cfg, 0, capacity, capacity, false)
			expect(pureRainbow).toBe(pureTotal)
			-- Rainbow never outnumbers the bundle it sits in, at any mix.
			for standard = 0, capacity do
				local t, r = CarriedDisplay.split(cfg, standard, capacity - standard, capacity, false)
				expect(r).toBeLessThanOrEqual(t)
				expect(r).toBeGreaterThanOrEqual(0)
			end
			-- Same rules on an infinite bag.
			local infTotal, infRainbow = CarriedDisplay.split(cfg, 400, 2, 0, true)
			expect(infTotal).toBe(maxVisible)
			expect(infRainbow).toBe(1)
		end)

		it("labels the bundle for reports", function()
			expect(CarriedDisplay.tier(0, maxVisible)).toBe("empty")
			expect(CarriedDisplay.tier(3, maxVisible)).toBe("partial")
			expect(CarriedDisplay.tier(maxVisible, maxVisible)).toBe("full")
		end)
	end)
end
