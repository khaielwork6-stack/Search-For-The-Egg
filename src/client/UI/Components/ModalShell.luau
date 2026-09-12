--!strict
-- Modal shell: dim overlay, centered card sized for phone/desktop, title, close button, and a
-- content frame. Open/close animate with token motion (scaled for reduced motion).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)

local ModalShell = {}

export type Shell = {
	root: Frame,
	card: Frame,
	content: Frame,
	closeButton: TextButton,
	open: () -> (),
	close: () -> (),
}

function ModalShell.create(
	gui: ScreenGui,
	options: { title: string, blocking: boolean, motion: Motion.MotionSettings, minimumTapTarget: number? }
): Shell
	-- Tap target in pre-scale pixels so the on-screen size stays >= the configured minimum.
	local tap = options.minimumTapTarget or Tokens.layout.minimumTapTargetPx
	local root = Instance.new("Frame")
	root.Name = "Modal_" .. options.title
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Tokens.color.overlay
	root.BackgroundTransparency = 1
	root.ZIndex = if options.blocking then Tokens.zIndex.blocking else Tokens.zIndex.modal
	root.Active = options.blocking

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.9, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Tokens.color.surface
	card.ZIndex = root.ZIndex + 1
	local maxSize = Instance.new("UISizeConstraint")
	maxSize.MaxSize = Vector2.new(520, 720)
	maxSize.Parent = card
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Tokens.radius.lg)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = Tokens.stroke.standard
	stroke.Color = Tokens.color.creamDeep
	stroke.Parent = card
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingBottom = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	padding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	padding.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Tokens.spacing.md)
	layout.Parent = card
	local cardScale = Instance.new("UIScale")
	cardScale.Scale = 0.94
	cardScale.Parent = card

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, tap)
	header.LayoutOrder = 1
	header.ZIndex = card.ZIndex
	header.Parent = card

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -tap, 1, 0)
	title.Font = Tokens.typography.title.font
	title.TextSize = Tokens.typography.title.size
	title.TextColor3 = Tokens.color.inkStrong
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = options.title
	title.ZIndex = card.ZIndex
	title.Parent = header

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(tap, tap)
	closeButton.BackgroundColor3 = Tokens.color.surfaceAlt
	closeButton.Text = "X"
	closeButton.Font = Tokens.typography.heading.font
	closeButton.TextSize = Tokens.typography.heading.size
	closeButton.TextColor3 = Tokens.color.ink
	closeButton.AutoButtonColor = false
	closeButton.ZIndex = card.ZIndex
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, Tokens.radius.pill)
	closeCorner.Parent = closeButton
	closeButton.Parent = header

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.LayoutOrder = 2
	content.ZIndex = card.ZIndex
	local contentLayout = Instance.new("UIListLayout")
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	contentLayout.Parent = content
	content.Parent = card

	card.Parent = root
	root.Parent = gui

	local function tween(object: Instance, token: string, goal: { [string]: any }, easing: Enum.EasingStyle?)
		local info = TweenInfo.new(Motion.duration(token, options.motion), easing or Tokens.motion.easeOut, Enum.EasingDirection.Out)
		local t = TweenService:Create(object, info, goal)
		t:Play()
		return t
	end

	local shell: Shell = {
		root = root,
		card = card,
		content = content,
		closeButton = closeButton,
		open = function()
			tween(root, "standard", { BackgroundTransparency = if options.blocking then 0.45 else 0.7 })
			tween(cardScale, "standard", { Scale = 1 }, Tokens.motion.easeBack)
		end,
		close = function()
			local t = tween(root, "quick", { BackgroundTransparency = 1 })
			tween(cardScale, "quick", { Scale = 0.94 })
			t.Completed:Once(function()
				root:Destroy()
			end)
		end,
	}
	return shell
end

return ModalShell
