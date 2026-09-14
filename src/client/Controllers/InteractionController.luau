--!strict
-- Routes world ProximityPrompts (server-created) to typed requests and lobby modals: station
-- prompts (and the portal) open their modal, the trading crate sells, the workbench opens the
-- upgrade modal, and the Egg prompt (hold) claims. Prompts give the anticipation/hold affordance;
-- the server owns every outcome.

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Signal = require(Shared.Util.Signal)
local Tokens = require(Shared.Design.Tokens)
local NpcPlate = require(script.Parent.Parent.UI.NpcPlate)

local InteractionController = {}
InteractionController.__index = InteractionController

export type InteractionController = typeof(setmetatable(
	{} :: {
		_deps: any,
		partyRequested: any,
		sold: any,
		claimed: any,
		openUpgrades: any,
		stationRequested: any,
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
		stationRequested = Signal.new(),
		displayRequested = Signal.new(),
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
	-- Station prompts glow on approach so the interaction target reads at a glance.
	self._trove:add(ProximityPromptService.PromptShown:Connect(function(prompt)
		if string.sub(prompt.Name, 1, 12) == "SFE_Station_" or prompt.Name == "SFE_Portal" then
			deps.audio:play(Tokens.sound.stationChime, { at = prompt.Parent :: any })
		end
	end))
	return self
end

-- Dispatches by prompt name. Returns the envelope (or nil) for tests/debug.
function InteractionController.handle(self: InteractionController, promptName: string): any
	self.stats.prompts += 1
	local deps = self._deps
	local station = string.match(promptName, "^SFE_Station_(%w+)$")
	if station then
		deps.audio:play(Tokens.sound.uiOpen)
		self.stationRequested:Fire(station)
		return nil
	elseif promptName == "SFE_Portal" then
		deps.audio:play(Tokens.sound.uiOpen)
		self.stationRequested:Fire("party")
		return nil
	elseif string.match(promptName, "^SFE_PadStart_(%d+)$") then
		-- Party nest sign post: the leader sets off; anyone else gets the party options.
		local party = deps.party and deps.party.party
		if party and deps.party:isLeader() and (party.phase == "Ready" or party.phase == "Forming") then
			deps.audio:play(Tokens.sound.uiConfirm)
			local result = deps.party:start()
			if not result.ok then
				deps.hud.toasts:push(
					if result.message == "destination_locked" or result.message == "not_ready"
						then "Someone in the party has not unlocked that yet"
						else "Party is not ready yet",
					"warning"
				)
				self.stationRequested:Fire("party")
			end
			self.partyRequested:Fire(result)
			return result
		end
		deps.audio:play(Tokens.sound.uiOpen)
		self.stationRequested:Fire("party")
		return nil
	elseif promptName == "SFE_Sell" then
		local token = deps.round:sessionToken()
		if not token then
			return nil
		end
		deps.audio:play(Tokens.sound.uiTap)
		local result = deps.net:request("SellRequest", { sessionToken = token })
		if not result.ok then
			deps.hud.toasts:push(
				if result.message == "nothing_to_sell"
					then "Your bag is empty"
					elseif result.message == "crate_busy" then "The crate is on its way - wait for it to come back"
					else "Trade unavailable",
				"warning"
			)
			deps.audio:play(Tokens.sound.uiError)
		end
		self.sold:Fire(result)
		return result
	elseif promptName == "SFE_Upgrade" then
		deps.audio:play(Tokens.sound.uiOpen)
		self.openUpgrades:Fire()
		return nil
	elseif string.match(promptName, "^SFE_Display_(%w+)$") then
		-- Barn shop displays: the DisplayController buys what the model sells.
		self.displayRequested:Fire(string.match(promptName, "^SFE_Display_(%w+)$"))
		return nil
	elseif promptName == "SFE_EggClaim" then
		local token = deps.round:sessionToken()
		if not token then
			return nil
		end
		local result = deps.net:request("EggClaim", { sessionToken = token })
		if result.ok then
			deps.audio:play(Tokens.sound.eggChime)
			deps.haptics:pulse(0.7, 0.15)
			if result.data and result.data.carrying then
				deps.hud.toasts:push("You have the Egg! Take it to the Farmer", "success")
			end
		else
			deps.audio:play(Tokens.sound.uiError)
			deps.hud.toasts:push(
				if result.message == "carried"
					then "Someone already has the Egg"
					elseif result.code == "out_of_range" then "Get closer to the Egg"
					else "Could not take the Egg",
				"warning"
			)
		end
		self.claimed:Fire(result)
		return result
	elseif promptName == "SFE_EggDeliver" then
		local token = deps.round:sessionToken()
		if not token then
			return nil
		end
		local result = deps.net:request("EggDeliver", { sessionToken = token })
		if not result.ok then
			local arena = workspace:FindFirstChild("SFE_Chapter1")
			local farmer = arena and arena:FindFirstChild("Farmer")
			local farmerRoot = farmer and farmer:FindFirstChild("HumanoidRootPart")
			if result.message == "not_revealed" or result.message == "not_carrier" then
				-- The Farmer answers in his own words in the dialogue frame; no error tone for asking early.
				deps.audio:play(Tokens.sound.uiTap)
				local line = if result.message == "not_revealed" then "Find me the egg buddy!" else "Bring me the Egg first, buddy!"
				if deps.dialogue and farmer and farmer:IsA("Model") then
					deps.dialogue:open(farmer, line, { seconds = 2.2, name = "Farmer" })
				else
					NpcPlate.sayOn(farmerRoot, line, 2.8)
				end
			else
				deps.audio:play(Tokens.sound.uiError)
				deps.hud.toasts:push(
					if result.code == "out_of_range" then "Stand next to the Farmer" else "The Farmer is not ready",
					"warning"
				)
			end
		end
		self.claimed:Fire(result)
		return result
	end
	return nil
end

-- Solo party: create then start (leader). Both are validated server-side. Kept for the automation
-- harness and the "Set off alone" path.
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
	self.stationRequested:Destroy()
end

return InteractionController
