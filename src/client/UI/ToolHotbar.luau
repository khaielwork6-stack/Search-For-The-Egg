--!strict
-- Tool hotbar: one slot per owned tool (Hand first), tap/click to equip, number-key / bumper hints
-- by input mode, and a per-slot status bar (Vac heat, Charge cooldown, Chick trip state). Sits above
-- the round strip inside the safe area; hidden outside rounds. Display names come from config.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Signal = require(Shared.Util.Signal)
local ToolSpecs = require(Shared.Domain.ToolSpecs)

local ToolHotbar = {}
ToolHotbar.__index = ToolHotbar

type Slot = { frame: TextButton, name: TextLabel, hint: TextLabel, status: TextLabel, bar: Frame, fill: Frame, index: number }

export type ToolHotbar = typeof(setmetatable(
	{} :: {
		root: Frame,
		activated: any, -- (toolId)
		_slots: { [string]: Slot },
		_order: { string },
		_owned: { [string]: boolean },
		_equipped: string,
		_mode: string,
		_motion: () -> Motion.MotionSettings,
		_config: { [string]: any },
	},
	ToolHotbar
))

local SLOT_WIDTH = 96

function ToolHotbar.new(
	gui: ScreenGui,
	config: { [string]: any },
	motion: () -> Motion.MotionSettings,
	minimumTapTarget: number,
	mode: string
): ToolHotbar
	local root = Instance.new("Frame")
	root.Name = "ToolHotbar"
	root.AnchorPoint = Vector2.new(0.5, 1)
	-- Above the round strip (safe padding + strip height + spacing).
	root.Position = UDim2.new(0.5, 0, 1, -(Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx + Tokens.spacing.md))
	root.Size = UDim2.fromOffset(0, minimumTapTarget + Tokens.spacing.md)
	root.AutomaticSize = Enum.AutomaticSize.X
	root.BackgroundTransparency = 1
	root.Visible = false
	root.ZIndex = Tokens.zIndex.hud
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, Tokens.spacing.sm)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Parent = root
	root.Parent = gui

	local self = setmetatable({
		root = root,
		activated = Signal.new(),
		_slots = {},
		_order = { "hand" },
		_owned = { hand = true },
		_equipped = "hand",
		_mode = mode,
		_motion = motion,
		_config = config,
	}, ToolHotbar)
	for _, toolId in ipairs(ToolSpecs.TOOL_IDS) do
		table.insert(self._order, toolId)
	end
	for index, toolId in ipairs(self._order) do
		self:_makeSlot(toolId, index, minimumTapTarget)
	end
	self:_refresh()
	return self
end

function ToolHotbar._makeSlot(self: ToolHotbar, toolId: string, index: number, minimumTapTarget: number)
	local frame = Instance.new("TextButton")
	frame.Name = "Slot_" .. toolId
	frame.LayoutOrder = index
	frame.AutoButtonColor = false
	frame.Text = ""
	frame.Size = UDim2.fromOffset(SLOT_WIDTH, minimumTapTarget + Tokens.spacing.md)
	frame.BackgroundColor3 = Tokens.color.surface
	frame.ZIndex = Tokens.zIndex.hud
	frame.Selectable = true
	frame.Visible = toolId == "hand"
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.creamDeep
	stroke.Parent = frame

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.Position = UDim2.fromOffset(Tokens.spacing.xs, Tokens.spacing.xs)
	name.Size = UDim2.new(1, -Tokens.spacing.xs * 2, 0, Tokens.typography.caption.size + 2)
	name.BackgroundTransparency = 1
	name.Font = Tokens.typography.heading.font
	name.TextSize = Tokens.typography.caption.size
	name.TextColor3 = Tokens.color.inkStrong
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = if toolId == "hand" then "Hand" else self._config.tools[toolId].displayName
	name.ZIndex = Tokens.zIndex.hud + 1
	name.Parent = frame

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, -Tokens.spacing.xs, 0, Tokens.spacing.xs)
	hint.Size = UDim2.fromOffset(28, Tokens.typography.caption.size + 2)
	hint.BackgroundTransparency = 1
	hint.Font = Tokens.typography.caption.font
	hint.TextSize = Tokens.typography.caption.size
	hint.TextColor3 = Tokens.color.inkMuted
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.ZIndex = Tokens.zIndex.hud + 1
	hint.Parent = frame

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, Tokens.spacing.xs, 1, -(Tokens.spacing.xs + 6))
	status.Size = UDim2.new(1, -Tokens.spacing.xs * 2, 0, Tokens.typography.caption.size + 2)
	status.BackgroundTransparency = 1
	status.Font = Tokens.typography.caption.font
	status.TextSize = Tokens.typography.caption.size
	status.TextColor3 = Tokens.color.inkMuted
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text = ""
	status.ZIndex = Tokens.zIndex.hud + 1
	status.Parent = frame

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, Tokens.spacing.xs, 1, -Tokens.spacing.xs)
	bar.Size = UDim2.new(1, -Tokens.spacing.xs * 2, 0, 4)
	bar.BackgroundColor3 = Tokens.color.creamDeep
	bar.BorderSizePixel = 0
	bar.ZIndex = Tokens.zIndex.hud + 1
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	barCorner.Parent = bar
	bar.Parent = frame
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Tokens.color.straw
	fill.BorderSizePixel = 0
	fill.ZIndex = Tokens.zIndex.hud + 2
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	fillCorner.Parent = fill
	fill.Parent = bar

	frame.Activated:Connect(function()
		self.activated:Fire(toolId)
	end)
	frame.Parent = self.root
	self._slots[toolId] = { frame = frame, name = name, hint = hint, status = status, bar = bar, fill = fill, index = index }
end

function ToolHotbar._refresh(self: ToolHotbar)
	local visibleIndex = 0
	for _, toolId in ipairs(self._order) do
		local slot = self._slots[toolId]
		local owned = self._owned[toolId] == true
		slot.frame.Visible = owned
		if owned then
			visibleIndex += 1
			if self._mode == "gamepad" then
				slot.hint.Text = if toolId == self._equipped then "LB/RB" else ""
			elseif self._mode == "touch" then
				slot.hint.Text = ""
			else
				slot.hint.Text = tostring(visibleIndex)
			end
		end
		local equipped = toolId == self._equipped
		local stroke = slot.frame:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Color = if equipped then Tokens.color.ember else Tokens.color.creamDeep
		slot.frame.BackgroundColor3 = if equipped then Tokens.color.surfaceAlt else Tokens.color.surface
	end
end

-- Owned tools from the authoritative player projection (`roundTools`).
function ToolHotbar.setOwned(self: ToolHotbar, roundTools: { [string]: boolean })
	self._owned = { hand = true }
	for toolId, owned in pairs(roundTools) do
		if owned then
			self._owned[toolId] = true
		end
	end
	self:_refresh()
end

function ToolHotbar.setEquipped(self: ToolHotbar, toolId: string)
	if self._equipped == toolId then
		return
	end
	self._equipped = toolId
	self:_refresh()
	local slot = self._slots[toolId]
	if slot then
		local scale = slot.frame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Parent = slot.frame
		scale.Scale = 1 + Motion.amplitude(0.06, self._motion())
		TweenService:Create(scale, TweenInfo.new(Motion.duration("quick", self._motion()), Tokens.motion.easeBack), { Scale = 1 }):Play()
	end
end

function ToolHotbar.setMode(self: ToolHotbar, mode: string)
	self._mode = mode
	self:_refresh()
end

-- Status for one slot: bar fraction [0,1], caption, tone ("info" | "warning" | "danger" | "success").
function ToolHotbar.setStatus(self: ToolHotbar, toolId: string, fraction: number?, text: string?, tone: string?)
	local slot = self._slots[toolId]
	if not slot then
		return
	end
	slot.status.Text = text or ""
	local colors =
		{ info = Tokens.color.straw, warning = Tokens.color.warning, danger = Tokens.color.danger, success = Tokens.color.success }
	slot.fill.BackgroundColor3 = colors[tone or "info"] or Tokens.color.straw
	slot.fill.Size = UDim2.fromScale(math.clamp(fraction or 0, 0, 1), 1)
	slot.bar.Visible = fraction ~= nil
end

-- Tool id at a visible slot position (1-based, owned tools only) for number keys.
function ToolHotbar.toolAtIndex(self: ToolHotbar, index: number): string?
	local visibleIndex = 0
	for _, toolId in ipairs(self._order) do
		if self._owned[toolId] then
			visibleIndex += 1
			if visibleIndex == index then
				return toolId
			end
		end
	end
	return nil
end

-- Next/previous owned tool relative to the equipped one (gamepad bumpers).
function ToolHotbar.cycle(self: ToolHotbar, direction: number): string
	local owned = {}
	for _, toolId in ipairs(self._order) do
		if self._owned[toolId] then
			table.insert(owned, toolId)
		end
	end
	local current = table.find(owned, self._equipped) or 1
	local next = ((current - 1 + direction) % #owned) + 1
	return owned[next]
end

function ToolHotbar.ownedCount(self: ToolHotbar): number
	local n = 0
	for _ in pairs(self._owned) do
		n += 1
	end
	return n
end

function ToolHotbar.setVisible(self: ToolHotbar, visible: boolean)
	self.root.Visible = visible
end

function ToolHotbar.destroy(self: ToolHotbar)
	self.root:Destroy()
	self.activated:Destroy()
end

return ToolHotbar
