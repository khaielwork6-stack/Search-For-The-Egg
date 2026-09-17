--!strict
-- Vendor presentation for the lobby NPCs: a floating nameplate (name + role pill) and a speech
-- bubble that pops when the player walks up. Drawn in the UI language (dark slate pills, black
-- keylines, white stroked lettering) inside world billboards (Components/WorldBillboard): sized in
-- studs so they shrink with distance, occluded by world geometry, culled past
-- Tokens.world.npcPlateMaxDistance. About 40% smaller than the old fixed-pixel plates at talking range.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Fit = require(script.Parent.Components.Fit)
local Depth = require(script.Parent.Components.Depth)
local WorldBillboard = require(script.Parent.Components.WorldBillboard)

local NpcPlate = {}

export type Handle = {
	say: (line: string, seconds: number?) -> (),
	hush: () -> (),
	destroy: () -> (),
}

-- `options.onTop` is accepted for older callers and ignored: plates are depth-tested so the pile and
-- the stalls hide them like any other object; they sit above the hat, so the NPC never covers its own.
function NpcPlate.build(adornee: BasePart, name: string, role: string, heightStuds: number, _options: { onTop: boolean? }?): Handle
	local world = Tokens.world
	-- Nameplate: stroked white name over a small dark slate role pill.
	local plate =
		WorldBillboard.create(adornee, "Nameplate", world.npcPlateStuds, Vector3.new(0, heightStuds, 0), world.npcPlateMaxDistance)
	WorldBillboard.text(plate, "Name", name, {
		size = UDim2.fromScale(1, 0.56),
		font = Tokens.typography.title.font,
		outline = 2.5,
	})
	WorldBillboard.pill(plate, "Role", role, {
		size = UDim2.fromScale(1, 0.4),
		position = UDim2.fromScale(0.5, 1),
		anchor = Vector2.new(0.5, 1),
		fill = Tokens.color.surface,
		textColor = Tokens.color.featherWhite,
	})

	-- Speech bubble: a dark slate card with a black keyline; grows in from the vendor's head.
	local bubble = WorldBillboard.create(
		adornee,
		"Speech",
		world.speechStuds,
		Vector3.new(0, heightStuds + world.npcPlateStuds.Y * 0.5 + world.speechStuds.Y * 0.5 + 0.1, 0),
		world.npcPlateMaxDistance
	)
	bubble.Enabled = false
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.fromScale(0.5, 0)
	card.Size = UDim2.fromScale(1, 0.84)
	card.BackgroundColor3 = Tokens.color.surface
	card.BorderSizePixel = 0
	card.ZIndex = 3
	Fit.corner(card, 0.3)
	Depth.keyline(card, Tokens.depth.keylineThin)
	local scale = Instance.new("UIScale")
	scale.Parent = card
	local text = WorldBillboard.text(card, "Line", "", {
		size = UDim2.fromScale(0.9, 0.76),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		font = Tokens.typography.body.font,
		outline = 1.5,
		zIndex = 4,
		wrap = true,
	})
	card.Parent = bubble
	-- Tail: a small rotated square under the card.
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.fromScale(0.5, 0.84)
	tail.Size = UDim2.fromScale(0, 0.2)
	tail.Rotation = 45
	tail.BackgroundColor3 = Tokens.color.surface
	tail.BorderSizePixel = 0
	tail.ZIndex = 2
	Fit.aspect(tail, 1, Enum.DominantAxis.Height)
	Depth.keyline(tail, Tokens.depth.keylineThin)
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
