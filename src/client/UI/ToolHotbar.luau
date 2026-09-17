--!strict
-- Tool hotbar: one dark slate square slot per owned tool (Hand first) with the tool art centred, the
-- name on a small dark pill beneath, a keycap hint in the corner by input mode, and a status bar for
-- cooldown / heat / trip state. Every slot wears a thick black outline; the equipped one swaps it
-- for gold and pops. Sits above the round strip inside the safe area; hidden outside rounds.
-- Display names come from config.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Signal = require(Shared.Util.Signal)
local ToolSpecs = require(Shared.Domain.ToolSpecs)
local Skin = require(script.Parent.Components.Skin)
local Icons = require(script.Parent.Components.Icons)
local FrameKit = require(script.Parent.Components.Frame)
local Depth = require(script.Parent.Components.Depth)
local Tween = require(script.Parent.Components.Tween)

local ToolHotbar = {}
ToolHotbar.__index = ToolHotbar

type Slot = {
	frame: TextButton,
	face: Frame,
	name: TextLabel,
	hint: Frame,
	hintText: TextLabel?,
	status: TextLabel,
	bar: Frame,
	fill: Frame,
	scale: UIScale,
	outline: UIStroke,
	index: number,
}

export type ToolHotbar = typeof(setmetatable(
	{} :: {
		root: Frame,
		activated: any,
		_slots: { [string]: Slot },
		_order: { string },
		_owned: { [string]: boolean },
		_equipped: string,
		_mode: string,
		_motion: () -> Motion.MotionSettings,
		_config: { [string]: any },
		_sound: ((role: string) -> ())?,
	},
	ToolHotbar
))

local SLOT = 72
local LIP = 5

function ToolHotbar.new(
	gui: Instance,
	config: { [string]: any },
	motion: () -> Motion.MotionSettings,
	minimumTapTarget: number,
	mode: string,
	sound: ((role: string) -> ())?
): ToolHotbar
	local root = Instance.new("Frame")
	root.Name = "ToolHotbar"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -(Tokens.layout.safeAreaPaddingPx + Tokens.layout.minimumTapTargetPx + Tokens.spacing.md))
	root.Size = UDim2.fromOffset(0, SLOT + Tokens.spacing.lg)
	root.AutomaticSize = Enum.AutomaticSize.X
	root.BackgroundTransparency = 1
	root.Visible = false
	root.ZIndex = Tokens.zIndex.hud
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, Tokens.spacing.sm + 2)
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
		_sound = sound,
	}, ToolHotbar)
	-- Every tool that can sit in the hand gets a slot, the lent rod last; a slot shows only while owned.
	for _, toolId in ipairs(ToolSpecs.ALL_TOOL_IDS) do
		table.insert(self._order, toolId)
	end
	for index, toolId in ipairs(self._order) do
		self:_makeSlot(toolId, index, minimumTapTarget)
	end
	self:_refresh()
	return self
end

function ToolHotbar._makeSlot(self: ToolHotbar, toolId: string, index: number, minimumTapTarget: number)
	local z = Tokens.zIndex.hud
	local size = math.max(SLOT, minimumTapTarget)
	local frame = Instance.new("TextButton")
	frame.Name = "Slot_" .. toolId
	frame.LayoutOrder = index
	frame.AutoButtonColor = false
	frame.Text = ""
	frame.Size = UDim2.fromOffset(size, size + Tokens.spacing.lg)
	frame.BackgroundTransparency = 1
	frame.ZIndex = z
	frame.Selectable = true
	frame.Visible = toolId == "hand"
	local scale = Instance.new("UIScale")
	scale.Parent = frame

	-- Lipped square tile: a dark lip, a slate face with the glossy ramp, a thick black keyline.
	local tile = Instance.new("Frame")
	tile.Name = "Tile"
	tile.Size = UDim2.fromOffset(size, size)
	tile.BackgroundColor3 = Tokens.color.panelDeep
	tile.BorderSizePixel = 0
	tile.ZIndex = z
	local tileCorner = Instance.new("UICorner")
	tileCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	tileCorner.Parent = tile
	local outline = Instance.new("UIStroke")
	outline.Name = "Outline"
	outline.Thickness = Tokens.depth.keyline
	outline.Color = Tokens.color.outline
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = tile
	tile.Parent = frame
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, -LIP)
	face.BackgroundColor3 = Tokens.color.surface
	face.BorderSizePixel = 0
	face.ZIndex = z + 1
	local faceCorner = Instance.new("UICorner")
	faceCorner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	faceCorner.Parent = face
	Depth.applySheen(face, Tokens.color.surface)
	Depth.rim(face, Tokens.color.surface)
	face.Parent = tile

	-- Tool art centred in the tile.
	local icon = Skin.icon(face, "tool." .. toolId .. ".normal", size - Tokens.spacing.lg, z + 2)
	if icon then
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
	else
		local glyph = Icons.feather(face, Tokens.icon.lg, { zIndex = z + 2 })
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.5)
	end

	-- Keycap hint in the top-left corner.
	local hint = Icons.keycap(frame, "1", Tokens.icon.md, { zIndex = z + 4 })
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(0, 0)
	hint.Position = UDim2.fromOffset(-Tokens.spacing.xs, -Tokens.spacing.xs)
	local hintText = hint:FindFirstChild("Glyph") :: TextLabel?

	-- Name pill hanging under the tile: a small dark pill with white stroked lettering.
	local name = FrameKit.pill(frame, "Name", if toolId == "hand" then "Hand" else self._config.tools[toolId].displayName, {
		size = UDim2.new(1, Tokens.spacing.sm, 0, Tokens.typography.caption.size + Tokens.spacing.md),
		textSize = Tokens.typography.caption.size,
		zIndex = z + 3,
		outline = true,
	})
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.fromScale(0.5, 1)
	name.TextColor3 = Tokens.color.featherWhite
	local namePadding = name:FindFirstChildOfClass("UIPadding")
	if namePadding then
		namePadding.PaddingLeft = UDim.new(0, Tokens.spacing.sm)
		namePadding.PaddingRight = UDim.new(0, Tokens.spacing.sm)
	end

	-- Status caption on a dark band above the bar, so it never fights the tool art.
	local band = Instance.new("Frame")
	band.Name = "StatusBand"
	band.AnchorPoint = Vector2.new(0.5, 1)
	band.Position = UDim2.new(0.5, 0, 1, -(LIP + Tokens.spacing.sm + 6))
	band.Size = UDim2.new(1, -Tokens.spacing.sm, 0, Tokens.typography.caption.size + 4)
	band.BackgroundColor3 = Tokens.color.panelDeep
	band.BackgroundTransparency = 0.08
	band.BorderSizePixel = 0
	band.ZIndex = z + 3
	band.Visible = false
	local bandCorner = Instance.new("UICorner")
	bandCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
	bandCorner.Parent = band
	local bandStroke = Instance.new("UIStroke")
	bandStroke.Thickness = 1.5
	bandStroke.Color = Tokens.color.outline
	bandStroke.Parent = band
	band.Parent = tile
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.fromScale(1, 1)
	status.BackgroundTransparency = 1
	status.Font = Tokens.typography.heading.font
	status.TextSize = Tokens.typography.caption.size - 2
	status.TextScaled = true
	status.TextWrapped = false
	local statusSize = Instance.new("UITextSizeConstraint")
	statusSize.MaxTextSize = Tokens.typography.caption.size - 2
	statusSize.MinTextSize = 7
	statusSize.Parent = status
	status.TextColor3 = Tokens.color.featherWhite
	status.Text = ""
	status.ZIndex = z + 4
	FrameKit.outline(status, 2)
	status.Parent = band
	status:GetPropertyChangedSignal("Text"):Connect(function()
		band.Visible = status.Text ~= ""
	end)
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -(LIP + Tokens.spacing.xs + 1))
	bar.Size = UDim2.new(1, -Tokens.spacing.md, 0, 6)
	bar.BackgroundColor3 = Tokens.color.panelDeep
	bar.BorderSizePixel = 0
	bar.ZIndex = z + 3
	bar.Visible = false
	bar.ClipsDescendants = true
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = bar
	local barStroke = Instance.new("UIStroke")
	barStroke.Thickness = 1.5
	barStroke.Color = Tokens.color.outline
	barStroke.Parent = bar
	bar.Parent = tile
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Tokens.color.gold
	fill.BorderSizePixel = 0
	fill.ZIndex = z + 4
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill
	fill.Parent = bar

	frame.MouseEnter:Connect(function()
		Tween.scale(scale, "hover", self._motion())
		if self._sound then
			self._sound(Tokens.sound.uiHover)
		end
	end)
	frame.MouseLeave:Connect(function()
		Tween.scale(scale, "release", self._motion(), 1)
		face.Position = UDim2.fromOffset(0, 0)
	end)
	frame.MouseButton1Down:Connect(function()
		face.Position = UDim2.fromOffset(0, LIP)
	end)
	frame.MouseButton1Up:Connect(function()
		face.Position = UDim2.fromOffset(0, 0)
	end)
	frame.SelectionGained:Connect(function()
		outline.Color = Tokens.color.goldLight
		outline.Thickness = Tokens.stroke.frame
	end)
	frame.SelectionLost:Connect(function()
		local equipped = toolId == self._equipped
		outline.Color = if equipped then Tokens.color.gold else Tokens.color.outline
		outline.Thickness = if equipped then Tokens.stroke.frame else Tokens.depth.keyline
	end)
	frame.Activated:Connect(function()
		if self._sound then
			self._sound(Tokens.sound.uiTap)
		end
		self.activated:Fire(toolId)
	end)
	frame.Parent = self.root
	self._slots[toolId] = {
		frame = frame,
		face = face,
		name = name,
		hint = hint,
		hintText = hintText,
		status = status,
		bar = bar,
		fill = fill,
		scale = scale,
		outline = outline,
		index = index,
	}
end

function ToolHotbar._refresh(self: ToolHotbar)
	local visibleIndex = 0
	for _, toolId in ipairs(self._order) do
		local slot = self._slots[toolId]
		local owned = self._owned[toolId] == true
		slot.frame.Visible = owned
		if owned then
			visibleIndex += 1
			local hintText = ""
			if self._mode == "gamepad" then
				hintText = if toolId == self._equipped then "LB/RB" else ""
			elseif self._mode == "mouse" then
				hintText = tostring(visibleIndex)
			end
			if slot.hintText then
				slot.hintText.Text = hintText
			end
			slot.hint.Visible = hintText ~= ""
		end
		-- The equipped slot: a lighter slate face inside a gold keyline; every other slot sits behind
		-- the same thick black line. The name pill's border follows the tile.
		local equipped = toolId == self._equipped
		local faceColor = if equipped then Depth.shade(Tokens.color.surface, 0.14) else Tokens.color.surface
		slot.face.BackgroundColor3 = faceColor
		Depth.applySheen(slot.face, faceColor)
		slot.outline.Color = if equipped then Tokens.color.gold else Tokens.color.outline
		slot.outline.Thickness = if equipped then Tokens.stroke.frame else Tokens.depth.keyline
		local nameBorder = slot.name:FindFirstChildOfClass("UIStroke")
		if nameBorder then
			nameBorder.Color = if equipped then Tokens.color.gold else Tokens.color.outline
		end
	end
end

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
		slot.scale.Scale = 1 + Motion.amplitude(0.1, self._motion())
		TweenService:Create(slot.scale, TweenInfo.new(Motion.duration("quick", self._motion()), Tokens.motion.easeBack), { Scale = 1 })
			:Play()
	end
end

function ToolHotbar.setMode(self: ToolHotbar, mode: string)
	self._mode = mode
	self:_refresh()
end

function ToolHotbar.setStatus(self: ToolHotbar, toolId: string, fraction: number?, text: string?, tone: string?)
	local slot = self._slots[toolId]
	if not slot then
		return
	end
	slot.status.Text = text or ""
	local colors =
		{ info = Tokens.color.gold, warning = Tokens.color.warning, danger = Tokens.color.danger, success = Tokens.color.success }
	slot.fill.BackgroundColor3 = colors[tone or "info"] or Tokens.color.gold
	local target = UDim2.fromScale(math.clamp(fraction or 0, 0, 1), 1)
	TweenService:Create(slot.fill, TweenInfo.new(Motion.duration("instant", self._motion())), { Size = target }):Play()
	slot.bar.Visible = fraction ~= nil
end

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
