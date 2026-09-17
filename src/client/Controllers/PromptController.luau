--!strict
-- Custom proximity prompts: the stock Roblox prompt is replaced by a dark slate pill in the UI
-- language (a green key square for the current input mode, object line, action line, hold fill for
-- hold prompts) that fades in on approach and away on leave. Drawn as a world billboard sized in
-- studs, depth-tested against the world and culled past Tokens.world.promptMaxDistance. Names and behaviour of the server
-- prompts are untouched; InteractionController keeps dispatching on them.

local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local Trove = require(Shared.Util.Trove)
local Depth = require(script.Parent.Parent.UI.Components.Depth)
local Fit = require(script.Parent.Parent.UI.Components.Fit)

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
	-- A world billboard: studs-sized so it shrinks with distance, depth-tested so the pile, the crates
	-- and the stalls hide it, and never drawn past Tokens.world.promptMaxDistance (or its own reach).
	local world = Tokens.world
	local lift = math.max(2.2, adornee.Size.Y * 0.5 + 0.9) + prompt.UIOffset.Y / 40
	local gui = Instance.new("BillboardGui")
	gui.Name = "SFE_Prompt_" .. prompt.Name
	gui.Adornee = adornee
	gui.Size = UDim2.fromScale(world.promptStuds.X, world.promptStuds.Y)
	gui.StudsOffsetWorldSpace = Vector3.new(0, lift, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = math.max(world.promptMaxDistance, prompt.MaxActivationDistance + 4)
	gui.ResetOnSpawn = false
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = Tokens.color.panelDeep
	card.BackgroundTransparency = 1
	card.ZIndex = 2
	Fit.corner(card, 0.5)
	local stroke = Depth.keyline(card, Tokens.depth.keylineThin)
	stroke.Transparency = 1
	local scale = Instance.new("UIScale")
	scale.Scale = 0.85
	scale.Parent = card
	local art: ImageLabel? = nil
	local promptFace = Instance.new("Frame")
	promptFace.Name = "Face"
	promptFace.Size = UDim2.fromScale(1, 0.92)
	promptFace.BackgroundColor3 = Tokens.color.surface
	promptFace.BackgroundTransparency = 1
	promptFace.BorderSizePixel = 0
	promptFace.ZIndex = 3
	Fit.corner(promptFace, 0.5)
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
	Fit.corner(fill, 0.5)
	fill.Parent = card
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = 5
	content.Parent = card
	-- The key square is the one colour on the pill: green, the "go" colour. Wider for "Tap" / "LMB".
	local cap = Instance.new("Frame")
	cap.Name = "Key"
	cap.AnchorPoint = Vector2.new(0, 0.5)
	cap.Position = UDim2.fromScale(0.06, 0.5)
	cap.Size = UDim2.fromScale(0, 0.64)
	cap.BackgroundColor3 = Tokens.color.success
	cap.BorderSizePixel = 0
	cap.ZIndex = 6
	Fit.corner(cap, 0.24)
	Depth.keyline(cap, Tokens.stroke.hairline)
	Depth.applySheen(cap, Tokens.color.success)
	local capAspect = Fit.aspect(cap, 1, Enum.DominantAxis.Height)
	cap.Parent = content
	local glyph = Fit.text(cap, "Glyph", keyFor(self._deps.input:mode(), prompt), {
		font = Tokens.typography.heading.font,
		color = Tokens.color.featherWhite,
		max = 120,
		min = 1,
		zIndex = 7,
		outline = 1.5,
		outlineColor = Tokens.color.outline,
		size = UDim2.fromScale(0.8, 0.74),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		wrap = false,
	})
	local function fitCap()
		capAspect.AspectRatio = if #glyph.Text > 2 then 1.6 elseif #glyph.Text > 1 then 1.3 else 1
	end
	glyph:GetPropertyChangedSignal("Text"):Connect(fitCap)
	fitCap()
	local object = Fit.text(content, "Object", prompt.ObjectText, {
		font = Tokens.typography.caption.font,
		color = Tokens.color.inkMuted,
		max = 120,
		min = 1,
		zIndex = 6,
		outline = 1.5,
		outlineColor = Tokens.color.outline,
		size = UDim2.fromScale(0.58, 0.28),
		position = UDim2.fromScale(0.36, 0.14),
		align = Enum.TextXAlignment.Left,
		wrap = false,
	})
	object.TextTruncate = Enum.TextTruncate.AtEnd
	local action = Fit.text(content, "Action", prompt.ActionText, {
		font = Tokens.typography.label.font,
		color = Tokens.color.featherWhite,
		max = 120,
		min = 1,
		zIndex = 6,
		outline = 2,
		outlineColor = Tokens.color.outline,
		size = UDim2.fromScale(0.58, 0.42),
		position = UDim2.fromScale(0.36, if prompt.ObjectText == "" then 0.29 else 0.42),
		align = Enum.TextXAlignment.Left,
		wrap = false,
	})
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
	for _, label in ipairs({ object, action, glyph }) do
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
