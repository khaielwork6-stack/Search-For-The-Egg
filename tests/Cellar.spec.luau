--!nocheck
-- Chapter 2 shared puzzle machine: solution generation from validated sets, stage ordering, wrong /
-- repeated / concurrent inputs, reset recovery, projection safety, and reachability of victory
-- from every generated solution.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local WeightedRandom = require(Shared.WeightedRandom)
	local CellarPuzzles = require(Shared.Domain.CellarPuzzles)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local p = cfg.chapters.chapter2.puzzles

	local function solve(state, solution, userId)
		-- Drives a state to "done" using only the solution; returns the state and the actions used.
		local actions = 0
		local function step(action)
			actions += 1
			local next, res = CellarPuzzles.apply(cfg, state, solution, action, userId or 1, actions)
			assert(res.ok, "unexpected refusal at stage " .. res.stage .. ": " .. tostring(res.code) .. " " .. tostring(res.message))
			state = next
		end
		state = CellarPuzzles.revealKey(state)
		step({ kind = "pickupKey" })
		for _, index in ipairs(solution.leverOrder) do
			step({ kind = "lever", index = index })
		end
		step({ kind = "crystals", value = solution.crystalCount })
		step({ kind = "code", value = solution.code })
		for index, turns in ipairs(state.tiles.rotations) do
			for _ = 1, (4 - turns) % 4 do
				step({ kind = "tile", index = index })
			end
		end
		step({ kind = "release" })
		return state, actions
	end

	describe("Generation", function()
		it("produces a valid solution from the configured sets for many seeds", function()
			for seed = 1, 200 do
				local solution = CellarPuzzles.generate(cfg, WeightedRandom.fromSeed(seed))
				local seen = {}
				expect(#solution.leverOrder).toBe(p.leverCount)
				for _, index in ipairs(solution.leverOrder) do
					expect(index >= 1 and index <= p.leverCount).toBe(true)
					expect(seen[index]).toBeNil()
					seen[index] = true
				end
				expect(solution.crystalCount >= p.crystalCountRange.min and solution.crystalCount <= p.crystalCountRange.max).toBe(true)
				expect(#solution.code).toBe(p.codeDigits)
				expect(string.match(solution.code, "^%d+$")).toBeTruthy()
				if p.codeDistinctDigits then
					local digits = {}
					for i = 1, #solution.code do
						local d = string.sub(solution.code, i, i)
						expect(digits[d]).toBeNil()
						digits[d] = true
					end
				end
				expect(#solution.tileScramble).toBe(p.tileRotationPuzzleSize)
				local scrambled = 0
				for _, turns in ipairs(solution.tileScramble) do
					expect(turns >= 0 and turns <= 3).toBe(true)
					if turns ~= 0 then
						scrambled += 1
					end
				end
				expect(scrambled >= p.tileMinimumScrambled).toBe(true)
				local slots = {}
				for _, note in ipairs(solution.codeNotes) do
					expect(slots[note.slot]).toBeNil()
					slots[note.slot] = true
					expect(note.digit).toBe(string.sub(solution.code, note.position, note.position))
				end
			end
		end)

		it("is deterministic for a seed and different across seeds", function()
			local a = CellarPuzzles.generate(cfg, WeightedRandom.fromSeed(7))
			local b = CellarPuzzles.generate(cfg, WeightedRandom.fromSeed(7))
			local c = CellarPuzzles.generate(cfg, WeightedRandom.fromSeed(8))
			expect(a.code).toBe(b.code)
			expect(a.leverOrder).toEqual(b.leverOrder)
			expect(a.code == c.code and a.crystalCount == c.crystalCount and table.concat(a.leverOrder) == table.concat(c.leverOrder)).toBe(
				false
			)
		end)
	end)

	describe("Reachability", function()
		it("every generated solution reaches the exit stage with only correct inputs", function()
			for seed = 1, 100 do
				local solution = CellarPuzzles.generate(cfg, WeightedRandom.fromSeed(seed))
				local state = CellarPuzzles.newState(cfg, solution)
				local final = solve(state, solution)
				expect(CellarPuzzles.currentStage(cfg, final)).toBe("exit")
				expect(final.tiles.solved).toBe(true)
				expect(final.hatchling.released).toBe(true)
				for _, stage in ipairs(p.order) do
					if stage ~= "exit" then
						expect(final.completedAt[stage]).toBeTruthy()
					end
				end
			end
		end)
	end)

	describe("Ordering and feedback", function()
		local solution = CellarPuzzles.generate(cfg, WeightedRandom.fromSeed(3))

		it("refuses inputs for later stages with not_yet and for earlier stages with already_done", function()
			local state = CellarPuzzles.newState(cfg, solution)
			local _, res = CellarPuzzles.apply(cfg, state, solution, { kind = "lever", index = 1 }, 1, 1)
			expect(res.ok).toBe(false)
			expect(res.code).toBe("not_yet")
			local _, hidden = CellarPuzzles.apply(cfg, state, solution, { kind = "pickupKey" }, 1, 1)
			expect(hidden.code).toBe("not_yet")
			state = CellarPuzzles.revealKey(state)
			local afterKey, taken = CellarPuzzles.apply(cfg, state, solution, { kind = "pickupKey" }, 1, 1)
			expect(taken.ok).toBe(true)
			expect(taken.solvedStage).toBe("findKey")
			expect(afterKey.key.heldBy).toBe(1)
			local _, again = CellarPuzzles.apply(cfg, afterKey, solution, { kind = "pickupKey" }, 2, 2)
			expect(again.code).toBe("already_done")
			local _, exitTry = CellarPuzzles.apply(cfg, afterKey, solution, { kind = "exit" }, 1, 1)
			expect(exitTry.code).toBe("invalid")
		end)

		it("a wrong lever resets the sequence without corrupting the solution; the right order still wins", function()
			local state = CellarPuzzles.revealKey(CellarPuzzles.newState(cfg, solution))
			state = CellarPuzzles.apply(cfg, state, solution, { kind = "pickupKey" }, 1, 1)
			local first = solution.leverOrder[1]
			local wrong = solution.leverOrder[2]
			state = CellarPuzzles.apply(cfg, state, solution, { kind = "lever", index = first }, 1, 1)
			expect(state.levers.progress).toBe(1)
			local reset, res = CellarPuzzles.apply(cfg, state, solution, { kind = "lever", index = solution.leverOrder[3] }, 2, 2)
			expect(res.code).toBe("wrong")
			expect(res.feedback).toBe("sequence_reset")
			expect(reset.levers.progress).toBe(0)
			expect(reset.levers.resets).toBe(1)
			-- Repeated press of an already-lit lever is refused, not reset.
			local lit = CellarPuzzles.apply(cfg, reset, solution, { kind = "lever", index = first }, 1, 3)
			local same, repeatRes = CellarPuzzles.apply(cfg, lit, solution, { kind = "lever", index = first }, 3, 4)
			expect(repeatRes.code).toBe("already_done")
			expect(same.levers.progress).toBe(1)
			local _ = wrong
			for i = 2, #solution.leverOrder do
				lit = CellarPuzzles.apply(cfg, lit, solution, { kind = "lever", index = solution.leverOrder[i] }, i, 10 + i)
			end
			expect(CellarPuzzles.currentStage(cfg, lit)).toBe("solveCrystals")
		end)

		it("count and code give layered feedback and unlimited attempts; invalid payloads never count", function()
			local state = CellarPuzzles.revealKey(CellarPuzzles.newState(cfg, solution))
			state = CellarPuzzles.apply(cfg, state, solution, { kind = "pickupKey" }, 1, 1)
			for _, index in ipairs(solution.leverOrder) do
				state = CellarPuzzles.apply(cfg, state, solution, { kind = "lever", index = index }, 1, 1)
			end
			local low, lowRes = CellarPuzzles.apply(cfg, state, solution, { kind = "crystals", value = solution.crystalCount - 1 }, 1, 1)
			expect(lowRes.feedback).toBe("too_low")
			local high, highRes = CellarPuzzles.apply(cfg, low, solution, { kind = "crystals", value = solution.crystalCount + 3 }, 1, 1)
			expect(highRes.feedback).toBe("too_high")
			expect(high.crystals.attempts).toBe(2)
			local _, bad = CellarPuzzles.apply(cfg, high, solution, { kind = "crystals", value = "seven" }, 1, 1)
			expect(bad.code).toBe("invalid")
			local solved = CellarPuzzles.apply(cfg, high, solution, { kind = "crystals", value = solution.crystalCount }, 1, 1)
			expect(CellarPuzzles.currentStage(cfg, solved)).toBe("solveCode")
			local wrongCode = string.sub(solution.code, 1, 2)
				.. string.format(
					"%d%d",
					(tonumber(string.sub(solution.code, 3, 3)) + 1) % 10,
					(tonumber(string.sub(solution.code, 4, 4)) + 1) % 10
				)
			local _, codeRes = CellarPuzzles.apply(cfg, solved, solution, { kind = "code", value = wrongCode }, 1, 1)
			expect(codeRes.code).toBe("wrong")
			expect(codeRes.extra.matches).toBe(2)
			local _, malformed = CellarPuzzles.apply(cfg, solved, solution, { kind = "code", value = "12a4" }, 1, 1)
			expect(malformed.code).toBe("invalid")
		end)

		it("tiles can always be rotated back, reset restores the scramble, and concurrent turns stay consistent", function()
			local state = CellarPuzzles.newState(cfg, solution)
			state.stageIndex = 5 -- solveTiles (test shortcut through the state, never through inputs)
			local a = CellarPuzzles.apply(cfg, state, solution, { kind = "tile", index = 1 }, 1, 1)
			local b = CellarPuzzles.apply(cfg, a, solution, { kind = "tile", index = 1 }, 2, 1)
			expect(b.tiles.rotations[1]).toBe((solution.tileScramble[1] + 2) % 4)
			expect(b.tiles.moves).toBe(2)
			local reset, res = CellarPuzzles.apply(cfg, b, solution, { kind = "reset" }, 1, 2)
			expect(res.feedback).toBe("tiles_reset")
			expect(reset.tiles.rotations).toEqual(solution.tileScramble)
			-- Rotating every tile the remaining turns solves it regardless of who turned what.
			local cur = reset
			for index, turns in ipairs(cur.tiles.rotations) do
				for k = 1, (4 - turns) % 4 do
					cur = CellarPuzzles.apply(cfg, cur, solution, { kind = "tile", index = index }, k, 3)
				end
			end
			expect(cur.tiles.solved).toBe(true)
			expect(CellarPuzzles.currentStage(cfg, cur)).toBe("releaseHatchling")
			local _, nothing = CellarPuzzles.apply(cfg, cur, solution, { kind = "reset" }, 1, 4)
			expect(nothing.code).toBe("invalid")
		end)
	end)

	describe("Projection", function()
		it("never contains the solution and carries copy, labels with glyphs, and progress", function()
			local solution = CellarPuzzles.generate(cfg, WeightedRandom.fromSeed(11))
			local state = CellarPuzzles.newState(cfg, solution)
			local projection = CellarPuzzles.project(cfg, state)
			local encoded = game:GetService("HttpService"):JSONEncode(projection)
			expect(string.find(encoded, solution.code, 1, true)).toBeNil()
			expect(projection.stage).toBe("findKey")
			expect(projection.copy.title).toBe(CellarPuzzles.COPY.findKey.title)
			expect(#projection.levers.labels).toBe(p.leverCount)
			expect(projection.levers.labels[1].glyph ~= "" and projection.levers.labels[1].color ~= nil).toBe(true)
			expect(projection.tiles.rotations).toEqual(solution.tileScramble)
			expect(projection.crystals.solved).toBe(false)
			local spec = CellarPuzzles.worldSpec(cfg, solution)
			expect(spec.crystalCount).toBe(solution.crystalCount)
			expect(#spec.notes).toBe(p.codeDigits)
			expect(string.find(spec.plaqueText, CellarPuzzles.SYMBOL_GLYPH[p.leverLabels[solution.leverOrder[1]].symbol], 1, true)).toBeTruthy()
		end)
	end)
end
