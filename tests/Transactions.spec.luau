--!nocheck
-- Idempotent transactions: victory replay, receipt replay, unknown products, save-failure retry.

return function(describe, it, expect)
	local ServerStorage = game:GetService("ServerStorage")
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Server = game:GetService("ServerScriptService").Server
	local Config = require(Shared.Config)
	local Clock = require(Shared.Clock)
	local ProfileSchema = require(Server.Data.ProfileSchema)
	local TransactionLedger = require(Server.Data.TransactionLedger)
	local MockDataStore = require(Server.Data.MockDataStore)
	local ProfileStore = require(Server.Data.ProfileStore)
	local ReceiptLedger = require(Server.Data.ReceiptLedger)
	local ProductMap = require(Server.Deployment.ProductMap)
	local ReceiptService = require(Server.Services.ReceiptService)
	local AnalyticsService = require(Server.Services.AnalyticsService)
	local AnalyticsAdapter = require(Server.Adapters.AnalyticsAdapter)
	local Log = require(Server.Log)
	local cfg = Config.fromRaw(require(ServerStorage.SFE.SystemConfig))

	describe("TransactionLedger", function()
		it("applies a victory reward exactly once across 100 replays", function()
			local data = ProfileSchema.default(1)
			local txId = TransactionLedger.victoryKey("round-1", 55, "chapter1", "normal")
			local applied = 0
			local rewards = cfg.chapters.chapter1.normalRewards
			for i = 1, 100 do
				local result = TransactionLedger.apply(data, txId, "victory", 100 + i, function(d)
					applied += 1
					d.currencies.gems += rewards.gems
					d.progression.totalWins += rewards.wins
					return { gems = rewards.gems }
				end)
				expect(result.result.gems).toBe(rewards.gems)
				expect(result.status).toBe(if i == 1 then "committed" else "replayed")
			end
			expect(applied).toBe(1)
			expect(data.currencies.gems).toBe(rewards.gems)
			expect(data.progression.totalWins).toBe(1)
			expect(TransactionLedger.isCommitted(data, txId)).toBe(true)
		end)

		it("different users in the same round get separate transactions", function()
			local a = TransactionLedger.victoryKey("r", 1, "chapter1", "normal")
			local b = TransactionLedger.victoryKey("r", 2, "chapter1", "normal")
			expect(a).never.toBe(b)
			expect(a).toBe("r:1:chapter1:normal")
		end)

		it("a failing mutation leaves no marker and grants nothing", function()
			local data = ProfileSchema.default(1)
			expect(function()
				TransactionLedger.apply(data, "tx-fail", "test", 1, function()
					error("boom")
				end)
			end).toThrow("boom")
			expect(data.pendingTransactions["tx-fail"]).toBeNil()
			local ok = TransactionLedger.apply(data, "tx-fail", "test", 2, function()
				return "fine"
			end)
			expect(ok.status).toBe("committed")
		end)

		it("prunes the oldest committed markers beyond retention", function()
			local data = ProfileSchema.default(1)
			for i = 1, 20 do
				TransactionLedger.apply(data, "tx" .. i, "t", i, function()
					return i
				end)
			end
			expect(TransactionLedger.prune(data, 5)).toBe(15)
			expect(TransactionLedger.count(data)).toBe(5)
			expect(data.pendingTransactions.tx20).toBeTruthy()
			expect(data.pendingTransactions.tx1).toBeNil()
		end)
	end)

	describe("ReceiptService", function()
		local PRODUCT_ID = 123456

		local function harness()
			local clock = Clock.fake(1000)
			local profileDs = MockDataStore.new("profiles")
			local receiptDs = MockDataStore.new("receipts")
			local log = Log.capture("receipts")
			local profiles =
				ProfileStore.new({ dataStore = profileDs, clock = clock, config = cfg, jobId = "job", wait = function() end, log = log })
			local deployment = { placeIds = {}, gamePasses = {}, developerProducts = { gemBundle100 = PRODUCT_ID } }
			local productMap = ProductMap.new(cfg, deployment)
			local analytics = AnalyticsService.new({ adapter = AnalyticsAdapter.mock(), config = cfg, buildInfo = { buildLabel = "test" } })
			local service = ReceiptService.new({
				productMap = productMap,
				profiles = profiles,
				receiptLedger = ReceiptLedger.new(receiptDs),
				clock = clock,
				log = log,
				analytics = analytics,
			})
			local grants = 0
			service:registerGrant("gems:100", function(data)
				grants += 1
				data.currencies.gems += 100
				return { gems = 100 }
			end)
			local profile = profiles:loadAsync(42).profile
			return {
				service = service,
				profiles = profiles,
				profileDs = profileDs,
				receiptDs = receiptDs,
				profile = profile,
				grants = function()
					return grants
				end,
				analytics = analytics,
			}
		end

		local function receipt(purchaseId, productId, userId)
			return { PurchaseId = purchaseId, PlayerId = userId or 42, ProductId = productId or PRODUCT_ID, CurrencySpent = 29 }
		end

		it("grants once and returns PurchaseGranted only after persistence; 100 replays grant once", function()
			local h = harness()
			for _ = 1, 100 do
				expect(h.service:processReceipt(receipt("p-1"))).toBe("PurchaseGranted")
			end
			expect(h.grants()).toBe(1)
			expect(h.profile.data.currencies.gems).toBe(100)
			expect(h.profileDs:peek(h.profiles:keyFor(42)).data.currencies.gems).toBe(100)
			expect(h.receiptDs:keyCount()).toBe(1)
			expect(h.service.stats.granted).toBe(1)
			expect(h.analytics.stats.sent).toBe(1)
		end)

		it("unknown product id returns NotProcessedYet and grants nothing", function()
			local h = harness()
			expect(h.service:processReceipt(receipt("p-2", 999999))).toBe("NotProcessedYet")
			expect(h.grants()).toBe(0)
			expect(h.profile.data.currencies.gems).toBe(0)
			expect(h.service.stats.unknown).toBe(1)
		end)

		it("save failure keeps the receipt pending and a later replay commits exactly once", function()
			local h = harness()
			h.profileDs:failNext(10)
			expect(h.service:processReceipt(receipt("p-3"))).toBe("NotProcessedYet")
			expect(h.grants()).toBe(1) -- applied in memory, not acknowledged
			expect(h.profileDs:peek(h.profiles:keyFor(42)).data.currencies.gems).toBe(0)
			h.profileDs:failNext(0)
			expect(h.service:processReceipt(receipt("p-3"))).toBe("PurchaseGranted")
			expect(h.grants()).toBe(1)
			expect(h.profile.data.currencies.gems).toBe(100)
			expect(h.profileDs:peek(h.profiles:keyFor(42)).data.currencies.gems).toBe(100)
		end)

		it("profile not loaded on this server defers without granting", function()
			local h = harness()
			expect(h.service:processReceipt(receipt("p-4", PRODUCT_ID, 77))).toBe("NotProcessedYet")
			expect(h.grants()).toBe(0)
		end)

		it("malformed receipts are refused", function()
			local h = harness()
			expect(h.service:processReceipt({ PurchaseId = 5 })).toBe("NotProcessedYet")
			expect(h.service:processReceipt(nil)).toBe("NotProcessedYet")
		end)

		it("a receipt already in the secondary ledger is acknowledged without touching the profile", function()
			local h = harness()
			h.receiptDs:seed("receipt:p-5", { purchaseId = "p-5", userId = 42, productId = PRODUCT_ID, grantedAt = 1 })
			expect(h.service:processReceipt(receipt("p-5"))).toBe("PurchaseGranted")
			expect(h.grants()).toBe(0)
			expect(h.service.stats.replayed).toBe(1)
		end)

		it("a product without a registered grant handler is deferred", function()
			local h = harness()
			local deployment = { placeIds = {}, gamePasses = {}, developerProducts = { gemBundle400 = 5555 } }
			local productMap = ProductMap.new(cfg, deployment)
			local service = ReceiptService.new({
				productMap = productMap,
				profiles = h.profiles,
				receiptLedger = ReceiptLedger.new(MockDataStore.new("r")),
				clock = Clock.fake(1),
			})
			expect(service:processReceipt(receipt("p-6", 5555))).toBe("NotProcessedYet")
		end)
	end)

	describe("ProductMap", function()
		it("derives every configured product key and reports all as missing by default", function()
			local map = ProductMap.new(cfg, { placeIds = {}, gamePasses = {}, developerProducts = {} })
			local missing = map:missingKeys()
			expect(#missing).toBe(map:count())
			expect(missing).toContain("gemBundle100")
			expect(missing).toContain("nestRakePermanent")
			expect(missing).toContain("featherVacOneRound")
			expect(missing).toContain("infiniteBag")
			expect(missing).toContain("eventChest10")
			expect(missing).toContain("chapter1")
			expect(map:isConfigured("gemBundle100")).toBe(false)
			expect(map:lookupDeveloperProduct(1)).toBeNil()
			expect(map:placeId("chapter1")).toBeNil()
		end)

		it("loads the shipped deployment file: every pass and product has an id, only place ids are missing", function()
			local ProductIds = require(Server.Deployment.ProductIds)
			local map = ProductMap.new(cfg, ProductIds)
			for _, key in ipairs(map:missingKeys()) do
				local entry = map:resolve(key)
				expect(entry and entry.kind).toBe("place")
			end
			expect(map:isConfigured("infiniteBag")).toBe(true)
			expect(map:isConfigured("gemBundle100")).toBe(true)
			expect(map:lookupGamePass(1976757816).key).toBe("confettiChargePermanent")
		end)

		it("accepts valid ids and refuses unknown keys, duplicates, and bad ids", function()
			local map = ProductMap.new(
				cfg,
				{ placeIds = { chapter1 = 10 }, gamePasses = { doubleGems = 11 }, developerProducts = { gemBundle100 = 12 } }
			)
			expect(map:placeId("chapter1")).toBe(10)
			expect(map:lookupGamePass(11).key).toBe("doubleGems")
			expect(map:lookupDeveloperProduct(12).grant).toBe("gems:100")
			expect(map:isConfigured("doubleGems")).toBe(true)
			expect(function()
				ProductMap.new(cfg, { developerProducts = { notAProduct = 1 } })
			end).toThrow("not a configured product")
			expect(function()
				ProductMap.new(cfg, { developerProducts = { gemBundle100 = 5, gemBundle400 = 5 } })
			end).toThrow("duplicate")
			expect(function()
				ProductMap.new(cfg, { developerProducts = { gemBundle100 = "5" } })
			end).toThrow()
		end)
	end)
end
