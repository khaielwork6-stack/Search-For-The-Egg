--!nocheck
-- Lobby ambience and the next-search line: the yard chickens' wander targets stay inside the yard
-- and outside every exclusion (portal corridor, spawn, pads, spawn-to-pad walking lines), and the
-- status line resolves every party state to the right copy.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Config = require(Shared.Config)
	local ChapterLayout = require(Shared.Domain.ChapterLayout)
	local LobbyYard = require(Shared.Domain.LobbyYard)
	local NextRoundStatus = require(Shared.Domain.NextRoundStatus)
	local WeightedRandom = require(Shared.WeightedRandom)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))
	local chickens = cfg.lobby.ambience.chickens
	local lobby = ChapterLayout.lobby

	local function yard()
		return LobbyYard.fromLayout(lobby, chickens)
	end

	local function flat(v)
		return Vector2.new(v.X, v.Z)
	end

	-- Independent of LobbyYard.isExcluded: recomputed from the layout and config directly.
	local function violates(point)
		local margin = chickens.exclusionMarginStuds
		for _, pad in ipairs(lobby.pads) do
			if
				math.abs(point.X - pad.center.X) <= pad.zoneSize.X / 2 + margin
				and math.abs(point.Y - pad.center.Z) <= pad.zoneSize.Z / 2 + margin
			then
				return "pad " .. pad.index
			end
			if LobbyYard.distanceToSegment(point, flat(lobby.spawn), flat(pad.center)) <= chickens.walkLineClearanceStuds then
				return "walking line to pad " .. pad.index
			end
		end
		for _, rect in ipairs(lobby.chickenYard.excludeRects) do
			if point.X >= rect.min.X and point.X <= rect.max.X and point.Y >= rect.min.Y and point.Y <= rect.max.Y then
				return "portal corridor"
			end
		end
		if (point - flat(lobby.spawn)).Magnitude <= 9 then
			return "spawn"
		end
		local inside = false
		for _, rect in ipairs(lobby.chickenYard.rects) do
			if point.X >= rect.min.X and point.X <= rect.max.X and point.Y >= rect.min.Y and point.Y <= rect.max.Y then
				inside = true
			end
		end
		return if inside then nil else "outside the yard"
	end

	describe("Yard chickens wander", function()
		it("the yard rectangles hold allowed ground on both sides of the barn door", function()
			local y = yard()
			local rng = WeightedRandom.fromSeed(7)
			local left, right = 0, 0
			for _ = 1, 200 do
				local point = LobbyYard.randomPoint(y, rng)
				expect(point).toBeTruthy()
				expect(violates(point)).toBeNil()
				if point.X < 0 then
					left += 1
				else
					right += 1
				end
			end
			expect(left).toBeGreaterThan(20)
			expect(right).toBeGreaterThan(20)
		end)

		it("a long walk of picked targets never leaves the yard or enters an exclusion", function()
			local y = yard()
			for seed = 1, 6 do
				local rng = WeightedRandom.fromSeed(seed * 101)
				local position = LobbyYard.randomPoint(y, rng)
				local moved = 0
				for _ = 1, 300 do
					local target = LobbyYard.pickTarget(y, rng, position, chickens.wanderStepMaxStuds)
					if target then
						expect((target - position).Magnitude <= chickens.wanderStepMaxStuds + 1e-6).toBe(true)
						-- Every stud of the walk, not just its end.
						for i = 0, 20 do
							local sample = position:Lerp(target, i / 20)
							local reason = violates(sample)
							if reason then
								error(string.format("walk from %s to %s crosses %s", tostring(position), tostring(target), reason))
							end
						end
						position = target
						moved += 1
					end
				end
				expect(moved).toBeGreaterThan(200)
			end
		end)

		it("excludes the spawn, the portal corridor, every pad and the walking lines", function()
			local y = yard()
			expect(LobbyYard.isAllowed(y, flat(lobby.spawn))).toBe(false)
			expect(LobbyYard.isAllowed(y, Vector2.new(-0.5, -150))).toBe(false) -- barn door path
			for _, pad in ipairs(lobby.pads) do
				expect(LobbyYard.isAllowed(y, flat(pad.center))).toBe(false)
				expect(LobbyYard.isExcluded(y, flat(lobby.spawn):Lerp(flat(pad.center), 0.6))).toBe(true)
			end
			expect(LobbyYard.isAllowed(y, Vector2.new(-20, -150))).toBe(true)
			expect(LobbyYard.isAllowed(y, Vector2.new(19, -150))).toBe(true)
			expect(LobbyYard.isAllowed(y, Vector2.new(-20, -175))).toBe(false) -- inside the barn
		end)

		it("never picks a path from one side of the door to the other", function()
			local y = yard()
			expect(LobbyYard.pathAllowed(y, Vector2.new(-11, -150), Vector2.new(10, -150))).toBe(false)
		end)

		it("honours the extra acceptance test and gives up cleanly", function()
			local y = yard()
			local rng = WeightedRandom.fromSeed(3)
			local from = Vector2.new(-20, -150)
			expect(LobbyYard.pickTarget(y, rng, from, 8, function()
				return false
			end)).toBeNil()
			local accepted = LobbyYard.pickTarget(y, rng, from, 8, function(point)
				return point.X < -20
			end, 40)
			expect(accepted).toBeTruthy()
			expect(accepted.X < -20).toBe(true)
		end)

		it("the validator rejects a low tier faster than the full rate and missing ambience", function()
			local Validator = require(Shared.Config.Validator)
			local TableUtil = require(Shared.Util.TableUtil)
			local raw = TableUtil.deepCopy(require(ServerStorage.SFE.SystemConfig))
			raw.lobby.ambience.chickens.lowTierUpdateHz = raw.lobby.ambience.chickens.updateHz + 1
			expect(Validator.validate(raw).ok).toBe(false)
			local missing = TableUtil.deepCopy(require(ServerStorage.SFE.SystemConfig))
			missing.lobby.ambience = nil
			expect(Validator.validate(missing).ok).toBe(false)
		end)

		it("low tier runs fewer chickens at a lower rate", function()
			expect(chickens.countByTier.low).toBe(2)
			expect(chickens.countByTier.low <= chickens.countByTier.medium).toBe(true)
			expect(chickens.countByTier.high >= 4 and chickens.countByTier.high <= 6).toBe(true)
			expect(chickens.lowTierUpdateHz < chickens.updateHz).toBe(true)
			expect(chickens.cullDistanceStuds).toBe(120)
		end)
	end)

	describe("Next search status", function()
		local ME = 11
		local function resolve(overrides)
			local input = {
				roundPhase = nil,
				sessionPhase = "Lobby",
				party = nil,
				countdownRemaining = nil,
				localUserId = ME,
				maxPartyPlayers = 4,
				onPad = false,
			}
			for key, value in pairs(overrides or {}) do
				input[key] = value
			end
			return NextRoundStatus.resolve(input)
		end
		local function party(phase, members, leader, extra)
			local list = {}
			for i = 1, members do
				table.insert(list, if i == 1 then leader else 100 + i)
			end
			local p = { partyId = "p1", phase = phase, members = list, leaderUserId = leader, maxMembers = 4, valid = true }
			for key, value in pairs(extra or {}) do
				p[key] = value
			end
			return p
		end

		it("no party: stand on a nest pad", function()
			local status = resolve()
			expect(status.state).toBe("noParty")
			expect(status.title).toBe("Stand on a nest pad to start a search")
			expect(status.detail).toBeNil()
			expect(resolve({ party = party("Closed", 1, ME) }).state).toBe("noParty")
		end)

		it("loading until the session arrives", function()
			expect(NextRoundStatus.resolve({ localUserId = ME, maxPartyPlayers = 4 }).state).toBe("loading")
			expect(resolve({ sessionPhase = "LoadingProfile" }).state).toBe("loading")
		end)

		it("forming and ready parties wait for players, with copy for leader, member, pad and screen parties", function()
			local leaderOnPad = resolve({ sessionPhase = "Party", party = party("Ready", 2, ME), onPad = true })
			expect(leaderOnPad.state).toBe("waiting")
			expect(leaderOnPad.title).toBe("Waiting for players 2/4")
			expect(leaderOnPad.detail).toBe("Starts when full, or Set off at the sign")
			local memberOnPad = resolve({ sessionPhase = "Party", party = party("Forming", 3, 1), onPad = true })
			expect(memberOnPad.title).toBe("Waiting for players 3/4")
			expect(memberOnPad.detail).toBe("Starts when full or the leader sets off")
			local leaderScreen = resolve({ sessionPhase = "Party", party = party("Ready", 1, ME), onPad = false })
			expect(leaderScreen.detail).toBe("Start the search when you're ready")
			local memberScreen = resolve({ sessionPhase = "Party", party = party("Ready", 2, 1), onPad = false })
			expect(memberScreen.detail).toBe("The leader starts the search")
		end)

		it("an invalid party says why it cannot set off", function()
			local status = resolve({ sessionPhase = "Party", party = party("Forming", 2, ME, { valid = false }), onPad = true })
			expect(status.state).toBe("waiting")
			expect(status.detail).toBe("Not everyone can enter this nest yet")
		end)

		it("a full party is about to set off", function()
			local status = resolve({ sessionPhase = "Party", party = party("Ready", 4, 1), onPad = true })
			expect(status.state).toBe("full")
			expect(status.title).toBe("Party full 4/4")
			expect(status.detail).toBe("Search starts in a moment")
		end)

		it("the countdown reads as a clock and never shows 0:00 while time remains", function()
			local status = resolve({ sessionPhase = "Party", party = party("Countdown", 2, ME), countdownRemaining = 6.2, onPad = true })
			expect(status.state).toBe("countdown")
			expect(status.title).toBe("Search starts in 0:07")
			expect(status.detail).toBe("Stay on the pad")
			expect(resolve({ party = party("Countdown", 2, ME), countdownRemaining = 0.05 }).title).toBe("Search starts in 0:01")
			expect(NextRoundStatus.formatClock(75)).toBe("1:15")
			expect(NextRoundStatus.formatClock(5)).toBe("0:05")
			expect(resolve({ party = party("Countdown", 2, ME), countdownRemaining = 0 }).state).toBe("teleporting")
		end)

		it("reserving, teleporting and a session on its way read as teleporting", function()
			for _, phase in ipairs({ "Reserving", "Teleporting" }) do
				local status = resolve({ sessionPhase = "Party", party = party(phase, 3, ME) })
				expect(status.state).toBe("teleporting")
				expect(status.title).toBe("Teleporting to the nest...")
			end
			expect(resolve({ sessionPhase = "Teleporting" }).state).toBe("teleporting")
		end)

		it("hidden while a round owns the pill; lobby phases still show the line", function()
			for _, phase in ipairs({ "Cutscene", "Countdown", "Searching", "EggRevealed", "Victory", "Results" }) do
				expect(resolve({ roundPhase = phase, sessionPhase = "Round" }).state).toBe("hidden")
			end
			expect(resolve({ sessionPhase = "Results" }).state).toBe("hidden")
			expect(resolve({ roundPhase = "Returning" }).state).toBe("returning")
			expect(resolve({ roundPhase = "Abandoned" }).state).toBe("noParty")
			expect(resolve({ roundPhase = "Lobby" }).state).toBe("noParty")
		end)
	end)
end
