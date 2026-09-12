--!strict
-- Infrastructure policy values that are not gameplay tunables (so they do not belong in
-- SYSTEM_CONFIG) but must still live in exactly one place. All values are ASSUMED and documented
-- in docs/IMPLEMENTATION_STATUS.md; DATASTORE_SCHEMA.md section 10 gives the cadence guidance.

return table.freeze({
	profileStoreName = "SFE_PlayerProfile_v1",
	receiptStoreName = "SFE_ReceiptLedger_v1",
	profileKeyPrefix = "player:",
	receiptKeyPrefix = "receipt:",

	sessionLockTimeoutSeconds = 90, -- a lock older than this is considered abandoned by a dead server
	loadAttempts = 5, -- total UpdateAsync attempts before the player is held at LoadRetry
	loadBackoffBaseSeconds = 1.5,
	loadBackoffMaxSeconds = 10,
	loadHoldSeconds = 25, -- how long a player may sit in LoadRetry before a friendly removal
	saveAttempts = 3,
	autosaveMinSeconds = 60,
	autosaveMaxSeconds = 120,
	shutdownFlushBudgetSeconds = 25,
	committedTransactionRetention = 500, -- committed idempotency markers kept per profile

	entitlementCacheSeconds = 120,
	rateLimiterSweepSeconds = 120,
	rateLimiterIdleSeconds = 300,
	securityLogSampleRate = 0.1,

	loadFailureKickMessage = "We couldn't load your nest safely. Please rejoin in a moment - your progress is protected.",
	duplicateSessionKickMessage = "You are already active in another server. Please try again shortly.",
})
