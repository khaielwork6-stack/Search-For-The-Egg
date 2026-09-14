--!strict
-- Tool Rack modal: tool-skin categories with owned-only equips. Owned skins show Equip / Equipped;
-- unowned event skins show where they come from. Equips are validated server-side and the modal
-- re-renders from the profile projection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Tokens = require(Shared.Design.Tokens)
local SkinCatalog = require(Shared.Domain.SkinCatalog)
local FrameKit = require(script.Parent.Parent.Components.Frame)
local Button = require(script.Parent.Parent.Components.Button)
local Skin = require(script.Parent.Parent.Components.Skin)

local InventoryModal = {}

export type Deps = {
	net: any,
	profile: any,
	audio: any,
	haptics: any,
	accessibility: any,
	config: { [string]: any },
	minimumTapTarget: number,
	toasts: any,
}

function InventoryModal.build(container: ScrollingFrame, api: any, deps: Deps): () -> ()
	local cleanups: { any } = {}
	local cfg = deps.config
	local motion = deps.accessibility:motionSettings()
	local tap = deps.minimumTapTarget
	local z = container.ZIndex + 1
	local catalog = SkinCatalog.all(cfg)

	type Row = { frame: Frame, label: TextLabel, equip: any, skin: SkinCatalog.Skin }
	local rows: { Row } = {}
	local order = 0
	local firstButton: TextButton? = nil
	for _, category in ipairs(SkinCatalog.CATEGORIES) do
		order += 1
		local header = FrameKit.heading(container, "Header_" .. category, cfg.tools[category].displayName, z)
		header.LayoutOrder = order
		for _, skin in ipairs(catalog) do
			if skin.category ~= category then
				continue
			end
			order += 1
			local frame = FrameKit.row(container, "Skin_" .. skin.id, tap + Tokens.spacing.md, z)
			frame.LayoutOrder = order
			local toolIcon = Skin.icon(frame, "tool." .. skin.category .. ".normal", Tokens.icon.lg, z + 1)
			if toolIcon then
				toolIcon.AnchorPoint = Vector2.new(0, 0.5)
				toolIcon.Position = UDim2.fromScale(0, 0.5)
			end
			local label = FrameKit.text(frame, "Label", skin.displayName, "body", { zIndex = z + 1, color = Tokens.color.inkStrong })
			label.Position = UDim2.fromOffset(if toolIcon then Tokens.icon.lg + Tokens.spacing.sm else 0, 0)
			label.Size = UDim2.new(1, -(tap * 3) - (if toolIcon then Tokens.icon.lg + Tokens.spacing.sm else 0), 1, 0)
			local equip = Button.build(frame, {
				text = "Equip",
				variant = "teal",
				minimumTapTarget = tap,
				motion = motion,
				size = UDim2.fromOffset(tap * 3 - Tokens.spacing.md, tap - Tokens.spacing.xs),
				zIndex = z + 1,
				textSize = Tokens.typography.body.size,
				sound = function()
					deps.audio:play(Tokens.sound.uiTap)
				end,
				hoverSound = function()
					deps.audio:play(Tokens.sound.uiHover)
				end,
				onActivated = function()
					local result = deps.net:request("InventoryEquip", { category = skin.category, itemId = skin.id })
					if result.ok then
						deps.audio:play(Tokens.sound.uiConfirm)
						deps.haptics:pulse(0.3, 0.06)
					else
						deps.audio:play(Tokens.sound.uiError)
						deps.toasts:push(
							if result.code == "not_authorized" then "You do not own that skin yet" else "Could not equip",
							"warning"
						)
					end
				end,
			})
			equip.button.AnchorPoint = Vector2.new(1, 0.5)
			equip.button.Position = UDim2.fromScale(1, 0.5)
			firstButton = firstButton or equip.button
			table.insert(cleanups, equip.destroy)
			table.insert(rows, { frame = frame, label = label, equip = equip, skin = skin })
		end
	end
	if firstButton then
		api.setInitialFocus(firstButton)
	end

	local function render()
		local projection = deps.profile.projection
		if not projection then
			return
		end
		for _, row in ipairs(rows) do
			local owned = projection.inventory.toolSkins[row.skin.id] == true
			local equipped = projection.inventory.equippedSkins[row.skin.category] == row.skin.id
			row.equip.button.Visible = owned
			row.equip.setText(if equipped then "Equipped" else "Equip")
			row.equip.setEnabled(not equipped)
			row.equip.setSelected(equipped)
			row.label.Text = if owned
				then row.skin.displayName .. (if equipped then "  -  on the rack" else "")
				else row.skin.displayName .. "  -  from the Moonlit Chest"
			row.label.TextColor3 = if owned then Tokens.color.inkStrong else Tokens.color.inkMuted
			row.frame.BackgroundTransparency = if owned then 0 else 0.5
		end
	end

	render()
	table.insert(cleanups, deps.profile.changed:Connect(render))
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

return InventoryModal
