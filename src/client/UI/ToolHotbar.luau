--!strict
-- Tool hotbar: one slot per owned tool (Hand first) with the tool's art, name, a keycap hint by
-- input mode, and a per-slot status bar (Vac heat, Charge cooldown, Chick trip state). Slots use
-- the idle / equipped / disabled art frames, lift on hover, pop when equipped, and stay clear of
-- the reticle. Sits above the round strip inside the safe area; hidden outside rounds.

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
local Tween = require(script.Parent.Components.Tween)

local ToolHotbar = {}
ToolHotbar.__index = ToolHotbar

type Slot = {
	frame: TextButton,
	art: ImageLabel?,
	icon: ImageLabel?,
	name: TextLabel,
	hint: Frame?,
	hintText: TextLabel?,
	status: TextLabel,
	bar: Frame,
	fill: GuiObject,
	fillArt: boolean,
	scale: UIScale,
	index: number,
}

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
		_sound: ((role: string) -> ())?,
	},
	ToolHotbar
))

local SLOT_WIDTH = 96

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
		_sound = sound,
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
	local z = Tokens.zIndex.hud
	local frame = Instance.new("TextButton")
	frame.Name = "Slot_" .. toolId
	frame.LayoutOrder = index
	frame.AutoButtonColor = false
	frame.Text = ""
	frame.Size = UDim2.fromOffset(SLOT_WIDTH, minimumTapTarget + Tokens.spacing.md)
	frame.BackgroundColor3 = Tokens.color.featherWhite
	frame.ZIndex = z
	frame.Selectable = true
	frame.Visible = toolId == "hand"
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Outline"
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.outline
	stroke.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	FrameKit.shadow(frame, { radius = Tokens.radius.md })
	local art = Skin.label(frame, "hotbar.slot.idle", { zIndex = z + 1, inset = 2, name = "ArtFrame" })
	if art then
		stroke.Enabled = false
		frame.BackgroundTransparency = 0.05
	end

	-- Tool art (left) with the name beside it.
	local icon = Skin.icon(frame, "tool." .. toolId .. ".normal", Tokens.icon.lg, z + 2)
	if icon then
		icon.Position = UDim2.fromOffset(Tokens.spacing.xs + 2, Tokens.spacing.xs)
	end
	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.Position = UDim2.fromOffset(if icon then Tokens.icon.lg + Tokens.spacing.sm else Tokens.spacing.sm, Tokens.spacing.xs + 2)
	name.Size = UDim2.new(
		1,
		-(if icon then Tokens.icon.lg + Tokens.spacing.sm else Tokens.spacing.sm) - Tokens.spacing.xs,
		0,
		Tokens.typography.caption.size + 2
	)
	name.BackgroundTransparency = 1
	name.Font = Tokens.typography.heading.font
	name.TextSize = Tokens.typography.caption.size
	name.TextColor3 = Tokens.color.inkStrong
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = if toolId == "hand" then "Hand" else self._config.tools[toolId].displayName
	name.ZIndex = z + 2
	name.Parent = frame

	-- Keycap hint (number key / bumper) in the top-right corner.
	local hint = Icons.keycap(frame, "1", Tokens.icon.md - 2, { zIndex = z + 3 })
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, -Tokens.spacing.xs, 0, -Tokens.spacing.xs)
	local hintText = hint:FindFirstChild("Glyph") :: TextLabel

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, Tokens.spacing.sm, 1, -(Tokens.spacing.xs + 8))
	status.Size = UDim2.new(1, -Tokens.spacing.sm * 2, 0, Tokens.typography.caption.size + 2)
	status.BackgroundTransparency = 1
	status.Font = Tokens.typography.caption.font
	status.TextSize = Tokens.typography.caption.size - 1
	status.TextColor3 = Tokens.color.inkMuted
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text = ""
	status.ZIndex = z + 2
	status.Parent = frame

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, Tokens.spacing.sm, 1, -(Tokens.spacing.xs + 2))
	bar.Size = UDim2.new(1, -Tokens.spacing.sm * 2, 0, 5)
	bar.BackgroundColor3 = Tokens.color.creamDeep
	bar.BorderSizePixel = 0
	bar.ZIndex = z + 2
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	barCorner.Parent = bar
	bar.Parent = frame
	local fill: GuiObject
	local fillArt = false
	if Skin.has("hotbar.status.info") then
		local trackArt = Skin.label(bar, "hotbar.status.track", { zIndex = z + 2 })
		if trackArt then
			bar.BackgroundTransparency = 1
		end
		local image = Instance.new("ImageLabel")
		image.Name = "Fill"
		image.BackgroundTransparency = 1
		image.Size = UDim2.fromScale(0, 1)
		image.ZIndex = z + 3
		Skin.apply(image, "hotbar.status.info")
		image.Parent = bar
		fill = image
		fillArt = true
	else
		local plain = Instance.new("Frame")
		plain.Name = "Fill"
		plain.Size = UDim2.fromScale(0, 1)
		plain.BackgroundColor3 = Tokens.color.straw
		plain.BorderSizePixel = 0
		plain.ZIndex = z + 3
		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
		fillCorner.Parent = plain
		plain.Parent = bar
		fill = plain
	end

	frame.MouseEnter:Connect(function()
		Tween.scale(scale, "hover", self._motion())
		if self._sound then
			self._sound(Tokens.sound.uiHover)
		end
	end)
	frame.MouseLeave:Connect(function()
		Tween.scale(scale, "release", self._motion(), 1)
	end)
	frame.SelectionGained:Connect(function()
		stroke.Enabled = true
		stroke.Color = Tokens.color.goldLight
		stroke.Thickness = Tokens.stroke.frame
	end)
	frame.SelectionLost:Connect(function()
		stroke.Color = Tokens.color.outline
		stroke.Thickness = Tokens.stroke.bold
		stroke.Enabled = art == nil
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
		art = art,
		icon = icon,
		name = name,
		hint = hint,
		hintText = hintText,
		status = status,
		bar = bar,
		fill = fill,
		fillArt = fillArt,
		scale = scale,
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
			if slot.hint and slot.hintText then
				slot.hintText.Text = hintText
				slot.hint.Visible = hintText ~= ""
			end
		end
		local equipped = toolId == self._equipped
		if slot.art then
			Skin.apply(slot.art, if equipped then "hotbar.slot.equipped" else "hotbar.slot.idle")
		else
			local stroke = slot.frame:FindFirstChild("Outline") :: UIStroke
			stroke.Color = if equipped then Tokens.color.gold else Tokens.color.outline
		end
		slot.frame.BackgroundColor3 = if equipped then Tokens.color.creamPill else Tokens.color.featherWhite
		slot.name.TextColor3 = if equipped then Tokens.color.goldDeep else Tokens.color.inkStrong
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
		slot.scale.Scale = 1 + Motion.amplitude(0.08, self._motion())
		TweenService:Create(slot.scale, TweenInfo.new(Motion.duration("quick", self._motion()), Tokens.motion.easeBack), { Scale = 1 })
			:Play()
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
	local toneName = tone or "info"
	if slot.fillArt then
		local role = ({
			info = "hotbar.status.info",
			warning = "hotbar.status.warning",
			danger = "hotbar.status.danger",
			success = "hotbar.status.green",
		})[toneName] or "hotbar.status.info"
		Skin.apply(slot.fill :: ImageLabel, role)
	else
		local colors =
			{ info = Tokens.color.straw, warning = Tokens.color.warning, danger = Tokens.color.danger, success = Tokens.color.success }
		(slot.fill :: Frame).BackgroundColor3 = colors[toneName] or Tokens.color.straw
	end
	local target = UDim2.fromScale(math.clamp(fraction or 0, 0, 1), 1)
	TweenService:Create(slot.fill, TweenInfo.new(Motion.duration("instant", self._motion())), { Size = target }):Play()
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
