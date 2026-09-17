--!strict
-- Purchase actions shared by the workbench modal, the barn displays and the lobby shops: one
-- place that sends the request, plays the confirmation or the refusal, and words the toast. The
-- server stays the authority on price, level and ownership; this only relays its answer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)

local UpgradeActions = {}

export type Deps = {
	net: any,
	round: any,
	audio: any,
	haptics: any,
	toasts: any,
	config: { [string]: any },
}

-- Latest server preview for an upgrade id (nil when the round has not sent one).
function UpgradeActions.previewFor(round: any, upgradeId: string): any?
	for _, preview in ipairs(round.previews or {}) do
		if preview.upgradeId == upgradeId then
			return preview
		end
	end
	return nil
end

function UpgradeActions.titleFor(config: { [string]: any }, preview: any, fallback: string?): string
	if preview.kind == "acquire" and preview.toolId then
		local tool = config.tools[preview.toolId]
		return tool and tool.displayName or preview.toolId
	elseif preview.kind == "bag" then
		return "Bag capacity"
	end
	return fallback or preview.upgradeId
end

-- Buys one round upgrade (bag level, hand path, tool path or tool acquisition). Returns the
-- server envelope, or nil when nothing was sent (no preview, maxed, no session).
function UpgradeActions.purchase(deps: Deps, upgradeId: string, title: string?): any?
	local latest = UpgradeActions.previewFor(deps.round, upgradeId)
	local token = deps.round:sessionToken()
	if not latest or latest.maxed or not token then
		return nil
	end
	local result = deps.net:request("UpgradePurchase", { sessionToken = token, upgradeId = upgradeId, expectedLevel = latest.level })
	local name = title or UpgradeActions.titleFor(deps.config, latest)
	if result.ok then
		deps.audio:play(Tokens.sound.upgradeChord)
		deps.haptics:pulse(0.5, 0.1)
		deps.toasts:push(if latest.kind == "acquire" then name .. " acquired" else name .. " improved", "success")
	else
		deps.audio:play(Tokens.sound.uiError)
		local message = if result.code == "insufficient_funds"
			then (if result.message == "gems" then "Not enough Gems" else "Not enough round cash")
			elseif result.code == "stale_token" then "Prices changed - try again"
			else "Upgrade unavailable"
		deps.toasts:push(message, "warning")
	end
	return result
end

-- Asks the server to open the native Robux prompt for a product key (pass or developer
-- product). The grant itself arrives later through the profile projection.
function UpgradeActions.promptPurchase(deps: { net: any, audio: any, toasts: any }, productKey: string, name: string?): any
	local result = deps.net:request("PurchasePromptRequest", { productKey = productKey })
	if result.ok then
		deps.audio:play(Tokens.sound.uiConfirm)
	else
		deps.audio:play(Tokens.sound.uiError)
		local message = if result.code == "already_done"
			then "You already own " .. (name or "that")
			elseif result.message == "not_available" then "Not for sale yet"
			else "Could not open the purchase"
		deps.toasts:push(message, if result.code == "already_done" then "info" else "warning")
	end
	return result
end

return UpgradeActions
