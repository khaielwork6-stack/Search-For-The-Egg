--!nocheck
-- Config-driven unlock policies; changing the policy object changes behaviour without service edits.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local UnlockPolicy = require(Shared.Domain.UnlockPolicy)
	local Config = require(Shared.Config)
	local TableUtil = require(Shared.Util.TableUtil)
	local cfg = Config.fromRaw(require(game:GetService("ServerStorage").SFE.SystemConfig))

	local function fresh()
		return { chapterWins = { chapter1 = { normal = 0, hard = 0 }, chapter2 = { normal = 0, hard = 0 } } }
	end

	describe("evaluate", function()
		it("chapter 1 normal is available by default", function()
			expect(UnlockPolicy.evaluate(cfg.chapters.chapter1.normalUnlock, fresh())).toBe(true)
		end)

		it("chapter 1 hard and chapter 2 normal are locked until the configured win", function()
			local p = fresh()
			expect(UnlockPolicy.evaluate(cfg.chapters.chapter1.hardUnlock, p)).toBe(false)
			expect(UnlockPolicy.evaluate(cfg.chapters.chapter2.normalUnlock, p)).toBe(false)
			p.chapterWins.chapter1.normal = cfg.chapters.chapter1.hardUnlock.count
			expect(UnlockPolicy.evaluate(cfg.chapters.chapter1.hardUnlock, p)).toBe(true)
			expect(UnlockPolicy.evaluate(cfg.chapters.chapter2.normalUnlock, p)).toBe(true)
			expect(UnlockPolicy.evaluate(cfg.chapters.chapter2.hardUnlock, p)).toBe(false)
		end)

		it("changing the policy changes behaviour without code changes", function()
			local chapters = TableUtil.deepCopy(cfg.chapters)
			chapters.chapter2.normalUnlock = { type = "chapterWins", chapter = "chapter1", difficulty = "hard", count = 3 }
			local p = fresh()
			p.chapterWins.chapter1.normal = 10
			expect(UnlockPolicy.evaluate(chapters.chapter2.normalUnlock, p)).toBe(false)
			p.chapterWins.chapter1.hard = 3
			expect(UnlockPolicy.evaluate(chapters.chapter2.normalUnlock, p)).toBe(true)
			chapters.chapter2.normalUnlock = { type = "always" }
			expect(UnlockPolicy.evaluate(chapters.chapter2.normalUnlock, fresh())).toBe(true)
		end)

		it("rejects unknown policy types", function()
			expect(function()
				UnlockPolicy.evaluate({ type = "badge" }, fresh())
			end).toThrow()
		end)
	end)

	describe("recompute", function()
		it("derives unlock booleans from wins rather than trusting saved flags", function()
			local p = fresh()
			local chapters, difficulties = UnlockPolicy.recompute(cfg.chapters, p)
			expect(chapters.chapter1).toBe(true)
			expect(chapters.chapter2).toBe(false)
			expect(difficulties.chapter1.hard).toBe(false)
			p.chapterWins.chapter1.normal = 1
			chapters, difficulties = UnlockPolicy.recompute(cfg.chapters, p)
			expect(chapters.chapter2).toBe(true)
			expect(difficulties.chapter1.hard).toBe(true)
			expect(difficulties.chapter2.normal).toBe(true)
		end)
	end)

	describe("partyCanStart", function()
		it("requires every member to own the unlock under the default rule", function()
			local a, b = fresh(), fresh()
			a.chapterWins.chapter1.normal = 1
			local ok, locked = UnlockPolicy.partyCanStart(cfg.chapters, "chapter1", "hard", { a, b })
			expect(ok).toBe(false)
			expect(locked).toEqual({ 2 })
			b.chapterWins.chapter1.normal = 1
			ok = UnlockPolicy.partyCanStart(cfg.chapters, "chapter1", "hard", { a, b })
			expect(ok).toBe(true)
		end)

		it("fails for unknown chapters", function()
			expect(UnlockPolicy.partyCanStart(cfg.chapters, "chapter9", "normal", { fresh() })).toBe(false)
		end)
	end)
end
