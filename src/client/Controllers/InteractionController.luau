--!strict
-- Routes world ProximityPrompts (server-created) to typed requests: the lobby portal creates and
-- starts a solo party, the trading crate sells, the workbench opens the upgrade modal, and the Egg
-- prompt (hold) claims. Prompts give the anticipation/hold affordance; the server owns the outcome.

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Signal = require(Shared.Util.Signal)
local Tokens = require(Shared.Design.Tokens)

local InteractionController = {}
InteractionController.__index = InteractionController

export type InteractionController = typeof(setmetatable(
	{} :: {
		_deps: any,
		partyRequested: any,
		sold: any,
		claimed: any,
		openUpgrades: any,
		_trove: Trove.Trove,
		stats: { prompts: number },
	},
	InteractionController
))

function InteractionController.new(
	deps: { net: any, round: any, audio: any, haptics: any, hud: any, config: { [string]: any } }
): InteractionController
	local self = setmetatable({
		_deps = deps,
		partyRequested = Signal.new(),
		sold = Signal.new(),
		claimed = Signal.new(),
		openUpgrades = Signal.new(),
		_trove = Trove.new(),
		stats = { prompts = 0 },
	}, InteractionController)

	self._trove:add(ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if player ~= game:GetService("Players").LocalPlayer then
			return
		end
		self:handle(prompt.Name)
	end))
	self._trove:add(ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
		if prompt.Name == "SFE_EggClaim" then
			deps.audio:play(Tokens.sound.eggClaimHold)
			deps.haptics:pulse(0.3, 0.1)
		end
	end))
	return self
end

-- Dispatches by prompt name. Returns the envelope (or nil) for tests/debug.
function InteractionController.handle(self: InteractionController, promptName: string): any
	self.stats.prompts += 1
	local deps = self._deps
	if promptName == "SFE_Portal" then
		return self:startSoloParty()
	elseif promptName == "SFE_Sell" then
		local token = deps.round:sessionToken()
		if not token then
			return nil
		end
		deps.audio:play(Tokens.sound.uiTap)
		local result = deps.net:request("SellRequest", { sessionToken = token })
		if not result.ok then
			deps.hud.toasts:push(if result.message == "nothing_to_sell" then "Your bag is empty" else "Trade unavailable", "warning")
			deps.audio:play(Tokens.sound.uiError)
		end
		self.sold:Fire(result)
		return result
	elseif promptName == "SFE_Upgrade" then
		deps.audio:play(Tokens.sound.uiOpen)
		self.openUpgrades:Fire()
		return nil
	elseif promptName == "SFE_EggClaim" then
		local token = deps.round:sessionToken()
		if not token then
			return nil
		end
		local result = deps.net:request("EggClaim", { sessionToken = token })
		if not result.ok and result.message ~= "already_won" then
			deps.hud.toasts:push("Get closer to the Egg", "warning")
		end
		self.claimed:Fire(result)
		return result
	end
	return nil
end

-- Solo party: create then start (leader). Both are validated server-side.
function InteractionController.startSoloParty(self: InteractionController): any
	local deps = self._deps
	deps.audio:play(Tokens.sound.uiConfirm)
	local created = deps.net:request("PartyCreate", { chapter = "chapter1", difficulty = "normal" })
	if not created.ok then
		deps.hud.toasts:push("Could not form a party", "warning")
		self.partyRequested:Fire(created)
		return created
	end
	local started = deps.net:request("PartyStart", { partyId = created.data.partyId })
	if not started.ok then
		deps.hud.toasts:push("Party is not ready yet", "warning")
	end
	self.partyRequested:Fire(started)
	return started
end

function InteractionController.destroy(self: InteractionController)
	self._trove:destroy()
	self.partyRequested:Destroy()
	self.sold:Destroy()
	self.claimed:Destroy()
	self.openUpgrades:Destroy()
end

return InteractionController
