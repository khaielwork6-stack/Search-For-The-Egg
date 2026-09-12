--!strict
-- Marketplace adapter interface with a real implementation (MarketplaceService) and a mock for
-- tests/Studio protocols. Services only ever see this interface.

local MarketplaceAdapter = {}

export type Adapter = {
	userOwnsGamePassAsync: (self: Adapter, userId: number, gamePassId: number) -> (boolean, boolean?),
	promptGamePassPurchase: (self: Adapter, player: any, gamePassId: number) -> boolean,
	promptProductPurchase: (self: Adapter, player: any, productId: number) -> boolean,
	bindProcessReceipt: (self: Adapter, handler: (receiptInfo: any) -> any) -> (),
	kind: string,
}

-- Real ---------------------------------------------------------------------------------------

local Real = {}
Real.__index = Real

function MarketplaceAdapter.real(): Adapter
	local self = setmetatable({ kind = "real" }, Real)
	return (self :: any) :: Adapter
end

function Real.userOwnsGamePassAsync(_, userId: number, gamePassId: number): (boolean, boolean?)
	local MarketplaceService = game:GetService("MarketplaceService")
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, gamePassId)
	end)
	if ok then
		return true, owns == true
	end
	return false, nil
end

function Real.promptGamePassPurchase(_, player: any, gamePassId: number): boolean
	local MarketplaceService = game:GetService("MarketplaceService")
	return pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, gamePassId)
	end)
end

function Real.promptProductPurchase(_, player: any, productId: number): boolean
	local MarketplaceService = game:GetService("MarketplaceService")
	return pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
end

function Real.bindProcessReceipt(_, handler: (receiptInfo: any) -> any)
	local MarketplaceService = game:GetService("MarketplaceService")
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local decision = handler(receiptInfo)
		if decision == "PurchaseGranted" then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

-- Mock ---------------------------------------------------------------------------------------

local Mock = {}
Mock.__index = Mock

export type Mock = Adapter & {
	grantPass: (self: Mock, userId: number, gamePassId: number) -> (),
	revokePass: (self: Mock, userId: number, gamePassId: number) -> (),
	failOwnershipChecks: (self: Mock, count: number) -> (),
	prompts: { { userId: number, kind: string, id: number } },
	receiptHandler: ((receiptInfo: any) -> any)?,
	ownershipCalls: number,
}

function MarketplaceAdapter.mock(): Mock
	local self = setmetatable({
		kind = "mock",
		_owned = {} :: { [string]: boolean },
		_failChecks = 0,
		prompts = {},
		receiptHandler = nil,
		ownershipCalls = 0,
	}, Mock)
	return (self :: any) :: Mock
end

local function ownKey(userId: number, gamePassId: number): string
	return tostring(userId) .. ":" .. tostring(gamePassId)
end

function Mock.userOwnsGamePassAsync(self, userId: number, gamePassId: number): (boolean, boolean?)
	(self :: any).ownershipCalls += 1
	if self._failChecks > 0 then
		self._failChecks -= 1
		return false, nil
	end
	return true, self._owned[ownKey(userId, gamePassId)] == true
end

function Mock.promptGamePassPurchase(self, player: any, gamePassId: number): boolean
	table.insert(self.prompts, { userId = player.UserId, kind = "gamePass", id = gamePassId })
	return true
end

function Mock.promptProductPurchase(self, player: any, productId: number): boolean
	table.insert(self.prompts, { userId = player.UserId, kind = "developerProduct", id = productId })
	return true
end

function Mock.bindProcessReceipt(self, handler)
	self.receiptHandler = handler
end

function Mock.grantPass(self, userId: number, gamePassId: number)
	self._owned[ownKey(userId, gamePassId)] = true
end

function Mock.revokePass(self, userId: number, gamePassId: number)
	self._owned[ownKey(userId, gamePassId)] = nil
end

function Mock.failOwnershipChecks(self, count: number)
	self._failChecks = count
end

return MarketplaceAdapter
