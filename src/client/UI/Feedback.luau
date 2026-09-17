--!strict
-- The one door every refusal goes through on the client: not enough money, bag full, still cooling,
-- out of range, can't use. `Feedback.deny(reasonKey, text)` plays the denial sound and shows the
-- toast once, then that reason stays silent for `hud.feedback.denialCooldownSeconds` (5 s) however
-- often the player presses. Other reasons are unaffected, so a different refusal still speaks.
--
-- A module-level singleton on purpose: modals, controllers and UI helpers all refuse things, and
-- none of them should need a new dependency threaded through to share one gate. The HUD binds the
-- toast queue and the audio at boot; before that (or in an edit-mode harness) `deny` still gates and
-- simply has nothing to show.
--
-- Reason keys are short, stable and specific ("gems", "bag_full", "sale:crate_busy"): the gate is per
-- reason, so two callers reporting the same refusal share one window.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local CooldownGate = require(Shared.Util.CooldownGate)

local DEFAULT_SECONDS = 5

local Feedback = {}

type Toasts = { push: (self: any, text: string, tone: string?, seconds: number?) -> any }
type Bound = { toasts: Toasts?, play: ((role: string) -> ())? }

local bound: Bound = {}
local gate = CooldownGate.new(DEFAULT_SECONDS, os.clock)
local stats = { denied = 0, suppressed = 0 }

-- `clock` is for tests; the game uses os.clock.
function Feedback.bind(options: {
	toasts: Toasts?,
	play: ((role: string) -> ())?,
	config: { [string]: any }?,
	clock: (() -> number)?,
})
	bound = { toasts = options.toasts, play = options.play }
	local window = gate:window()
	local feedbackConfig = options.config and options.config.hud and options.config.hud.feedback
	if feedbackConfig and type(feedbackConfig.denialCooldownSeconds) == "number" then
		window = feedbackConfig.denialCooldownSeconds
	end
	gate = CooldownGate.new(window, options.clock or os.clock)
end

export type DenyOptions = { tone: string?, silent: boolean?, seconds: number? }

-- Plays the denial sound and shows `text` (when given) unless this reason was already reported
-- inside the window. Returns true when the feedback was shown, so a caller can add its own
-- one-off extra (a shake, a haptic) only when the player actually got the refusal.
function Feedback.deny(reasonKey: string, text: string?, options: DenyOptions?): boolean
	if not gate:tryPass(reasonKey) then
		stats.suppressed += 1
		return false
	end
	stats.denied += 1
	local opts = options or {}
	if not opts.silent and bound.play then
		bound.play(Tokens.sound.uiError)
	end
	if text and bound.toasts then
		bound.toasts:push(text, opts.tone or "warning", opts.seconds, true)
	end
	return true
end

-- A refused sale reads the same whichever path refused it (the crate prompt's request, or the
-- crate click's SaleResult push), so both share one reason key and one line.
function Feedback.saleReason(result: { [string]: any }): string
	return "sale:" .. tostring(result.message or result.code)
end

function Feedback.saleText(result: { [string]: any }): string
	if result.message == "nothing_to_sell" then
		return "Your bag is empty"
	elseif result.message == "crate_busy" then
		return "The crate is on its way - wait for it to come back"
	end
	return "Trade unavailable"
end

-- True when a denial for this reason would be shown right now.
function Feedback.canDeny(reasonKey: string): boolean
	return gate:isOpen(reasonKey)
end

function Feedback.stats(): { denied: number, suppressed: number, window: number }
	return { denied = stats.denied, suppressed = stats.suppressed, window = gate:window() }
end

function Feedback.reset()
	gate:reset()
	stats.denied = 0
	stats.suppressed = 0
end

return Feedback
