--!nocheck
-- Daily quests: which three a player gets, how progress reads, and that a claim cannot pay twice.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local DailyQuests = require(Shared.Domain.DailyQuests)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local settings = cfg.dailyQuests
	local DAY = settings.resetSeconds

	describe("Selection", function()
		it("gives the same board for the same player and day, and a different one tomorrow", function()
			local today = DailyQuests.dayIndex(DAY * 900 + 5, DAY)
			local first = DailyQuests.select(cfg, 7, today)
			local again = DailyQuests.select(cfg, 7, today)
			expect(#first).toBe(settings.slots)
			for index, quest in ipairs(first) do
				expect(again[index].id).toBe(quest.id)
			end
			-- A board of three must not contain the same objective twice.
			local seen = {}
			for _, quest in ipairs(first) do
				expect(seen[quest.id]).toBeNil()
				seen[quest.id] = true
			end
			-- Some day within the next fortnight must differ, or the board never changes.
			local changed = false
			for ahead = 1, 14 do
				local later = DailyQuests.select(cfg, 7, today + ahead)
				for index, quest in ipairs(later) do
					if first[index].id ~= quest.id then
						changed = true
					end
				end
			end
			expect(changed).toBe(true)
		end)

		it("rolls the whole world over at the same instant", function()
			local before = DailyQuests.dayIndex(DAY * 10 - 1, DAY)
			local after = DailyQuests.dayIndex(DAY * 10, DAY)
			expect(after).toBe(before + 1)
			expect(DailyQuests.secondsUntilReset(DAY * 10, DAY)).toBe(DAY)
			expect(DailyQuests.secondsUntilReset(DAY * 10 + 1, DAY)).toBe(DAY - 1)
		end)
	end)

	describe("Progress", function()
		it("reads a stale day as a fresh board rather than yesterday's numbers", function()
			local now = DAY * 40 + 60
			local today = DailyQuests.dayIndex(now, DAY)
			local quest = DailyQuests.select(cfg, 11, today)[1]
			local stale = { day = today - 1, progress = { [quest.id] = quest.target }, claimed = { [quest.id] = true } }
			local view = DailyQuests.view(cfg, stale, 11, now)
			expect(view[1].progress).toBe(0)
			expect(view[1].complete).toBe(false)
			expect(view[1].claimed).toBe(false)
		end)

		it("reports exact numbers, a bounded fraction and a completion flag", function()
			local now = DAY * 41 + 5
			local today = DailyQuests.dayIndex(now, DAY)
			local quest = DailyQuests.select(cfg, 3, today)[1]
			local half = math.floor(quest.target / 2)
			local state = { day = today, progress = { [quest.id] = half }, claimed = {} }
			local view = DailyQuests.view(cfg, state, 3, now)
			expect(view[1].progress).toBe(half)
			expect(view[1].target).toBe(quest.target)
			expect(view[1].complete).toBe(false)
			-- Overshooting is held at the target: the bar cannot run past its end.
			state.progress[quest.id] = quest.target * 5
			view = DailyQuests.view(cfg, state, 3, now)
			expect(view[1].progress).toBe(quest.target)
			expect(view[1].fraction).toBe(1)
			expect(view[1].complete).toBe(true)
		end)

		it("writes the target into the title so a card states the real number", function()
			local view = DailyQuests.view(cfg, nil, 5, DAY * 42)
			for _, quest in ipairs(view) do
				expect(string.find(quest.title, "{target}", 1, true)).toBeNil()
				expect(#quest.title > 0).toBe(true)
				expect(quest.gems > 0).toBe(true)
			end
		end)
	end)

	describe("Claim keys", function()
		it("are unique per player, day and quest", function()
			local a = DailyQuests.transactionKey(1, 100, "findEgg")
			expect(DailyQuests.transactionKey(1, 100, "findEgg")).toBe(a)
			expect(DailyQuests.transactionKey(2, 100, "findEgg")).never.toBe(a)
			expect(DailyQuests.transactionKey(1, 101, "findEgg")).never.toBe(a)
			expect(DailyQuests.transactionKey(1, 100, "winSearch")).never.toBe(a)
		end)

		it("refuses a quest that is not on today's board", function()
			local today = DailyQuests.dayIndex(DAY * 50, DAY)
			local board = DailyQuests.select(cfg, 9, today)
			expect(DailyQuests.questFor(cfg, 9, today, board[1].id)).toBeTruthy()
			expect(DailyQuests.questFor(cfg, 9, today, "notAQuest")).toBeNil()
		end)
	end)
end
