--!strict
-- Player nameplates: the display name over every character with their record time beneath
-- ("Record 01:35.34" or "No record yet"). The record comes from the SFE_BestTimeMs attribute the
-- server keeps on each Player; the plate hides itself for the local player while in first person.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Trove = require(Shared.Util.Trove)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)

local NameplateController = {}
NameplateController.__index = NameplateController

export type NameplateController = typeof(setmetatable(
	{} :: { _trove: any, _plates: { [Player]: { gui: BillboardGui, record: TextLabel } } },
	NameplateController
))

local function formatRecord(ms: number?): string
	if not ms or ms <= 0 then
		return "No record yet"
	end
	local totalSeconds = math.floor(ms / 1000)
	return string.format("Record  %02d:%02d.%02d", math.floor(totalSeconds / 60), totalSeconds % 60, math.floor((ms % 1000) / 10))
end

function NameplateController.new(): NameplateController
	local self = setmetatable({ _trove = Trove.new(), _plates = {} }, NameplateController)
	local function watch(player: Player)
		local function onCharacter(character: Model)
			self:_attach(player, character)
		end
		self._trove:add(player.CharacterAdded:Connect(onCharacter))
		if player.Character then
			onCharacter(player.Character)
		end
		self._trove:add(player:GetAttributeChangedSignal("SFE_BestTimeMs"):Connect(function()
			local plate = self._plates[player]
			if plate then
				plate.record.Text = formatRecord(player:GetAttribute("SFE_BestTimeMs") :: number?)
			end
		end))
	end
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	self._trove:add(Players.PlayerAdded:Connect(watch))
	self._trove:add(Players.PlayerRemoving:Connect(function(player)
		self._plates[player] = nil
	end))
	return self
end

function NameplateController._attach(self: NameplateController, player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "SFE_Nameplate"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(220, 54)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	local name = FrameKit.text(gui, "Name", player.DisplayName, "title", {
		zIndex = 2,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	name.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 4)
	name.TextSize = Tokens.typography.title.size - 2
	FrameKit.outline(name, 2.4)
	local record = FrameKit.pill(gui, "Record", formatRecord(player:GetAttribute("SFE_BestTimeMs") :: number?), {
		size = UDim2.fromOffset(0, Tokens.typography.caption.size + Tokens.spacing.sm + 2),
		textSize = Tokens.typography.caption.size,
		zIndex = 2,
		fill = Tokens.color.creamPill,
		textColor = Tokens.color.inkStrong,
		fitText = true,
		outline = true,
	})
	record.AnchorPoint = Vector2.new(0.5, 1)
	record.Position = UDim2.fromScale(0.5, 1)
	gui.Parent = head
	self._plates[player] = { gui = gui, record = record }
end

function NameplateController.count(self: NameplateController): number
	local n = 0
	for _ in pairs(self._plates) do
		n += 1
	end
	return n
end

function NameplateController.destroy(self: NameplateController)
	for _, plate in pairs(self._plates) do
		plate.gui:Destroy()
	end
	self._plates = {}
	self._trove:destroy()
end

return NameplateController
