--!strict
-- Input abstraction: semantic actions (Primary, Interact, Cancel, Back) bound through
-- ContextActionService for keyboard/mouse, touch, and gamepad; input-mode detection so prompts
-- swap without rebuilding UI; began/ended signals so hold tools can cancel on release or focus loss.

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local InputController = {}
InputController.__index = InputController

export type Mode = "mouse" | "touch" | "gamepad"
export type Action = "Primary" | "Interact" | "Cancel" | "Back" | "Menu" | "Cursor"

export type InputController = typeof(setmetatable(
	{} :: {
		_mode: Mode,
		_held: { [string]: boolean },
		_suspended: boolean,
		modeChanged: any,
		actionBegan: any,
		actionEnded: any,
		_trove: Trove.Trove,
	},
	InputController
))

local BINDINGS: { [Action]: { any } } = {
	Primary = { Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2 },
	Interact = { Enum.KeyCode.E, Enum.KeyCode.ButtonX },
	Cancel = { Enum.KeyCode.Escape, Enum.KeyCode.ButtonB },
	Back = { Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB },
	Menu = { Enum.KeyCode.Tab, Enum.KeyCode.Backquote, Enum.KeyCode.ButtonY },
	Cursor = { Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt },
}

local function modeFor(inputType: Enum.UserInputType): Mode?
	if inputType == Enum.UserInputType.Touch then
		return "touch"
	elseif inputType.Name:match("^Gamepad") then
		return "gamepad"
	elseif
		inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.Keyboard
	then
		return "mouse"
	end
	return nil
end

function InputController.new(): InputController
	local self = setmetatable({
		_mode = (if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
			then "touch"
			elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then "gamepad"
			else "mouse") :: Mode,
		_held = {},
		_suspended = false,
		modeChanged = Signal.new(),
		actionBegan = Signal.new(),
		actionEnded = Signal.new(),
		_trove = Trove.new(),
	}, InputController)

	for action, keys in pairs(BINDINGS) do
		local actionName = "SFE_" .. action
		ContextActionService:BindAction(actionName, function(_, state)
			return self:_handle(action, state)
		end, false, table.unpack(keys))
		self._trove:add(function()
			ContextActionService:UnbindAction(actionName)
		end)
	end

	self._trove:add(UserInputService.LastInputTypeChanged:Connect(function(inputType)
		local mode = modeFor(inputType)
		if mode and mode ~= self._mode then
			self._mode = mode
			self.modeChanged:Fire(mode)
		end
	end))
	-- Release every held action on focus loss or menu open so continuous tools never stick.
	self._trove:add(UserInputService.WindowFocusReleased:Connect(function()
		self:releaseAll("focus_lost")
	end))
	self._trove:add(GuiService.MenuOpened:Connect(function()
		self:releaseAll("menu")
	end))
	return self
end

function InputController._handle(self: InputController, action: Action, state: Enum.UserInputState): Enum.ContextActionResult
	if self._suspended and action ~= "Cancel" and action ~= "Back" then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		self._held[action] = true
		self.actionBegan:Fire(action)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		if self._held[action] then
			self._held[action] = nil
			self.actionEnded:Fire(action, state == Enum.UserInputState.Cancel and "cancelled" or "released")
		end
	end
	return Enum.ContextActionResult.Sink
end

-- Touch: the HUD's primary button calls these directly for press/release/cancel.
function InputController.touchBegin(self: InputController, action: Action)
	self:_handle(action, Enum.UserInputState.Begin)
end

function InputController.touchEnd(self: InputController, action: Action, cancelled: boolean?)
	self:_handle(action, if cancelled then Enum.UserInputState.Cancel else Enum.UserInputState.End)
end

function InputController.releaseAll(self: InputController, reason: string)
	for action in pairs(table.clone(self._held)) do
		self._held[action] = nil
		self.actionEnded:Fire(action, reason)
	end
end

-- Modal ownership suspends gameplay actions (Primary/Interact) while Cancel/Back keep working.
function InputController.setSuspended(self: InputController, suspended: boolean)
	if suspended and not self._suspended then
		self:releaseAll("suspended")
	end
	self._suspended = suspended
end

function InputController.isHeld(self: InputController, action: Action): boolean
	return self._held[action] == true
end

function InputController.mode(self: InputController): Mode
	return self._mode
end

function InputController.destroy(self: InputController)
	self:releaseAll("destroyed")
	self._trove:destroy()
	self.modeChanged:Destroy()
	self.actionBegan:Destroy()
	self.actionEnded:Destroy()
end

return InputController
