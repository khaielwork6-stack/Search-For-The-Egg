--!strict
-- Modal ownership foundation. Wraps the pure ModalReducer, renders modal shells through the
-- component library, suspends gameplay input while a blocking modal is open, blurs the world behind
-- blocking modals (ref-counted, owner recipe timings), restores controller selection/focus on close,
-- and handles Cancel/Back. Exactly one blocking modal owns focus at a time (STATE_MACHINES 13).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage.Shared
local ModalReducer = require(Shared.Reducers.ModalReducer)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local Motion = require(Shared.Design.Motion)
local ModalShell = require(script.Parent.Parent.UI.Components.ModalShell)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)

local ModalController = {}
ModalController.__index = ModalController

export type Api = {
	close: () -> (),
	shell: ModalShell.Shell,
	setInitialFocus: (object: GuiObject) -> (),
	focus: (object: GuiObject?) -> (),
	minimumTapTarget: number,
	registerDebug: ((actions: { [string]: (...any) -> any }) -> ())?,
}

export type ModalController = typeof(setmetatable(
	{} :: {
		_state: ModalReducer.ModalState,
		_input: any,
		_accessibility: any,
		_config: { [string]: any },
		_views: { [string]: any },
		_focusMemory: { [string]: GuiObject? },
		_externalUnlock: boolean?,
		_unlockBound: boolean?,
		mouseUnlocked: boolean?,
		_debug: { [string]: { [string]: (...any) -> any } },
		_blur: BlurEffect,
		gui: ScreenGui,
		stage: Frame,
		changed: any,
		opened: any,
		closed: any,
		_trove: Trove.Trove,
	},
	ModalController
))

function ModalController.new(input: any, accessibility: any, config: { [string]: any }, parent: Instance?): ModalController
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Modals"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = Tokens.zIndex.modal
	gui.Parent = parent or Players.LocalPlayer:WaitForChild("PlayerGui")
	local _, _, stage = SafeArea.applyScale(gui, config)

	local blur = Lighting:FindFirstChild("SFE_ModalBlur") :: BlurEffect?
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "SFE_ModalBlur"
		blur.Size = 0
		blur.Enabled = false
		blur.Parent = Lighting
	end

	local self = setmetatable({
		_state = ModalReducer.create(),
		_input = input,
		_accessibility = accessibility,
		_config = config,
		_views = {},
		_focusMemory = {},
		_debug = {},
		_blur = blur :: BlurEffect,
		gui = gui,
		stage = stage,
		changed = Signal.new(),
		opened = Signal.new(),
		closed = Signal.new(),
		_trove = Trove.new(),
	}, ModalController)
	self._trove:add(gui)
	self._trove:add(input.actionBegan:Connect(function(action)
		if action == "Cancel" or action == "Back" then
			local top = ModalReducer.top(self._state)
			if top then
				self:close(top.id)
			end
		end
	end))
	return self
end

local function firstSelectable(root: Instance): GuiObject?
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiObject") and descendant.Selectable and descendant.Visible then
			return descendant
		end
	end
	return nil
end

-- First-person mouse lock (owner requirement): the player stays in first person at all times; a
-- blocking menu unlocks the mouse and shows the cursor, closing it hides the cursor and re-centres.
-- Passive HUD never touches this. Classic camera at zoom 0.5 keeps the first-person view while the
-- cursor is free (LockFirstPerson would re-lock the mouse every frame).
function ModalController._applyMouseLock(self: ModalController)
	local player = Players.LocalPlayer
	local blocking = ModalReducer.isBlocking(self._state) or self._externalUnlock == true
	if blocking then
		player.CameraMinZoomDistance = 0.5
		player.CameraMaxZoomDistance = 0.5
		player.CameraMode = Enum.CameraMode.Classic
		UserInputService.MouseIconEnabled = true
		if not self._unlockBound then
			-- The camera module re-locks the mouse every frame at first-person zoom; free it after it.
			self._unlockBound = true
			RunService:BindToRenderStep("SFE_MenuMouseUnlock", Enum.RenderPriority.Camera.Value + 1, function()
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end)
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	else
		if self._unlockBound then
			self._unlockBound = false
			RunService:UnbindFromRenderStep("SFE_MenuMouseUnlock")
		end
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
	self.mouseUnlocked = blocking
end

-- Non-modal blocking surfaces (the cutscene overlay with its Skip button) borrow the same unlock.
function ModalController.setExternalUnlock(self: ModalController, unlocked: boolean)
	self._externalUnlock = unlocked
	self:_applyMouseLock()
end

function ModalController._applyBlur(self: ModalController)
	local motion = self._accessibility:motionSettings()
	local blur = self._blur
	if ModalReducer.isBlocking(self._state) then
		local recipe = Motion.recipe("blurIn", motion)
		blur.Enabled = true
		TweenService:Create(blur, Motion.tweenInfo(recipe), { Size = recipe.size or 14 }):Play()
	else
		local recipe = Motion.recipe("blurOut", motion)
		local tween = TweenService:Create(blur, Motion.tweenInfo(recipe), { Size = 0 })
		tween:Play()
		tween.Completed:Once(function()
			if not ModalReducer.isBlocking(self._state) then
				blur.Enabled = false
			end
		end)
	end
end

-- Opens a modal with a view builder: build(container, api) -> optional cleanup fn.
function ModalController.open(
	self: ModalController,
	id: string,
	priority: number,
	blocking: boolean,
	build: (container: ScrollingFrame, api: Api) -> (() -> ())?,
	title: string?,
	options: { wide: boolean?, compact: boolean?, icon: string? }?
): (boolean, string?)
	local next, err = ModalReducer.open(self._state, { id = id, priority = priority, blocking = blocking })
	if not next then
		return false, err
	end
	self._focusMemory[id] = GuiService.SelectedObject
	self._state = ModalReducer.normalize(next)
	local minimumTap = SafeArea.minimumTapTarget(self.gui, self._config)
	local shell = ModalShell.create(self.stage, {
		title = title or id,
		id = id,
		blocking = blocking,
		motion = self._accessibility:motionSettings(),
		minimumTapTarget = minimumTap,
		wide = options and options.wide or false,
		compact = options and options.compact or false,
		icon = options and options.icon or nil,
	})
	local initialFocus: GuiObject? = nil
	local api: Api = {
		close = function()
			self:close(id)
		end,
		shell = shell,
		setInitialFocus = function(object)
			initialFocus = object
		end,
		focus = function(object)
			GuiService.SelectedObject = object
		end,
		minimumTapTarget = minimumTap,
		registerDebug = if RunService:IsStudio()
			then function(actions)
				self._debug[id] = actions
			end
			else nil,
	}
	local cleanup = build(shell.content, api)
	self._views[id] = { shell = shell, cleanup = cleanup }
	shell.closeButton.Activated:Connect(function()
		self:close(id)
	end)
	if blocking then
		self._input:setSuspended(true)
	end
	-- Controller focus lands on the builder's choice (when it is selectable), else the first
	-- actionable control, else Close. Selection never falls to nil while a modal is open.
	local focusTarget = initialFocus
	if not focusTarget or not focusTarget.Selectable or not focusTarget.Visible then
		focusTarget = firstSelectable(shell.content)
	end
	GuiService.SelectedObject = focusTarget or shell.closeButton
	shell.open()
	self:_applyBlur()
	self:_applyMouseLock()
	self.changed:Fire(self._state)
	self.opened:Fire(id)
	return true, nil
end

function ModalController.close(self: ModalController, id: string): boolean
	local next = ModalReducer.close(self._state, id)
	if not next then
		return false
	end
	self._state = ModalReducer.normalize(next)
	local view = self._views[id]
	self._views[id] = nil
	self._debug[id] = nil
	if view then
		if view.cleanup then
			view.cleanup()
		end
		view.shell.close()
	end
	self._input:setSuspended(ModalReducer.isBlocking(self._state))
	-- Restore focus to the previous modal's first control, else the remembered selection.
	local top = ModalReducer.top(self._state)
	if top and self._views[top.id] then
		local topShell = self._views[top.id].shell
		GuiService.SelectedObject = firstSelectable(topShell.content) or topShell.closeButton
	else
		local remembered = self._focusMemory[id]
		GuiService.SelectedObject = if remembered and remembered.Parent then remembered else nil
	end
	self._focusMemory[id] = nil
	self:_applyBlur()
	self:_applyMouseLock()
	self.changed:Fire(self._state)
	self.closed:Fire(id)
	return true
end

-- Studio-only: invokes a builder-registered debug action on an open modal (same client routine the
-- button would call). Returns nil when the modal or action is unknown.
function ModalController.debugAction(self: ModalController, id: string, action: string, ...: any): any
	local actions = self._debug[id]
	local fn = actions and actions[action]
	if not fn then
		return nil
	end
	return fn(...)
end

function ModalController.closeAll(self: ModalController)
	for id in pairs(table.clone(self._views)) do
		self:close(id)
	end
end

function ModalController.isOpen(self: ModalController, id: string): boolean
	return ModalReducer.isOpen(self._state, id)
end

function ModalController.openCount(self: ModalController): number
	return #self._state.stack
end

function ModalController.isBlocking(self: ModalController): boolean
	return ModalReducer.isBlocking(self._state)
end

function ModalController.topId(self: ModalController): string?
	local top = ModalReducer.top(self._state)
	return top and top.id or nil
end

function ModalController.blurSize(self: ModalController): number
	return if self._blur.Enabled then self._blur.Size else 0
end

function ModalController.destroy(self: ModalController)
	self:closeAll()
	self._blur.Enabled = false
	self._trove:destroy()
	self.changed:Destroy()
	self.opened:Destroy()
	self.closed:Destroy()
end

ModalController.Priority = ModalReducer.Priority

return ModalController
