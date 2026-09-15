--!strict
-- Daily Nest modal.
--
-- Reads as a streak rather than a grid of numbers: a header that says where you are and when the
-- next nest opens, a progress rail under it, the early days as cookie tiles, and the last day as a
-- wide premium card so the run has somewhere to arrive. Each tile states its own reward (icon and
-- quantity) and its own state - claimed, today, or locked - so nothing depends on colour alone.
--
-- Nothing here decides anything. The server owns the streak, the cooldown and the grant; this reads
-- `projection.rewards.daily`, and the reward toast and count-up run only after the server has
-- acknowledged the claim, so a replayed claim never pays twice on screen either.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local DailyRewards = require(Shared.Domain.DailyRewards)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
local Skin = require(script.Parent.Parent.Components.Skin)
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
}

local COLUMNS = 4

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end

type Cell = {
	root: Frame,
	face: Frame,
	scale: UIScale,
	stroke: UIStroke,
	header: Frame,
	title: TextLabel,
	amount: TextLabel,
	footer: TextButton,
	hit: TextButton,
	gems: { Frame },
	rays: GuiObject?,
	check: Frame,
	lock: Frame,
	ribbon: TextLabel?,
	stopPulse: (() -> ())?,
}

function DailyModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local receivedAt = os.clock()
	local rewards = cfg.dailyRewards
	local finalDay = #rewards

	-- Header: the one line that says where the streak stands, with the live countdown beside it.
	-- Warm, not navy. A cold dark slab across the top of the first screen a player ever sees belongs
	-- to some other game; this is a barn.
	local header, headerFace = FrameKit.tile(container, "Header", {
		fill = Tokens.color.cocoa,
		deep = Tokens.color.outline,
		zIndex = z,
		radius = Tokens.radius.lg,
		size = UDim2.new(1, 0, 0, math.floor(tap * 0.82)),
	})
	header.LayoutOrder = 1
	local headerPad = Instance.new("UIPadding")
	headerPad.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	headerPad.PaddingRight = UDim.new(0, Tokens.spacing.md)
	headerPad.Parent = headerFace
	-- One line, not two.
	--
	-- This said "Day 1 of 8 is ready" over "10 Gems waiting in the nest" while the card directly
	-- beneath it showed DAY 1, +10, and a pulsing CLAIM. Two lines of banner to repeat what the
	-- artwork already says is the writing that pushes the bottom half of the calendar off screen.
	-- The streak sits left, the countdown right, and when a nest is open the card is the one that
	-- says so.
	local status = FrameKit.text(headerFace, "Status", "", "heading", { zIndex = z + 2, color = Tokens.color.featherWhite })
	status.AnchorPoint = Vector2.new(0, 0.5)
	status.Position = UDim2.fromScale(0, 0.5)
	status.Size = UDim2.fromScale(0.5, 1)
	status.TextYAlignment = Enum.TextYAlignment.Center
	local timer = FrameKit.text(headerFace, "Timer", "", "caption", { zIndex = z + 2, color = Tokens.color.straw })
	timer.AnchorPoint = Vector2.new(1, 0.5)
	timer.Position = UDim2.fromScale(1, 0.5)
	timer.Size = UDim2.fromScale(0.5, 1)
	timer.TextXAlignment = Enum.TextXAlignment.Right
	timer.TextYAlignment = Enum.TextYAlignment.Center

	-- Progress rail: claimed days filled, today's notch bright, the rest dark.
	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.BackgroundTransparency = 1
	rail.Size = UDim2.new(1, 0, 0, 14)
	rail.LayoutOrder = 2
	rail.ZIndex = z
	local railLayout = Instance.new("UIListLayout")
	railLayout.FillDirection = Enum.FillDirection.Horizontal
	railLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	railLayout.SortOrder = Enum.SortOrder.LayoutOrder
	railLayout.Parent = rail
	rail.Parent = container
	local notches: { Frame } = {}
	for day = 1, finalDay do
		local notch = Instance.new("Frame")
		notch.Name = "Notch" .. day
		notch.LayoutOrder = day
		notch.Size = UDim2.new(1 / finalDay, -Tokens.spacing.xs, 1, 0)
		notch.BackgroundColor3 = Tokens.color.creamDeep
		notch.BorderSizePixel = 0
		notch.ZIndex = z + 1
		local notchCorner = Instance.new("UICorner")
		notchCorner.CornerRadius = UDim.new(1, 0)
		notchCorner.Parent = notch
		-- A keyline, so an unfilled notch is a visible empty slot rather than a pale smudge on cream.
		local notchLine = Instance.new("UIStroke")
		notchLine.Thickness = 1.5
		notchLine.Color = Tokens.color.strawDeep
		notchLine.Transparency = 0.35
		notchLine.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		notchLine.Parent = notch
		notch.Parent = rail
		table.insert(notches, notch)
	end

	local grid = Instance.new("Frame")
	grid.Name = "Calendar"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.fromScale(1, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.LayoutOrder = 3
	grid.ZIndex = z
	local layout = Instance.new("UIGridLayout")
	-- Tall enough for the artwork to be the biggest thing on the card. At 2.9 the four bands added up
	-- to more than the cell, so the art band collapsed to its 18px floor and the gems came out smaller
	-- than the vector lozenges they replaced.
	local CELL_HEIGHT = math.floor(tap * 3.4)
	layout.CellSize = UDim2.new(1 / COLUMNS, -Tokens.spacing.sm, 0, CELL_HEIGHT)
	layout.CellPadding = UDim2.fromOffset(Tokens.spacing.sm, Tokens.spacing.sm)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	grid.Parent = container

	-- One reward card, laid out in bands so nothing can overlap: a day header, the amount, a block of
	-- artwork, then a footer that carries the state. The previous version centred the gem icon and the
	-- amount on the same point, which drew the icon straight through the number.
	local function buildCell(parent: Instance, entry: any, grand: boolean): Cell
		local root, face = FrameKit.tile(parent, "Day" .. entry.day, {
			fill = Tokens.color.surface,
			deep = Tokens.color.creamDeep,
			zIndex = z + 1,
			radius = Tokens.radius.md,
			lip = 5,
		})
		root.LayoutOrder = entry.day
		local scale = Instance.new("UIScale")
		scale.Parent = root
		local stroke = Depth.keylineOf(root) :: UIStroke

		-- Header band: the day number, always legible against the card whatever state it is in.
		-- Bands, measured off the cell height, so the header, amount, artwork and footer occupy four
		-- strips that cannot intersect whatever the viewport scale does.
		local headerHeight = Tokens.typography.label.size + Tokens.spacing.sm
		-- Big, but not so big it starves the picture underneath: display type at full size took 36px of
		-- a 127px card and left the art 18. This is the number's own size, set once here.
		local amountHeight = Tokens.typography.title.size + 6
		-- Tall enough to read as a button rather than a printed strip. The card itself carries the tap
		-- target (see the hit layer below), so this is about weight, not reach.
		local footerHeight = Tokens.typography.label.size + Tokens.spacing.md
		local artTop = headerHeight + amountHeight + Tokens.spacing.xs
		local artHeight = math.max(18, CELL_HEIGHT - artTop - footerHeight - Tokens.spacing.sm * 2)

		local header = Instance.new("Frame")
		header.Name = "Header"
		header.Size = UDim2.new(1, 0, 0, headerHeight)
		header.BackgroundColor3 = Tokens.color.strawDeep
		header.BorderSizePixel = 0
		header.ZIndex = z + 2
		header.Parent = face
		local headerCorner = Instance.new("UICorner")
		headerCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
		headerCorner.Parent = header
		local title = FrameKit.text(header, "Title", "DAY " .. entry.day, "label", {
			align = Enum.TextXAlignment.Center,
			zIndex = z + 3,
			color = Tokens.color.featherWhite,
		})
		title.Size = UDim2.fromScale(1, 1)

		local amount = FrameKit.text(face, "Amount", "", "display", {
			align = Enum.TextXAlignment.Center,
			zIndex = z + 3,
			color = Tokens.color.goldDeep,
		})
		amount.TextSize = Tokens.typography.title.size + 4
		amount.AnchorPoint = Vector2.new(0.5, 0)
		amount.Position = UDim2.new(0.5, 0, 0, headerHeight)
		amount.Size = UDim2.new(1, 0, 0, amountHeight)

		-- Artwork band. The grand prize gets a cluster rather than a single stone, so "a lot" reads
		-- without writing the word.
		local art = Instance.new("Frame")
		art.Name = "Art"
		art.BackgroundTransparency = 1
		art.AnchorPoint = Vector2.new(0.5, 0)
		art.Position = UDim2.new(0.5, 0, 0, artTop)
		art.Size = UDim2.new(1, -Tokens.spacing.sm, 0, artHeight)
		art.ZIndex = z + 3
		art.Parent = face
		-- The real gem, not a drawn diamond.
		--
		-- Every card used to show `Icons.gem` - a flat teal vector lozenge that looks nothing like the
		-- gem in the player's own HUD - at 32px in a 46px band, so eight cards each held one small cold
		-- shape. It is the game's gem art now, sized off the band, and *how many* are drawn scales with
		-- what the day actually pays: one stone for a small day, a row of three for a good one, a heap
		-- for the grand prize. "A lot" then reads off the picture without anyone writing the word.
		local rays = Skin.texture(art, "texture.sunburst", {
			zIndex = z + 3,
			transparency = 0.55,
			color = Tokens.color.goldLight,
		})
		local gems: { Frame } = {}
		local biggest = 0
		for _, reward in ipairs(rewards) do
			biggest = math.max(biggest, reward.gems or 0)
		end
		local share = if biggest > 0 then (entry.gems or 0) / biggest else 0
		-- Tuned against the real ladder (10 / 120 / 50 / 500): a token day gets one stone, an ordinary
		-- day two, the big mid-week day three, and the finale a heap. At the old thresholds five of the
		-- eight days drew the same single gem, which is the monotony this was meant to break.
		local cluster = if grand then 6 elseif share >= 0.2 then 3 elseif share >= 0.06 then 2 else 1
		local px = math.floor(math.clamp(artHeight * (if cluster > 3 then 0.52 else 0.82), 18, 54))
		for index = 1, cluster do
			local gem = Skin.icon(art, "hud.gem", px, z + 4) or Icons.gem(art, px, { zIndex = z + 4 })
			gem.AnchorPoint = Vector2.new(0.5, 0.5)
			if cluster == 1 then
				gem.Position = UDim2.fromScale(0.5, 0.5)
			elseif cluster <= 3 then
				-- A row, slightly fanned, so three stones read as a handful rather than a diagram.
				local t = (index - 1) / math.max(1, cluster - 1) - 0.5
				gem.Position = UDim2.fromScale(0.5 + t * 0.44, 0.5 - math.abs(t) * 0.12)
				gem.Rotation = t * 14
			else
				-- A heap: a back row and a front row, the front one larger and lower.
				local back = index <= 3
				local within = if back then index - 2 else index - 5
				gem.Position = UDim2.fromScale(0.5 + within * (if back then 0.3 else 0.26), if back then 0.38 else 0.62)
				gem.Rotation = within * 10
				gem.Size = UDim2.fromOffset(px, px)
			end
			table.insert(gems, gem)
		end

		-- The whole card is the tap target.
		--
		-- The footer band used to be the only place a card could be pressed, which made the real target
		-- 124x21 - less than half the 44px minimum the tokens declare, on the one control in this modal
		-- a player is here to press. The band still shows the state; this sits over the card and takes
		-- the press, so the target is the full 127px cell.
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Size = UDim2.fromScale(1, 1)
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.ZIndex = z + 6
		hit.Parent = face

		-- Footer: the state the card is in, drawn as the affordance.
		local footer = Instance.new("TextButton")
		footer.Name = "Footer"
		footer.AnchorPoint = Vector2.new(0.5, 1)
		footer.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.xs)
		footer.Size = UDim2.new(1, -Tokens.spacing.sm, 0, footerHeight)
		footer.BackgroundColor3 = Tokens.color.creamDeep
		footer.BorderSizePixel = 0
		footer.AutoButtonColor = false
		footer.Font = Tokens.typography.label.font
		footer.TextSize = Tokens.typography.caption.size
		footer.TextColor3 = Tokens.color.ink
		footer.Text = ""
		footer.Active = false
		footer.ZIndex = z + 4
		footer.Parent = face
		local footerCorner = Instance.new("UICorner")
		footerCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
		footerCorner.Parent = footer
		local footerStroke = Instance.new("UIStroke")
		footerStroke.Thickness = Tokens.stroke.hairline
		footerStroke.Color = Tokens.color.outline
		footerStroke.Transparency = 0.4
		footerStroke.Parent = footer

		local check = Icons.check(face, Tokens.icon.sm, { zIndex = z + 5, color = Tokens.color.featherWhite })
		check.AnchorPoint = Vector2.new(1, 0)
		check.Position = UDim2.new(1, -Tokens.spacing.xs, 0, Tokens.spacing.xs)
		check.Visible = false
		local lock = Icons.lock(face, Tokens.icon.sm, { zIndex = z + 5, color = Tokens.color.inkMuted })
		lock.AnchorPoint = Vector2.new(1, 0)
		lock.Position = UDim2.new(1, -Tokens.spacing.xs, 0, Tokens.spacing.xs)
		lock.Visible = false
		local ribbon: TextLabel? = nil
		if grand then
			-- One word. "GRAND PRIZE" did not fit the card's width and was rendering clipped, and a
			-- truncated label on the one card meant to feel like the prize is worse than a shorter one.
			ribbon = FrameKit.badge(face, "Ribbon", "JACKPOT", Tokens.color.ember, z + 6);
			(ribbon :: TextLabel).AnchorPoint = Vector2.new(0.5, 0);
			(ribbon :: TextLabel).Position = UDim2.new(0.5, 0, 0, header.Size.Y.Offset + Tokens.spacing.xs)
		end
		return {
			root = root,
			face = face,
			scale = scale,
			stroke = stroke,
			header = header,
			title = title,
			amount = amount,
			footer = footer,
			hit = hit,
			gems = gems,
			rays = rays,
			check = check,
			lock = lock,
			ribbon = ribbon,
			stopPulse = nil,
		}
	end

	-- All eight days in one 4x2 grid, the way the reference reads: the grand prize is a card in the
	-- run, not a separate banner under it.
	local cells: { Cell } = {}
	for _, entry in ipairs(rewards) do
		table.insert(cells, buildCell(grid, entry, entry.day == finalDay))
	end

	local grace = FrameKit.text(container, "Grace", "", "caption", { zIndex = z, color = Tokens.color.inkMuted, wrap = true })
	grace.LayoutOrder = 5
	grace.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 6)

	local claim = Button.build(container, {
		text = "Claim",
		variant = "primary",
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(1, 0, 0, tap),
		zIndex = z + 1,
	})
	claim.button.LayoutOrder = 6
	claim.button.Name = "ClaimButton"
	table.insert(cleanups, claim.destroy)
	api.setInitialFocus(claim.button)

	local doClaim: () -> ()

	-- Steps a piece of artwork back without making anything appear that was not there.
	--
	-- Writing the dim straight onto every descendant would set BackgroundTransparency on the icon's own
	-- container - a frame that is deliberately invisible - and paint a solid box behind the gem. Each
	-- part's own starting transparency is remembered the first time it is touched, and the dim is
	-- applied as a fraction of what is left, so a part that began invisible stays invisible.
	local BASE_ATTRIBUTE = "SFE_BaseTransparency"
	local function fadePart(part: Instance, property: string, amount: number)
		local key = BASE_ATTRIBUTE .. property
		local base = part:GetAttribute(key)
		if typeof(base) ~= "number" then
			base = (part :: any)[property]
			part:SetAttribute(key, base)
		end
		(part :: any)[property] = base + (1 - base) * amount
	end
	local function fade(root: GuiObject, amount: number)
		if root:IsA("ImageLabel") or root:IsA("ImageButton") then
			fadePart(root, "ImageTransparency", amount)
		elseif root:IsA("Frame") then
			fadePart(root, "BackgroundTransparency", amount)
		end
		for _, piece in ipairs(root:GetDescendants()) do
			if piece:IsA("ImageLabel") or piece:IsA("ImageButton") then
				fadePart(piece, "ImageTransparency", amount)
			elseif piece:IsA("Frame") then
				fadePart(piece, "BackgroundTransparency", amount)
			elseif piece:IsA("UIStroke") then
				fadePart(piece, "Transparency", amount)
			end
		end
	end

	local function evaluation(): any?
		local projection = deps.profile.projection
		return projection and projection.rewards.daily or nil
	end

	local function render()
		local daily = evaluation()
		if not daily then
			return
		end
		receivedAt = os.clock()
		local calendar = DailyRewards.calendar(cfg, { dayIndex = daily.dayIndex } :: any)
		local ready = daily.status == "ready" or daily.status == "reset"
		for index, cell in ipairs(cells) do
			local info = calendar[index]
			local grand = index == finalDay
			-- Just the number. The gem sitting directly underneath says what it is, and "Gems" written
			-- eight times down a grid is the wall of text the picture was supposed to replace.
			cell.amount.Text = "+" .. info.gems
			cell.title.Text = "DAY " .. info.day
			cell.check.Visible = info.claimed
			-- The grand prize says GRAND PRIZE. A padlock pinned over its header as well read as a
			-- rendering fault rather than a state.
			cell.lock.Visible = not info.claimed and not info.current and not grand
			cell.footer.Active = false
			cell.footer.AutoButtonColor = false
			for _, gem in ipairs(cell.gems) do
				gem.Visible = true
			end
			if info.claimed then
				-- Done: cool, quiet, and unmistakably finished.
				cell.face.BackgroundColor3 = Tokens.color.tealTint
				cell.header.BackgroundColor3 = Tokens.color.leafDeep
				cell.stroke.Color = Tokens.color.leafDeep
				cell.stroke.Thickness = Tokens.stroke.standard
				cell.amount.TextColor3 = Tokens.color.leafDeep
				cell.footer.BackgroundColor3 = Tokens.color.leafBright
				cell.footer.TextColor3 = Tokens.color.featherWhite
				cell.footer.Text = "CLAIMED"
			elseif info.current and ready then
				-- The one card that wants to be pressed: bright face, gold frame, green Claim.
				cell.face.BackgroundColor3 = Tokens.color.creamPill
				cell.header.BackgroundColor3 = Tokens.color.goldDeep
				cell.stroke.Color = Tokens.color.gold
				cell.stroke.Thickness = Tokens.stroke.frame
				cell.amount.TextColor3 = Tokens.color.goldDeep
				cell.footer.BackgroundColor3 = Tokens.color.success
				cell.footer.TextColor3 = Tokens.color.featherWhite
				cell.footer.Text = "CLAIM"
				cell.footer.Active = true
				cell.footer.AutoButtonColor = true
			elseif info.current then
				-- Today, but the nest has not opened yet: the footer becomes the countdown.
				cell.face.BackgroundColor3 = Tokens.color.surfaceAlt
				cell.header.BackgroundColor3 = Tokens.color.strawDeep
				cell.stroke.Color = Tokens.color.gold
				cell.stroke.Thickness = Tokens.stroke.bold
				cell.amount.TextColor3 = Tokens.color.goldDeep
				cell.footer.BackgroundColor3 = Tokens.color.tealPanel
				cell.footer.TextColor3 = Tokens.color.featherWhite
				cell.footer.Text = "--:--:--"
			else
				-- Not yet, rather than dead.
				--
				-- A locked day used to take an inkMuted header and inkMuted type, so five of the eight
				-- cards were grey-brown slabs and the grid read as mostly switched off. It keeps the
				-- warm straw of the set and simply steps back: paler header, cocoa type, and the gems
				-- dimmed rather than the whole card drained. The reward is still the thing you see.
				cell.face.BackgroundColor3 = Tokens.color.surface
				cell.header.BackgroundColor3 = Tokens.color.straw
				cell.stroke.Color = Tokens.color.strawDeep
				cell.stroke.Thickness = Tokens.stroke.standard
				cell.amount.TextColor3 = Tokens.color.cocoa
				cell.footer.BackgroundColor3 = Tokens.color.creamDeep
				cell.footer.TextColor3 = Tokens.color.cocoa
				cell.footer.Text = "DAY " .. info.day
			end
			-- The artwork carries the state: full strength on the day you can claim, stepped back while
			-- locked, quiet once it is done. The rays only ever burn behind the claimable card, which is
			-- what makes one card out of eight obviously the one to press.
			local claimable = info.current and ready
			local dim = if claimable then 0 elseif info.claimed then 0.45 else 0.3
			for _, gem in ipairs(cell.gems) do
				gem.Visible = true
				fade(gem, dim)
			end
			if cell.rays then
				cell.rays.Visible = claimable or (grand and not info.claimed)
			end
			if grand and not info.claimed then
				-- The grand prize keeps a gold face even while locked, so the run has a visible end.
				cell.face.BackgroundColor3 = if info.current and ready then Tokens.color.goldLight else Tokens.color.creamPill
				cell.header.BackgroundColor3 = Tokens.color.goldDeep
				cell.stroke.Color = Tokens.color.goldDeep
				cell.stroke.Thickness = Tokens.stroke.frame
				cell.amount.TextColor3 = Tokens.color.goldDeep
			end
			if cell.ribbon then
				cell.ribbon.Visible = not info.claimed
			end
			-- Only the claimable day breathes; everything else stays still.
			local shouldPulse = info.current and ready
			if shouldPulse and not cell.stopPulse then
				cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.055)
			elseif not shouldPulse and cell.stopPulse then
				cell.stopPulse()
				cell.stopPulse = nil
			end
			local notch = notches[index]
			if notch then
				notch.BackgroundColor3 = if info.claimed
					then Tokens.color.leafBright
					elseif info.current then Tokens.color.gold
					else Tokens.color.creamDeep
			end
		end
		if ready then
			status.Text = if daily.status == "reset"
				then "Streak rested - restarting on Day 1"
				else string.format("Day %d of %d is ready", daily.dayIndex, finalDay)
			timer.Text = "Nest open"
			claim.setEnabled(true)
			claim.setText(string.format("Claim %d Gems", daily.gems))
		else
			status.Text = string.format("Day %d of %d", daily.dayIndex, finalDay)
			claim.setEnabled(false)
			claim.setText("Come back soon")
		end
		if daily.graceRemainingSeconds and daily.graceRemainingSeconds > 0 and daily.status == "early" then
			grace.Text = string.format(
				"Claim within %s of the next day to keep your streak. After Day %d the nest loops back to Day 1.",
				clock(cfg.dailyRewardRules.gracePeriodSeconds - cfg.dailyRewardRules.claimCooldownSeconds),
				finalDay
			)
		else
			grace.Text =
				string.format("Claim once a day to walk the nest from Day 1 to Day %d. Miss two days and it rests back to Day 1.", finalDay)
		end
	end

	function doClaim()
		claim.setPending(true, "Opening...")
		local result = deps.net:request("DailyClaim", nil)
		claim.setPending(false)
		if result.ok then
			local data = result.data
			if data.replayed then
				-- The server already paid this streak day: say so, and pay nothing on screen.
				deps.toasts:push("Today's Gems are already in your pouch", "info")
			else
				deps.audio:play(Tokens.sound.rewardLand)
				deps.haptics:pulse(0.6, 0.1)
				local cell = cells[data.dayIndex]
				if cell then
					if cell.stopPulse then
						cell.stopPulse()
						cell.stopPulse = nil
					end
					cell.scale.Scale = 1.12
					Tween.scale(cell.scale, "release", motion, 1)
					Confetti.burst(cell.root, {
						origin = UDim2.fromScale(0.5, 0.5),
						count = if data.dayIndex == finalDay then 44 else 22,
						spread = if data.dayIndex == finalDay then 220 else 130,
						motion = motion,
						tier = deps.quality and deps.quality:tier() or nil,
						zIndex = z + 8,
					})
					deps.audio:play(Tokens.sound.uiConfetti)
				end
				deps.toasts:reward(string.format("Day %d nest opened", data.dayIndex), data.gems)
			end
		else
			deps.audio:play(Tokens.sound.uiError)
			deps.toasts:push(if result.message == "not_ready" then "The nest is still resting" else "Could not claim right now", "warning")
		end
	end

	table.insert(cleanups, claim.button.Activated:Connect(doClaim))
	-- A card is pressable only in the state that set Active, so Locked, Claimed and countdown cards
	-- swallow the press instead of firing a request the server would only refuse.
	for _, cell in ipairs(cells) do
		-- `Active` on the footer is still what says "this card is claimable"; the hit layer only decides
		-- where a finger has to land, so both fire the same guarded handler.
		local function pressed()
			if cell.footer.Active then
				doClaim()
			end
		end
		table.insert(cleanups, cell.footer.Activated:Connect(pressed))
		table.insert(cleanups, cell.hit.Activated:Connect(pressed))
	end
	if api.registerDebug then
		api.registerDebug({
			claim = doClaim,
			report = function()
				local daily = evaluation()
				local states = {}
				for _, cell in ipairs(cells) do
					table.insert(states, cell.state.Text)
				end
				return {
					status = daily and daily.status or "none",
					dayIndex = daily and daily.dayIndex or 0,
					claimEnabled = claim.button.Active,
					claimText = (function()
						local label = claim.button:FindFirstChild("Label")
						return if label and label:IsA("TextLabel") then label.Text else claim.button.Text
					end)(),
					headline = status.Text,
					timer = timer.Text,
					days = #cells,
					cellStates = states,
					finaleGems = cells[finalDay] and cells[finalDay].amount.Text or "",
				}
			end,
		})
	end

	render()
	table.insert(cleanups, deps.profile.changed:Connect(render))
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function()
			local daily = evaluation()
			if daily and daily.status == "early" then
				local remaining = daily.nextClaimInSeconds - (os.clock() - receivedAt)
				local formatted = clock(remaining)
				timer.Text = string.format("Next nest opens in %s", formatted)
				-- The waiting day counts down on its own card, which is where the eye already is.
				local cell = cells[daily.dayIndex]
				if cell and not cell.footer.Active then
					cell.footer.Text = formatted
				end
			end
		end)
	)
	deps.audio:play(Tokens.sound.uiOpen)

	return function()
		for _, cell in ipairs(cells) do
			if cell.stopPulse then
				cell.stopPulse()
			end
		end
		for _, cleanup in ipairs(cleanups) do
			if type(cleanup) == "function" then
				cleanup()
			else
				cleanup:Disconnect()
			end
		end
		deps.audio:play(Tokens.sound.uiClose)
	end
end

return DailyModal
