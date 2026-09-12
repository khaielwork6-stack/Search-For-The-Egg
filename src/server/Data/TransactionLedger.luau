--!strict
-- Idempotent transaction helper (DATASTORE_SCHEMA.md section 8). A transaction id is applied to a
-- profile at most once; replays return the original committed result without granting again.
-- The pending marker, mutation, and commit happen synchronously in memory so they always persist
-- together on the next save.

local ServerPolicy = require(script.Parent.Parent.ServerPolicy)

local TransactionLedger = {}

export type ApplyResult = { status: "committed" | "replayed", result: any }

TransactionLedger.VICTORY_KEY_FORMAT = "%s:%d:%s:%s" -- roundId:userId:chapterId:difficulty
TransactionLedger.RECEIPT_KEY_PREFIX = "receipt:"

function TransactionLedger.victoryKey(roundId: string, userId: number, chapterId: string, difficulty: string): string
	return string.format(TransactionLedger.VICTORY_KEY_FORMAT, roundId, userId, chapterId, difficulty)
end

function TransactionLedger.receiptKey(purchaseId: string): string
	return TransactionLedger.RECEIPT_KEY_PREFIX .. purchaseId
end

function TransactionLedger.isCommitted(data: { [string]: any }, txId: string): boolean
	local tx = data.pendingTransactions and data.pendingTransactions[txId]
	return type(tx) == "table" and tx.committedAt ~= nil
end

-- Applies `mutate(data)` exactly once for txId. `mutate` must be synchronous and may return a
-- serializable result (numbers/strings/tables) that is stored for replays.
function TransactionLedger.apply(
	data: { [string]: any },
	txId: string,
	kind: string,
	now: number,
	mutate: (data: { [string]: any }) -> any
): ApplyResult
	assert(type(txId) == "string" and #txId > 0, "transaction id required")
	if type(data.pendingTransactions) ~= "table" then
		data.pendingTransactions = {}
	end
	local existing = data.pendingTransactions[txId]
	if type(existing) == "table" and existing.committedAt ~= nil then
		return { status = "replayed", result = existing.result }
	end

	local marker: any = { id = txId, kind = kind, createdAt = now, committedAt = nil, result = nil }
	data.pendingTransactions[txId] = marker
	local ok, result = pcall(mutate, data)
	if not ok then
		data.pendingTransactions[txId] = nil -- mutation failed before commit; nothing granted
		error(result)
	end
	marker.committedAt = now
	marker.result = result
	TransactionLedger.prune(data, ServerPolicy.committedTransactionRetention)
	return { status = "committed", result = result }
end

-- Keeps only the newest `maxEntries` committed markers (uncommitted markers never survive because
-- apply is synchronous). Returns the number removed.
function TransactionLedger.prune(data: { [string]: any }, maxEntries: number): number
	local list = {}
	for txId, tx in pairs(data.pendingTransactions) do
		table.insert(list, { id = txId, at = tx.committedAt or tx.createdAt or 0 })
	end
	if #list <= maxEntries then
		return 0
	end
	table.sort(list, function(a, b)
		return a.at < b.at
	end)
	local removed = 0
	for i = 1, #list - maxEntries do
		data.pendingTransactions[list[i].id] = nil
		removed += 1
	end
	return removed
end

function TransactionLedger.count(data: { [string]: any }): number
	local n = 0
	for _ in pairs(data.pendingTransactions or {}) do
		n += 1
	end
	return n
end

return TransactionLedger
