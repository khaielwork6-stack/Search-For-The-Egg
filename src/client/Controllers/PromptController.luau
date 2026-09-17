--!strict
-- Custom proximity prompts: the stock Roblox prompt is replaced by a dark slate pill in the UI
-- language (a green key square for the current input mode, object line, action line, hold fill for
-- hold prompts) that fades in on approach and away on leave. Names and behaviour of the server
-- prompts are untouched; InteractionController keeps dispatching on them.

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Trove = require(Shared.Util.Trove)
local FrameKit = require(script.Parent.Parent.UI.Components.Frame)
local Depth = require(script.Parent.Parent.UI.Components.Depth)
local Icons = require(script.Parent.Parent.UI.Components.Icons)

local PromptController = {}
PromptController.__index = PromptController

export type PromptController = typeof(setmetatable(
	{} :: {
		_deps: any,
		_live: { [ProximityPrompt]: { gui: BillboardGui, fill: Frame, scale: UIScale, holdTween: Tween? } },
		_trove: Trove.Trove,
		stats: { shown: number, hidden: number },
	},
	PromptController
))

local WIDTH = 236
local HEIGHT = 64

local function keyFor(mode: string, prompt: ProximityPrompt): string
	if mode == "touch" then
		return "Tap"
	elseif mode == "gamepad" then
		return (prompt.GamepadKeyCode.Name:gsub("Button", ""))
	end
	return prompt.KeyboardKeyCode.Name
end

function PromptController.new(deps: any): PromptController
	local self = setmetatable({ _deps = deps, _live = {}, _trove = Trove.new(), stats = { shown = 0, hidden = 0 } }, PromptController)
	self._trove:add(ProximityPromptService.PromptShown:Connect(function(prompt)
		if prompt.Style == Enum.ProximityPromptStyle.Custom then
			self:_show(prompt)
		end
	end))
	self._trove:add(ProximityPromptService.PromptHidden:Connect(function(prompt)
		self:_hide(prompt)
	end))
	self._trove:add(ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
		local entry = self._live[prompt]
		if entry and prompt.HoldDuration > 0 then
			entry.fill.Visible = true
			entry.fill.Size = UDim2.fromScale(0, 1)
			entry.holdTween = TweenService:Create(
				entry.fill,
				TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear),
				{ Size = UDim2.fromScale(1, 1) }
			)
			entry.holdTween:Play()
		end
	end))
	self._trove:add(ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt)
		local entry = self._live[prompt]
		if entry then
			if entry.holdTween then
				entry.holdTween:Cancel()
				entry.holdTween = nil
			end
			entry.fill.Size = UDim2.fromScale(0, 1)
		end
	end))
	self._trove:add(deps.input.modeChanged:Connect(function(mode)
		for prompt, entry in pairs(self._live) do
			local cap = entry.gui:FindFirstChild("Glyph", true) :: TextLabel?
			if cap then
				cap.Text = keyFor(mode, prompt)
			end
		end
	end))
	return self
end

function PromptController._show(self: PromptController, prompt: ProximityPrompt)
	if self._live[prompt] then
		return
	end
	local adornee = prompt.Parent
	if not adornee or not adornee:IsA("BasePart") then
		return
	end
	local motion = self._deps.accessibility:motionSettings()
	local gui = Instance.new("BillboardGui")
	gui.Name = "SFE_Prompt_" .. prompt.Name
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	gui.StudsOffsetWorldSpace = Vector3.new(0, prompt.UIOffset.Y / 40 + 2.2, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = prompt.MaxActivationDistance + 8
	gui.ResetOnSpawn = false
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = Tokens.color.panelDeep
	card.BackgroundTransparency = 1
	card.ZIndex = 2
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	corner.Parent = card
	local stroke = Depth.keyline(card)
	stroke.Transparency = 1
	local scale = Instance.new("UIScale")
	scale.Scale = 0.85
	scale.Parent = card
	local art: ImageLabel? = nil
	local promptFace = Instance.new("Frame")
	promptFace.Name = "Face"
	promptFace.Size = UDim2.new(1, 0, 1, -4)
	promptFace.BackgroundColor3 = Tokens.color.surface
	promptFace.BackgroundTransparency = 1
	promptFace.BorderSizePixel = 0
	promptFace.ZIndex = 3
	local promptFaceCorner = Instance.new("UICorner")
	promptFaceCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	promptFaceCorner.Parent = promptFace
	Depth.applySheen(promptFace, Tokens.color.surface)
	promptFace.Parent = card
	local fill = Instance.new("Frame")
	fill.Name = "HoldFill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Tokens.color.success
	fill.BackgroundTransparency = 0.5
	fill.BorderSizePixel = 0
	fill.ZIndex = 4
	fill.Visible = prompt.HoldDuration > 0
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	fillCorner.Parent = fill
	fill.Parent = card
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = 5
	content.Parent = card
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = content
	-- The key square is the one colour on the pill: green, the "go" colour.
	local cap = Icons.keycap(content, keyFor(self._deps.input:mode(), prompt), Tokens.icon.lg, { zIndex = 6, color = Tokens.color.success })
	cap.AnchorPoint = Vector2.new(0, 0.5)
	cap.Position = UDim2.fromScale(0, 0.5)
	local textLeft = Tokens.icon.lg * 1.6 + Tokens.spacing.md
	local object = FrameKit.text(content, "Object", prompt.ObjectText, "caption", { zIndex = 6, color = Tokens.color.inkMuted })
	object.Position = UDim2.fromOffset(textLeft, Tokens.spacing.sm + 2)
	object.Size = UDim2.new(1, -textLeft, 0, Tokens.typography.caption.size + 2)
	object.TextTruncate = Enum.TextTruncate.AtEnd
	FrameKit.outline(object, 2)
	local action = FrameKit.text(content, "Action", prompt.ActionText, "heading", { zIndex = 6, color = Tokens.color.featherWhite })
	action.Font = Tokens.typography.label.font
	FrameKit.outline(action, 2.5)
	action.Position = UDim2.fromOffset(textLeft, Tokens.spacing.sm + Tokens.typography.caption.size + 4)
	action.Size = UDim2.new(1, -textLeft, 0, Tokens.typography.heading.size + 4)
	action.TextTruncate = Enum.TextTruncate.AtEnd
	if prompt.HoldDuration > 0 then
		action.Text = "Hold  -  " .. prompt.ActionText
	end
	card.Parent = gui
	gui.Parent = adornee
	self._live[prompt] = { gui = gui, fill = fill, scale = scale, holdTween = nil }
	self.stats.shown += 1
	local info = TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeOut)
	TweenService:Create(card, info, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(promptFace, info, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(stroke, info, { Transparency = 0 }):Play()
	local _ = art
	TweenService:Create(scale, TweenInfo.new(Motion.duration("standard", motion), Tokens.motion.easeBack), { Scale = 1 }):Play()
	for _, label in ipairs({ object, action, cap:FindFirstChild("Glyph") }) do
		if label and label:IsA("TextLabel") then
			label.TextTransparency = 1
			TweenService:Create(label, info, { TextTransparency = 0 }):Play()
			-- The stroke is its own object: it fades with the lettering it wraps.
			local textOutline = label:FindFirstChild("TextOutline")
			if textOutline and textOutline:IsA("UIStroke") then
				textOutline.Transparency = 1
				TweenService:Create(textOutline, info, { Transparency = 0 }):Play()
			end
		end
	end
	cap.BackgroundTransparency = 1
	TweenService:Create(cap, info, { BackgroundTransparency = 0 }):Play()
end

function PromptController._hide(self: PromptController, prompt: ProximityPrompt)
	local entry = self._live[prompt]
	if not entry then
		return
	end
	self._live[prompt] = nil
	self.stats.hidden += 1
	local motion = self._deps.accessibility:motionSettings()
	local gui = entry.gui
	local info = TweenInfo.new(Motion.duration("quick", motion), Tokens.motion.easeOut)
	TweenService:Create(entry.scale, info, { Scale = 0.85 }):Play()
	for _, d in ipairs(gui:GetDescendants()) do
		if d:IsA("TextLabel") then
			TweenService:Create(d, info, { TextTransparency = 1 }):Play()
		elseif d:IsA("ImageLabel") then
			TweenService:Create(d, info, { ImageTransparency = 1 }):Play()
		elseif d:IsA("Frame") and d.Name ~= "Content" then
			TweenService:Create(d, info, { BackgroundTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
	task.delay(Motion.duration("quick", motion) + 0.05, function()
		gui:Destroy()
	end)
end

function PromptController.liveCount(self: PromptController): number
	local n = 0
	for _ in pairs(self._live) do
		n += 1
	end
	return n
end

function PromptController.destroy(self: PromptController)
	for prompt in pairs(table.clone(self._live)) do
		self:_hide(prompt)
	end
	self._trove:destroy()
end

return PromptController
