--!nocheck
-- The round intro: the pure timing and wording, and the readiness barrier that decides when a round
-- actually starts. Both are headless, so the parts that must not regress are checked without Studio.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local RoundIntro = require(Shared.Domain.RoundIntro)
	local RoundReducer = require(Shared.Reducers.RoundReducer)
	local EconomyMath = require(Shared.EconomyMath)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local intro = cfg.round.intro

	describe("Flyer", function()
		it("prints the reward the round actually pays, not a number written anywhere", function()
			local chapter = cfg.chapters.chapter1
			-- Same arithmetic the victory payout uses: dollars to cents, then the difficulty multiplier.
			local expectedNormal =
				EconomyMath.roundHalfUp(EconomyMath.dollarsToCents(chapter.normalRewards.cash) * cfg.difficulty.normal.rewardMultiplier)
			local expectedHard =
				EconomyMath.roundHalfUp(EconomyMath.dollarsToCents(chapter.hardRewards.cash) * cfg.difficulty.hard.rewardMultiplier)
			expect(RoundIntro.rewardCents(cfg, "chapter1", "normal")).toBe(expectedNormal)
			expect(RoundIntro.rewardCents(cfg, "chapter1", "hard")).toBe(expectedHard)
			expect(RoundIntro.rewardText(cfg, "chapter1", "normal")).toBe(EconomyMath.formatCents(expectedNormal))
			-- Hard pays more, so the flyer must say so.
			expect(RoundIntro.rewardCents(cfg, "chapter1", "hard")).toBeGreaterThan(RoundIntro.rewardCents(cfg, "chapter1", "normal"))
		end)

		it("says find the egg, where it is, and what it pays", function()
			local lines = RoundIntro.posterLines(cfg, "chapter1", "normal")
			expect(#lines).toBe(4)
			expect(lines[1]).toBe(intro.poster.title)
			expect(lines[2]).toBe(intro.poster.subtitle)
			expect(lines[3]).toContain(RoundIntro.rewardText(cfg, "chapter1", "normal"))
			-- An unknown chapter must not error; it just has nothing to promise.
			expect(RoundIntro.rewardCents(cfg, "nope", "normal")).toBe(0)
		end)
	end)

	describe("Timeline", function()
		it("covers its whole run with shots and never falls off either end", function()
			local shots = intro.shots
			expect(#shots).toBeGreaterThan(1)
			-- Before the first shot and long after the last one, there is still a shot to show.
			local first = RoundIntro.shotAt(shots, -5)
			expect(first).toBeTruthy()
			local last, progress = RoundIntro.shotAt(shots, 9999)
			expect(last.marker).toBe(shots[#shots].marker)
			expect(progress).toBe(1)
			-- Each shot is current at its own start, and the list has no gap.
			for index, shot in ipairs(shots) do
				local chosen, alpha = RoundIntro.shotAt(shots, shot.at + 0.001)
				expect(chosen.marker).toBe(shot.marker)
				expect(alpha).toBeGreaterThanOrEqual(0)
				if index > 1 then
					expect(shot.at).toBeGreaterThanOrEqual(shots[index - 1].at)
				end
			end
			-- The run is at least as long as the shot list, so no shot is cut off.
			expect(RoundIntro.duration(cfg)).toBeGreaterThanOrEqual(shots[#shots].at + shots[#shots].seconds)
		end)

		it("types each subtitle in and holds it until the next one", function()
			local beats = intro.beats
			local cps = intro.subtitleCharactersPerSecond
			-- Nothing before the first line.
			local before = RoundIntro.subtitleAt(beats, beats[1].at - 0.01, cps)
			expect(before).toBeNil()
			-- The first line starts empty and fills.
			local text, fraction = RoundIntro.subtitleAt(beats, beats[1].at, cps)
			expect(text).toBe(beats[1].text)
			expect(fraction).toBe(0)
			expect(RoundIntro.typedText(text, 0)).toBe("")
			local _, later = RoundIntro.subtitleAt(beats, beats[1].at + #beats[1].text / cps, cps)
			expect(later).toBe(1)
			expect(RoundIntro.typedText(text, 1)).toBe(text)
			-- A half-typed line is a prefix of the whole line, never scrambled.
			local half = RoundIntro.typedText(text, 0.5)
			expect(string.sub(text, 1, #half)).toBe(half)
			-- The last line stays up to the end of the intro.
			local final = RoundIntro.subtitleAt(beats, RoundIntro.duration(cfg), cps)
			expect(final).toBe(beats[#beats].text)
		end)

		it("walks the actor smoothly and only once", function()
			local actor = intro.actor
			expect(RoundIntro.actorAlpha(actor, actor.walkAt - 1)).toBe(0)
			expect(RoundIntro.actorAlpha(actor, actor.walkAt + actor.walkSeconds)).toBe(1)
			expect(RoundIntro.actorAlpha(actor, 9999)).toBe(1)
			-- Monotonic, and eased at both ends rather than starting at full speed.
			local previous = -1
			for step = 0, 40 do
				local t = actor.walkAt + (step / 40) * actor.walkSeconds
				local alpha = RoundIntro.actorAlpha(actor, t)
				expect(alpha).toBeGreaterThanOrEqual(previous)
				previous = alpha
			end
			local quarter = RoundIntro.actorAlpha(actor, actor.walkAt + actor.walkSeconds * 0.25)
			expect(quarter).toBeLessThan(0.25) -- eased in, not linear
			-- The walk finishes before the hand reaches for the flyer.
			expect(actor.walkAt + actor.walkSeconds).toBeLessThanOrEqual(actor.reachAt)
			expect(actor.reachAt).toBeLessThanOrEqual(actor.takeAt)
			expect(actor.takeAt).toBeLessThanOrEqual(actor.readAt)
			expect(actor.readAt).toBeLessThanOrEqual(actor.turnAt)
		end)
	end)

	describe("Readiness barrier", function()
		local function roundWith(members)
			return RoundReducer.bootstrapComplete(RoundReducer.create("r", "chapter1", "normal", 1, members), "chapter1:node_1")
		end

		it("holds the round until every present member has reported", function()
			local state = roundWith({ 1, 2 })
			expect(state.phase).toBe("Cutscene")
			expect(RoundReducer.allPresentIntroReady(state)).toBe(false)
			state = RoundReducer.introReady(state, 1)
			expect(RoundReducer.allPresentIntroReady(state)).toBe(false)
			local ready, present = RoundReducer.introReadyCounts(state)
			expect(ready).toBe(1)
			expect(present).toBe(2)
			state = RoundReducer.introReady(state, 2)
			expect(RoundReducer.allPresentIntroReady(state)).toBe(true)
		end)

		it("counts a skip as ready, so a party that all skip starts at once", function()
			local state = roundWith({ 1, 2 })
			state = RoundReducer.voteSkip(state, 1)
			state = RoundReducer.voteSkip(state, 2)
			expect(RoundReducer.allPresentIntroReady(state)).toBe(true)
		end)

		it("never traps the party behind someone who left", function()
			local state = roundWith({ 1, 2 })
			state = RoundReducer.introReady(state, 1)
			expect(RoundReducer.allPresentIntroReady(state)).toBe(false)
			-- Player 2 disconnects: they are no longer present, so player 1 is not held.
			state = RoundReducer.setPresent(state, 2, false)
			expect(RoundReducer.allPresentIntroReady(state)).toBe(true)
			local ready, present = RoundReducer.introReadyCounts(state)
			expect(ready).toBe(1)
			expect(present).toBe(1)
		end)

		it("is idempotent, so ready and skip spam cannot start the round twice", function()
			local state = roundWith({ 1 })
			local first = RoundReducer.introReady(state, 1)
			expect(first.version).toBeGreaterThan(state.version)
			-- The same report again changes nothing at all, not even the version other systems watch.
			local second = RoundReducer.introReady(first, 1)
			expect(second).toBe(first)
			expect(second.version).toBe(first.version)
			for _ = 1, 20 do
				second = RoundReducer.introReady(second, 1)
			end
			expect(second.version).toBe(first.version)
			expect(RoundReducer.allPresentIntroReady(second)).toBe(true)
		end)

		it("refuses a stranger and refuses the wrong phase", function()
			local state = roundWith({ 1 })
			local bad, err = RoundReducer.introReady(state, 99)
			expect(bad).toBeNil()
			expect(err).toBe(RoundReducer.Errors.NOT_MEMBER)
			local searching = RoundReducer.beginSearching(RoundReducer.cutsceneFinished(state, 0), 0)
			expect(searching.phase).toBe("Searching")
			local late, lateErr = RoundReducer.introReady(searching, 1)
			expect(late).toBeNil()
			expect(lateErr).toBe(RoundReducer.Errors.INVALID_PHASE)
		end)

		it("gives the intro room to finish before the backstop fires", function()
			expect(intro.maxWaitSeconds).toBeGreaterThan(RoundIntro.duration(cfg))
		end)
	end)
end
