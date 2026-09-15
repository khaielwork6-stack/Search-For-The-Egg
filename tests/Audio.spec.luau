--!nocheck
-- Every sound the game plays is config data now, so it can be checked without a client. These are
-- the owner's 15 Sep 2026 assignments and the rules that keep one event from making two sounds.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Tokens = require(Shared.Design.Tokens)
	local Config = require(Shared.Config)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))
	local roles = cfg.audio.roles

	describe("Owner assignments", function()
		it("puts each supplied id on the moment it belongs to", function()
			-- The rake's sound is the contact, not the swing.
			expect(roles["tool.rakeImpact"].id).toBe("rbxassetid://81267530921314")
			expect(roles["tool.vacMotor"].id).toBe("rbxassetid://91395529514868")
			expect(roles["tool.blast"].id).toBe("rbxassetid://124256466623788")
			expect(roles["class.land"].id).toBe("rbxassetid://90853027572825")
			expect(roles["ui.pageFlip"].id).toBe("rbxassetid://114448027739800")
			expect(roles["music.search"].id).toBe("rbxassetid://130867147321580")
		end)

		it("silences the spinner's own sound so a reroll only sounds when it lands", function()
			expect(roles["class.spin"].id).toBe("")
			expect(roles["class.land"].id).never.toBe("")
		end)

		it("gives the rake and the vac exactly one sound each", function()
			-- The placeholder swing whoosh and the one-shot suck are gone: the contact and the loop
			-- are the whole of each tool's voice.
			expect(roles["tool.rakeSwing"].id).toBe("")
			expect(roles["tool.vacSuck"].id).toBe("")
			expect(roles["tool.vacMotor"].looped).toBe(true)
		end)
	end)

	describe("Music", function()
		it("plays in a round and not in the lobby", function()
			expect(roles[cfg.audio.music.Lobby].id).toBe("")
			for _, state in ipairs({ "Search", "Discovery", "Victory", "Results" }) do
				expect(roles[cfg.audio.music[state]].id).toBe("rbxassetid://130867147321580")
			end
		end)

		it("fades rather than cuts, and sits under the effects", function()
			expect(cfg.audio.musicFadeSeconds).toBeGreaterThan(0.5)
			expect(cfg.audio.loopFadeSeconds).toBeGreaterThan(0)
			-- Balance: every gameplay effect the owner supplied reads above the music bed.
			for _, role in ipairs({ "tool.rakeImpact", "tool.blast", "tool.vacMotor", "class.land", "ui.pageFlip" }) do
				expect(roles[role].volume).toBeGreaterThan(cfg.audio.musicVolume)
			end
			-- ...and none of them is loud enough to clip against the rest of the mix.
			expect(roles["tool.blast"].volume).toBeLessThanOrEqual(0.9)
		end)
	end)

	describe("One denial, one sound", function()
		it("throttles the refusal roles together", function()
			-- Both roles are the same refusal asset played by different callers. Sharing a group means
			-- the second one inside the window is dropped instead of doubling.
			expect(roles["ui.error"].group).toBe("denial")
			expect(roles["collect.bagFull"].group).toBe(roles["ui.error"].group)
			expect(roles["ui.error"].id).toBe(roles["collect.bagFull"].id)
			expect(roles["ui.error"].minGap).toBeGreaterThan(0)
			expect(roles["collect.bagFull"].minGap).toBeGreaterThan(0)
		end)
	end)

	describe("Coverage", function()
		it("defines every role the client asks for", function()
			-- A role the code plays but the config omits would only surface as a runtime warning.
			local missing = {}
			for name, role in pairs(Tokens.sound) do
				if roles[role] == nil then
					table.insert(missing, name .. " (" .. tostring(role) .. ")")
				end
			end
			expect(table.concat(missing, ", ")).toBe("")
		end)

		it("keeps every mix value inside its bounds", function()
			for role, tuning in pairs(roles) do
				expect(type(tuning.id) == "string").toBe(true)
				expect(tuning.volume >= 0 and tuning.volume <= 1).toBe(true)
				expect(tuning.speed > 0).toBe(true)
				expect(tuning.minGap >= 0).toBe(true)
				expect(role ~= "").toBe(true)
			end
		end)
	end)
end
