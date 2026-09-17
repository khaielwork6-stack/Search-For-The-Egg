--!strict
-- Daily Nest, v3 (17 Sep 2026): the owner's reference clip, adapted.
--
-- One charcoal panel, the title floating above its top-left, a red X on its corner, and eight dark
-- slate cards in a 4x2 grid. Each card is the day, the reward in white (gold on the finale), the
-- painted gem art as the biggest thing on it, and one green pill along the bottom that carries the
-- state: CLAIM on the open day (the whole card glows lime and breathes), CLAIMED once taken, and a
-- countdown on the rest. Nothing else: no strip, no rule line, no second button.
--
-- Nothing here decides anything. The server owns the streak, the cooldown and the grant; this reads
-- `projection.rewards.daily`, and the gems only fly to the pouch after the server has acknowledged
-- the claim, so a replayed claim never pays twice on screen either.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Feedback = require(script.Parent.Parent.Feedback)
local Motion = require(Shared.Design.Motion)
local AssetManifest = require(Shared.Design.AssetManifest)
local DailyRewards = require(Shared.Domain.DailyRewards)
local Depth = require(script.Parent.Parent.Components.Depth)
local Tween = require(script.Parent.Parent.Components.Tween)
local Icons = require(script.Parent.Parent.Components.Icons)
local Fit = require(script.Parent.Parent.Components.Fit)
local Confetti = require(script.Parent.Parent.Components.Confetti)

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

local CARD = Tokens.color.surface
local CARD_LIVE = Color3.fromRGB(66, 70, 92)
local CARD_DONE = Color3.fromRGB(52, 56, 74)
local LIME = Color3.fromRGB(196, 250, 82)
local GREEN = Color3.fromRGB(96, 208, 40)
local GREEN_DEEP = Color3.fromRGB(38, 132, 24)
local PILL_TEXT = Color3.fromRGB(18, 40, 12)

local FLIGHT_SECONDS = 0.55
local FLIGHT_STAGGER = 0.06

-- "1d 23h" / "23h 31m" / "31m": the countdown a locked pill carries, the way the reference writes it.
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

-- Which painted piece stands for a day's reward: one stone for the token day, a three-gem cluster
-- for an ordinary day, the spilling bag for the big mid-week day, the overflowing chest for the finale.
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
	body: Frame,
	bodyStroke: UIStroke,
	glow: UIStroke,
	title: TextLabel,
	amount: TextLabel,
	art: GuiObject,
	artHome: UDim2,
	artScale: UIScale,
	pill: TextButton,
	pillLabel: TextLabel,
	flash: Frame,
	hit: TextButton,
	sparkles: { Frame },
	live: boolean,
	claimable: boolean,
	stopPulse: (() -> ())?,
	floatTween: Tween?,
	glowTween: Tween?,
}

type Flight = { image: ImageLabel, start: number, from: Vector2, control: Vector2, landed: boolean }

function DailyModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local z = container.ZIndex + 1
	local rewards = cfg.dailyRewards
	local finalDay = #rewards
	local cooldown = cfg.dailyRewardRules.claimCooldownSeconds
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
	container.Position = UDim2.fromScale(0.015, 0.035)
	container.Size = UDim2.fromScale(0.97, 0.94)
	local listLayout = container:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		listLayout:Destroy()
	end
	local listPadding = container:FindFirstChildOfClass("UIPadding")
	if listPadding then
		listPadding:Destroy()
	end

	-- Reward grid --------------------------------------------------------------------------------
	local grid = Fit.frame(container, "Calendar", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), z)
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.235, 0.47)
	layout.CellPadding = UDim2.fromScale(0.02, 0.06)
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

		-- The card: dark slate, a thick black keyline, a glossy ramp; the lime glow lives on a second
		-- stroke so the keyline never has to change.
		local body = Instance.new("Frame")
		body.Name = "Body"
		body.Size = UDim2.fromScale(1, 1)
		body.BackgroundColor3 = CARD
		body.BorderSizePixel = 0
		body.ZIndex = z + 2
		Fit.corner(body, 0.12)
		local bodyStroke = Depth.keyline(body, Tokens.depth.keyline, Tokens.color.outline)
		Depth.applySheen(body, CARD)
		local glow = Instance.new("UIStroke")
		glow.Name = "Glow"
		glow.Thickness = 0
		glow.Color = LIME
		glow.Transparency = 0.15
		glow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		glow.Parent = body
		body.Parent = root

		local title = Fit.text(body, "Title", "DAY " .. entry.day, {
			font = Tokens.typography.display.font,
			color = Tokens.color.featherWhite,
			max = 36,
			min = 10,
			outline = 3,
			outlineColor = Tokens.color.outline,
			zIndex = z + 4,
			size = UDim2.fromScale(0.9, 0.17),
			position = UDim2.fromScale(0.5, 0.05),
			anchor = Vector2.new(0.5, 0),
		})
		local amount = Fit.text(body, "Amount", "+" .. tostring(entry.gems) .. " Gems", {
			font = Tokens.typography.label.font,
			color = if grand then Tokens.color.gold else Tokens.color.featherWhite,
			max = 24,
			min = 8,
			outline = 2.2,
			outlineColor = Tokens.color.outline,
			zIndex = z + 4,
			size = UDim2.fromScale(0.92, 0.11),
			position = UDim2.fromScale(0.5, 0.215),
			anchor = Vector2.new(0.5, 0),
		})

		-- Artwork: the painted reward, the biggest thing on the card.
		local artBox = Fit.frame(body, "ArtBox", UDim2.fromScale(0.5, 0.33), UDim2.fromScale(0.86, 0.42), z + 3, Vector2.new(0.5, 0))
		local artScale = Instance.new("UIScale")
		artScale.Parent = artBox
		local role = artRoleFor(entry.gems or 0, biggest, grand)
		local overscan = if role == "hud.gem" or role == "perk.gemValue" then 1.3 else 1.14
		local art: GuiObject? = Fit.image(artBox, role, {
			size = UDim2.fromScale(overscan, overscan),
			position = UDim2.fromScale(0.5, 0.5),
			zIndex = z + 4,
			name = "Art",
		})
		if not art then
			local drawn = Icons.gem(artBox, 40, { zIndex = z + 4 })
			drawn.AnchorPoint = Vector2.new(0.5, 0.5)
			drawn.Position = UDim2.fromScale(0.5, 0.5)
			drawn.Size = UDim2.fromScale(0.6, 0.9)
			Fit.aspect(drawn, 1, Enum.DominantAxis.Height)
		end

		-- The pill: green, thick keyline, dark lettering; the state it carries is set by render.
		local pill = Instance.new("TextButton")
		pill.Name = "Pill"
		pill.Text = ""
		pill.AutoButtonColor = false
		pill.AnchorPoint = Vector2.new(0.5, 1)
		pill.Position = UDim2.fromScale(0.5, 0.94)
		pill.Size = UDim2.fromScale(0.8, 0.17)
		pill.BackgroundColor3 = GREEN
		pill.BorderSizePixel = 0
		pill.Active = false
		pill.Selectable = false
		pill.ZIndex = z + 5
		Fit.corner(pill, 0.4)
		Depth.keyline(pill, Tokens.depth.keyline, Tokens.color.outline)
		Depth.applySheen(pill, GREEN, LIME)
		pill.Parent = body
		local pillLabel = Fit.text(pill, "State", "", {
			font = Tokens.typography.label.font,
			color = PILL_TEXT,
			max = 26,
			min = 8,
			zIndex = z + 6,
			size = UDim2.fromScale(0.9, 0.82),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})

		-- Flash for the claim moment.
		local flash = Instance.new("Frame")
		flash.Name = "Flash"
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = Color3.new(1, 1, 1)
		flash.BackgroundTransparency = 1
		flash.BorderSizePixel = 0
		flash.ZIndex = z + 7
		Fit.corner(flash, 0.12)
		flash.Parent = body

		-- The whole card is the tap target while it can be claimed.
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Size = UDim2.fromScale(1, 1)
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.Active = false
		hit.Selectable = false
		hit.ZIndex = z + 8
		hit.Parent = root

		root.Parent = grid
		return {
			day = entry.day,
			root = root,
			scale = scale,
			body = body,
			bodyStroke = bodyStroke,
			glow = glow,
			title = title,
			amount = amount,
			art = artBox,
			artHome = artBox.Position,
			artScale = artScale,
			pill = pill,
			pillLabel = pillLabel,
			flash = flash,
			hit = hit,
			sparkles = {},
			live = false,
			claimable = false,
			stopPulse = nil,
			floatTween = nil,
			glowTween = nil,
		}
	end

	local cells: { Cell } = {}
	for _, entry in ipairs(rewards) do
		table.insert(cells, buildCell(entry))
	end

	-- Sparkles: a small pool of stars on the lively cards, cycled by a wait loop (no per-frame work).
	local function sparkleAt(cell: Cell)
		if motion.reducedMotion or not alive or not cell.live then
			return
		end
		local pool = cell.sparkles
		if #pool < 5 then
			local star = Icons.star(cell.body, 14, { zIndex = z + 6, color = LIME })
			star.Name = "Sparkle"
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Size = UDim2.fromScale(0, 0.1)
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
		sparkle.Position = UDim2.fromScale(0.16 + math.random() * 0.68, 0.32 + math.random() * 0.42)
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
				{ Position = cell.artHome - UDim2.fromScale(0, amp(0.025)) }
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
			cell.glow.Thickness = Tokens.depth.keyline + 2
			cell.glow.Transparency = 0.1
			if not motion.reducedMotion then
				cell.glowTween = TweenService:Create(
					cell.glow,
					TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ Transparency = 0.5 }
				)
				cell.glowTween:Play()
			end
		else
			cell.glow.Thickness = 0
		end
	end

	local function tintArt(cell: Cell, locked: boolean, done: boolean)
		local art = cell.art:FindFirstChild("Art")
		if art and art:IsA("ImageLabel") then
			art.ImageColor3 = if locked
				then Color3.fromRGB(196, 200, 214)
				elseif done then Color3.fromRGB(214, 214, 222)
				else Color3.new(1, 1, 1)
			art.ImageTransparency = if locked then 0.08 elseif done then 0.28 else 0
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
			cell.amount.Text = "+" .. tostring(info.gems) .. " Gems"
			cell.title.Text = "DAY " .. info.day
			cell.hit.Active = claimable
			cell.pill.Active = claimable
			cell.amount.TextColor3 = if grand then Tokens.color.gold elseif claimable then LIME else Tokens.color.featherWhite
			if info.claimed then
				cell.body.BackgroundColor3 = CARD_DONE
				Depth.applySheen(cell.body, CARD_DONE)
				cell.pill.BackgroundColor3 = GREEN_DEEP
				Depth.applySheen(cell.pill, GREEN_DEEP, GREEN)
				cell.pillLabel.TextColor3 = Tokens.color.featherWhite
				cell.pillLabel.Text = "CLAIMED"
				setGlow(cell, false)
				setLive(cell, false)
				tintArt(cell, false, true)
			elseif claimable then
				cell.body.BackgroundColor3 = CARD_LIVE
				Depth.applySheen(cell.body, CARD_LIVE)
				cell.pill.BackgroundColor3 = GREEN
				Depth.applySheen(cell.pill, GREEN, LIME)
				cell.pillLabel.TextColor3 = Tokens.color.featherWhite
				cell.pillLabel.Text = "CLAIM"
				setGlow(cell, true)
				setLive(cell, true)
				tintArt(cell, false, false)
			else
				cell.body.BackgroundColor3 = CARD
				Depth.applySheen(cell.body, CARD)
				cell.pill.BackgroundColor3 = GREEN
				Depth.applySheen(cell.pill, GREEN, LIME)
				cell.pillLabel.TextColor3 = PILL_TEXT
				cell.pillLabel.Text = unlockText(unlockIn(daily, info.day))
				setGlow(cell, false)
				setLive(cell, grand)
				tintArt(cell, not info.current, false)
			end
			local shouldPulse = claimable
			if shouldPulse and not cell.stopPulse then
				cell.scale.Scale = 1 + amp(0.02)
				cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.04)
			elseif not shouldPulse and cell.stopPulse then
				cell.stopPulse()
				cell.stopPulse = nil
			elseif not shouldPulse then
				cell.scale.Scale = 1
			end
		end
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
				if not info.claimed and not cell.claimable then
					cell.pillLabel.Text = unlockText(unlockIn(daily, info.day))
				end
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
		if animating then
			return
		end
		local target: Cell? = nil
		for _, cell in ipairs(cells) do
			if cell.claimable then
				target = cell
			end
		end
		if not target then
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
		local pressed = target :: Cell
		pressed.pillLabel.Text = "..."
		local result = deps.net:request("DailyClaim", nil)
		if not alive then
			releaseHold()
			return
		end
		if not result.ok then
			releaseHold()
			pressed.pillLabel.Text = "CLAIM"
			Feedback.deny(
				"daily:" .. tostring(result.message or result.code),
				if result.message == "not_ready" then "The nest is still resting" else "Could not claim right now"
			)
			return
		end
		local data = result.data
		if data.replayed then
			-- The server already paid this streak day: say so, and pay nothing on screen.
			releaseHold()
			deps.toasts:push("Today's Gems are already in your pouch", "info")
			render()
			return
		end
		local cell = cells[data.dayIndex] or pressed
		animating = true
		play(Tokens.sound.uiConfirm)
		deps.haptics:pulse(0.5, 0.08)
		if cell.stopPulse then
			cell.stopPulse()
			cell.stopPulse = nil
		end
		-- Flash, and the cluster grows for a beat.
		cell.flash.BackgroundTransparency = 0.2
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
				count = if data.dayIndex == finalDay then 48 else 30,
				spread = if data.dayIndex == finalDay then 240 else 170,
				motion = motion,
				tier = deps.quality and deps.quality:tier() or nil,
				zIndex = z + 20,
			})
			Tween.floatText(cell.body, string.format("+%s GEMS", withCommas(data.gems or 0)), LIME, motion, z + 14)
			animating = false
			-- The card turns CLAIMED and the next day lights now that the gems have landed.
			render()
			if deps.toasts and deps.toasts.reward then
				deps.toasts:reward(string.format("Day %d nest opened", data.dayIndex), data.gems)
			end
		end)
	end

	for _, cell in ipairs(cells) do
		local function pressed()
			if cell.claimable then
				doClaim()
			end
		end
		table.insert(cleanups, cell.hit.Activated:Connect(pressed))
		table.insert(cleanups, cell.pill.Activated:Connect(pressed))
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
					cell.scale.Scale = 1 + amp(0.02)
					cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.04)
				end
			end)
		)
	end
	api.setInitialFocus(cells[1].hit)

	if api.registerDebug then
		api.registerDebug({
			claim = doClaim,
			report = function()
				local daily = evaluation()
				local states = {}
				for _, cell in ipairs(cells) do
					table.insert(states, cell.pillLabel.Text)
				end
				local claimEnabled = false
				for _, cell in ipairs(cells) do
					if cell.claimable then
						claimEnabled = true
					end
				end
				return {
					status = daily and daily.status or "none",
					dayIndex = daily and daily.dayIndex or 0,
					claimEnabled = claimEnabled,
					claimText = if claimEnabled then "CLAIM" else "",
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

	-- Opening: the cards pop in from Day 1 to Day 8, the open card gives one lime pulse and its gems
	-- rise. Everything is pressable from the first frame; nothing waits on this.
	if not motion.reducedMotion then
		for index, cell in ipairs(cells) do
			cell.scale.Scale = 0.6
			local rest = if cell.claimable then 1 + amp(0.02) else 1
			TweenService:Create(
				cell.scale,
				TweenInfo.new(seconds(0.24), Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0.03 * (index - 1)),
				{ Scale = rest }
			):Play()
		end
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
						{ Scale = 1 + amp(0.02) }
					)
					settle:Play()
					settle.Completed:Once(function()
						if alive and cell.claimable and not cell.stopPulse then
							cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.04)
						end
					end)
					cell.artScale.Scale = 1 + amp(0.12)
					Tween.scale(cell.artScale, "release", motion, 1)
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
