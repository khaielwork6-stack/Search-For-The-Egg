--!strict
-- The single typed remote registry contract. Every logical message declares direction, kind,
-- payload schema, payload bounds, and rate limit. There is deliberately no generic
-- "call any method" remote. Rates come from SYSTEM_CONFIG.interaction through `build(cfg)`.

local Schema = require(script.Parent.Schema)

local NetSchema = {}

export type Direction = "clientToServer" | "serverToClient"
export type Kind = "request" | "event" -- request = RemoteFunction (client invokes), event = RemoteEvent

export type MessageDef = {
	name: string,
	direction: Direction,
	kind: Kind,
	payload: Schema.Validator,
	rate: { perSecond: number, burst: number }?, -- clientToServer only
	maxBytes: number,
	maxDepth: number,
	phase: number, -- phase in which handlers become live (informational)
}

NetSchema.DEFAULT_MAX_BYTES = 2048
NetSchema.DEFAULT_MAX_DEPTH = 6

local DIFFICULTY = Schema.enum({ "normal", "hard" })
local TOKEN = Schema.string({ min = 8, max = 64, pattern = "^[%w%-{}]+$" })
-- Upgrade ids: "bag", "handGrasp", "<tool>.<path>", "tool:<tool>" (dots and colons are structural).
local UPGRADE_ID = Schema.string({ max = 48, min = 1, pattern = "^[%w_%-%.:]+$" })
-- Molly's map: the nest's four named areas.
local REGION = Schema.enum({ "backBarn", "backFence", "frontBarn", "frontFence" })

local function request(
	name: string,
	payload: Schema.Validator,
	rate: { perSecond: number, burst: number },
	phase: number,
	maxBytes: number?
): MessageDef
	return {
		name = name,
		direction = "clientToServer",
		kind = "request",
		payload = payload,
		rate = rate,
		maxBytes = maxBytes or NetSchema.DEFAULT_MAX_BYTES,
		maxDepth = NetSchema.DEFAULT_MAX_DEPTH,
		phase = phase,
	}
end

local function serverEvent(name: string, payload: Schema.Validator, phase: number, maxBytes: number?): MessageDef
	return {
		name = name,
		direction = "serverToClient",
		kind = "event",
		payload = payload,
		maxBytes = maxBytes or 65536,
		maxDepth = 10,
		phase = phase,
	}
end

-- Builds the registry from config. Returns an ordered array plus a name lookup.
function NetSchema.build(cfg: { [string]: any }): { list: { MessageDef }, byName: { [string]: MessageDef } }
	local interaction = cfg.interaction
	local burst = interaction.remoteBurstAllowance
	local slowRate = { perSecond = interaction.purchaseRequestRatePerSecond, burst = burst }
	local collectRate = { perSecond = interaction.collectRequestRatePerSecond, burst = burst }
	local toolRate = { perSecond = interaction.toolRequestRatePerSecond, burst = burst }
	local uiRate = { perSecond = 2, burst = burst }
	local puzzleRate = { perSecond = 5, burst = burst } -- shared puzzle inputs (tile turns are rapid)
	local rollRate = { perSecond = cfg.lobby.autoRollMaxPerMinute / 60, burst = 2 }
	local codeRate = { perSecond = cfg.codePolicy.attemptsPerMinute / 60, burst = cfg.codePolicy.burst }
	local maxParty = cfg.project.maxPartyPlayers
	local PERK_ID = Schema.id()

	local list: { MessageDef } = {
		-- Party -------------------------------------------------------------------------------
		request(
			"PartyCreate",
			Schema.object({
				chapter = Schema.id(),
				difficulty = DIFFICULTY,
				size = Schema.optional(Schema.number({ min = 1, max = 8, integer = true })),
			}),
			uiRate,
			1
		),
		request("PartyJoin", Schema.object({ partyId = TOKEN }), uiRate, 1),
		request("PartyLeave", Schema.none(), uiRate, 1),
		request(
			"PartySetDestination",
			Schema.object({
				chapter = Schema.id(),
				difficulty = DIFFICULTY,
			}),
			uiRate,
			1
		),
		request("PartyStart", Schema.object({ partyId = TOKEN }), uiRate, 1),
		request("PartyCancel", Schema.object({ partyId = TOKEN }), uiRate, 4),
		-- Tutorial / round actions (handlers land in Phase 2+; schemas exist now) --------------
		request("TutorialAction", Schema.object({ step = Schema.id(), action = Schema.enum({ "complete", "skip" }) }), uiRate, 2),
		request("RoundSkipVote", Schema.object({ sessionToken = TOKEN }), uiRate, 2),
		-- Reported once per client when the intro finishes, is skipped, or falls back after an error.
		-- Idempotent server-side, so retries and spam cannot start the round more than once.
		request("RoundIntroReady", Schema.object({ sessionToken = TOKEN }), uiRate, 2),
		request("BundleGather", Schema.object({ sessionToken = TOKEN, bundleId = Schema.id() }), collectRate, 3, 256),
		request(
			"CollectAction",
			Schema.object({
				sessionToken = TOKEN,
				origin = Schema.vector3(),
				direction = Schema.vector3(2),
				toolId = Schema.id(),
				requestId = Schema.optional(Schema.number({ min = 0, max = 1e12, integer = true })),
				featherId = Schema.optional(Schema.number({ min = 0, max = 1e9, integer = true })),
			}),
			collectRate,
			2,
			512
		),
		request("ToolEquip", Schema.object({ toolId = Schema.id() }), uiRate, 3),
		request(
			"ToolActionBegin",
			Schema.object({
				sessionToken = TOKEN,
				toolId = Schema.id(),
				origin = Schema.vector3(),
				direction = Schema.vector3(2),
				-- The record under the reticle: a hint the server validates, never trusted.
				featherId = Schema.optional(Schema.number({ min = 0, max = 1e9, integer = true })),
			}),
			toolRate,
			3,
			512
		),
		request("ToolActionEnd", Schema.object({ sessionToken = TOKEN, toolId = Schema.id() }), toolRate, 3, 256),
		-- Continuous tools re-aim from the reticle while held (the vac follows the player's aim).
		request(
			"ToolActionAim",
			Schema.object({
				sessionToken = TOKEN,
				toolId = Schema.id(),
				origin = Schema.vector3(),
				direction = Schema.vector3(2),
				-- The record under the reticle: a hint the server validates, never trusted.
				featherId = Schema.optional(Schema.number({ min = 0, max = 1e9, integer = true })),
			}),
			toolRate,
			3,
			512
		),
		request("SellRequest", Schema.object({ sessionToken = TOKEN }), slowRate, 2),
		request(
			"UpgradePurchase",
			Schema.object({
				sessionToken = TOKEN,
				upgradeId = UPGRADE_ID,
				expectedLevel = Schema.number({ min = 0, max = 100, integer = true }),
			}),
			slowRate,
			2
		),
		request("EggClaim", Schema.object({ sessionToken = TOKEN }), slowRate, 2),
		request("EggDeliver", Schema.object({ sessionToken = TOKEN }), slowRate, 2),
		-- Professor Plume's analysis: one clue per player per round, paid in Rainbow Feathers.
		request("PlumeAnalyse", Schema.object({ sessionToken = TOKEN }), slowRate, 2),
		-- Molly's survey names one of the four areas; the live pick may clear (no region).
		request("SurveyRequest", Schema.object({ sessionToken = TOKEN, region = REGION }), slowRate, 2),
		request("SurveySelect", Schema.object({ sessionToken = TOKEN, region = Schema.optional(REGION) }), uiRate, 2),

		-- Meta ---------------------------------------------------------------------------------
		request(
			"ClassRoll",
			Schema.object({ slot = Schema.number({ min = 1, max = cfg.classes.maximumSlots, integer = true }) }),
			rollRate,
			4
		),
		request(
			"ClassEquip",
			Schema.object({ classId = Schema.id(), slot = Schema.number({ min = 1, max = cfg.classes.maximumSlots, integer = true }) }),
			uiRate,
			4
		),
		request(
			"PerkPurchase",
			Schema.object({ perkId = PERK_ID, expectedLevel = Schema.number({ min = 0, max = 100, integer = true }) }),
			slowRate,
			4
		),
		request("DailyClaim", Schema.none(), slowRate, 4),
		-- One quest, by id. The server refuses an id that is not on today's board and replays a retry
		-- rather than paying twice.
		request("QuestClaim", Schema.object({ questId = Schema.id() }), slowRate, 4),
		request(
			"CodeRedeem",
			Schema.object({ code = Schema.string({ min = 1, max = cfg.codePolicy.maxLength + 8, pattern = "^[%w%s%-_]+$" }) }),
			codeRate,
			4
		),
		request("GroupRewardClaim", Schema.none(), slowRate, 4),
		request("InventoryEquip", Schema.object({ category = Schema.id(), itemId = Schema.id() }), uiRate, 4),
		request("LeaderboardRequest", Schema.none(), uiRate, 4),
		request("ResultsAction", Schema.object({ action = Schema.enum({ "replay", "lobby" }) }), uiRate, 2),
		request(
			"SettingsUpdate",
			Schema.object({
				musicVolume = Schema.optional(Schema.number({ min = 0, max = 1 })),
				sfxVolume = Schema.optional(Schema.number({ min = 0, max = 1 })),
				reducedMotion = Schema.optional(Schema.boolean()),
				cameraShake = Schema.optional(Schema.boolean()),
				haptics = Schema.optional(Schema.boolean()),
				qualityMode = Schema.optional(Schema.enum({ "auto", "low", "medium", "high" })),
			}),
			uiRate,
			1
		),
		request("PurchasePromptRequest", Schema.object({ productKey = Schema.id() }), slowRate, 5),
		request("ProductCatalogRequest", Schema.none(), uiRate, 5),
		request("EventChestOpen", Schema.object({ count = Schema.number({ min = 1, max = 10, integer = true }) }), slowRate, 5),
		request(
			"PuzzleAction",
			Schema.object({
				sessionToken = TOKEN,
				kind = Schema.enum({ "pickupKey", "lever", "crystals", "code", "tile", "release", "reset" }),
				index = Schema.optional(Schema.number({ min = 1, max = 16, integer = true })),
				count = Schema.optional(Schema.number({ min = 0, max = 99, integer = true })),
				value = Schema.optional(Schema.string({ min = 1, max = 8, pattern = "^%d+$" })),
			}),
			puzzleRate,
			5,
			512
		),
		-- Server -> client projections/events ------------------------------------------------
		serverEvent("ProfileProjection", Schema.object({ projection = Schema.object({}) }), 1),
		serverEvent("PartyProjection", Schema.object({}), 1),
		serverEvent("PadPrompt", Schema.object({ pad = Schema.number({ min = 1, max = 16, integer = true }) }), 1),
		serverEvent("SessionProjection", Schema.object({}), 1),
		-- The snapshot carries every pile cell (48x48 remaining + base arrays); deltas batch cells.
		serverEvent("RoundSnapshot", Schema.object({}), 2, 524288),
		serverEvent("RoundDelta", Schema.object({}), 2, 131072),
		serverEvent("ObjectiveChanged", Schema.object({}), 2),
		serverEvent("ActionResult", Schema.object({}), 2),
		serverEvent("SaleResult", Schema.object({}), 2),
		serverEvent("CrateRun", Schema.object({}), 2),
		serverEvent("UpgradeResult", Schema.object({}), 2),
		serverEvent("EggRevealed", Schema.object({}), 2),
		serverEvent("SurveyCompleted", Schema.object({}), 2),
		serverEvent("SurveySelection", Schema.object({}), 2),
		serverEvent("EggCarried", Schema.object({}), 2),
		serverEvent("EggDropped", Schema.object({}), 2),
		serverEvent("VictoryStarted", Schema.object({}), 2),
		serverEvent("RewardsCommitted", Schema.object({}), 2),
		serverEvent("ResultsProjection", Schema.object({}), 2),
		serverEvent("Toast", Schema.object({ key = Schema.id(), tone = Schema.enum({ "info", "success", "warning" }) }), 1),
		serverEvent("ModalDirective", Schema.object({ modalId = Schema.id(), action = Schema.enum({ "open", "close" }) }), 1),
		serverEvent("EntitlementsProjection", Schema.object({}), 1),
		serverEvent("ToolEvent", Schema.object({}), 3),
		serverEvent("PartyListProjection", Schema.object({}), 4),
		serverEvent("LeaderboardProjection", Schema.object({}), 4),
		serverEvent("RewardGranted", Schema.object({}), 4),
		serverEvent("PuzzleProjection", Schema.object({}), 5),
		serverEvent("PurchaseGranted", Schema.object({}), 5),
	}

	local byName: { [string]: MessageDef } = {}
	for _, def in ipairs(list) do
		assert(byName[def.name] == nil, "duplicate message " .. def.name)
		if def.direction == "clientToServer" then
			assert(def.rate ~= nil, "client request " .. def.name .. " needs a rate limit")
		end
		byName[def.name] = def
	end
	assert(maxParty >= 1, "maxPartyPlayers must be >= 1")
	return { list = list, byName = byName }
end

return NetSchema
