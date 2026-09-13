--!strict
-- Maps server objective ids to copy in the HUD banner and highlights one world target at a time
-- (portal / nest / crate / workbench / Egg) with a Highlight that never covers the reticle area.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Trove = require(Shared.Util.Trove)
local Objectives = require(Shared.Domain.Objectives)
local Tokens = require(Shared.Design.Tokens)

local ObjectiveController = {}
ObjectiveController.__index = ObjectiveController

export type ObjectiveController = typeof(setmetatable(
	{} :: { _deps: any, step: string?, inRound: boolean, _highlight: Highlight?, _trove: Trove.Trove },
	ObjectiveController
))

-- Highlight targets: the first path that resolves wins (map-mode anchors and props first, then the
-- greybox parts), so the highlight lands on whatever the current environment provides.
local TARGETS: { [string]: { { string } } } = {
	enter_party = { { "SFE_LobbyShell", "PortalAnchor" }, { "SFE_LobbyShell", "PortalDiorama" } },
	collect_25 = { { "SFE_PileVisual", "Dome" }, { "SFE_Chapter1", "NestBase" } },
	sell_first_bag = { { "SearchForTheEgg_Map2", "Processor", "GreenButton" }, { "SFE_Chapter1", "SellStation" } },
	buy_first_upgrade = { { "SearchForTheEgg_Map2", "SupplyShop", "CounterBody" }, { "SFE_Chapter1", "UpgradeBoard" } },
	claim_or_complete_round = { { "SFE_Chapter1", "SFE_Egg" } },
}

local function resolve(path: { string }): Instance?
	local node: Instance? = workspace
	for _, name in ipairs(path) do
		node = node and node:FindFirstChild(name)
		if not node then
			return nil
		end
	end
	return node
end

function ObjectiveController.new(deps: { net: any, hud: any, round: any }): ObjectiveController
	local self = setmetatable({ _deps = deps, step = nil, inRound = false, _highlight = nil, _trove = Trove.new() }, ObjectiveController)
	self._trove:add(deps.net:on("ObjectiveChanged", function(payload)
		self:apply(payload.step, payload.inRound == true)
	end))
	-- Re-apply the current copy once Searching begins (the countdown text owns the banner until then).
	self._trove:add(deps.round.phaseChanged:Connect(function(phase)
		if phase == "Searching" and self.step then
			self:apply(self.step, true)
		end
	end))
	self._trove:add(deps.round.eggRevealed:Connect(function()
		if self.step == "claim_or_complete_round" then
			task.delay(0.5, function()
				self:_highlightTarget()
			end)
		end
	end))
	return self
end

function ObjectiveController.apply(self: ObjectiveController, step: string, inRound: boolean)
	self.step = step
	self.inRound = inRound
	local copy = Objectives.COPY[step]
	if step == Objectives.COMPLETE and not inRound then
		self._deps.hud:setObjective("Ready for another search", "Enter the henhouse doorway when you like")
	elseif copy then
		self._deps.hud:setObjective(copy.title, copy.detail)
	end
	self:_highlightTarget()
end

function ObjectiveController._highlightTarget(self: ObjectiveController)
	if self._highlight then
		self._highlight:Destroy()
		self._highlight = nil
	end
	local paths = self.step and TARGETS[self.step]
	if not paths then
		return
	end
	local part: Instance? = nil
	for _, path in ipairs(paths) do
		part = resolve(path)
		if part then
			break
		end
	end
	if not part then
		return
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "SFE_ObjectiveHighlight"
	highlight.FillColor = Tokens.color.straw
	highlight.FillTransparency = 0.85
	highlight.OutlineColor = Tokens.color.ember
	highlight.OutlineTransparency = 0.1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = part
	highlight.Parent = part
	self._highlight = highlight
end

function ObjectiveController.destroy(self: ObjectiveController)
	if self._highlight then
		self._highlight:Destroy()
	end
	self._trove:destroy()
end

return ObjectiveController
