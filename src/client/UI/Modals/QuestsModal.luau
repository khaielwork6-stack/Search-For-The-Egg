--!strict
-- Daily Quests.
--
-- Three cards: what to do, how far along, what it pays, and a claim. Everything shown comes from the
-- profile projection, so progress that lands while the panel is open updates in place without it
-- being reopened, and the panel never decides whether a quest is complete or claimable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local Depth = require(script.Parent.Parent.Components.Depth)
local Tween = require(script.Parent.Parent.Components.Tween)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Icons = require(script.Parent.Parent.Components.Icons)
local Confetti = require(script.Parent.Parent.Components.Confetti)

local QuestsModal = {}

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

type Card = {
	root: Frame,
	face: Frame,
	scale: UIScale,
	stroke: UIStroke,
	title: TextLabel,
	detail: TextLabel,
	count: TextLabel,
	fill: Frame,
	meter: FrameKit.MeterHandle,
	reward: TextLabel,
	claim: Button.Handle,
	questId: string?,
}

local function clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
end

function QuestsModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local slots = deps.config.dailyQuests.slots
	local receivedAt = os.clock()

	-- The reset line sits in a dark band across the top of the list.
	local header, headerFace = FrameKit.tile(container, "Header", {
		fill = Tokens.color.surfaceAlt,
		deep = Tokens.color.panelDeep,
		zIndex = z,
		radius = Tokens.radius.lg,
		size = UDim2.new(1, 0, 0, tap),
	})
	header.LayoutOrder = 1
	local headerPad = Instance.new("UIPadding")
	headerPad.PaddingLeft = UDim.new(0, Tokens.spacing.md)
	headerPad.PaddingRight = UDim.new(0, Tokens.spacing.md)
	headerPad.Parent = headerFace
	local resetLine = FrameKit.text(headerFace, "Reset", "", "heading", { zIndex = z + 2, color = Tokens.color.featherWhite })
	resetLine.Size = UDim2.fromScale(1, 1)
	FrameKit.outline(resetLine, 2.5)

	local list = Instance.new("Frame")
	list.Name = "Quests"
	list.BackgroundTransparency = 1
	list.Size = UDim2.fromScale(1, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.LayoutOrder = 2
	list.ZIndex = z
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list
	list.Parent = container

	local cards: { Card } = {}
	for slot = 1, slots do
		local root, face = FrameKit.tile(list, "Quest" .. slot, {
			fill = Tokens.color.surface,
			deep = Tokens.color.panelDeep,
			zIndex = z + 1,
			radius = Tokens.radius.md,
			size = UDim2.new(1, 0, 0, math.floor(tap * 2.1)),
		})
		root.LayoutOrder = slot
		local scale = Instance.new("UIScale")
		scale.Parent = root
		local stroke = Depth.keylineOf(root) :: UIStroke
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, Tokens.spacing.md)
		pad.PaddingRight = UDim.new(0, Tokens.spacing.md)
		pad.PaddingTop = UDim.new(0, Tokens.spacing.sm)
		pad.Parent = face

		local badge = Icons.star(face, Tokens.icon.lg, { zIndex = z + 3, color = Tokens.color.gold })
		badge.AnchorPoint = Vector2.new(0, 0)
		badge.Position = UDim2.fromOffset(0, 2)

		local title = FrameKit.text(face, "Title", "", "heading", { zIndex = z + 3, color = Tokens.color.featherWhite })
		title.Position = UDim2.fromOffset(Tokens.icon.lg + Tokens.spacing.sm, 0)
		title.Size = UDim2.new(1, -(Tokens.icon.lg + Tokens.spacing.sm + tap * 2.6), 0, Tokens.typography.heading.size + 2)
		FrameKit.outline(title, 2.5)
		local detail = FrameKit.text(face, "Detail", "", "caption", { zIndex = z + 3, color = Tokens.color.inkMuted })
		detail.Position = UDim2.fromOffset(Tokens.icon.lg + Tokens.spacing.sm, Tokens.typography.heading.size + 4)
		detail.Size = UDim2.new(1, -(Tokens.icon.lg + Tokens.spacing.sm + tap * 2.6), 0, Tokens.typography.caption.size + 2)
		FrameKit.outline(detail, 2)

		-- Progress rail: the kit's dark meter with a green fill, and the exact numbers over it so
		-- the bar is never the only reading.
		local track, fill, meter = FrameKit.meter(face, "Track", 0, { height = 14, fill = Tokens.color.success, zIndex = z + 3 })
		track.AnchorPoint = Vector2.new(0, 1)
		track.Position = UDim2.new(0, 0, 1, -Tokens.spacing.sm)
		track.Size = UDim2.new(1, -(tap * 2.6), 0, 14)
		local count = FrameKit.text(face, "Count", "", "caption", {
			zIndex = z + 5,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		count.AnchorPoint = Vector2.new(0, 1)
		count.Position = UDim2.new(0, 0, 1, -Tokens.spacing.sm + 1)
		count.Size = UDim2.new(1, -(tap * 2.6), 0, 14)
		FrameKit.outline(count, 2)

		local reward = FrameKit.text(face, "Reward", "", "label", {
			zIndex = z + 3,
			color = Tokens.color.gold,
			align = Enum.TextXAlignment.Right,
		})
		reward.AnchorPoint = Vector2.new(1, 0)
		reward.Position = UDim2.fromScale(1, 0)
		reward.Size = UDim2.fromOffset(tap * 2.4, Tokens.typography.label.size + 2)
		FrameKit.outline(reward, 2.5)

		local claim = Button.build(face, {
			text = "CLAIM",
			variant = "success",
			minimumTapTarget = tap,
			motion = motion,
			-- Wide enough for IN PROGRESS at label size; the pill never truncates its own state.
			size = UDim2.fromOffset(math.floor(tap * 3.3), math.floor(tap * 0.9)),
			textSize = Tokens.typography.label.size,
			zIndex = z + 4,
			sound = function()
				deps.audio:play(Tokens.sound.uiTap)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
		})
		claim.button.AnchorPoint = Vector2.new(1, 1)
		claim.button.Position = UDim2.new(1, 0, 1, -Tokens.spacing.xs)
		table.insert(cleanups, claim.destroy)

		local card: Card = {
			root = root,
			face = face,
			scale = scale,
			stroke = stroke,
			title = title,
			detail = detail,
			count = count,
			fill = fill,
			meter = meter,
			reward = reward,
			claim = claim,
			questId = nil,
		}
		table.insert(cards, card)
		table.insert(
			cleanups,
			claim.button.Activated:Connect(function()
				local questId = card.questId
				if not questId then
					return
				end
				claim.setPending(true, "...")
				local result = deps.net:request("QuestClaim", { questId = questId })
				claim.setPending(false)
				if result.ok and not result.data.replayed then
					deps.audio:play(Tokens.sound.rewardLand)
					deps.haptics:pulse(0.6, 0.1)
					card.scale.Scale = 1.06
					Tween.scale(card.scale, "release", motion, 1)
					Confetti.burst(card.root, {
						origin = UDim2.fromScale(0.5, 0.5),
						count = 20,
						spread = 140,
						motion = motion,
						tier = deps.quality and deps.quality:tier() or nil,
						zIndex = z + 8,
					})
					deps.toasts:reward("Quest complete", result.data.gems)
				elseif result.ok then
					deps.toasts:push("Those Gems are already in your pouch", "info")
				else
					deps.audio:play(Tokens.sound.uiError)
					deps.toasts:push(
						if result.message == "not_complete" then "Not finished yet" else "Could not claim right now",
						"warning"
					)
				end
			end)
		)
	end

	if cards[1] then
		api.setInitialFocus(cards[1].claim.button)
	end

	local function questsOf(): ({ [string]: any }, number)
		local projection = deps.profile.projection
		local rewards = projection and projection.rewards
		return (rewards and rewards.quests) or {}, (rewards and rewards.questResetInSeconds) or 0
	end

	-- A card's face is re-lit, not just recoloured, so the sheen follows the state.
	local function paint(card: Card, face: Color3)
		card.face.BackgroundColor3 = face
		Depth.applySheen(card.face, face)
	end

	local function render()
		local quests, resetIn = questsOf()
		receivedAt = os.clock()
		resetLine.Text = string.format("Daily Quests  ·  resets in %s", clock(resetIn))
		for index, card in ipairs(cards) do
			local quest = quests[index]
			card.root.Visible = quest ~= nil
			if quest then
				card.questId = quest.id
				card.title.Text = quest.title
				card.detail.Text = quest.detail
				card.count.Text = string.format("%d / %d", quest.progress, quest.target)
				card.reward.Text = string.format("+%d Gems", quest.gems)
				card.meter.set(math.clamp(quest.fraction or 0, 0, 1))
				if quest.claimed then
					card.stroke.Color = Tokens.color.leafDeep
					card.stroke.Thickness = Tokens.stroke.frame
					paint(card, Tokens.color.surfaceAlt)
					card.meter.setColor(Tokens.color.leafDeep)
					card.claim.setVariant("success")
					card.claim.setText("CLAIMED")
					card.claim.setEnabled(false)
				elseif quest.complete then
					card.stroke.Color = Tokens.color.gold
					card.stroke.Thickness = Tokens.stroke.frame
					paint(card, Tokens.color.surface)
					card.meter.setColor(Tokens.color.success)
					card.claim.setVariant("success")
					card.claim.setText("CLAIM")
					card.claim.setEnabled(true)
				else
					card.stroke.Color = Tokens.color.outline
					card.stroke.Thickness = Tokens.stroke.frame
					paint(card, Tokens.color.surface)
					card.meter.setColor(Tokens.color.success)
					card.claim.setVariant("secondary")
					card.claim.setText("IN PROGRESS")
					card.claim.setEnabled(false)
				end
			else
				card.questId = nil
			end
		end
	end

	render()
	-- Progress arrives on the profile projection, so a quest that completes mid-session fills in
	-- without the panel being closed and reopened.
	table.insert(cleanups, deps.profile.changed:Connect(render))
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function()
			local _, resetIn = questsOf()
			if resetIn > 0 then
				resetLine.Text = string.format("Daily Quests  ·  resets in %s", clock(resetIn - (os.clock() - receivedAt)))
			end
		end)
	)

	if api.registerDebug then
		api.registerDebug({
			report = function()
				local quests = questsOf()
				local rows = {}
				for _, card in ipairs(cards) do
					table.insert(rows, string.format("%s|%s|%s", tostring(card.questId), card.count.Text, card.claim.button.Text))
				end
				return { count = #quests, rows = rows, header = resetLine.Text }
			end,
			claim = function(index)
				local card = cards[tonumber(index) or 1]
				if card and card.questId then
					return deps.net:request("QuestClaim", { questId = card.questId })
				end
				return { ok = false, message = "no_quest" }
			end,
		})
	end

	return function()
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

return QuestsModal
