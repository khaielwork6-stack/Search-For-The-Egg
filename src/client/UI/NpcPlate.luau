--!strict
-- Vendor presentation for the lobby NPCs: a floating nameplate (name + role pill) and a speech
-- bubble that pops when the player walks up. Drawn in the UI language (cream, cocoa outline, gold
-- lip) inside BillboardGuis so it reads at a fixed screen size from any distance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Components.Frame)

local NpcPlate = {}

export type Handle = {
	say: (line: string, seconds: number?) -> (),
	hush: () -> (),
	destroy: () -> (),
}

local function billboard(name: string, adornee: BasePart, size: UDim2, offset: Vector3): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Adornee = adornee
	gui.Size = size
	gui.StudsOffsetWorldSpace = offset
	gui.AlwaysOnTop = false
	gui.MaxDistance = 90
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Parent = adornee
	return gui
end

function NpcPlate.build(adornee: BasePart, name: string, role: string, heightStuds: number, options: { onTop: boolean? }?): Handle
	local opts = (options or {}) :: any
	-- Nameplate: outlined name over a small gold role pill.
	local plate = billboard("Nameplate", adornee, UDim2.fromOffset(220, 62), Vector3.new(0, heightStuds, 0))
	plate.AlwaysOnTop = opts.onTop == true
	local nameLabel = FrameKit.text(plate, "Name", name, "title", {
		zIndex = 2,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	nameLabel.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 6)
	nameLabel.TextSize = Tokens.typography.title.size - 2
	FrameKit.outline(nameLabel, 2.4)
	-- Role pill: cocoa plank with white outlined lettering. Gold-on-gold caption text was unreadable
	-- against the sky and the barn.
	local pill = FrameKit.pill(plate, "Role", role, {
		size = UDim2.fromOffset(0, Tokens.typography.label.size + Tokens.spacing.md),
		textSize = Tokens.typography.label.size - 2,
		zIndex = 2,
		fill = Tokens.color.cocoa,
		textColor = Tokens.color.featherWhite,
		fitText = true,
		outline = true,
	})
	pill.Font = Tokens.typography.label.font
	-- A UIGradient on a TextLabel tints the lettering too, so the pill is a flat cocoa plank.
	local pillShade = pill:FindFirstChildOfClass("UIGradient")
	if pillShade then
		pillShade:Destroy()
	end
	pill.BackgroundColor3 = Tokens.color.cocoa
	local roleOutline = pill:FindFirstChild("TextOutline")
	if roleOutline and roleOutline:IsA("UIStroke") then
		roleOutline.Thickness = 2
	end
	pill.AnchorPoint = Vector2.new(0.5, 1)
	pill.Position = UDim2.fromScale(0.5, 1)

	-- Speech bubble: cream card with a cocoa outline; grows in from the vendor's head.
	local bubble = billboard("Speech", adornee, UDim2.fromOffset(260, 74), Vector3.new(0, heightStuds + 1.4, 0))
	bubble.AlwaysOnTop = opts.onTop == true
	bubble.Enabled = false
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.fromScale(0.5, 1)
	card.Size = UDim2.new(1, 0, 1, -8)
	card.BackgroundColor3 = Tokens.color.featherWhite
	card.BorderSizePixel = 0
	card.ZIndex = 3
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.bold
	stroke.Color = Tokens.color.outline
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.md)
	padding.PaddingTop = UDim.new(0, Tokens.spacing.xs)
	padding.PaddingBottom = UDim.new(0, Tokens.spacing.xs)
	padding.Parent = card
	local scale = Instance.new("UIScale")
	scale.Parent = card
	local text = FrameKit.text(card, "Line", "", "body", {
		zIndex = 4,
		color = Tokens.color.inkStrong,
		align = Enum.TextXAlignment.Center,
		wrap = true,
	})
	text.Size = UDim2.fromScale(1, 1)
	text.TextYAlignment = Enum.TextYAlignment.Center
	card.Parent = bubble
	-- Tail: a small rotated square under the card.
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.new(0.5, 0, 1, -8)
	tail.Size = UDim2.fromOffset(14, 14)
	tail.Rotation = 45
	tail.BackgroundColor3 = Tokens.color.featherWhite
	tail.BorderSizePixel = 0
	tail.ZIndex = 2
	local tailStroke = Instance.new("UIStroke")
	tailStroke.Thickness = Tokens.stroke.bold
	tailStroke.Color = Tokens.color.outline
	tailStroke.Parent = tail
	tail.Parent = bubble

	local hushToken = 0
	local function hush()
		hushToken += 1
		TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.6 }):Play()
		task.delay(0.18, function()
			if bubble.Parent then
				bubble.Enabled = false
			end
		end)
	end
	local function say(line: string, seconds: number?)
		hushToken += 1
		local token = hushToken
		text.Text = line
		bubble.Enabled = true
		scale.Scale = 0.6
		TweenService:Create(scale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		if seconds then
			task.delay(seconds, function()
				if hushToken == token then
					hush()
				end
			end)
		end
	end

	return {
		say = say,
		hush = hush,
		destroy = function()
			plate:Destroy()
			bubble:Destroy()
		end,
	}
end

-- Speaks through an existing vendor's bubble (built by NpcPlate.build) from anywhere on the client.
function NpcPlate.sayOn(adornee: Instance?, line: string, seconds: number?)
	local speech = adornee and adornee:FindFirstChild("Speech")
	local card = speech and speech:FindFirstChild("Card")
	local text = card and card:FindFirstChild("Line")
	local scale = card and card:FindFirstChildOfClass("UIScale")
	if not (speech and speech:IsA("BillboardGui") and text and text:IsA("TextLabel") and scale) then
		return false
	end
	text.Text = line
	speech.Enabled = true
	scale.Scale = 0.6
	TweenService:Create(scale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(seconds or 2.6, function()
		if speech.Parent and text.Text == line then
			speech.Enabled = false
		end
	end)
	return true
end

return NpcPlate
