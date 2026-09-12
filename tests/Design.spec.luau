--!nocheck
-- Design tokens and motion semantics stay consistent with configured polish budgets.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Tokens = require(Shared.Design.Tokens)
	local Motion = require(Shared.Design.Motion)
	local Config = require(Shared.Config)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))

	describe("Tokens", function()
		it("are frozen and mirror the configured minimum tap target", function()
			expect(table.isfrozen(Tokens.color)).toBe(true)
			expect(table.isfrozen(Tokens.motion)).toBe(true)
			expect(Tokens.layout.minimumTapTargetPx).toBe(cfg.polishBudgets.minimumTapTargetPixels)
		end)

		it("keep body text at or above the legibility floor", function()
			expect(Tokens.typography.body.size).toBeGreaterThanOrEqual(Tokens.typography.minimumBodySize)
			expect(Tokens.typography.caption.size).toBeGreaterThanOrEqual(Tokens.typography.minimumBodySize)
		end)

		it("provide prompts for every input mode with the same keys", function()
			for _, mode in ipairs({ "mouse", "touch", "gamepad" }) do
				local prompts = Tokens.prompts[mode]
				expect(prompts.primary).toBeType("string")
				expect(prompts.interact).toBeType("string")
				expect(prompts.cancel).toBeType("string")
			end
		end)

		it("motion tokens never exceed the configured UI tween cap", function()
			for name, value in pairs(Tokens.motion) do
				if type(value) == "number" and string.find(name, "Scale") == nil and string.find(name, "Overshoot") == nil then
					expect(value).toBeLessThanOrEqual(cfg.polishBudgets.maximumUiTweenSeconds)
				end
			end
		end)
	end)

	describe("SafeArea layout class", function()
		local SafeArea = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.UI.SafeArea)

		it("classifies landscape phone, tablet, and desktop viewports", function()
			expect(SafeArea.layoutClass(750, 361)).toBe("phone") -- iPhone 17 Pro landscape
			expect(SafeArea.layoutClass(705, 338)).toBe("phone") -- low-end Android landscape
			expect(SafeArea.layoutClass(1376, 1012)).toBe("tablet") -- iPad Pro
			expect(SafeArea.layoutClass(1279, 720)).toBe("desktop") -- Studio viewport
			expect(SafeArea.layoutClass(1920, 1080)).toBe("desktop")
			expect(SafeArea.scaleFor("phone")).toBe(Tokens.layout.phoneUiScale)
		end)
	end)

	describe("Motion", function()
		local settings = {
			reducedMotion = false,
			maximumUiTweenSeconds = cfg.polishBudgets.maximumUiTweenSeconds,
			reducedMotionScale = cfg.polishBudgets.reducedMotionScale,
		}

		it("caps durations and scales for reduced motion", function()
			expect(Motion.duration("standard", settings)).toBe(Tokens.motion.standard)
			local reduced = table.clone(settings)
			reduced.reducedMotion = true
			expect(Motion.duration("standard", reduced)).toBeCloseTo(Tokens.motion.standard * cfg.polishBudgets.reducedMotionScale, 1e-9)
			expect(Motion.amplitude(10, reduced)).toBeCloseTo(10 * cfg.polishBudgets.reducedMotionScale, 1e-9)
			local capped = table.clone(settings)
			capped.maximumUiTweenSeconds = 0.1
			expect(Motion.duration("slow", capped)).toBe(0.1)
		end)

		it("rejects unknown tokens", function()
			expect(function()
				Motion.duration("glacial", settings)
			end).toThrow()
		end)
	end)
end
