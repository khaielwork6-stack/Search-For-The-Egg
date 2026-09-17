--!strict
-- Segmented tab strip: a dark recessed track, one blue selected tab that slides between items, hover
-- and press feedback on every tab, controller selectable, wraps on narrow screens. Selection is
-- announced through onSelect; the caller owns what the tab shows.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Depth)
local Motion = require(Shared.Design.Motion)
local Button = require(script.Parent.Button)

local Tabs = {}

export type Item = { id: string, label: string }

export type Options = {
	items: { Item },
	selected: string?,
	minimumTapTarget: number,
	motion: Motion.MotionSettings,
	onSelect: (id: string) -> (),
	zIndex: number?,
	sound: (() -> ())?,
	hoverSound: (() -> ())?,
	width: number?, -- per tab; default from label length
}

export type Handle = {
	frame: Frame,
	buttons: { [string]: Button.Handle },
	select: (id: string, silent: boolean?) -> (),
	setLabel: (id: string, label: string) -> (),
	selected: () -> string?,
	destroy: () -> (),
}

function Tabs.build(parent: Instance, options: Options): Handle
	local z = options.zIndex or 1
	local frame = Instance.new("Frame")
	frame.Name = "Tabs"
	frame.Size = UDim2.new(1, 0, 0, options.minimumTapTarget + Tokens.spacing.sm)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = Tokens.color.panelDeep
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md + 2)
	corner.Parent = frame
	Depth.keyline(frame, Tokens.depth.keylineThin)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, Tokens.spacing.xs)
	padding.PaddingBottom = UDim.new(0, Tokens.spacing.xs)
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.xs)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.xs)
	padding.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.xs)
	layout.Wraps = true
	-- Tabs share the track evenly so the strip never leaves dead space on the right.
	layout.HorizontalFlex = Enum.UIFlexAlignment.Fill
	layout.Parent = frame
	frame.Parent = parent

	local buttons: { [string]: Button.Handle } = {}
	local current: string? = options.selected
	local function apply(animate: boolean)
		for id, handle in pairs(buttons) do
			local on = id == current
			handle.setVariant(if on then "teal" else "ghost")
			handle.button.BackgroundTransparency = 1
			-- Segmented tabs are lipless: every face fills its slot so labels share one baseline.
			local face = handle.button:FindFirstChild("Face") :: Frame?
			if face then
				face.Size = UDim2.fromScale(1, 1)
			end
			local outline = Depth.keylineOf(handle.button) :: UIStroke?
			if outline then
				outline.Transparency = if on then 0 else 1
				outline.Color = Tokens.color.outline
			end
			if on and animate then
				local scale = handle.button:FindFirstChildOfClass("UIScale")
				if scale then
					scale.Scale = 1.06
					TweenService
						:Create(scale, TweenInfo.new(Motion.duration("quick", options.motion), Tokens.motion.easeBack), { Scale = 1 })
						:Play()
				end
			end
		end
	end
	for index, item in ipairs(options.items) do
		local width = options.width or math.max(options.minimumTapTarget * 2, #item.label * 11 + Tokens.spacing.xl + Tokens.spacing.sm)
		local handle = Button.build(frame, {
			text = item.label,
			variant = "ghost",
			minimumTapTarget = options.minimumTapTarget,
			motion = options.motion,
			size = UDim2.fromOffset(width, options.minimumTapTarget),
			zIndex = z + 1,
			textSize = Tokens.typography.body.size,
			sound = options.sound,
			hoverSound = options.hoverSound,
			onActivated = function()
				if current == item.id then
					return
				end
				current = item.id
				apply(true)
				options.onSelect(item.id)
			end,
		})
		handle.button.LayoutOrder = index
		handle.button.Name = "Tab_" .. item.id
		local outline = Depth.keylineOf(handle.button) :: UIStroke?
		if outline then
			outline.Transparency = 1
		end
		buttons[item.id] = handle
	end
	apply(false)
	return {
		frame = frame,
		buttons = buttons,
		select = function(id: string, silent: boolean?)
			current = id
			apply(true)
			if not silent then
				options.onSelect(id)
			end
		end,
		setLabel = function(id: string, label: string)
			local handle = buttons[id]
			if handle then
				handle.setText(label)
			end
		end,
		selected = function()
			return current
		end,
		destroy = function()
			for _, handle in pairs(buttons) do
				handle.destroy()
			end
			frame:Destroy()
		end,
	}
end

return Tabs
