--!strict
-- Daily Nest, v2 (17 Sep 2026).
--
-- The first screen most players ever see, so it is built as one hero card in Scale rather than a
-- stack of rows: a chocolate frame around cream, the carved sign grown to a banner, a compact streak
-- strip of eight egg markers, eight reward cards in a 4x2 grid with the painted gem art as the
-- biggest thing on each, one big green CLAIM under a one-line rule. Nothing is placed in pixels.
--
-- The card that can be claimed is the one that moves: it glows, breathes, its rays turn, its gems
-- float and sparkle. Locked days keep their reward visible and step back; the finale keeps a gold
-- frame and a JACKPOT badge whatever state it is in, so the run always has somewhere to arrive.
--
-- Nothing here decides anything. The server owns the streak, the cooldown and the grant; this reads
-- `projection.rewards.daily`, and the gems only fly to the pouch after the server has acknowledged
-- the claim, so a replayed claim never pays twice on screen either.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local DailyRewards = require(Shared.Domain.DailyRewards)
local Depth = require(script.Parent.Parent.Components.Depth)
local Tween = require(script.Parent.Parent.Components.Tween)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
local Skin = require(script.Parent.Parent.Components.Skin)
local Fit = require(script.Parent.Parent.Components.Fit)
local Confetti = require(script.Parent.Parent.Components.Confetti)
local SafeArea = require(script.Parent.Parent.SafeArea)

local DailyModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
	quality: any?,
	hud: any?,
	modals: any?,
}

-- Palette for this screen: the tokens' cocoa and gold, plus two darker browns for the frame.
local CHOCOLATE = Color3.fromRGB(78, 46, 24)
local CHOCOLATE_DEEP = Color3.fromRGB(52, 30, 16)
local CHOCOLATE_LIGHT = Color3.fromRGB(122, 78, 42)
local CREAM_LIVE = Color3.fromRGB(255, 249, 226)
local CREAM_DONE = Color3.fromRGB(240, 246, 226)
local CREAM_LOCKED = Color3.fromRGB(246, 238, 222)
local LOCKED_TINT = Color3.fromRGB(214, 204, 192)

local FLIGHT_SECONDS = 0.55
local FLIGHT_STAGGER = 0.06

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end

-- "1d 4h" / "4h 12m" / "12m": the coarse countdown a locked card carries.
local function unlockText(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local days = math.floor(s / 86400)
	local hours = math.floor(s % 86400 / 3600)
	local minutes = math.floor(s % 3600 / 60)
	if days > 0 then
		return string.format("%dd %dh", days, hours)
	elseif hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	return string.format("%dm", math.max(1, minutes))
end

local function withCommas(n: number): string
	local text = tostring(math.floor(n))
	return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

-- Which painted piece stands for a day's reward. Sized off the ladder, not the literal count: one
-- stone for the token day, a three-gem cluster for an ordinary day, a spilling bag for the big
-- mid-week day, and the overflowing chest for the finale.
local function artRoleFor(gems: number, biggest: number, grand: boolean): string
	if grand then
		return "bundle.gems1500"
	end
	local share = if biggest > 0 then gems / biggest else 0
	if share >= 0.2 then
		return "bundle.gems100"
	elseif share >= 0.06 then
		return "perk.gemValue"
	end
	return "hud.gem"
end

type Cell = {
	day: number,
	root: Frame,
	scale: UIScale,
	glow: Frame,
	body: Frame,
	bodyStroke: UIStroke,
	face: Frame,
	rays: ImageLabel?,
	tag: Frame,
	tagLabel: TextLabel,
	amount: TextLabel,
	art: GuiObject,
	artHome: UDim2,
	artScale: UIScale,
	footer: Frame,
	footerLabel: TextLabel,
	footerIcon: Frame?,
	lock: Frame,
	check: Frame,
	badge: Frame?,
	hit: TextButton,
	flash: Frame,
	sparkles: { Frame },
	live: boolean,
	claimable: boolean,
	stopPulse: (() -> ())?,
	raysTween: Tween?,
	floatTween: Tween?,
	glowTween: Tween?,
}

type Flight = { image: ImageLabel, start: number, from: Vector2, control: Vector2, landed: boolean }

type Marker = {
	root: Frame,
	face: Frame,
	egg: Frame,
	check: Frame,
	lock: Frame,
	crown: Frame?,
	stroke: UIStroke,
}

function DailyModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local rewards = cfg.dailyRewards
	local finalDay = #rewards
	local cooldown = cfg.dailyRewardRules.claimCooldownSeconds
	local shell = api.shell
	local phone = SafeArea.classOf(container) == "phone"
	local alive = true
	local receivedAt = os.clock()
	local biggest = 0
	for _, entry in ipairs(rewards) do
		biggest = math.max(biggest, entry.gems or 0)
	end

	local function play(role: string)
		deps.audio:play(role)
	end
	local function seconds(value: number): number
		return Motion.clampSeconds(value, motion)
	end
	local function amp(value: number): number
		return Motion.amplitude(value, motion)
	end

	-- The content frame is the one root: no scrolling, every child in Scale.
	container.AutomaticCanvasSize = Enum.AutomaticSize.None
	container.CanvasSize = UDim2.fromScale(0, 0)
	container.ScrollingEnabled = false
	container.ScrollBarThickness = 0
	container.Position = UDim2.fromScale(0.02, 0.035)
	container.Size = UDim2.fromScale(0.96, 0.945)
	local listLayout = container:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		listLayout:Destroy()
	end
	local listPadding = container:FindFirstChildOfClass("UIPadding")
	if listPadding then
		listPadding:Destroy()
	end

	-- Frame: the shell's wood becomes a chocolate frame with a proper drop shadow; the parchment
	-- keeps its gold rim and gets a slightly richer cream.
	if shell then
		local board = shell.card:FindFirstChild("Board")
		if board and board:IsA("Frame") then
			board.BackgroundColor3 = CHOCOLATE
			local boardSheen = board:FindFirstChildOfClass("UIGradient")
			if boardSheen then
				boardSheen.Color = Depth.sheen(CHOCOLATE, CHOCOLATE_LIGHT)
			end
			local rail = board:FindFirstChild("Rail")
			if rail and rail:IsA("Frame") then
				rail.BackgroundColor3 = CHOCOLATE_LIGHT
				rail.BackgroundTransparency = 0.7
			end
			local foot = board:FindFirstChild("Shadow")
			if foot and foot:IsA("Frame") then
				foot.BackgroundColor3 = CHOCOLATE_DEEP
			end
			local rim = Depth.keylineOf(board)
			if rim then
				rim.Color = CHOCOLATE_DEEP
				rim.Thickness = 3
			end
		end
		local drop = Instance.new("Frame")
		drop.Name = "DropShadow"
		drop.AnchorPoint = Vector2.new(0.5, 0.5)
		drop.Position = UDim2.fromScale(0.5, 0.5 + 0.022)
		drop.Size = UDim2.fromScale(1, 1)
		drop.BackgroundColor3 = Color3.fromRGB(30, 18, 8)
		drop.BackgroundTransparency = 0.55
		drop.BorderSizePixel = 0
		drop.ZIndex = 0
		local dropCorner = Instance.new("UICorner")
		dropCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
		dropCorner.Parent = drop
		drop.Parent = shell.card
		local panel = shell.panel
		panel.BackgroundColor3 = Tokens.color.cream
		local panelSheen = panel:FindFirstChildOfClass("UIGradient")
		if panelSheen then
			panelSheen.Color = Depth.sheen(Tokens.color.cream, Tokens.color.featherWhite)
		end
		local panelLine = Depth.keylineOf(panel)
		if panelLine then
			panelLine.Color = Tokens.color.gold
			panelLine.Thickness = 3
		end
		-- Banner: the carved sign grows and sits over the parchment's top edge, with the nest glyph
		-- big on the left and the right leaf kept as the accent.
		shell.plaque.Size = UDim2.fromScale(if phone then 0.5 else 0.46, if phone then 1.16 else 1.3)
		shell.plaque.Position = UDim2.fromScale(0.5, 0.64)
		local titleConstraint = shell.titleLabel:FindFirstChildOfClass("UITextSizeConstraint")
		if titleConstraint then
			titleConstraint.MaxTextSize = 60
		end
		shell.titleLabel.Size = UDim2.fromScale(0.62, 0.64)
		shell.titleLabel.Position = UDim2.fromScale(0.55, 0.5)
		local glyph = shell.plaque:FindFirstChild("Glyph")
		if glyph and glyph:IsA("ImageLabel") then
			glyph.Size = UDim2.fromScale(0.19, 1.0)
			glyph.Position = UDim2.fromScale(0.11, 0.5)
		end
		local leafLeft = shell.plaque:FindFirstChild("LeafLeft")
		if leafLeft and leafLeft:IsA("GuiObject") then
			leafLeft.Visible = false
		end
		local leafRight = shell.plaque:FindFirstChild("LeafRight")
		if leafRight and leafRight:IsA("GuiObject") then
			leafRight.Size = UDim2.fromScale(0.11, 0.66)
			leafRight.Position = UDim2.fromScale(0.925, 0.5)
		end
		local feather = Fit.image(shell.plaque, "icon.feather", {
			size = UDim2.fromScale(0.09, 0.6),
			position = UDim2.fromScale(0.955, 0.36),
			zIndex = 5,
			name = "FeatherAccent",
		})
		if feather then
			feather.Rotation = 18
		end
		-- Close knob: bigger, and it compresses under the press.
		shell.headerRight.Size = UDim2.fromScale(0.36, 0.84)
		local closeScale = shell.closeButton:FindFirstChildOfClass("UIScale")
		if closeScale then
			table.insert(
				cleanups,
				shell.closeButton.MouseButton1Down:Connect(function()
					TweenService:Create(closeScale, TweenInfo.new(seconds(0.08)), { Scale = 1 - amp(0.1) }):Play()
				end)
			)
			table.insert(
				cleanups,
				shell.closeButton.MouseButton1Up:Connect(function()
					TweenService:Create(closeScale, TweenInfo.new(seconds(0.18), Enum.EasingStyle.Back), { Scale = 1 }):Play()
				end)
			)
		end
	end

	-- Streak strip -------------------------------------------------------------------------------
	local strip = Fit.frame(container, "Streak", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.1), z)
	local message = Fit.text(strip, "Message", "", {
		font = Tokens.typography.display.font,
		color = Tokens.color.inkStrong,
		max = 38,
		min = 12,
		align = Enum.TextXAlignment.Left,
		zIndex = z + 1,
		size = UDim2.fromScale(0.44, 0.9),
		position = UDim2.fromScale(0.005, 0.5),
		anchor = Vector2.new(0, 0.5),
	})
	local subline = Fit.text(strip, "Subline", "", {
		font = Tokens.typography.body.font,
		color = Tokens.color.inkMuted,
		max = 16,
		min = 9,
		align = Enum.TextXAlignment.Left,
		zIndex = z + 1,
		size = UDim2.fromScale(0.44, 0.3),
		position = UDim2.fromScale(0.005, 1),
		anchor = Vector2.new(0, 1),
	})
	subline.Visible = false
	local markersHolder = Fit.frame(strip, "Markers", UDim2.fromScale(1, 0.5), UDim2.fromScale(0.54, 0.86), z + 1, Vector2.new(1, 0.5))
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0.5, 0.5)
	track.Size = UDim2.fromScale(0.94, 0.12)
	track.BackgroundColor3 = Tokens.color.creamDeep
	track.BorderSizePixel = 0
	track.ZIndex = z + 1
	Fit.corner(track, 0.5)
	Depth.keyline(track, 1.5, Tokens.color.strawDeep).Transparency = 0.5
	track.Parent = markersHolder
	local markersRow = Fit.frame(markersHolder, "Row", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), z + 2)
	Fit.row(markersRow, { gap = 0.014, halign = Enum.HorizontalAlignment.Center })
	local markers: { Marker } = {}
	for day = 1, finalDay do
		local root = Instance.new("Frame")
		root.Name = "Marker" .. day
		root.LayoutOrder = day
		root.Size = UDim2.fromScale(0, 0.92)
		root.BackgroundColor3 = CHOCOLATE
		root.BorderSizePixel = 0
		root.ZIndex = z + 2
		Fit.aspect(root, 1, Enum.DominantAxis.Height)
		Fit.corner(root, 0.5)
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.AnchorPoint = Vector2.new(0.5, 0.5)
		face.Position = UDim2.fromScale(0.5, 0.5)
		face.Size = UDim2.fromScale(0.8, 0.8)
		face.BackgroundColor3 = Tokens.color.creamDeep
		face.BorderSizePixel = 0
		face.ZIndex = z + 3
		Fit.corner(face, 0.5)
		face.Parent = root
		local stroke = Depth.keyline(root, 2, CHOCOLATE_DEEP)
		local egg = Icons.egg(face, 20, { zIndex = z + 4, color = Tokens.color.goldLight })
		egg.AnchorPoint = Vector2.new(0.5, 0.5)
		egg.Position = UDim2.fromScale(0.5, 0.5)
		egg.Size = UDim2.fromScale(0.8, 0.8)
		local check = Icons.check(face, 20, { zIndex = z + 4, color = Tokens.color.featherWhite })
		check.AnchorPoint = Vector2.new(0.5, 0.5)
		check.Position = UDim2.fromScale(0.5, 0.5)
		check.Size = UDim2.fromScale(0.78, 0.78)
		local lock = Icons.lock(face, 20, { zIndex = z + 4, color = Tokens.color.cocoa })
		lock.AnchorPoint = Vector2.new(0.5, 0.5)
		lock.Position = UDim2.fromScale(0.5, 0.52)
		lock.Size = UDim2.fromScale(0.62, 0.62)
		local crown: Frame? = nil
		if day == finalDay then
			crown = Icons.star(root, 16, { zIndex = z + 5, color = Tokens.color.gold })
			local star = crown :: Frame
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Position = UDim2.fromScale(0.82, 0.08)
			star.Size = UDim2.fromScale(0.62, 0.62)
		end
		root.Parent = markersRow
		table.insert(markers, { root = root, face = face, egg = egg, check = check, lock = lock, crown = crown, stroke = stroke })
	end

	-- Reward grid --------------------------------------------------------------------------------
	local grid = Fit.frame(container, "Calendar", UDim2.fromScale(0, 0.115), UDim2.fromScale(1, 0.625), z)
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.2365, 0.47)
	layout.CellPadding = UDim2.fromScale(0.018, 0.06)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = grid

	local function buildCell(entry: any): Cell
		local grand = entry.day == finalDay
		local root = Instance.new("Frame")
		root.Name = "Day" .. entry.day
		root.LayoutOrder = entry.day
		root.BackgroundTransparency = 1
		root.BorderSizePixel = 0
		root.ZIndex = z + 1
		local scale = Instance.new("UIScale")
		scale.Parent = root

		-- Glow behind the claimable card; a shadow under every card; the dark body is the border.
		local glow = Instance.new("Frame")
		glow.Name = "Glow"
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.fromScale(0.5, 0.5)
		glow.Size = UDim2.fromScale(1.1, 1.12)
		glow.BackgroundColor3 = Tokens.color.gold
		glow.BackgroundTransparency = 1
		glow.BorderSizePixel = 0
		glow.ZIndex = z + 1
		Fit.corner(glow, 0.16)
		glow.Parent = root
		local shadow = Instance.new("Frame")
		shadow.Name = "DropShadow"
		shadow.AnchorPoint = Vector2.new(0.5, 0.5)
		shadow.Position = UDim2.fromScale(0.5, 0.5 + 0.045)
		shadow.Size = UDim2.fromScale(1, 1)
		shadow.BackgroundColor3 = Color3.fromRGB(40, 24, 10)
		shadow.BackgroundTransparency = 0.6
		shadow.BorderSizePixel = 0
		shadow.ZIndex = z + 2
		Fit.corner(shadow, 0.14)
		shadow.Parent = root
		local body = Instance.new("Frame")
		body.Name = "Body"
		body.Size = UDim2.fromScale(1, 1)
		body.BackgroundColor3 = CHOCOLATE
		body.BorderSizePixel = 0
		body.ZIndex = z + 3
		Fit.corner(body, 0.14)
		local bodyStroke = Depth.keyline(body, 2, CHOCOLATE_DEEP)
		local bodyGradient = Instance.new("UIGradient")
		bodyGradient.Rotation = 90
		bodyGradient.Color = ColorSequence.new(CHOCOLATE_LIGHT, CHOCOLATE)
		bodyGradient.Parent = body
		body.Parent = root
		local face = Instance.new("Frame")
		face.Name = "Face"
		face.AnchorPoint = Vector2.new(0.5, 0.5)
		face.Position = UDim2.fromScale(0.5, 0.485)
		face.Size = UDim2.fromScale(0.9, 0.87)
		face.BackgroundColor3 = CREAM_LOCKED
		face.BorderSizePixel = 0
		face.ZIndex = z + 4
		face.ClipsDescendants = true
		Fit.corner(face, 0.12)
		Depth.applySheen(face, CREAM_LOCKED, Tokens.color.featherWhite)
		local faceRim = Depth.rim(face, CREAM_LOCKED, Tokens.color.goldLight)
		faceRim.Transparency = 0.45
		face.Parent = body

		-- Rays behind the reward, clipped by the face: they turn on the claimable card and the finale.
		local rays = Skin.texture(face, "texture.sunburst", {
			zIndex = z + 5,
			transparency = 0.45,
			color = Tokens.color.goldLight,
			name = "Rays",
		})
		if rays then
			-- Never rotated: a rotated child escapes ClipsDescendants and the burst would spill
			-- over the parchment. It breathes in transparency instead.
			rays.AnchorPoint = Vector2.new(0.5, 0.5)
			rays.Position = UDim2.fromScale(0.5, 0.58)
			rays.Size = UDim2.fromScale(1.2, 1.2)
			rays.ScaleType = Enum.ScaleType.Fit
			rays.Visible = false
		end

		-- Day tag: a pill at the top of the face carrying the day and its state colour.
		local tag = Instance.new("Frame")
		tag.Name = "Tag"
		tag.AnchorPoint = Vector2.new(0.5, 0)
		tag.Position = UDim2.fromScale(0.5, 0.04)
		tag.Size = UDim2.fromScale(0.82, 0.155)
		tag.BackgroundColor3 = Tokens.color.strawDeep
		tag.BorderSizePixel = 0
		tag.ZIndex = z + 6
		Fit.corner(tag, 0.5)
		Depth.keyline(tag, 2, CHOCOLATE_DEEP)
		Depth.applySheen(tag, Tokens.color.strawDeep)
		tag.Parent = face
		local tagLabel = Fit.text(tag, "Title", "DAY " .. entry.day, {
			font = Tokens.typography.label.font,
			color = Tokens.color.featherWhite,
			max = 24,
			min = 8,
			outline = 1.6,
			outlineColor = CHOCOLATE_DEEP,
			zIndex = z + 7,
			size = UDim2.fromScale(0.7, 0.86),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		-- State glyphs live inside the tag, at its right end.
		local lock = Icons.lock(tag, 16, { zIndex = z + 8, color = Tokens.color.featherWhite })
		lock.AnchorPoint = Vector2.new(1, 0.5)
		lock.Position = UDim2.fromScale(0.95, 0.5)
		lock.Size = UDim2.fromScale(0, 0.78)
		Fit.aspect(lock, 1, Enum.DominantAxis.Height)
		lock.Visible = false
		local check = Icons.check(tag, 16, { zIndex = z + 8, color = Tokens.color.featherWhite })
		check.AnchorPoint = Vector2.new(1, 0.5)
		check.Position = UDim2.fromScale(0.95, 0.5)
		check.Size = UDim2.fromScale(0, 0.8)
		Fit.aspect(check, 1, Enum.DominantAxis.Height)
		check.Visible = false

		-- Amount: the biggest type on the card after the artwork.
		local amount = Fit.text(face, "Amount", "+" .. tostring(entry.gems), {
			font = Tokens.typography.display.font,
			color = Tokens.color.goldDeep,
			max = 44,
			min = 10,
			outline = 1.2,
			outlineColor = Tokens.color.featherWhite,
			zIndex = z + 7,
			size = UDim2.fromScale(0.9, 0.19),
			position = UDim2.fromScale(0.5, 0.205),
			anchor = Vector2.new(0.5, 0),
		})

		-- Artwork: the painted reward, near half the card tall.
		local artBox = Fit.frame(face, "ArtBox", UDim2.fromScale(0.5, 0.375), UDim2.fromScale(0.96, 0.43), z + 6, Vector2.new(0.5, 0))
		local artScale = Instance.new("UIScale")
		artScale.Parent = artBox
		local role = artRoleFor(entry.gems or 0, biggest, grand)
		-- The painted pieces carry transparent margins, so the image overscans its box (the face
		-- clips it) and the visible stone fills the band it was given.
		local overscan = if role == "hud.gem" or role == "perk.gemValue" then 1.34 else 1.16
		local art: GuiObject? = Fit.image(artBox, role, {
			size = UDim2.fromScale(overscan, overscan),
			position = UDim2.fromScale(0.5, 0.5),
			zIndex = z + 7,
			name = "Art",
		})
		if not art then
			-- No painted art on this build: a drawn gem keeps the card complete.
			local drawn = Icons.gem(artBox, 40, { zIndex = z + 7 })
			drawn.AnchorPoint = Vector2.new(0.5, 0.5)
			drawn.Position = UDim2.fromScale(0.5, 0.5)
			drawn.Size = UDim2.fromScale(0.6, 0.9)
			Fit.aspect(drawn, 1, Enum.DominantAxis.Height)
			art = drawn
		end
		local artHome = artBox.Position

		-- Footer: the state, drawn as the affordance (CLAIM / CLAIMED / a countdown).
		local footer = Instance.new("Frame")
		footer.Name = "Footer"
		footer.AnchorPoint = Vector2.new(0.5, 1)
		footer.Position = UDim2.fromScale(0.5, 0.96)
		footer.Size = UDim2.fromScale(0.84, 0.15)
		footer.BackgroundColor3 = Tokens.color.creamDeep
		footer.BorderSizePixel = 0
		footer.ZIndex = z + 6
		Fit.corner(footer, 0.5)
		Depth.keyline(footer, 2, CHOCOLATE_DEEP)
		Depth.applySheen(footer, Tokens.color.creamDeep)
		footer.Parent = face
		local footerIcon = Icons.clock(footer, 14, { zIndex = z + 8, color = Tokens.color.cocoa })
		footerIcon.AnchorPoint = Vector2.new(0, 0.5)
		footerIcon.Position = UDim2.fromScale(0.07, 0.5)
		footerIcon.Size = UDim2.fromScale(0, 0.68)
		Fit.aspect(footerIcon, 1, Enum.DominantAxis.Height)
		local footerLabel = Fit.text(footer, "State", "", {
			font = Tokens.typography.label.font,
			color = Tokens.color.cocoa,
			max = 22,
			min = 8,
			zIndex = z + 7,
			size = UDim2.fromScale(0.74, 0.82),
			position = UDim2.fromScale(0.56, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})

		-- JACKPOT: the finale wears its badge over the amount whatever state it is in.
		local badge: Frame? = nil
		if grand then
			local pill = Instance.new("Frame")
			pill.Name = "Jackpot"
			pill.AnchorPoint = Vector2.new(0.5, 0.5)
			pill.Position = UDim2.fromScale(0.5, 0.275)
			pill.Size = UDim2.fromScale(0.6, 0.12)
			pill.BackgroundColor3 = Tokens.color.ember
			pill.BorderSizePixel = 0
			pill.ZIndex = z + 9
			pill.Rotation = -4
			Fit.corner(pill, 0.5)
			Depth.keyline(pill, 2, CHOCOLATE_DEEP)
			Depth.applySheen(pill, Tokens.color.ember)
			Fit.text(pill, "Label", "JACKPOT", {
				font = Tokens.typography.label.font,
				color = Tokens.color.featherWhite,
				max = 18,
				min = 7,
				outline = 1.4,
				outlineColor = Tokens.color.emberDeep,
				zIndex = z + 10,
				size = UDim2.fromScale(0.86, 0.8),
				position = UDim2.fromScale(0.5, 0.5),
				anchor = Vector2.new(0.5, 0.5),
			})
			local star = Icons.star(pill, 12, { zIndex = z + 11, color = Tokens.color.goldLight })
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Position = UDim2.fromScale(0.04, 0.2)
			star.Size = UDim2.fromScale(0, 0.9)
			Fit.aspect(star, 1, Enum.DominantAxis.Height)
			pill.Parent = face
			badge = pill
			-- The amount drops under the badge on this card.
			amount.Position = UDim2.fromScale(0.5, 0.335)
			amount.Size = UDim2.fromScale(0.9, 0.14)
			artBox.Position = UDim2.fromScale(0.5, 0.465)
			artBox.Size = UDim2.fromScale(0.98, 0.35)
			artHome = artBox.Position
		end

		-- Flash for the claim moment.
		local flash = Instance.new("Frame")
		flash.Name = "Flash"
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = Tokens.color.goldLight
		flash.BackgroundTransparency = 1
		flash.BorderSizePixel = 0
		flash.ZIndex = z + 12
		Fit.corner(flash, 0.12)
		flash.Parent = face

		-- The whole card is the tap target while it can be claimed.
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Size = UDim2.fromScale(1, 1)
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.Active = false
		hit.Selectable = false
		hit.ZIndex = z + 13
		hit.Parent = root

		root.Parent = grid
		return {
			day = entry.day,
			root = root,
			scale = scale,
			glow = glow,
			body = body,
			bodyStroke = bodyStroke,
			face = face,
			rays = rays,
			tag = tag,
			tagLabel = tagLabel,
			amount = amount,
			art = artBox,
			artHome = artHome,
			artScale = artScale,
			footer = footer,
			footerLabel = footerLabel,
			footerIcon = footerIcon,
			lock = lock,
			check = check,
			badge = badge,
			hit = hit,
			flash = flash,
			sparkles = {},
			live = false,
			claimable = false,
			stopPulse = nil,
			raysTween = nil,
			floatTween = nil,
			glowTween = nil,
		}
	end

	local cells: { Cell } = {}
	for _, entry in ipairs(rewards) do
		table.insert(cells, buildCell(entry))
	end

	-- Rule and claim -----------------------------------------------------------------------------
	local rule = Fit.frame(container, "Rule", UDim2.fromScale(0.5, 0.755), UDim2.fromScale(0.86, 0.055), z, Vector2.new(0.5, 0))
	local ruleIcon = Icons.clock(rule, 18, { zIndex = z + 2, color = Tokens.color.cocoa })
	ruleIcon.AnchorPoint = Vector2.new(1, 0.5)
	ruleIcon.Position = UDim2.fromScale(0.5, 0.5)
	ruleIcon.Size = UDim2.fromScale(0, 0.9)
	Fit.aspect(ruleIcon, 1, Enum.DominantAxis.Height)
	local ruleText = Fit.text(rule, "Text", "", {
		font = Tokens.typography.body.font,
		color = Tokens.color.ink,
		max = 18,
		min = 9,
		align = Enum.TextXAlignment.Left,
		zIndex = z + 1,
		size = UDim2.fromScale(0.8, 1),
		position = UDim2.fromScale(0.52, 0.5),
		anchor = Vector2.new(0, 0.5),
	})
	-- The icon hangs just left of wherever the text starts, so the pair reads as one centred line.
	local function fitRule()
		local width = rule.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local textWidth = math.min(ruleText.TextBounds.X, ruleText.AbsoluteSize.X)
		local iconWidth = ruleIcon.AbsoluteSize.X
		local gap = math.max(6, rule.AbsoluteSize.Y * 0.25)
		local total = textWidth + iconWidth + gap
		local left = (width - total) / 2
		ruleIcon.AnchorPoint = Vector2.new(0, 0.5)
		ruleIcon.Position = UDim2.fromScale(left / width, 0.5)
		ruleText.Position = UDim2.fromScale((left + iconWidth + gap) / width, 0.5)
		ruleText.Size = UDim2.fromScale(math.min(0.8, (width - left - iconWidth - gap) / width), 1)
	end
	table.insert(cleanups, ruleText:GetPropertyChangedSignal("TextBounds"):Connect(fitRule))
	table.insert(cleanups, rule:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitRule))

	local claimGlow = Instance.new("Frame")
	claimGlow.Name = "Glow"
	claimGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	claimGlow.Position = UDim2.fromScale(0.5, 0.905)
	claimGlow.Size = UDim2.fromScale(0.6, 0.19)
	claimGlow.BackgroundColor3 = Tokens.color.leafBright
	claimGlow.BackgroundTransparency = 1
	claimGlow.BorderSizePixel = 0
	claimGlow.ZIndex = z
	Fit.corner(claimGlow, 0.5)
	claimGlow.Parent = container
	local claim = Button.build(container, {
		text = "CLAIM",
		variant = "success",
		sound = function()
			play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			play(Tokens.sound.uiHover)
		end,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromScale(if phone then 0.62 else 0.56, 0.165),
		zIndex = z + 2,
	})
	claim.button.Name = "ClaimButton"
	claim.button.AnchorPoint = Vector2.new(0.5, 0.5)
	claim.button.Position = UDim2.fromScale(0.5, 0.905)
	local claimLabel = Fit.buttonText(claim, 36, 8)
	local claimFace = claim.button:FindFirstChild("Face")
	if claimFace and claimFace:IsA("GuiObject") then
		local edge = Instance.new("UIStroke")
		edge.Name = "GoldEdge"
		edge.Thickness = 2
		edge.Color = Tokens.color.goldLight
		edge.Transparency = 0.35
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		edge.Parent = claimFace
		local gem = Fit.image(claimFace, "hud.gem", {
			size = UDim2.fromScale(0.16, 0.74),
			position = UDim2.fromScale(0.11, 0.5),
			zIndex = z + 6,
			name = "GemIcon",
		})
		if gem and claimLabel then
			claimLabel.Position = UDim2.fromScale(0.09, 0)
			claimLabel.Size = UDim2.fromScale(0.86, 1)
		end
	end
	table.insert(cleanups, claim.destroy)
	table.insert(
		cleanups,
		claim.button.MouseEnter:Connect(function()
			if claim.button.Active then
				TweenService:Create(claimGlow, TweenInfo.new(seconds(0.16)), { BackgroundTransparency = 0.72 }):Play()
			end
		end)
	)
	table.insert(
		cleanups,
		claim.button.MouseLeave:Connect(function()
			TweenService:Create(claimGlow, TweenInfo.new(seconds(0.2)), { BackgroundTransparency = 1 }):Play()
		end)
	)
	api.setInitialFocus(claim.button)

	-- Sparkles: a small pool of stars per lively card, cycled by a wait loop (no per-frame work).
	local function sparkleAt(cell: Cell)
		if motion.reducedMotion or not alive or not cell.live then
			return
		end
		local pool = cell.sparkles
		if #pool < 5 then
			local star = Icons.star(cell.face, 14, { zIndex = z + 11, color = Tokens.color.goldLight })
			star.Name = "Sparkle"
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Size = UDim2.fromScale(0, 0.11)
			Fit.aspect(star, 1, Enum.DominantAxis.Height)
			local starScale = Instance.new("UIScale")
			starScale.Scale = 0
			starScale.Parent = star
			star.Visible = false
			table.insert(pool, star)
		end
		local star: Frame? = nil
		for _, candidate in ipairs(pool) do
			if not candidate.Visible then
				star = candidate
				break
			end
		end
		if not star then
			return
		end
		local sparkle = star :: Frame
		local starScale = sparkle:FindFirstChildOfClass("UIScale") :: UIScale
		sparkle.Position = UDim2.fromScale(0.18 + math.random() * 0.64, 0.4 + math.random() * 0.42)
		sparkle.Rotation = math.random() * 40 - 20
		sparkle.Visible = true
		starScale.Scale = 0
		local rise =
			TweenService:Create(starScale, TweenInfo.new(seconds(0.22), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 })
		rise:Play()
		rise.Completed:Once(function()
			local fall =
				TweenService:Create(starScale, TweenInfo.new(seconds(0.3), Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0 })
			fall:Play()
			fall.Completed:Once(function()
				sparkle.Visible = false
			end)
		end)
	end
	task.spawn(function()
		while alive do
			for _, cell in ipairs(cells) do
				if cell.live and math.random() < 0.7 then
					sparkleAt(cell)
				end
			end
			task.wait(0.22 + math.random() * 0.2)
		end
	end)

	-- Card state ----------------------------------------------------------------------------------
	local function setLive(cell: Cell, live: boolean)
		if cell.live == live then
			return
		end
		cell.live = live
		if cell.rays then
			cell.rays.Visible = live
			if cell.raysTween then
				cell.raysTween:Cancel()
				cell.raysTween = nil
			end
			if live and not motion.reducedMotion then
				cell.rays.ImageTransparency = 0.45
				cell.raysTween = TweenService:Create(
					cell.rays,
					TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ ImageTransparency = 0.66 }
				)
				cell.raysTween:Play()
			end
		end
		if cell.floatTween then
			cell.floatTween:Cancel()
			cell.floatTween = nil
			cell.art.Position = cell.artHome
		end
		if live and not motion.reducedMotion then
			cell.art.Position = cell.artHome
			cell.floatTween = TweenService:Create(
				cell.art,
				TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Position = cell.artHome - UDim2.fromScale(0, amp(0.03)) }
			)
			cell.floatTween:Play()
		end
		if not live then
			for _, star in ipairs(cell.sparkles) do
				star.Visible = false
			end
		end
	end

	local function setGlow(cell: Cell, on: boolean)
		if cell.glowTween then
			cell.glowTween:Cancel()
			cell.glowTween = nil
		end
		if on then
			cell.glow.BackgroundTransparency = 0.6
			if not motion.reducedMotion then
				cell.glowTween = TweenService:Create(
					cell.glow,
					TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ BackgroundTransparency = 0.82 }
				)
				cell.glowTween:Play()
			end
		else
			cell.glow.BackgroundTransparency = 1
		end
	end

	local function tintArt(cell: Cell, locked: boolean, done: boolean)
		local art = cell.art:FindFirstChild("Art")
		if art and art:IsA("ImageLabel") then
			art.ImageColor3 = if locked then LOCKED_TINT elseif done then Color3.fromRGB(232, 232, 226) else Color3.new(1, 1, 1)
			art.ImageTransparency = if locked then 0.12 elseif done then 0.3 else 0
		end
	end

	local function evaluation(): any?
		local projection = deps.profile.projection
		return projection and projection.rewards.daily or nil
	end

	-- Seconds until `day` can be claimed, from the server's evaluation (never the local clock alone).
	local function unlockIn(daily: any, day: number): number
		local base = if daily.status == "early" then daily.nextClaimInSeconds - (os.clock() - receivedAt) else 0
		return math.max(0, base) + math.max(0, day - daily.dayIndex) * cooldown
	end

	local animating = false

	local function render()
		local daily = evaluation()
		if not daily then
			return
		end
		if animating then
			-- The projection already changed; the card flips when the gems have landed.
			return
		end
		receivedAt = os.clock()
		local calendar = DailyRewards.calendar(cfg, { dayIndex = daily.dayIndex } :: any)
		local ready = daily.status == "ready" or daily.status == "reset"
		for index, cell in ipairs(cells) do
			local info = calendar[index]
			local grand = index == finalDay
			local claimable = info.current and ready
			cell.claimable = claimable
			cell.amount.Text = "+" .. tostring(info.gems)
			cell.tagLabel.Text = "DAY " .. info.day
			cell.check.Visible = info.claimed
			cell.lock.Visible = not info.claimed and not info.current
			cell.hit.Active = claimable
			cell.hit.Selectable = false
			if cell.footerIcon then
				cell.footerIcon.Visible = false
			end
			cell.footerLabel.Size = UDim2.fromScale(0.86, 0.82)
			cell.footerLabel.Position = UDim2.fromScale(0.5, 0.5)
			if info.claimed then
				cell.face.BackgroundColor3 = CREAM_DONE
				cell.tag.BackgroundColor3 = Tokens.color.leafDeep
				cell.amount.TextColor3 = Tokens.color.leafDeep
				cell.footer.BackgroundColor3 = Tokens.color.leaf
				cell.footerLabel.TextColor3 = Tokens.color.featherWhite
				cell.footerLabel.Text = "CLAIMED"
				cell.body.BackgroundColor3 = CHOCOLATE
				cell.bodyStroke.Color = CHOCOLATE_DEEP
				cell.bodyStroke.Thickness = 2
				setGlow(cell, false)
				setLive(cell, false)
				tintArt(cell, false, true)
			elseif claimable then
				cell.face.BackgroundColor3 = CREAM_LIVE
				cell.tag.BackgroundColor3 = Tokens.color.goldDeep
				cell.amount.TextColor3 = Tokens.color.goldDeep
				cell.footer.BackgroundColor3 = Tokens.color.success
				cell.footerLabel.TextColor3 = Tokens.color.featherWhite
				cell.footerLabel.Text = "CLAIM"
				cell.body.BackgroundColor3 = Tokens.color.goldDeep
				cell.bodyStroke.Color = Tokens.color.gold
				cell.bodyStroke.Thickness = 3
				setGlow(cell, true)
				setLive(cell, true)
				tintArt(cell, false, false)
			elseif info.current then
				-- Today, but the nest has not opened: the footer becomes the countdown.
				cell.face.BackgroundColor3 = CREAM_LIVE
				cell.tag.BackgroundColor3 = Tokens.color.strawDeep
				cell.amount.TextColor3 = Tokens.color.goldDeep
				cell.footer.BackgroundColor3 = Tokens.color.tealPanel
				cell.footerLabel.TextColor3 = Tokens.color.featherWhite
				cell.footerLabel.Text = clock(unlockIn(daily, info.day))
				cell.body.BackgroundColor3 = CHOCOLATE
				cell.bodyStroke.Color = Tokens.color.gold
				cell.bodyStroke.Thickness = 3
				setGlow(cell, false)
				setLive(cell, false)
				tintArt(cell, false, false)
			else
				cell.face.BackgroundColor3 = CREAM_LOCKED
				cell.tag.BackgroundColor3 = Tokens.color.cocoa
				cell.amount.TextColor3 = Tokens.color.cocoa
				cell.footer.BackgroundColor3 = Tokens.color.creamDeep
				cell.footerLabel.TextColor3 = Tokens.color.cocoa
				cell.footerLabel.Text = unlockText(unlockIn(daily, info.day))
				if cell.footerIcon then
					cell.footerIcon.Visible = true
					cell.footerLabel.Size = UDim2.fromScale(0.68, 0.82)
					cell.footerLabel.Position = UDim2.fromScale(0.58, 0.5)
				end
				cell.body.BackgroundColor3 = CHOCOLATE
				cell.bodyStroke.Color = CHOCOLATE_DEEP
				cell.bodyStroke.Thickness = 2
				setGlow(cell, false)
				setLive(cell, grand)
				tintArt(cell, true, false)
			end
			if grand and not info.claimed then
				-- The finale keeps its gold frame and warm face however far away it is.
				cell.body.BackgroundColor3 = Tokens.color.goldDeep
				cell.bodyStroke.Color = Tokens.color.gold
				cell.bodyStroke.Thickness = 3
				cell.tag.BackgroundColor3 = if claimable then Tokens.color.goldDeep else Tokens.color.emberDeep
				cell.face.BackgroundColor3 = if claimable then CREAM_LIVE else Tokens.color.creamPill
				cell.amount.TextColor3 = Tokens.color.goldDeep
				tintArt(cell, false, false)
			end
			if cell.badge then
				cell.badge.Visible = not info.claimed
			end
			local shouldPulse = claimable
			if shouldPulse and not cell.stopPulse then
				cell.scale.Scale = 1 + amp(0.03)
				cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.045)
			elseif not shouldPulse and cell.stopPulse then
				cell.stopPulse()
				cell.stopPulse = nil
			elseif not shouldPulse then
				cell.scale.Scale = 1
			end
			-- Markers mirror the cards.
			local marker = markers[index]
			if marker then
				marker.egg.Visible = not info.claimed and (info.current or grand)
				marker.check.Visible = info.claimed
				marker.lock.Visible = not info.claimed and not info.current and not grand
				if info.claimed then
					marker.face.BackgroundColor3 = Tokens.color.leaf
					marker.root.BackgroundColor3 = Tokens.color.leafDeep
					marker.stroke.Color = Tokens.color.leafDeep
				elseif info.current then
					marker.face.BackgroundColor3 = Tokens.color.gold
					marker.root.BackgroundColor3 = Tokens.color.goldDeep
					marker.stroke.Color = Tokens.color.gold
				else
					marker.face.BackgroundColor3 = if grand then Tokens.color.creamPill else Tokens.color.creamDeep
					marker.root.BackgroundColor3 = if grand then Tokens.color.goldDeep else CHOCOLATE
					marker.stroke.Color = if grand then Tokens.color.goldDeep else CHOCOLATE_DEEP
				end
				if marker.crown then
					marker.crown.Visible = not info.claimed
				end
			end
		end
		if ready then
			message.Text = if daily.status == "reset"
				then "Streak rested - back to Day 1!"
				else string.format("Day %d is ready!", daily.dayIndex)
			claim.setEnabled(true)
			claim.setText(string.format("CLAIM %s GEMS", withCommas(daily.gems)))
			claim.pulse(true)
		else
			message.Text = string.format("Day %d opens in %s", daily.dayIndex, clock(unlockIn(daily, daily.dayIndex)))
			claim.setEnabled(false)
			claim.setText(string.format("OPENS IN %s", clock(unlockIn(daily, daily.dayIndex))))
			claim.pulse(false)
		end
		ruleText.Text = string.format("Claim once a day to reach Day %d. Miss two days and your streak resets to Day 1.", finalDay)
		fitRule()
	end

	-- Countdowns tick once a second while the screen is open.
	task.spawn(function()
		while alive do
			task.wait(1)
			local daily = evaluation()
			if not alive or not daily or animating then
				continue
			end
			local calendar = DailyRewards.calendar(cfg, { dayIndex = daily.dayIndex } :: any)
			for index, cell in ipairs(cells) do
				local info = calendar[index]
				if info.claimed or cell.claimable then
					continue
				end
				if info.current then
					cell.footerLabel.Text = clock(unlockIn(daily, info.day))
				else
					cell.footerLabel.Text = unlockText(unlockIn(daily, info.day))
				end
			end
			if daily.status == "early" then
				local remaining = clock(unlockIn(daily, daily.dayIndex))
				message.Text = string.format("Day %d opens in %s", daily.dayIndex, remaining)
				claim.setText("OPENS IN " .. remaining)
			end
		end
	end)

	-- Claim ---------------------------------------------------------------------------------------
	-- Where the flying gems land: the HUD's gem chip when there is one, else the top-left corner.
	local function pouchPoint(): Vector2
		local hud = deps.hud
		if hud and hud.currencyChipPoint then
			local point = hud:currencyChipPoint("gems")
			if point then
				return point
			end
		end
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
		return Vector2.new(math.min(120, viewport.X * 0.08), 44)
	end

	local function overlayGui(): Instance?
		local modals = deps.modals
		if modals and modals.gui then
			return modals.gui
		end
		return container:FindFirstAncestorWhichIsA("ScreenGui")
	end

	-- Gem copies arc from the card to the pouch; the count-up runs when the last one lands.
	local function flyGems(cell: Cell, count: number, onLanded: (index: number) -> (), onDone: () -> ())
		local gui = overlayGui()
		local gemId = AssetManifest.image("hud.gem")
		if not gui or not gemId or motion.reducedMotion then
			task.delay(seconds(0.2), function()
				for index = 1, count do
					onLanded(index)
				end
				onDone()
			end)
			return
		end
		local overlay = Instance.new("Frame")
		overlay.Name = "DailyFlight"
		overlay.Size = UDim2.fromScale(1, 1)
		overlay.BackgroundTransparency = 1
		overlay.ZIndex = Tokens.zIndex.veil
		overlay.Parent = gui
		local origin = overlay.AbsolutePosition
		local from = cell.art.AbsolutePosition + cell.art.AbsoluteSize * 0.5 - origin
		local to = pouchPoint() - origin
		local px = math.clamp(cell.art.AbsoluteSize.Y * 0.42, 22, 52)
		local flights: { Flight } = {}
		local started = os.clock()
		for index = 1, count do
			local image = Instance.new("ImageLabel")
			image.Name = "Gem"
			image.BackgroundTransparency = 1
			image.Image = gemId
			image.ScaleType = Enum.ScaleType.Fit
			image.AnchorPoint = Vector2.new(0.5, 0.5)
			image.Size = UDim2.fromOffset(px, px)
			image.ZIndex = overlay.ZIndex + 1
			local spread =
				Vector2.new((math.random() - 0.5) * cell.art.AbsoluteSize.X * 0.6, (math.random() - 0.5) * cell.art.AbsoluteSize.Y * 0.4)
			local start = from + spread
			image.Position = UDim2.fromOffset(start.X, start.Y)
			image.Parent = overlay
			local mid = (start + to) * 0.5
			local control = mid + Vector2.new((math.random() - 0.5) * 160, -math.abs(start.Y - to.Y) * 0.35 - 90)
			table.insert(
				flights,
				{ image = image, start = started + (index - 1) * FLIGHT_STAGGER, from = start, control = control, landed = false }
			)
		end
		local remaining = count
		local connection: RBXScriptConnection
		connection = RunService.RenderStepped:Connect(function()
			local now = os.clock()
			for index, flight in ipairs(flights) do
				if flight.landed then
					continue
				end
				local t = math.clamp((now - flight.start) / FLIGHT_SECONDS, 0, 1)
				local eased = t * t * (3 - 2 * t)
				local u = 1 - eased
				local point = flight.from * (u * u) + flight.control * (2 * u * eased) + to * (eased * eased)
				flight.image.Position = UDim2.fromOffset(point.X, point.Y)
				flight.image.Rotation = eased * 260
				local size = px * (1 + 0.25 * math.sin(eased * math.pi)) * (1 - 0.45 * eased * eased)
				flight.image.Size = UDim2.fromOffset(size, size)
				if t >= 1 then
					flight.landed = true
					flight.image.Visible = false
					remaining -= 1
					onLanded(index)
				end
			end
			if remaining <= 0 or now - started > FLIGHT_SECONDS + count * FLIGHT_STAGGER + 1 then
				connection:Disconnect()
				overlay:Destroy()
				onDone()
			end
		end)
		table.insert(cleanups, function()
			if connection.Connected then
				connection:Disconnect()
			end
			if overlay.Parent then
				overlay:Destroy()
			end
		end)
	end

	local function doClaim()
		if animating or not claim.button.Active then
			return
		end
		local hud = deps.hud
		if hud and hud.holdCurrency then
			hud:holdCurrency("gems")
		end
		local held = true
		local function releaseHold()
			if held then
				held = false
				if hud and hud.releaseCurrency then
					hud:releaseCurrency("gems")
				end
			end
		end
		claim.setPending(true, "OPENING...")
		local result = deps.net:request("DailyClaim", nil)
		claim.setPending(false)
		if not alive then
			releaseHold()
			return
		end
		if not result.ok then
			releaseHold()
			play(Tokens.sound.uiError)
			deps.toasts:push(if result.message == "not_ready" then "The nest is still resting" else "Could not claim right now", "warning")
			return
		end
		local data = result.data
		if data.replayed then
			-- The server already paid this streak day: say so, and pay nothing on screen.
			releaseHold()
			deps.toasts:push("Today's Gems are already in your pouch", "info")
			return
		end
		local cell = cells[data.dayIndex]
		if not cell then
			releaseHold()
			deps.toasts:reward(string.format("Day %d nest opened", data.dayIndex), data.gems)
			return
		end
		animating = true
		claim.setEnabled(false)
		claim.pulse(false)
		play(Tokens.sound.uiConfirm)
		deps.haptics:pulse(0.5, 0.08)
		if cell.stopPulse then
			cell.stopPulse()
			cell.stopPulse = nil
		end
		-- Flash, and the cluster grows for a beat.
		cell.flash.BackgroundTransparency = 0.15
		TweenService
			:Create(
				cell.flash,
				TweenInfo.new(seconds(0.4), Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 1 }
			)
			:Play()
		cell.artScale.Scale = 1 + amp(0.28)
		Tween.scale(cell.artScale, "release", motion, 1)
		cell.scale.Scale = 1 + amp(0.08)
		Tween.scale(cell.scale, "release", motion, 1)
		local copies = math.clamp(3 + math.floor((data.gems or 0) / 40), 3, 9)
		flyGems(cell, copies, function()
			play(Tokens.sound.rewardTick)
			if hud and hud.celebrateCurrency then
				hud:celebrateCurrency("gems", 1)
			end
		end, function()
			if not alive then
				releaseHold()
				return
			end
			releaseHold()
			play(Tokens.sound.rewardLand)
			play(Tokens.sound.uiConfetti)
			deps.haptics:pulse(0.7, 0.12)
			Confetti.burst(cell.root, {
				origin = UDim2.fromScale(0.5, 0.45),
				count = if data.dayIndex == finalDay then 48 else 26,
				spread = if data.dayIndex == finalDay then 240 else 150,
				motion = motion,
				tier = deps.quality and deps.quality:tier() or nil,
				zIndex = z + 20,
			})
			Tween.floatText(cell.face, string.format("+%s GEMS", withCommas(data.gems or 0)), Tokens.color.goldDeep, motion, z + 14)
			animating = false
			-- The card turns CLAIMED and the next marker lights now that the gems have landed.
			render()
			if deps.toasts and deps.toasts.reward then
				deps.toasts:reward(string.format("Day %d nest opened", data.dayIndex), data.gems)
			end
		end)
	end

	table.insert(cleanups, claim.button.Activated:Connect(doClaim))
	for _, cell in ipairs(cells) do
		table.insert(
			cleanups,
			cell.hit.Activated:Connect(function()
				if cell.claimable then
					doClaim()
				end
			end)
		)
		table.insert(
			cleanups,
			cell.hit.MouseEnter:Connect(function()
				if cell.claimable and not motion.reducedMotion then
					if cell.stopPulse then
						cell.stopPulse()
						cell.stopPulse = nil
					end
					TweenService:Create(cell.scale, TweenInfo.new(seconds(0.14), Enum.EasingStyle.Back), { Scale = 1 + amp(0.06) }):Play()
				end
			end)
		)
		table.insert(
			cleanups,
			cell.hit.MouseLeave:Connect(function()
				if cell.claimable and not cell.stopPulse then
					cell.scale.Scale = 1 + amp(0.03)
					cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.045)
				end
			end)
		)
	end

	if api.registerDebug then
		api.registerDebug({
			claim = doClaim,
			report = function()
				local daily = evaluation()
				local states = {}
				for _, cell in ipairs(cells) do
					table.insert(states, cell.footerLabel.Text)
				end
				local label = claim.button:FindFirstChild("Face")
				label = label and label:FindFirstChild("Label")
				return {
					status = daily and daily.status or "none",
					dayIndex = daily and daily.dayIndex or 0,
					claimEnabled = claim.button.Active,
					claimText = if label and label:IsA("TextLabel") then label.Text else "",
					headline = message.Text,
					days = #cells,
					cellStates = states,
					finaleGems = cells[finalDay] and cells[finalDay].amount.Text or "",
					animating = animating,
				}
			end,
		})
	end

	render()
	table.insert(
		cleanups,
		deps.profile.changed:Connect(function()
			render()
		end)
	)

	-- Opening: the cards pop in from Day 1 to Day 8, the banner settles, the claimable card gives one
	-- gold pulse and its gems rise, the button slides up. Everything is pressable from the first
	-- frame; nothing waits on this.
	if not motion.reducedMotion then
		for index, cell in ipairs(cells) do
			cell.scale.Scale = 0.6
			local rest = if cell.claimable then 1 + amp(0.03) else 1
			TweenService:Create(
				cell.scale,
				TweenInfo.new(seconds(0.24), Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0.03 * (index - 1)),
				{ Scale = rest }
			):Play()
		end
		if shell then
			local plaqueRest = shell.plaque.Position
			shell.plaque.Position = plaqueRest - UDim2.fromScale(0, 0.35)
			TweenService
				:Create(
					shell.plaque,
					TweenInfo.new(seconds(0.4), Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Position = plaqueRest }
				)
				:Play()
		end
		local buttonRest = claim.button.Position
		claim.button.Position = buttonRest + UDim2.fromScale(0, 0.06)
		TweenService:Create(
			claim.button,
			TweenInfo.new(seconds(0.34), Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.12),
			{ Position = buttonRest }
		):Play()
		task.delay(0.3, function()
			if not alive then
				return
			end
			for _, cell in ipairs(cells) do
				if cell.claimable then
					if cell.stopPulse then
						cell.stopPulse()
						cell.stopPulse = nil
					end
					cell.scale.Scale = 1 + amp(0.09)
					local settle = TweenService:Create(
						cell.scale,
						TweenInfo.new(seconds(0.34), Enum.EasingStyle.Back, Enum.EasingDirection.Out),
						{ Scale = 1 + amp(0.03) }
					)
					settle:Play()
					settle.Completed:Once(function()
						if alive and cell.claimable and not cell.stopPulse then
							cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.045)
						end
					end)
					cell.artScale.Scale = 1 + amp(0.12)
					Tween.scale(cell.artScale, "release", motion, 1)
					cell.glow.BackgroundTransparency = 0.35
				end
			end
		end)
	end
	play(Tokens.sound.uiOpen)

	return function()
		alive = false
		for _, cell in ipairs(cells) do
			if cell.stopPulse then
				cell.stopPulse()
			end
			if cell.raysTween then
				cell.raysTween:Cancel()
			end
			if cell.floatTween then
				cell.floatTween:Cancel()
			end
			if cell.glowTween then
				cell.glowTween:Cancel()
			end
		end
		for _, cleanup in ipairs(cleanups) do
			if type(cleanup) == "function" then
				cleanup()
			else
				cleanup:Disconnect()
			end
		end
		play(Tokens.sound.uiClose)
	end
end

return DailyModal
