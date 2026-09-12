--!nocheck
-- Service-level lifecycle: sessions, parties, rounds, entitlements, analytics, player data glue.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local Clock = require(Shared.Clock)
	local WeightedRandom = require(Shared.WeightedRandom)
	local MockDataStore = require(Server.Data.MockDataStore)
	local ProfileStore = require(Server.Data.ProfileStore)
	local ProfileProjection = require(Server.Data.ProfileProjection)
	local ProductMap = require(Server.Deployment.ProductMap)
	local MarketplaceAdapter = require(Server.Adapters.MarketplaceAdapter)
	local TeleportAdapter = require(Server.Adapters.TeleportAdapter)
	local AnalyticsAdapter = require(Server.Adapters.AnalyticsAdapter)
	local AnalyticsService = require(Server.Services.AnalyticsService)
	local EntitlementService = require(Server.Services.EntitlementService)
	local SessionService = require(Server.Services.SessionService)
	local PartyService = require(Server.Services.PartyService)
	local RoundService = require(Server.Services.RoundService)
	local PlayerDataService = require(Server.Services.PlayerDataService)
	local ServerPolicy = require(Server.ServerPolicy)
	local Log = require(Server.Log)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	local function fakePlayer(userId)
		local p = { UserId = userId, Name = "P" .. userId, kicked = nil, characterLoads = 0 }
		function p.Kick(self, message)
			self.kicked = message
		end
		function p.LoadCharacter(self)
			self.characterLoads += 1
		end
		return p
	end

	-- Full server harness with injected adapters. Wires party->round like init.server.luau.
	local function harness(options)
		options = options or {}
		local clock = Clock.fake(1000)
		local counter = 0
		local function idGen()
			counter += 1
			return "id-" .. string.format("%08d", counter)
		end
		local log = Log.capture("svc")
		local dataStore = MockDataStore.new("profiles")
		local profiles =
			ProfileStore.new({ dataStore = dataStore, clock = clock, config = cfg, jobId = "job", wait = function() end, log = log })
		local marketplace = MarketplaceAdapter.mock()
		local productMap = ProductMap.new(cfg, options.deployment or { placeIds = {}, gamePasses = {}, developerProducts = {} })
		local entitlements =
			EntitlementService.new({ marketplace = marketplace, productMap = productMap, clock = clock, cacheSeconds = 60 })
		local analyticsAdapter = AnalyticsAdapter.mock()
		local analytics = AnalyticsService.new({
			adapter = analyticsAdapter,
			config = cfg,
			buildInfo = { buildLabel = "test" },
			rng = function()
				return 0
			end,
		})
		local sent = {}
		local sessions = SessionService.new({ idGen = idGen, clock = clock })
		local playerData = PlayerDataService.new({
			profiles = profiles,
			sessions = sessions,
			entitlements = entitlements,
			clock = clock,
			policy = ServerPolicy,
			send = function(player, name, payload)
				table.insert(sent, { userId = player.UserId, name = name, payload = payload })
			end,
			analytics = analytics,
			log = log,
		})
		local teleport = options.teleport or TeleportAdapter.localAdapter(idGen)
		local parties = PartyService.new({
			config = cfg,
			clock = clock,
			idGen = idGen,
			sessions = sessions,
			getProgression = function(userId)
				return playerData:getProgression(userId)
			end,
			teleport = teleport,
			analytics = analytics,
		})
		local rounds = RoundService.new({
			config = cfg,
			clock = clock,
			idGen = idGen,
			rng = WeightedRandom.fromSeed(7),
			sessions = sessions,
			analytics = analytics,
		})
		parties.started:Connect(function(party, reservation)
			if reservation.isLocal then
				rounds:createForParty(party)
				parties:finish(party.partyId, true)
			else
				parties:finish(party.partyId, false)
			end
		end)
		return {
			clock = clock,
			profiles = profiles,
			dataStore = dataStore,
			marketplace = marketplace,
			productMap = productMap,
			entitlements = entitlements,
			analytics = analytics,
			analyticsAdapter = analyticsAdapter,
			sessions = sessions,
			playerData = playerData,
			parties = parties,
			rounds = rounds,
			sent = sent,
			lines = log,
			join = function(userId)
				local player = fakePlayer(userId)
				local outcome = playerData:onPlayerAdded(player, cfg)
				return player, outcome
			end,
		}
	end

	describe("PlayerDataService", function()
		it("loads a profile, opens a session in Lobby, sends sanitized projections, then spawns", function()
			local h = harness()
			local player, outcome = h.join(1)
			expect(outcome).toBe("loaded")
			expect(h.sessions:get(1).phase).toBe("Lobby")
			expect(player.characterLoads).toBe(1)
			local projectionMessage
			for _, message in ipairs(h.sent) do
				if message.name == "ProfileProjection" then
					projectionMessage = message
				end
			end
			expect(projectionMessage).toBeTruthy()
			local projection = projectionMessage.payload.projection
			expect(ProfileProjection.leaks(projection)).toBe(false)
			expect(projection.pendingTransactions).toBeNil()
			expect(projection.entitlementsCache).toBeNil()
			expect(projection.currencies.gems).toBe(0)
			expect(projection.rewards.dailyReady).toBe(true)
			expect(projection.entitlements.doubleGems).toBe(false)
			expect(h.analyticsAdapter:countOf("session_start")).toBe(1)
		end)

		it("two players get separate profiles and both locks release on flush", function()
			local h = harness()
			h.join(1)
			h.join(2)
			expect(h.profiles:activeCount()).toBe(2)
			h.profiles:get(1):update(function(data)
				data.currencies.gems = 5
			end)
			expect(h.profiles:get(2).data.currencies.gems).toBe(0)
			local flush = h.playerData:flushAll()
			expect(flush.released).toBe(2)
			expect(h.dataStore:peek(h.profiles:keyFor(1)).lock).toBeNil()
			expect(h.dataStore:peek(h.profiles:keyFor(2)).lock).toBeNil()
			expect(h.dataStore:peek(h.profiles:keyFor(1)).data.currencies.gems).toBe(5)
		end)

		it("load failure holds then removes the player without a writable profile", function()
			local h = harness()
			h.dataStore:failNext(100)
			local player, outcome = h.join(3)
			expect(outcome).toBe("kicked")
			expect(player.kicked).toBe(ServerPolicy.loadFailureKickMessage)
			expect(player.characterLoads).toBe(0)
			expect(h.profiles:activeCount()).toBe(0)
			expect(h.sessions:has(3)).toBe(false)
			local heldProjection
			for _, message in ipairs(h.sent) do
				if message.name == "SessionProjection" and message.payload.phase == "LoadRetry" then
					heldProjection = message
				end
			end
			expect(heldProjection).toBeTruthy()
		end)

		it("leaving releases the profile and records playtime", function()
			local h = harness()
			local player = h.join(4)
			h.clock:advance(90)
			expect(h.playerData:onPlayerRemoving(player)).toBe(true)
			expect(h.profiles:activeCount()).toBe(0)
			expect(h.dataStore:peek(h.profiles:keyFor(4)).data.stats.playtimeSeconds).toBe(90)
			expect(h.sessions:has(4)).toBe(false)
		end)
	end)

	describe("EntitlementService", function()
		it("unconfigured passes are never owned and never queried", function()
			local h = harness()
			local snapshot = h.entitlements:refresh(1)
			expect(snapshot.doubleGems).toBe(false)
			expect(h.marketplace.ownershipCalls).toBe(0)
			expect(h.entitlements:ownsPass(1, "infiniteBag")).toBe(false)
		end)

		it("configured passes come from the marketplace and failures never grant", function()
			local h = harness({ deployment = { placeIds = {}, gamePasses = { infiniteBag = 900 }, developerProducts = {} } })
			expect(h.entitlements:ownsPass(1, "infiniteBag")).toBe(false)
			h.marketplace:grantPass(1, 900)
			h.clock:advance(120)
			expect(h.entitlements:ownsPass(1, "infiniteBag")).toBe(true)
			h.marketplace:failOwnershipChecks(5)
			h.clock:advance(120)
			expect(h.entitlements:refresh(1).infiniteBag).toBe(true) -- keeps last known
			expect(h.entitlements:refresh(2).infiniteBag).toBe(false) -- unknown + failure => false
		end)
	end)

	describe("AnalyticsService", function()
		it("accepts enumerated events, rejects unknown events and free text", function()
			local h = harness()
			expect(h.analytics:track("round_started", { chapter = "chapter1", partySize = 2 })).toBe(true)
			local okUnknown, reason = h.analytics:track("player_typed_chat", {})
			expect(okUnknown).toBe(false)
			expect(reason).toBe("unknown_event")
			local okFree, freeReason = h.analytics:track("round_started", { note = "hello there" })
			expect(okFree).toBe(false)
			expect(freeReason).toContain("free_text")
			local okNaN = h.analytics:track("round_started", { partySize = 0 / 0 })
			expect(okNaN).toBe(false)
			local event = h.analyticsAdapter.events[1]
			expect(event.fields.configVersion).toBe(cfg.configVersion)
			expect(event.fields.buildLabel).toBe("test")
		end)

		it("samples high-frequency collection events at the configured rate", function()
			local roll = 0
			local adapter = AnalyticsAdapter.mock()
			local analytics = AnalyticsService.new({
				adapter = adapter,
				config = cfg,
				buildInfo = { buildLabel = "t" },
				rng = function()
					return roll
				end,
			})
			roll = cfg.analytics.sampledCollectionEventRate - 0.001
			expect(analytics:track("feather_collected", { amount = 1 })).toBe(true)
			roll = cfg.analytics.sampledCollectionEventRate
			local ok, reason = analytics:track("feather_collected", { amount = 1 })
			expect(ok).toBe(false)
			expect(reason).toBe("sampled_out")
			expect(adapter.events[1].fields.sampleRate).toBe(cfg.analytics.sampledCollectionEventRate)
		end)
	end)

	describe("Party -> Round lifecycle", function()
		it("solo party: create, start, countdown, local reservation, round bootstrap", function()
			local h = harness()
			h.join(1)
			local party, err = h.parties:create(1, "chapter1", "normal")
			expect(err).toBeNil()
			expect(party.phase).toBe("Ready")
			expect(h.sessions:get(1).phase).toBe("Party")
			expect(h.analyticsAdapter:countOf("party_created")).toBe(1)
			local started = h.parties:start(1, party.partyId)
			expect(started.phase).toBe("Countdown")
			expect(h.parties:tick()).toBe(0)
			h.clock:advance(cfg.round.countdownSeconds)
			expect(h.parties:tick()).toBe(1)
			expect(h.parties:count()).toBe(0) -- closed after local hand-off
			local session = h.sessions:get(1)
			expect(session.phase).toBe("Round")
			expect(session.roundId).toBeTruthy()
			local round = h.rounds:get(session.roundId)
			expect(round.phase).toBe("Cutscene")
			expect(round.eggNodeId).toContain("chapter1:node_")
			expect(h.analyticsAdapter:countOf("round_started")).toBe(1)
		end)

		it("locked destination keeps the party Forming and start is rejected", function()
			local h = harness()
			h.join(1)
			local party = h.parties:create(1, "chapter1", "hard")
			expect(party.phase).toBe("Forming")
			local started, err = h.parties:start(1, party.partyId)
			expect(started).toBeNil()
			expect(err).toBe("not_ready")
			-- Config-driven: give the win and the same party becomes Ready.
			h.profiles:get(1):update(function(data)
				data.progression.chapterWins.chapter1.normal = cfg.chapters.chapter1.hardUnlock.count
			end)
			local ready = h.parties:setDestination(1, "chapter1", "hard")
			expect(ready.phase).toBe("Ready")
		end)

		it("duplicate start, double party membership, and non-lobby joins are refused", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local party = h.parties:create(1, "chapter1", "normal")
			local _, dup = h.parties:create(1, "chapter1", "normal")
			expect(dup).toBe(PartyService.Errors.IN_PARTY)
			h.parties:start(1, party.partyId)
			local _, again = h.parties:start(1, party.partyId)
			expect(again).toBe("already_started")
			local _, joinDuringCountdown = h.parties:join(2, party.partyId)
			expect(joinDuringCountdown).toBe("invalid_phase")
		end)

		it("member leaving during countdown cancels it and leadership transfers", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:join(2, party.partyId)
			expect(h.parties:get(party.partyId).members).toEqual({ 1, 2 })
			h.parties:start(1, party.partyId)
			local after = h.parties:leave(1)
			expect(after.leaderUserId).toBe(2)
			expect(after.phase).toBe("Ready")
			expect(h.sessions:get(1).phase).toBe("Lobby")
			expect(h.sessions:get(2).phase).toBe("Party")
		end)

		it("reservation failure returns the party to Ready", function()
			local h = harness({ teleport = TeleportAdapter.failing() })
			h.join(1)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:start(1, party.partyId)
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			expect(h.parties:get(party.partyId).phase).toBe("Ready")
			expect(h.sessions:get(1).phase).toBe("Party")
		end)

		it("round advances cutscene -> countdown -> searching on server time and skip votes", function()
			local h = harness()
			h.join(1)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:start(1, party.partyId)
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			local roundId = h.sessions:get(1).roundId
			expect(h.rounds:tick()).toBe(0)
			h.rounds:voteSkip(roundId, 1)
			expect(h.rounds:tick()).toBe(1)
			expect(h.rounds:get(roundId).phase).toBe("Countdown")
			h.clock:advance(cfg.round.countdownSeconds)
			expect(h.rounds:tick()).toBe(1)
			local state = h.rounds:get(roundId)
			expect(state.phase).toBe("Searching")
			expect(state.searchingStartedAtMs).toBe(h.clock:nowMs())
			h.clock:advance(2)
			expect(h.rounds:project(roundId).elapsedMs).toBe(2000)
			expect(h.rounds:project(roundId).eggNodeId).toBeNil()
		end)

		it("claim requires a valid round token; first claim wins; commit and return restore lobby", function()
			local h = harness()
			h.join(1)
			h.join(2)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:join(2, party.partyId)
			h.parties:start(1, party.partyId)
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			local roundId = h.sessions:get(1).roundId
			h.rounds:voteSkip(roundId, 1)
			h.rounds:voteSkip(roundId, 2)
			h.rounds:tick()
			h.clock:advance(cfg.round.countdownSeconds)
			h.rounds:tick()
			local _, early = h.rounds:claim(roundId, 1, h.sessions:get(1).sessionToken)
			expect(early).toBe("invalid_phase")
			h.rounds:markEggRevealed(roundId)
			local _, stale = h.rounds:claim(roundId, 1, "stale-token")
			expect(stale).toBe("stale_token")
			local won = h.rounds:claim(roundId, 2, h.sessions:get(2).sessionToken)
			expect(won.phase).toBe("Victory")
			expect(won.victory.finderUserId).toBe(2)
			local _, second = h.rounds:claim(roundId, 1, h.sessions:get(1).sessionToken)
			expect(second).toBe("already_won")
			expect(h.analyticsAdapter:countOf("egg_claimed")).toBe(1)

			local commits = 0
			local results = h.rounds:commitAndFinish(roundId, function()
				commits += 1
				return true
			end)
			expect(results.phase).toBe("Results")
			expect(commits).toBe(1)
			expect(h.sessions:get(1).phase).toBe("Results")
			expect(h.sessions:get(2).phase).toBe("Results")
			local tokenBefore = h.sessions:get(1).sessionToken
			h.rounds:returnToLobby(roundId)
			expect(h.sessions:get(1).phase).toBe("Lobby")
			expect(h.sessions:get(1).roundId).toBeNil()
			expect(h.sessions:get(1).sessionToken).never.toBe(tokenBefore)
			expect(h.rounds:count()).toBe(0)
		end)

		it("commit failure holds the round in CommittingRewards", function()
			local h = harness()
			h.join(1)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:start(1, party.partyId)
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			local roundId = h.sessions:get(1).roundId
			h.rounds:voteSkip(roundId, 1)
			h.rounds:tick()
			h.clock:advance(cfg.round.countdownSeconds)
			h.rounds:tick()
			h.rounds:markEggRevealed(roundId)
			h.rounds:claim(roundId, 1, h.sessions:get(1).sessionToken)
			local state, err = h.rounds:commitAndFinish(roundId, function()
				return false
			end)
			expect(state.phase).toBe("CommittingRewards")
			expect(err).toBe("commit_pending")
		end)

		it("egg node selection avoids the most recent nodes", function()
			local h = harness()
			local seen = {}
			for _ = 1, cfg.eggSpawn.repeatProtectionRounds + 1 do
				table.insert(seen, h.rounds:selectEggNode("chapter1").id)
			end
			for i = 1, cfg.eggSpawn.repeatProtectionRounds do
				for j = i + 1, cfg.eggSpawn.repeatProtectionRounds + 1 do
					if j - i <= cfg.eggSpawn.repeatProtectionRounds then
						expect(seen[i]).never.toBe(seen[j])
					end
				end
			end
		end)

		it("abandons a round whose lifetime exceeds the configured maximum", function()
			local h = harness()
			h.join(1)
			local party = h.parties:create(1, "chapter1", "normal")
			h.parties:start(1, party.partyId)
			h.clock:advance(cfg.round.countdownSeconds)
			h.parties:tick()
			local roundId = h.sessions:get(1).roundId
			h.rounds:voteSkip(roundId, 1)
			h.rounds:tick()
			h.clock:advance(cfg.round.countdownSeconds)
			h.rounds:tick()
			h.clock:advance(cfg.round.maximumRoundSeconds)
			h.rounds:tick()
			expect(h.rounds:get(roundId).phase).toBe("Abandoned")
		end)
	end)
end
