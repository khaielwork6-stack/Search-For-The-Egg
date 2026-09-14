--!strict
-- Settings switch row: label on the left, a pill toggle on the right whose knob slides and whose
-- track turns teal when on. The whole row is the tap target (controller selectable), the state is
-- owned by the caller (server-acknowledged) and applied through set().

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local FrameKit = require(script.Parent.Frame)

local Switch = {}

export type Options = {
	label: string,
	detail: string?,
	on: boolean,
	minimumTapTarget: number,
	motion: Motion.MotionSettings,
	onToggle: (on: boolean) -> (),
	zIndex: number?,
	sound: (() -> ())?,
}

export type Handle = { row: TextButton, set: (on: boolean) -> (), setEnabled: (enabled: boolean) -> (), destroy: () -> () }

function Switch.build(parent: Instance, options: Options): Handle
	local z = options.zIndex or 1
	local tap = options.minimumTapTarget
	local row = Instance.new("TextButton")
	row.Name = "Switch_" .. options.label
	row.AutoButtonColor = false
	row.Text = ""
	row.Size = UDim2.new(1, 0, 0, tap + Tokens.spacing.sm)
	row.BackgroundColor3 = Tokens.color.featherWhite
	row.BorderSizePixel = 0
	row.ZIndex = z
	row.Selectable = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.md)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.hairline + 0.5
	stroke.Color = Tokens.color.strawDeep
	stroke.Transparency = 0.45
	stroke.Parent = row
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	padding.Parent = row
	local scale = Instance.new("UIScale")
	scale.Parent = row

	local label = FrameKit.text(row, "Label", options.label, "heading", { zIndex = z + 1, color = Tokens.color.inkStrong })
	label.Size = UDim2.new(1, -(tap * 2), 0, Tokens.typography.heading.size + Tokens.spacing.xs)
	label.Position = UDim2.fromOffset(
		0,
		if options.detail then Tokens.spacing.xs else (tap + Tokens.spacing.sm - Tokens.typography.heading.size - Tokens.spacing.xs) / 2
	)
	if options.detail then
		local detail = FrameKit.text(row, "Detail", options.detail, "caption", { zIndex = z + 1, color = Tokens.color.inkMuted })
		detail.Position = UDim2.fromOffset(0, Tokens.typography.heading.size + Tokens.spacing.sm)
		detail.Size = UDim2.new(1, -(tap * 2), 0, Tokens.typography.caption.size + Tokens.spacing.xs)
	end

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.fromScale(1, 0.5)
	track.Size = UDim2.fromOffset(tap + Tokens.spacing.md, Tokens.icon.md + Tokens.spacing.xs)
	track.BackgroundColor3 = Tokens.color.creamDeep
	track.BorderSizePixel = 0
	track.ZIndex = z + 1
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = track
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Thickness = Tokens.stroke.standard
	trackStroke.Color = Tokens.color.outline
	trackStroke.Parent = track
	track.Parent = row
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.Size = UDim2.fromOffset(Tokens.icon.md - 2, Tokens.icon.md - 2)
	knob.BackgroundColor3 = Tokens.color.featherWhite
	knob.BorderSizePixel = 0
	knob.ZIndex = z + 2
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob
	local knobStroke = Instance.new("UIStroke")
	knobStroke.Thickness = Tokens.stroke.standard
	knobStroke.Color = Tokens.color.outline
	knobStroke.Parent = knob
	knob.Parent = track
	local state =
		FrameKit.text(row, "State", "", "caption", { zIndex = z + 1, color = Tokens.color.inkMuted, align = Enum.TextXAlignment.Right })
	state.AnchorPoint = Vector2.new(1, 0.5)
	state.Position = UDim2.new(1, -(tap + Tokens.spacing.lg + Tokens.spacing.sm), 0.5, 0)
	state.Size = UDim2.fromOffset(tap, Tokens.typography.caption.size + Tokens.spacing.xs)

	local on = options.on
	local enabled = true
	local function apply(animate: boolean)
		local knobX = if on then UDim2.new(1, -(Tokens.icon.md - 2) - 3, 0.5, 0) else UDim2.new(0, 3, 0.5, 0)
		local trackColor = if on then Tokens.color.tealAccent else Tokens.color.creamDeep
		state.Text = if on then "On" else "Off"
		state.TextColor3 = if on then Tokens.color.tealDeep else Tokens.color.inkMuted
		if animate then
			local info = TweenInfo.new(Motion.duration("quick", options.motion), Tokens.motion.easeBack)
			TweenService:Create(knob, info, { Position = knobX }):Play()
			TweenService:Create(track, TweenInfo.new(Motion.duration("quick", options.motion)), { BackgroundColor3 = trackColor }):Play()
			scale.Scale = 1.02
			TweenService:Create(scale, info, { Scale = 1 }):Play()
		else
			knob.Position = knobX
			track.BackgroundColor3 = trackColor
		end
	end
	apply(false)
	local connections = {
		row.Activated:Connect(function()
			if not enabled then
				return
			end
			on = not on
			apply(true)
			if options.sound then
				options.sound()
			end
			options.onToggle(on)
		end),
		row.MouseEnter:Connect(function()
			TweenService:Create(row, TweenInfo.new(Motion.duration("quick", options.motion)), { BackgroundColor3 = Tokens.color.creamPill })
				:Play()
		end),
		row.MouseLeave:Connect(function()
			TweenService
				:Create(row, TweenInfo.new(Motion.duration("quick", options.motion)), { BackgroundColor3 = Tokens.color.featherWhite })
				:Play()
		end),
		row.SelectionGained:Connect(function()
			stroke.Color = Tokens.color.goldLight
			stroke.Thickness = Tokens.stroke.frame
			stroke.Transparency = 0
		end),
		row.SelectionLost:Connect(function()
			stroke.Color = Tokens.color.strawDeep
			stroke.Thickness = Tokens.stroke.hairline + 0.5
			stroke.Transparency = 0.45
		end),
	}
	row.Parent = parent
	return {
		row = row,
		set = function(value: boolean)
			if on ~= value then
				on = value
				apply(true)
			end
		end,
		setEnabled = function(value: boolean)
			enabled = value
			row.Active = value
			label.TextTransparency = if value then 0 else 0.45
		end,
		destroy = function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			row:Destroy()
		end,
	}
end

return Switch
