--!strict
-- Modal ownership foundation. Wraps the pure ModalReducer, renders modal shells through the
-- component library, suspends gameplay input while a blocking modal is open, restores controller
-- selection/focus on close, and handles Cancel/Back.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage.Shared
local ModalReducer = require(Shared.Reducers.ModalReducer)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local Tokens = require(Shared.Design.Tokens)
local ModalShell = require(script.Parent.Parent.UI.Components.ModalShell)
local SafeArea = require(script.Parent.Parent.UI.SafeArea)

local ModalController = {}
ModalController.__index = ModalController

export type ModalController = typeof(setmetatable(
	{} :: {
		_state: ModalReducer.ModalState,
		_input: any,
		_accessibility: any,
		_config: { [string]: any },
		_views: { [string]: any },
		_focusMemory: { [string]: GuiObject? },
		gui: ScreenGui,
		changed: any,
		_trove: Trove.Trove,
	},
	ModalController
))

function ModalController.new(input: any, accessibility: any, config: { [string]: any }): ModalController
	local gui = Instance.new("ScreenGui")
	gui.Name = "SFE_Modals"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = Tokens.zIndex.modal
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	SafeArea.applyScale(gui, config)

	local self = setmetatable({
		_state = ModalReducer.create(),
		_input = input,
		_accessibility = accessibility,
		_config = config,
		_views = {},
		_focusMemory = {},
		gui = gui,
		changed = Signal.new(),
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

-- Opens a modal with a view builder: build(container, api) -> optional cleanup fn.
function ModalController.open(
	self: ModalController,
	id: string,
	priority: number,
	blocking: boolean,
	build: (container: Frame, api: { close: () -> () }) -> (() -> ())?,
	title: string?
): (boolean, string?)
	local next, err = ModalReducer.open(self._state, { id = id, priority = priority, blocking = blocking })
	if not next then
		return false, err
	end
	self._focusMemory[id] = GuiService.SelectedObject
	self._state = ModalReducer.normalize(next)
	local shell = ModalShell.create(self.gui, {
		title = title or id,
		blocking = blocking,
		motion = self._accessibility:motionSettings(),
		minimumTapTarget = SafeArea.minimumTapTarget(self.gui, self._config),
	})
	local cleanup = build(shell.content, {
		close = function()
			self:close(id)
		end,
	})
	self._views[id] = { shell = shell, cleanup = cleanup }
	shell.closeButton.Activated:Connect(function()
		self:close(id)
	end)
	if blocking then
		self._input:setSuspended(true)
	end
	GuiService.SelectedObject = shell.closeButton
	shell.open()
	self.changed:Fire(self._state)
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
	if view then
		if view.cleanup then
			view.cleanup()
		end
		view.shell.close()
	end
	self._input:setSuspended(ModalReducer.isBlocking(self._state))
	-- Restore focus to the previous modal's close button, else the remembered selection.
	local top = ModalReducer.top(self._state)
	if top and self._views[top.id] then
		GuiService.SelectedObject = self._views[top.id].shell.closeButton
	else
		local remembered = self._focusMemory[id]
		GuiService.SelectedObject = if remembered and remembered.Parent then remembered else nil
	end
	self._focusMemory[id] = nil
	self.changed:Fire(self._state)
	return true
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

function ModalController.destroy(self: ModalController)
	for id in pairs(table.clone(self._views)) do
		self:close(id)
	end
	self._trove:destroy()
	self.changed:Destroy()
end

ModalController.Priority = ModalReducer.Priority

return ModalController
