--!strict
-- Player nameplates: the display name over every character with their record time beneath
-- ("Record 01:35.34" or "No record yet"). The record comes from the SFE_BestTimeMs attribute the
-- server keeps on each Player; the plate hides itself for the local player while in first person.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Trove = require(Shared.Util.Trove)
local WorldBillboard = require(script.Parent.Parent.UI.Components.WorldBillboard)

local NameplateController = {}
NameplateController.__index = NameplateController

export type NameplateController = typeof(setmetatable(
	{} :: { _trove: any, _plates: { [Player]: { gui: BillboardGui, record: Frame, recordText: TextLabel } }, _showRecord: boolean },
	NameplateController
))

local function formatRecord(ms: number?): string
	if not ms or ms <= 0 then
		return "No record yet"
	end
	local totalSeconds = math.floor(ms / 1000)
	return string.format("Record  %02d:%02d.%02d", math.floor(totalSeconds / 60), totalSeconds % 60, math.floor((ms % 1000) / 10))
end

function NameplateController.new(round: any?): NameplateController
	local self = setmetatable({ _trove = Trove.new(), _plates = {}, _showRecord = true }, NameplateController)
	-- The record pill is a lobby thing: it hides for everyone once a round is under way.
	if round and round.phaseChanged then
		self._trove:add(round.phaseChanged:Connect(function(phase)
			self:setRecordVisible(phase == nil or phase == "Lobby")
		end))
	end
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
				plate.recordText.Text = formatRecord(player:GetAttribute("SFE_BestTimeMs") :: number?)
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
	-- A world billboard (studs-sized, occluded by geometry, culled past Tokens.world range).
	local world = Tokens.world
	local gui = WorldBillboard.create(head, "SFE_Nameplate", world.playerPlateStuds, Vector3.new(0, 2.2, 0), world.playerPlateMaxDistance)
	WorldBillboard.text(gui, "Name", player.DisplayName, {
		size = UDim2.fromScale(1, 0.58),
		font = Tokens.typography.title.font,
		outline = 2.4,
	})
	local record, recordText = WorldBillboard.pill(gui, "Record", formatRecord(player:GetAttribute("SFE_BestTimeMs") :: number?), {
		size = UDim2.fromScale(1, 0.38),
		position = UDim2.fromScale(0.5, 1),
		anchor = Vector2.new(0.5, 1),
		fill = Tokens.color.creamPill,
		textColor = Tokens.color.inkStrong,
	})
	record.Visible = self._showRecord
	self._plates[player] = { gui = gui, record = record, recordText = recordText }
end

function NameplateController.setRecordVisible(self: NameplateController, visible: boolean)
	self._showRecord = visible
	for _, plate in pairs(self._plates) do
		plate.record.Visible = visible
	end
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
