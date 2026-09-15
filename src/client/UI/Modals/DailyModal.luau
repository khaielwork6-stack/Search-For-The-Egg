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
local DailyRewards = require(Shared.Domain.DailyRewards)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
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
	gems: { Frame },
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
	local header, headerFace = FrameKit.tile(container, "Header", {
		fill = Tokens.color.tealPanel,
		deep = Tokens.color.tealDeep,
		zIndex = z,
		radius = Tokens.radius.lg,
		size = UDim2.new(1, 0, 0, tap + Tokens.spacing.md),
	})
	header.LayoutOrder = 1
	local headerPad = Instance.new("UIPadding")
	headerPad.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	headerPad.PaddingRight = UDim.new(0, Tokens.spacing.md)
	headerPad.Parent = headerFace
	local status = FrameKit.text(headerFace, "Status", "", "heading", { zIndex = z + 2, color = Tokens.color.featherWhite })
	status.AnchorPoint = Vector2.new(0, 0)
	status.Position = UDim2.fromOffset(0, Tokens.spacing.sm)
	status.Size = UDim2.new(1, 0, 0, Tokens.typography.heading.size + 2)
	local timer = FrameKit.text(headerFace, "Timer", "", "caption", { zIndex = z + 2, color = Tokens.color.tealTint })
	timer.AnchorPoint = Vector2.new(0, 1)
	timer.Position = UDim2.new(0, 0, 1, -Tokens.spacing.sm)
	timer.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 2)

	-- Progress rail: claimed days filled, today's notch bright, the rest dark.
	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.BackgroundTransparency = 1
	rail.Size = UDim2.new(1, 0, 0, 10)
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
		notchCorner.CornerRadius = UDim.new(0, Tokens.radius.sm)
		notchCorner.Parent = notch
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
	layout.CellSize = UDim2.new(1 / COLUMNS, -Tokens.spacing.sm, 0, math.floor(tap * 2.9))
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
		local stroke = root:FindFirstChild("Outline") :: UIStroke

		-- Header band: the day number, always legible against the card whatever state it is in.
		local header = Instance.new("Frame")
		header.Name = "Header"
		header.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + Tokens.spacing.sm)
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

		local amount = FrameKit.text(face, "Amount", "", "heading", {
			align = Enum.TextXAlignment.Center,
			zIndex = z + 3,
			color = Tokens.color.goldDeep,
		})
		amount.AnchorPoint = Vector2.new(0.5, 0)
		amount.Position = UDim2.new(0.5, 0, 0, header.Size.Y.Offset + Tokens.spacing.xs)
		amount.Size = UDim2.new(1, 0, 0, Tokens.typography.heading.size + 2)

		-- Artwork band. The grand prize gets a cluster rather than a single stone, so "a lot" reads
		-- without writing the word.
		local art = Instance.new("Frame")
		art.Name = "Art"
		art.BackgroundTransparency = 1
		art.AnchorPoint = Vector2.new(0.5, 0.5)
		art.Position = UDim2.fromScale(0.5, 0.56)
		art.Size = UDim2.new(1, -Tokens.spacing.sm, 0.44, 0)
		art.ZIndex = z + 3
		art.Parent = face
		local gems: { Frame } = {}
		local cluster = if grand then 5 else 1
		for index = 1, cluster do
			local px = if grand then Tokens.icon.md else Tokens.icon.lg
			local gem = Icons.gem(art, px, { zIndex = z + 4 })
			gem.AnchorPoint = Vector2.new(0.5, 0.5)
			if grand then
				local ring = (index - 1) / cluster * math.pi * 2
				gem.Position = UDim2.fromScale(0.5 + math.cos(ring) * 0.2, 0.5 + math.sin(ring) * 0.26)
			else
				gem.Position = UDim2.fromScale(0.5, 0.5)
			end
			table.insert(gems, gem)
		end

		-- Footer: the state, and the only place a card can be pressed.
		local footer = Instance.new("TextButton")
		footer.Name = "Footer"
		footer.AnchorPoint = Vector2.new(0.5, 1)
		footer.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.xs)
		footer.Size = UDim2.new(1, -Tokens.spacing.sm, 0, Tokens.typography.caption.size + Tokens.spacing.sm)
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
			ribbon = FrameKit.badge(face, "Ribbon", "GRAND PRIZE", Tokens.color.ember, z + 6);
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
			gems = gems,
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
			cell.amount.Text = string.format("+%d Gems", info.gems)
			cell.title.Text = "DAY " .. info.day
			cell.check.Visible = info.claimed
			cell.lock.Visible = not info.claimed and not info.current
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
				cell.face.BackgroundColor3 = Tokens.color.surface
				cell.header.BackgroundColor3 = Tokens.color.inkMuted
				cell.stroke.Color = Tokens.color.strawDeep
				cell.stroke.Thickness = Tokens.stroke.standard
				cell.amount.TextColor3 = Tokens.color.inkMuted
				cell.footer.BackgroundColor3 = Tokens.color.creamDeep
				cell.footer.TextColor3 = Tokens.color.inkMuted
				cell.footer.Text = "LOCKED"
				for _, gem in ipairs(cell.gems) do
					gem.Visible = true
				end
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
				cell.stopPulse = Tween.pulseLoop(cell.scale, motion, 0.04)
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
			timer.Text = string.format("%d Gems waiting in the nest", daily.gems)
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
		table.insert(
			cleanups,
			cell.footer.Activated:Connect(function()
				if cell.footer.Active then
					doClaim()
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
