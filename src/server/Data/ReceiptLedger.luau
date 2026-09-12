--!strict
-- Secondary idempotency ledger for developer-product receipts (SFE_ReceiptLedger_v1). The profile
-- transaction marker is the primary guard; this store lets a receipt be recognised even when the
-- purchaser's profile is not loaded on this server.

local ServerPolicy = require(script.Parent.Parent.ServerPolicy)

local ReceiptLedger = {}
ReceiptLedger.__index = ReceiptLedger

export type ReceiptLedger = typeof(setmetatable({} :: { _dataStore: any }, ReceiptLedger))

function ReceiptLedger.new(dataStore: any): ReceiptLedger
	return setmetatable({ _dataStore = dataStore }, ReceiptLedger)
end

local function keyFor(purchaseId: string): string
	return ServerPolicy.receiptKeyPrefix .. purchaseId
end

-- Returns (ok, record?) where record is nil when the receipt is unknown.
function ReceiptLedger.lookup(self: ReceiptLedger, purchaseId: string): (boolean, any)
	return self._dataStore:getAsync(keyFor(purchaseId))
end

function ReceiptLedger.record(self: ReceiptLedger, purchaseId: string, userId: number, productId: number, now: number): boolean
	local ok = self._dataStore:updateAsync(keyFor(purchaseId), function(existing: any): any
		if type(existing) == "table" then
			return nil -- already recorded; keep the original
		end
		return { purchaseId = purchaseId, userId = userId, productId = productId, grantedAt = now }
	end)
	return ok
end

return ReceiptLedger
