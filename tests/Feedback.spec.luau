--!nocheck
-- Denial and notification spam gates: one refusal per reason per window (client UI/Feedback and the
-- server's sendDenial share Shared/Util/CooldownGate), and one notification per identical message.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local CooldownGate = require(Shared.Util.CooldownGate)
	local Tokens = require(Shared.Design.Tokens)
	local Config = require(Shared.Config)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))
	local Client = game:GetService("StarterPlayer").StarterPlayerScripts.Client

	local function fakeClock()
		local t = { now = 100 }
		return t, function()
			return t.now
		end
	end

	describe("CooldownGate", function()
		it("passes once, refuses inside the window, and passes again after it", function()
			local t, clock = fakeClock()
			local gate = CooldownGate.new(5, clock)
			expect(gate:tryPass("bag_full")).toBe(true)
			t.now += 1
			expect(gate:tryPass("bag_full")).toBe(false)
			t.now += 3.9
			expect(gate:tryPass("bag_full")).toBe(false)
			t.now += 0.1
			expect(gate:tryPass("bag_full")).toBe(true)
		end)

		it("does not extend the window while refusing", function()
			local t, clock = fakeClock()
			local gate = CooldownGate.new(5, clock)
			gate:tryPass("gems")
			for _ = 1, 32 do
				t.now += 0.125
				gate:tryPass("gems")
			end
			t.now += 1 -- 5 s after the first pass, although the last refusal was 1 s ago
			expect(gate:tryPass("gems")).toBe(true)
		end)

		it("keeps reasons independent", function()
			local _, clock = fakeClock()
			local gate = CooldownGate.new(5, clock)
			expect(gate:tryPass("bag_full")).toBe(true)
			expect(gate:tryPass("vac_cooling")).toBe(true)
			expect(gate:tryPass("bag_full")).toBe(false)
			expect(gate:isOpen("charge_cooling")).toBe(true)
		end)

		it("keys per player on the server and forgets a player who leaves", function()
			local _, clock = fakeClock()
			local gate = CooldownGate.new(5, clock)
			expect(gate:tryPass("1:sale:crate_busy")).toBe(true)
			expect(gate:tryPass("2:sale:crate_busy")).toBe(true)
			expect(gate:tryPass("1:sale:crate_busy")).toBe(false)
			gate:clearPrefix("1:")
			expect(gate:tryPass("1:sale:crate_busy")).toBe(true)
			expect(gate:tryPass("2:sale:crate_busy")).toBe(false)
		end)

		it("sweeps closed windows", function()
			local t, clock = fakeClock()
			local gate = CooldownGate.new(1.5, clock)
			gate:tryPass("a")
			gate:tryPass("b")
			t.now += 2
			gate:tryPass("c")
			gate:sweep()
			expect(gate:size()).toBe(1)
		end)

		it("treats identical text as one message", function()
			expect(CooldownGate.textKey("Bag full - trade your feathers")).toBe(CooldownGate.textKey("  bag full -  trade your FEATHERS "))
			expect(CooldownGate.textKey("Not enough Gems")).never.toBe(CooldownGate.textKey("Not enough round cash"))
		end)
	end)

	describe("Feedback.deny", function()
		local Feedback = require(Client.UI.Feedback)

		local function bindFake()
			local t, clock = fakeClock()
			local log = { sounds = {}, toasts = {} }
			Feedback.reset()
			Feedback.bind({
				config = cfg,
				clock = clock,
				play = function(role)
					table.insert(log.sounds, role)
				end,
				toasts = {
					push = function(_, text, tone)
						table.insert(log.toasts, { text = text, tone = tone })
					end,
				},
			})
			return t, log
		end

		it("shows and sounds a refusal once, then holds that reason for the configured five seconds", function()
			local t, log = bindFake()
			expect(cfg.hud.feedback.denialCooldownSeconds).toBe(5)
			expect(Feedback.deny("gems", "Not enough Gems")).toBe(true)
			for _ = 1, 16 do
				t.now += 0.25
				expect(Feedback.deny("gems", "Not enough Gems")).toBe(false)
			end
			expect(#log.sounds).toBe(1)
			expect(log.sounds[1]).toBe(Tokens.sound.uiError)
			expect(#log.toasts).toBe(1)
			expect(log.toasts[1].tone).toBe("warning")
			t.now += 1 -- 5 s after the first
			expect(Feedback.deny("gems", "Not enough Gems")).toBe(true)
			expect(#log.sounds).toBe(2)
			expect(Feedback.stats().suppressed).toBe(16)
		end)

		it("lets a different reason through inside another reason's window", function()
			local _, log = bindFake()
			Feedback.deny("bag_full", "Bag full - trade your feathers")
			expect(Feedback.deny("vac_cooling", "Feather Vac is still cooling")).toBe(true)
			expect(#log.toasts).toBe(2)
		end)

		it("honours silent and tone options", function()
			local _, log = bindFake()
			Feedback.deny("no_feathers", "Nothing left there", { tone = "info", silent = true })
			expect(#log.sounds).toBe(0)
			expect(log.toasts[1].tone).toBe("info")
			-- Sound-only refusals open the window too.
			Feedback.deny("equip_refused")
			expect(#log.sounds).toBe(1)
			expect(#log.toasts).toBe(1)
			expect(Feedback.canDeny("equip_refused")).toBe(false)
		end)

		it("reports a refused sale the same way from either path", function()
			local click = { ok = false, code = "invalid_state", message = "crate_busy" }
			local prompt = { ok = false, code = "invalid_state", message = "crate_busy" }
			expect(Feedback.saleReason(click)).toBe(Feedback.saleReason(prompt))
			expect(Feedback.saleText({ message = "nothing_to_sell" })).toBe("Your bag is empty")
		end)
	end)

	describe("Notification de-dupe", function()
		it("is configured", function()
			expect(cfg.hud.feedback.notificationDedupeSeconds).toBe(1.5)
		end)

		it("merges an identical toast pushed inside the window into the first", function()
			local Toast = require(Client.UI.Components.Toast)
			local t, clock = fakeClock()
			local gui = Instance.new("Frame")
			local toasts = Toast.new(gui, function()
				return {}
			end, { dedupeSeconds = 1.5, clock = clock })
			toasts._max = 0 -- queue only: no cards are built under lune
			expect(toasts:push("Aim at the nest", "info")).toBe(true)
			t.now += 0.5
			expect(toasts:push("Aim at the nest", "warning")).toBe(false)
			expect(toasts:reward("Aim at the nest", 5)).toBe(false)
			expect(toasts:push("Bag full - trade your feathers", "warning")).toBe(true)
			expect(#toasts._queue).toBe(2)
			expect(toasts.merged).toBe(2)
			t.now += 1.0
			expect(toasts:push("Aim at the nest", "info")).toBe(true)
			expect(#toasts._queue).toBe(3)
		end)
	end)
end
