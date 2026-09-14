--!strict
-- Party screen: a big destination card on the left (preview, name, CREATE PARTY, difficulty
-- chips with lock states, party size stepper, one green CREATE) beside the stack of destination
-- cards on the right (the Henhouse, the locked Cellar with its win requirement). Once a party
-- exists the left card turns into the party panel: members, status, the 5 s countdown, leader
-- actions and Leave. Open parties can still be joined from the list beneath. Every action is a
-- validated request; the screen only re-renders from projections.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Dialog = require(script.Parent.Parent.Components.Dialog)
local Skin = require(script.Parent.Parent.Components.Skin)
local Icons = require(script.Parent.Parent.Components.Icons)

local PartyModal = {}

export type Deps = {
	net: any,
	party: any,
	profile: any,
	modals: any?,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
}

local DIFFICULTIES = { "normal", "hard" }
local DIFFICULTY_LABEL = { normal = "NORMAL", hard = "HARD" }
local CHAPTERS = { "chapter1", "chapter2" }
-- Card art and tint per chapter (the Cellar is dark, the Henhouse is daylight).
local CHAPTER_LOOK: { [string]: { art: string, fill: Color3, deep: Color3, short: string } } = {
	chapter1 = { art = "station.party.normal", fill = Tokens.color.leaf, deep = Tokens.color.leafDeep, short = "HENHOUSE" },
	chapter2 = { art = "station.event.normal", fill = Color3.fromRGB(70, 60, 96), deep = Color3.fromRGB(40, 32, 58), short = "CELLAR" },
}

local function unlockedFor(profile: any, chapter: string, difficulty: string): boolean
	local projection = profile.projection
	if not projection then
		return false
	end
	local difficulties = projection.progression.unlockedDifficulties[chapter]
	return difficulties ~= nil and difficulties[difficulty] == true
end

-- "1 Win" style requirement from the chapter's unlock policy.
local function requirementText(cfg: { [string]: any }, chapterKey: string, difficulty: string): string
	local chapter = cfg.chapters[chapterKey]
	local policy = chapter and chapter[difficulty .. "Unlock"]
	if policy and policy.type == "chapterWins" then
		local count = policy.count or 1
		return string.format("%d Win%s", count, if count == 1 then "" else "s")
	end
	return "Locked"
end

function PartyModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local selected = { chapter = "chapter1", difficulty = "normal", size = 1 }
	local maxSize = cfg.project.maxPartyPlayers
	local pending = false

	local function toast(text: string, tone: string?)
		deps.toasts:push(text, tone or "warning")
	end

	local function failureCopy(result: any): string
		local message = result.message or result.code
		if message == "chapter_unavailable" then
			return "That chapter opens in a later update"
		elseif message == "destination_locked" then
			return "Someone in the party has not unlocked that yet"
		elseif message == "party_full" then
			return "That party is full"
		elseif message == "party_not_found" then
			return "That party has already set off"
		elseif message == "not_leader" then
			return "Only the party leader can do that"
		elseif message == "already_in_party" then
			return "Leave your current party first"
		elseif message == "not_ready" then
			return "The party is not ready to start"
		elseif result.code == "rate_limited" then
			return "One moment..."
		end
		return "Party action unavailable"
	end

	local function send(fn: () -> any, successSound: string?)
		if pending then
			return
		end
		pending = true
		local result = fn()
		pending = false
		if result.ok then
			deps.audio:play(successSound or Tokens.sound.uiConfirm)
			deps.haptics:pulse(0.3, 0.06)
		else
			deps.audio:play(Tokens.sound.uiError)
			toast(failureCopy(result))
		end
		return result
	end

	-- Layout: left card + right column ------------------------------------------------------------
	local layoutHeight = tap * 9 + Tokens.spacing.lg
	local layout = Instance.new("Frame")
	layout.Name = "Layout"
	layout.BackgroundTransparency = 1
	layout.Size = UDim2.new(1, 0, 0, layoutHeight)
	layout.LayoutOrder = 1
	layout.ZIndex = z
	layout.Parent = container

	local _, leftFace = FrameKit.tile(layout, "Main", {
		fill = Tokens.color.featherWhite,
		deep = Tokens.color.strawDeep,
		zIndex = z + 1,
		radius = Tokens.radius.xl,
		size = UDim2.new(0.58, -Tokens.spacing.sm, 1, 0),
	})
	local right = Instance.new("Frame")
	right.Name = "Destinations"
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.fromScale(1, 0)
	right.Size = UDim2.new(0.42, -Tokens.spacing.sm, 1, 0)
	right.BackgroundTransparency = 1
	right.ZIndex = z + 1
	right.Parent = layout
	local rightLayout = Instance.new("UIListLayout")
	rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rightLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	rightLayout.Parent = right

	-- Preview band on the left card.
	local previewHeight = tap * 3 + Tokens.spacing.md
	local preview = Instance.new("Frame")
	preview.Name = "Preview"
	preview.Size = UDim2.new(1, 0, 0, previewHeight)
	preview.BackgroundColor3 = Tokens.color.sky
	preview.BorderSizePixel = 0
	preview.ZIndex = z + 2
	preview.ClipsDescendants = true
	local previewCorner = Instance.new("UICorner")
	previewCorner.CornerRadius = UDim.new(0, Tokens.radius.xl)
	previewCorner.Parent = preview
	local previewGradient = Instance.new("UIGradient")
	previewGradient.Rotation = 90
	previewGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Tokens.color.sky),
		ColorSequenceKeypoint.new(0.62, Color3.fromRGB(184, 222, 236)),
		ColorSequenceKeypoint.new(1, Tokens.color.leaf),
	})
	previewGradient.Parent = preview
	preview.Parent = leftFace
	Skin.texture(preview, "texture.rays", { zIndex = z + 2, transparency = 0.8, color = Tokens.color.featherWhite })
	local previewArt = Skin.icon(preview, CHAPTER_LOOK.chapter1.art, tap * 2 + Tokens.spacing.lg, z + 3)
	if previewArt then
		previewArt.AnchorPoint = Vector2.new(0.5, 0.5)
		previewArt.Position = UDim2.fromScale(0.5, 0.42)
	end
	local previewTitle = FrameKit.text(preview, "Title", "", "display", {
		zIndex = z + 4,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	previewTitle.AnchorPoint = Vector2.new(0.5, 1)
	previewTitle.Position = UDim2.new(0.5, 0, 1, -(Tokens.typography.label.size + Tokens.spacing.md))
	previewTitle.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 4)
	previewTitle.TextSize = Tokens.typography.display.size - 2
	FrameKit.outline(previewTitle, 3)
	local previewSub = FrameKit.text(preview, "Sub", "CREATE PARTY", "label", {
		zIndex = z + 4,
		color = Tokens.color.featherWhite,
		align = Enum.TextXAlignment.Center,
	})
	previewSub.AnchorPoint = Vector2.new(0.5, 1)
	previewSub.Position = UDim2.new(0.5, 0, 1, -Tokens.spacing.sm)
	previewSub.Size = UDim2.new(1, 0, 0, Tokens.typography.label.size + 4)
	FrameKit.outline(previewSub, 2.2)

	-- Create panel under the preview.
	local createPanel = Instance.new("Frame")
	createPanel.Name = "Create"
	createPanel.BackgroundTransparency = 1
	createPanel.Position = UDim2.fromOffset(0, previewHeight)
	createPanel.Size = UDim2.new(1, 0, 1, -previewHeight)
	createPanel.ZIndex = z + 2
	local createPadding = Instance.new("UIPadding")
	createPadding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	createPadding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	createPadding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	createPadding.PaddingBottom = UDim.new(0, Tokens.spacing.md)
	createPadding.Parent = createPanel
	createPanel.Parent = leftFace

	-- Difficulty chips.
	local chipsRow = Instance.new("Frame")
	chipsRow.Name = "Difficulty"
	chipsRow.BackgroundTransparency = 1
	chipsRow.Size = UDim2.new(1, 0, 0, tap)
	chipsRow.ZIndex = z + 3
	local chipsLayout = Instance.new("UIListLayout")
	chipsLayout.FillDirection = Enum.FillDirection.Horizontal
	chipsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	chipsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	chipsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	chipsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	chipsLayout.Parent = chipsRow
	chipsRow.Parent = createPanel
	local chips: { [string]: { handle: any, lock: Frame } } = {}
	local render
	for index, difficulty in ipairs(DIFFICULTIES) do
		local handle = Button.build(chipsRow, {
			text = DIFFICULTY_LABEL[difficulty],
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap * 3, tap - Tokens.spacing.xs),
			zIndex = z + 3,
			textSize = Tokens.typography.title.size - 2,
			sound = function()
				deps.audio:play(Tokens.sound.uiSelect)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				if not unlockedFor(deps.profile, selected.chapter, difficulty) then
					deps.audio:play(Tokens.sound.uiError)
					toast(
						string.format(
							"%s unlocks after %s",
							DIFFICULTY_LABEL[difficulty],
							requirementText(cfg, selected.chapter, difficulty)
						),
						"info"
					)
					return
				end
				selected.difficulty = difficulty
				if deps.party.party and deps.party:isLeader() then
					send(function()
						return deps.party:setDestination(selected.chapter, difficulty)
					end)
				end
				render()
			end,
		})
		handle.button.LayoutOrder = index
		handle.button.Name = "Difficulty_" .. difficulty
		local lock = Icons.lock(handle.button, Tokens.icon.sm + 2, { zIndex = z + 6, color = Tokens.color.gold })
		lock.AnchorPoint = Vector2.new(0, 0.5)
		lock.Position = UDim2.new(0, Tokens.spacing.sm, 0.5, -2)
		lock.Visible = false
		chips[difficulty] = { handle = handle, lock = lock }
		table.insert(cleanups, handle.destroy)
	end

	-- Party size.
	local sizeCaption = FrameKit.text(createPanel, "SizeCaption", "PARTY SIZE:", "title", {
		zIndex = z + 3,
		color = Tokens.color.inkStrong,
		align = Enum.TextXAlignment.Center,
	})
	sizeCaption.Position = UDim2.fromOffset(0, tap + Tokens.spacing.xs)
	sizeCaption.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 4)
	local sizeRow = Instance.new("Frame")
	sizeRow.Name = "SizeRow"
	sizeRow.BackgroundTransparency = 1
	sizeRow.Position = UDim2.fromOffset(0, tap + Tokens.typography.title.size + Tokens.spacing.md)
	sizeRow.Size = UDim2.new(1, 0, 0, tap + Tokens.spacing.xs)
	sizeRow.ZIndex = z + 3
	sizeRow.Parent = createPanel
	local sizeValue, sizeValueFace = FrameKit.tile(sizeRow, "Value", {
		fill = Tokens.color.creamPill,
		deep = Tokens.color.strawDeep,
		zIndex = z + 3,
		radius = Tokens.radius.md,
		lip = 4,
		size = UDim2.fromOffset(tap + Tokens.spacing.lg, tap + Tokens.spacing.xs),
	})
	sizeValue.AnchorPoint = Vector2.new(0.5, 0.5)
	sizeValue.Position = UDim2.fromScale(0.5, 0.5)
	local sizeText = FrameKit.text(sizeValueFace, "Text", "1", "display", {
		zIndex = z + 4,
		color = Tokens.color.inkStrong,
		align = Enum.TextXAlignment.Center,
	})
	sizeText.Size = UDim2.fromScale(1, 1)
	sizeText.TextYAlignment = Enum.TextYAlignment.Center
	local function stepper(name: string, glyph: string, direction: number)
		local handle = Button.build(sizeRow, {
			text = glyph,
			variant = "secondary",
			minimumTapTarget = tap,
			motion = motion,
			size = UDim2.fromOffset(tap + Tokens.spacing.xs, tap + Tokens.spacing.xs),
			zIndex = z + 3,
			textSize = Tokens.typography.display.size,
			sound = function()
				deps.audio:play(Tokens.sound.uiTab)
			end,
			hoverSound = function()
				deps.audio:play(Tokens.sound.uiHover)
			end,
			onActivated = function()
				selected.size = math.clamp(selected.size + direction, 1, maxSize)
				sizeText.Text = tostring(selected.size)
			end,
		})
		handle.button.Name = name
		handle.button.AnchorPoint = Vector2.new(0.5, 0.5)
		handle.button.Position = UDim2.new(0.5, direction * (tap + Tokens.spacing.lg + Tokens.spacing.md), 0.5, 0)
		table.insert(cleanups, handle.destroy)
		return handle
	end
	stepper("Fewer", "-", -1)
	stepper("More", "+", 1)
	local hint = FrameKit.text(createPanel, "Hint", "Friends can join at the pad while the party forms", "caption", {
		zIndex = z + 3,
		color = Tokens.color.inkMuted,
		align = Enum.TextXAlignment.Center,
		wrap = true,
	})
	hint.Position = UDim2.fromOffset(0, tap * 2 + Tokens.typography.title.size + Tokens.spacing.lg + Tokens.spacing.sm)
	hint.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size * 2 + 4)

	local createHandle = Button.build(createPanel, {
		text = "CREATE",
		variant = "success",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.new(0.8, 0, 0, tap + Tokens.spacing.sm),
		zIndex = z + 3,
		textSize = Tokens.typography.display.size - 6,
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		hoverSound = function()
			deps.audio:play(Tokens.sound.uiHover)
		end,
		onActivated = function()
			local created = send(function()
				return deps.party:create(selected.chapter, selected.difficulty, selected.size)
			end, Tokens.sound.partyReady)
			if created and created.ok then
				-- Back to the world: the pad board and the banner carry the wait and the countdown.
				api.close()
			end
		end,
	})
	createHandle.button.Name = "SoloButton"
	createHandle.button.AnchorPoint = Vector2.new(0.5, 1)
	createHandle.button.Position = UDim2.fromScale(0.5, 1)
	table.insert(cleanups, createHandle.destroy)
	api.setInitialFocus(createHandle.button)

	-- Party panel (replaces the create panel while in a party).
	local partyPanel = Instance.new("Frame")
	partyPanel.Name = "Party"
	partyPanel.BackgroundTransparency = 1
	partyPanel.Position = UDim2.fromOffset(0, previewHeight)
	partyPanel.Size = UDim2.new(1, 0, 1, -previewHeight)
	partyPanel.ZIndex = z + 2
	partyPanel.Visible = false
	local partyPadding = Instance.new("UIPadding")
	partyPadding.PaddingLeft = UDim.new(0, Tokens.spacing.lg)
	partyPadding.PaddingRight = UDim.new(0, Tokens.spacing.lg)
	partyPadding.PaddingTop = UDim.new(0, Tokens.spacing.sm)
	partyPadding.PaddingBottom = UDim.new(0, Tokens.spacing.md)
	partyPadding.Parent = partyPanel
	partyPanel.Parent = leftFace
	local status = FrameKit.text(partyPanel, "Status", "", "title", {
		zIndex = z + 3,
		color = Tokens.color.goldDeep,
		align = Enum.TextXAlignment.Center,
	})
	status.Size = UDim2.new(1, 0, 0, Tokens.typography.title.size + 4)
	local members = Instance.new("Frame")
	members.Name = "Members"
	members.BackgroundTransparency = 1
	members.Position = UDim2.fromOffset(0, Tokens.typography.title.size + Tokens.spacing.sm)
	members.Size = UDim2.new(1, 0, 1, -(Tokens.typography.title.size + Tokens.spacing.sm + tap + Tokens.spacing.md))
	members.ZIndex = z + 3
	local membersLayout = Instance.new("UIListLayout")
	membersLayout.SortOrder = Enum.SortOrder.LayoutOrder
	membersLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	membersLayout.Parent = members
	members.Parent = partyPanel
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.BackgroundTransparency = 1
	actions.AnchorPoint = Vector2.new(0, 1)
	actions.Position = UDim2.fromScale(0, 1)
	actions.Size = UDim2.new(1, 0, 0, tap)
	actions.ZIndex = z + 3
	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Padding = UDim.new(0, Tokens.spacing.sm)
	actionsLayout.HorizontalFlex = Enum.UIFlexAlignment.Fill
	actionsLayout.Parent = actions
	actions.Parent = partyPanel
	local startHandle = Button.build(actions, {
		text = "START",
		variant = "success",
		sound = function()
			deps.audio:play(Tokens.sound.uiTap)
		end,
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(140, tap),
		zIndex = z + 3,
		onActivated = function()
			send(function()
				return deps.party:start()
			end, Tokens.sound.partyReady)
		end,
	})
	startHandle.button.LayoutOrder = 1
	startHandle.button.Name = "StartButton"
	local cancelHandle = Button.build(actions, {
		text = "Cancel",
		variant = "secondary",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(140, tap),
		zIndex = z + 3,
		onActivated = function()
			send(function()
				return deps.party:cancel()
			end, Tokens.sound.uiCancel)
		end,
	})
	cancelHandle.button.LayoutOrder = 2
	local leaveHandle = Button.build(actions, {
		text = "Leave",
		variant = "danger",
		minimumTapTarget = tap,
		motion = motion,
		size = UDim2.fromOffset(140, tap),
		zIndex = z + 3,
		onActivated = function()
			Dialog.open(deps.modals, {
				id = "confirm_leave_party",
				title = "Leave party?",
				message = "Your seat opens up for someone else and the leader keeps the destination.",
				confirmText = "Leave",
				cancelText = "Stay",
				tone = "warning",
				audio = deps.audio,
				accessibility = deps.accessibility,
				config = deps.config,
				onConfirm = function()
					send(function()
						return deps.party:leave()
					end, Tokens.sound.uiCancel)
				end,
			})
		end,
	})
	leaveHandle.button.LayoutOrder = 3
	for _, handle in ipairs({ startHandle, cancelHandle, leaveHandle }) do
		table.insert(cleanups, handle.destroy)
	end

	-- Destination cards (right column) ------------------------------------------------------------
	type Card = {
		tile: Frame,
		face: Frame,
		hit: TextButton,
		lockBadge: Frame,
		lockText: TextLabel,
		lockNote: TextLabel,
		name: TextLabel,
		art: ImageLabel?,
	}
	local cards: { [string]: Card } = {}
	local cardHeight = math.floor((layoutHeight - Tokens.spacing.sm) / 2)
	for index, chapterKey in ipairs(CHAPTERS) do
		local look = CHAPTER_LOOK[chapterKey]
		local chapter = cfg.chapters[chapterKey]
		local tile, face = FrameKit.tile(right, "Card_" .. chapterKey, {
			fill = look.fill,
			deep = look.deep,
			zIndex = z + 2,
			radius = Tokens.radius.lg,
			size = UDim2.new(1, 0, 0, cardHeight),
		})
		tile.LayoutOrder = index
		Skin.texture(face, "texture.rays", { zIndex = z + 3, transparency = 0.82, color = Tokens.color.featherWhite })
		local art = Skin.icon(face, look.art, tap * 2, z + 4)
		if art then
			art.AnchorPoint = Vector2.new(0.5, 0.5)
			art.Position = UDim2.fromScale(0.5, 0.42)
		end
		local name = FrameKit.text(face, "Name", string.upper(look.short), "title", {
			zIndex = z + 5,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Right,
		})
		name.AnchorPoint = Vector2.new(1, 1)
		name.Position = UDim2.new(1, -Tokens.spacing.md, 1, -Tokens.spacing.sm)
		name.Size = UDim2.new(1, -Tokens.spacing.md * 2, 0, Tokens.typography.title.size + 4)
		FrameKit.outline(name, 2.4)
		local lockBadge = Instance.new("Frame")
		lockBadge.Name = "Lock"
		lockBadge.AnchorPoint = Vector2.new(0.5, 0.5)
		lockBadge.Position = UDim2.fromScale(0.5, 0.4)
		lockBadge.Size = UDim2.fromOffset(tap + Tokens.spacing.xs, tap + Tokens.spacing.xs)
		lockBadge.BackgroundColor3 = Tokens.color.gold
		lockBadge.ZIndex = z + 6
		local lockCorner = Instance.new("UICorner")
		lockCorner.CornerRadius = UDim.new(0, Tokens.radius.md)
		lockCorner.Parent = lockBadge
		local lockStroke = Instance.new("UIStroke")
		lockStroke.Thickness = Tokens.stroke.bold
		lockStroke.Color = Tokens.color.outline
		lockStroke.Parent = lockBadge
		local lockGlyph = Icons.lock(lockBadge, Tokens.icon.lg, { zIndex = z + 7, color = Tokens.color.inkStrong })
		lockGlyph.AnchorPoint = Vector2.new(0.5, 0.5)
		lockGlyph.Position = UDim2.fromScale(0.5, 0.5)
		lockBadge.Parent = face
		local lockText = FrameKit.text(face, "LockText", "", "display", {
			zIndex = z + 6,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		lockText.AnchorPoint = Vector2.new(0.5, 0)
		lockText.Position = UDim2.new(0.5, 0, 0.4, tap / 2 + Tokens.spacing.sm)
		lockText.Size = UDim2.new(1, 0, 0, Tokens.typography.display.size + 4)
		lockText.TextSize = Tokens.typography.display.size - 4
		FrameKit.outline(lockText, 3)
		local lockNote = FrameKit.text(face, "LockNote", "Coming soon", "caption", {
			zIndex = z + 6,
			color = Tokens.color.featherWhite,
			align = Enum.TextXAlignment.Center,
		})
		lockNote.AnchorPoint = Vector2.new(0.5, 0)
		lockNote.Position = UDim2.new(0.5, 0, 0.4, tap / 2 + Tokens.spacing.sm + Tokens.typography.display.size + 2)
		lockNote.Size = UDim2.new(1, 0, 0, Tokens.typography.caption.size + 4)
		FrameKit.outline(lockNote, 2)
		local hit = Instance.new("TextButton")
		hit.Name = "Hit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = z + 8
		hit.Parent = tile
		table.insert(
			cleanups,
			hit.Activated:Connect(function()
				local available = chapter.availableDifficulties and chapter.availableDifficulties.normal == true
				if not available then
					deps.audio:play(Tokens.sound.uiError)
					toast(chapter.displayName .. " opens in a later update", "info")
					return
				end
				if not unlockedFor(deps.profile, chapterKey, "normal") then
					deps.audio:play(Tokens.sound.uiError)
					toast(string.format("%s unlocks after %s", chapter.displayName, requirementText(cfg, chapterKey, "normal")), "info")
					return
				end
				deps.audio:play(Tokens.sound.uiSelect)
				selected.chapter = chapterKey
				if not unlockedFor(deps.profile, chapterKey, selected.difficulty) then
					selected.difficulty = "normal"
				end
				if deps.party.party and deps.party:isLeader() then
					send(function()
						return deps.party:setDestination(chapterKey, selected.difficulty)
					end)
				end
				render()
			end)
		)
		cards[chapterKey] = {
			tile = tile,
			face = face,
			hit = hit,
			lockBadge = lockBadge,
			lockText = lockText,
			lockNote = lockNote,
			name = name,
			art = art,
		}
	end

	-- Open parties list --------------------------------------------------------------------------
	FrameKit.heading(container, "ListHeader", "Parties forming", z).LayoutOrder = 2
	local listFrame = Instance.new("Frame")
	listFrame.Name = "OpenParties"
	listFrame.BackgroundTransparency = 1
	listFrame.Size = UDim2.fromScale(1, 0)
	listFrame.AutomaticSize = Enum.AutomaticSize.Y
	listFrame.LayoutOrder = 3
	listFrame.ZIndex = z
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, Tokens.spacing.xs)
	listLayout.Parent = listFrame
	listFrame.Parent = container
	local emptyList =
		FrameKit.text(container, "EmptyList", "No open parties right now", "caption", { zIndex = z, color = Tokens.color.inkMuted })
	emptyList.LayoutOrder = 4

	local rowHandles: { any } = {}
	local function renderList()
		for _, handle in ipairs(rowHandles) do
			handle.destroy()
		end
		table.clear(rowHandles)
		for _, child in ipairs(listFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local mine = deps.party.party
		local shown = 0
		for index, entry in ipairs(deps.party.list or {}) do
			if mine and entry.partyId == mine.partyId then
				continue
			end
			if entry.phase ~= "Forming" and entry.phase ~= "Ready" then
				continue
			end
			shown += 1
			local row = FrameKit.row(listFrame, "Party" .. index, tap + Tokens.spacing.sm, z)
			row.LayoutOrder = index
			local text = FrameKit.text(
				row,
				"Text",
				string.format(
					"%s's party  -  %s %s  -  %d/%d",
					entry.leaderName or "Forager",
					cfg.chapters[entry.chapter] and cfg.chapters[entry.chapter].displayName or entry.chapter,
					DIFFICULTY_LABEL[entry.difficulty] or entry.difficulty,
					#entry.members,
					entry.maxMembers
				),
				"body",
				{ zIndex = z + 1 }
			)
			text.Size = UDim2.new(1, -(tap * 2 + Tokens.spacing.md), 1, 0)
			local joinHandle = Button.build(row, {
				text = "Join",
				variant = "teal",
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.fromOffset(tap * 2, tap),
				zIndex = z + 1,
				onActivated = function()
					send(function()
						return deps.party:join(entry.partyId)
					end)
				end,
			})
			joinHandle.button.AnchorPoint = Vector2.new(1, 0.5)
			joinHandle.button.Position = UDim2.fromScale(1, 0.5)
			joinHandle.setEnabled(#entry.members < entry.maxMembers)
			table.insert(rowHandles, joinHandle)
		end
		emptyList.Visible = shown == 0
		listFrame.Visible = shown > 0
	end

	-- Rendering ------------------------------------------------------------------------------------
	render = function()
		local projection = deps.profile.projection
		local party = deps.party.party
		local isLeader = deps.party:isLeader()
		local chapterKey = if party then party.chapter else selected.chapter
		local difficulty = if party then party.difficulty else selected.difficulty
		local chapter = cfg.chapters[chapterKey]
		previewTitle.Text = string.upper(chapter and chapter.displayName or chapterKey)
		previewSub.Text = if party then "YOUR PARTY" else "CREATE PARTY"
		if previewArt then
			Skin.apply(previewArt, CHAPTER_LOOK[chapterKey].art)
		end
		-- Difficulty chips reflect unlocks for the chosen chapter.
		for _, key in ipairs(DIFFICULTIES) do
			local chip = chips[key]
			local unlocked = projection ~= nil and unlockedFor(deps.profile, chapterKey, key)
			local available = chapter and chapter.availableDifficulties and chapter.availableDifficulties[key] == true
			local active = unlocked and available
			chip.handle.setVariant(if key == difficulty and active then "teal" else "secondary")
			chip.handle.setSelected(key == difficulty and active)
			chip.handle.setText(if active then DIFFICULTY_LABEL[key] else "    " .. requirementText(cfg, chapterKey, key))
			chip.lock.Visible = not active
			chip.handle.setEnabled(party == nil or isLeader)
		end
		-- Destination cards.
		for key, card in pairs(cards) do
			local cardChapter = cfg.chapters[key]
			local available = cardChapter.availableDifficulties and cardChapter.availableDifficulties.normal == true
			local unlocked = projection ~= nil and unlockedFor(deps.profile, key, "normal")
			local open = available and unlocked
			local outline = card.tile:FindFirstChild("Outline") :: UIStroke?
			if outline then
				outline.Color = if key == chapterKey then Tokens.color.featherWhite else Tokens.color.outline
				outline.Thickness = if key == chapterKey then Tokens.stroke.frame + 1 else Tokens.stroke.frame
			end
			card.lockBadge.Visible = not open
			card.lockText.Visible = not open
			card.lockText.Text = requirementText(cfg, key, "normal")
			card.lockNote.Visible = not available
			card.face.BackgroundTransparency = if open then 0 else 0.15
			if card.art then
				card.art.ImageTransparency = if open then 0 else 0.5
			end
			card.name.TextTransparency = if open then 0 else 0.2
		end
		-- Panels.
		createPanel.Visible = party == nil
		partyPanel.Visible = party ~= nil
		for _, child in ipairs(members:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		if party then
			for index, memberId in ipairs(party.members) do
				local row = FrameKit.row(members, "Member" .. index, tap - Tokens.spacing.xs, z + 3)
				row.LayoutOrder = index
				local name = party.memberNames and party.memberNames[tostring(memberId)] or ("Forager " .. tostring(memberId))
				local suffix = (if memberId == party.leaderUserId then "  -  leader" else "")
					.. (if table.find(party.lockedUserIds or {}, memberId) then "  -  needs the unlock" else "")
				local label = FrameKit.text(row, "Name", name .. suffix, "body", {
					zIndex = z + 4,
					color = if memberId == Players.LocalPlayer.UserId then Tokens.color.goldDeep else Tokens.color.inkStrong,
				})
				label.Size = UDim2.fromScale(1, 1)
			end
			for index = #party.members + 1, party.maxMembers do
				local row = FrameKit.row(members, "Empty" .. index, tap - Tokens.spacing.xs, z + 3)
				row.LayoutOrder = index
				row.BackgroundTransparency = 0.7
				FrameKit.text(row, "Name", "Open seat", "caption", { zIndex = z + 4, color = Tokens.color.inkMuted }).Size =
					UDim2.fromScale(1, 1)
			end
			local phase = party.phase
			local size = party.maxMembers or maxSize
			if phase == "Countdown" then
				status.Text = "Setting off..."
			elseif phase == "Reserving" or phase == "Teleporting" then
				status.Text = "Finding a henhouse..."
			elseif not party.valid then
				status.Text = if party.invalidReason == "destination_locked"
					then "Waiting on an unlock for the chosen destination"
					else "Choose an available destination"
			elseif #party.members >= size then
				status.Text = "Party full - setting off"
			elseif isLeader then
				status.Text = string.format("%d / %d  -  waiting for %d more", #party.members, size, size - #party.members)
			else
				status.Text = "Waiting for the leader"
			end
			startHandle.button.Visible = isLeader and phase ~= "Countdown" and phase ~= "Reserving" and phase ~= "Teleporting"
			startHandle.setEnabled(party.valid == true)
			cancelHandle.button.Visible = isLeader and phase == "Countdown"
			leaveHandle.button.Visible = phase ~= "Reserving" and phase ~= "Teleporting"
		end
		renderList()
	end

	render()
	table.insert(cleanups, deps.party.changed:Connect(render))
	table.insert(cleanups, deps.party.listChanged:Connect(renderList))
	table.insert(cleanups, deps.profile.changed:Connect(render))
	-- Countdown text ticks from the projection deadline; the server owns the deadline.
	table.insert(
		cleanups,
		RunService.RenderStepped:Connect(function()
			local remaining = deps.party:countdownRemaining()
			if remaining and partyPanel.Visible then
				status.Text = string.format("Setting off in %d...", math.max(1, math.ceil(remaining)))
			end
		end)
	)
	deps.audio:play(Tokens.sound.uiOpen)

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

return PartyModal
