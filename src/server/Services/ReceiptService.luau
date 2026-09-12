--!strict
-- The single ProcessReceipt implementation (DATASTORE_SCHEMA.md section 9). Grant handlers are
-- registered by grant kind ("gems:100", "oneRoundTool:nestRake", ...). Phase 1 ships the
-- pipeline and replay safety; real handlers land in Phase 5. Decisions are strings mapped to
-- Enum.ProductPurchaseDecision by the Marketplace adapter.

local TransactionLedger = require(script.Parent.Parent.Data.TransactionLedger)

local ReceiptService = {}
ReceiptService.__index = ReceiptService

export type Decision = "PurchaseGranted" | "NotProcessedYet"

export type GrantHandler = (profileData: { [string]: any }, receipt: any, entry: any) -> any

export type ReceiptService = typeof(setmetatable(
	{} :: {
		_productMap: any,
		_profiles: any, -- ProfileStore
		_receiptLedger: any,
		_clock: any,
		_log: any,
		_analytics: any,
		_handlers: { [string]: GrantHandler },
		stats: { granted: number, replayed: number, deferred: number, unknown: number },
	},
	ReceiptService
))

function ReceiptService.new(
	options: { productMap: any, profiles: any, receiptLedger: any, clock: any, log: any?, analytics: any? }
): ReceiptService
	return setmetatable({
		_productMap = options.productMap,
		_profiles = options.profiles,
		_receiptLedger = options.receiptLedger,
		_clock = options.clock,
		_log = options.log,
		_analytics = options.analytics,
		_handlers = {},
		stats = { granted = 0, replayed = 0, deferred = 0, unknown = 0 },
	}, ReceiptService)
end

function ReceiptService.registerGrant(self: ReceiptService, grantKind: string, handler: GrantHandler)
	assert(self._handlers[grantKind] == nil, "grant handler already registered: " .. grantKind)
	self._handlers[grantKind] = handler
end

local function log(self: ReceiptService, level: string, code: string, fields: { [string]: any }?)
	if self._log then
		self._log[level](self._log, code, fields)
	end
end

-- receiptInfo: { PurchaseId: string, PlayerId: number, ProductId: number, ... }
function ReceiptService.processReceipt(self: ReceiptService, receiptInfo: any): Decision
	if
		type(receiptInfo) ~= "table"
		or type(receiptInfo.PurchaseId) ~= "string"
		or type(receiptInfo.PlayerId) ~= "number"
		or type(receiptInfo.ProductId) ~= "number"
	then
		self.stats.unknown += 1
		log(self, "error", "receipt_malformed")
		return "NotProcessedYet"
	end
	local purchaseId = receiptInfo.PurchaseId
	local userId = receiptInfo.PlayerId
	local now = self._clock:now()

	-- 1. Secondary ledger: already persisted grant (possibly from another server).
	local ledgerOk, existing = self._receiptLedger:lookup(purchaseId)
	if ledgerOk and type(existing) == "table" then
		self.stats.replayed += 1
		return "PurchaseGranted"
	end

	-- 2. Product must be a configured, deployed product; unknown IDs never grant.
	local entry = self._productMap:lookupDeveloperProduct(receiptInfo.ProductId)
	if not entry then
		self.stats.unknown += 1
		log(self, "error", "receipt_unknown_product", { productId = receiptInfo.ProductId, userId = userId })
		return "NotProcessedYet"
	end
	local handler = self._handlers[entry.grant]
	if not handler then
		self.stats.deferred += 1
		log(self, "error", "receipt_no_grant_handler", { productId = receiptInfo.ProductId, userId = userId })
		return "NotProcessedYet"
	end

	-- 3. Profile must be loaded and locked on this server.
	local profile = self._profiles:get(userId)
	if not profile or not profile:isActive() then
		self.stats.deferred += 1
		log(self, "warn", "receipt_profile_unavailable", { userId = userId })
		return "NotProcessedYet"
	end

	-- 4. Idempotent in-memory grant.
	local txId = TransactionLedger.receiptKey(purchaseId)
	local applied = profile:update(function(data)
		return TransactionLedger.apply(data, txId, "receipt", now, function(mutableData)
			return handler(mutableData, receiptInfo, entry)
		end)
	end)

	-- 5. Persist before acknowledging. Failure keeps the receipt pending; the marker in memory
	--    guarantees the retry does not grant twice on this server, and a fresh server reloads the
	--    un-granted profile so the single grant happens then.
	local saved = self._profiles:saveAsync(profile)
	if not saved then
		self.stats.deferred += 1
		log(self, "warn", "receipt_save_failed", { userId = userId })
		return "NotProcessedYet"
	end

	-- 6. Record in the secondary ledger (best effort; profile marker remains authoritative).
	self._receiptLedger:record(purchaseId, userId, receiptInfo.ProductId, now)
	if applied.status == "committed" then
		self.stats.granted += 1
		if self._analytics then
			self._analytics:track("purchase_completed", { productKey = entry.key }, userId)
		end
	else
		self.stats.replayed += 1
	end
	log(self, "info", "receipt_granted", { userId = userId, productId = receiptInfo.ProductId, replayed = applied.status == "replayed" })
	return "PurchaseGranted"
end

return ReceiptService
