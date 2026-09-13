--!strict
-- Group-membership adapter for the one-time group reward (ASSUMED A-META-04). The group id is a
-- deployment value (ProductIds.social.groupId); when it is nil the reward is unavailable and never
-- grants. Real: Player:IsInGroup through Players. Mock: explicit membership for tests/Studio.

local GroupAdapter = {}

export type Adapter = {
	isConfigured: (self: Adapter) -> boolean,
	isMember: (self: Adapter, userId: number) -> (boolean, boolean?), -- ok, member
	kind: string,
}

local Real = {}
Real.__index = Real

function GroupAdapter.real(groupId: number?, playersService: any): Adapter
	local self = setmetatable({ kind = "real", _groupId = groupId, _players = playersService }, Real)
	return (self :: any) :: Adapter
end

function Real.isConfigured(self): boolean
	return type(self._groupId) == "number" and self._groupId > 0
end

function Real.isMember(self, userId: number): (boolean, boolean?)
	if not self:isConfigured() then
		return false, nil
	end
	local player = self._players:GetPlayerByUserId(userId)
	if not player then
		return false, nil
	end
	local ok, member = pcall(function()
		return player:IsInGroup(self._groupId)
	end)
	if ok then
		return true, member == true
	end
	return false, nil
end

local Mock = {}
Mock.__index = Mock

export type Mock = Adapter & {
	setMember: (self: Mock, userId: number, member: boolean) -> (),
	setConfigured: (self: Mock, configured: boolean) -> (),
	failNext: (self: Mock, count: number) -> (),
	checks: number,
}

function GroupAdapter.mock(configured: boolean?): Mock
	local self = setmetatable({ kind = "mock", _members = {}, _configured = configured ~= false, _fail = 0, checks = 0 }, Mock)
	return (self :: any) :: Mock
end

function Mock.isConfigured(self): boolean
	return self._configured
end

function Mock.isMember(self, userId: number): (boolean, boolean?)
	self.checks += 1
	if self._fail > 0 then
		self._fail -= 1
		return false, nil
	end
	return true, self._members[userId] == true
end

function Mock.setMember(self, userId: number, member: boolean)
	self._members[userId] = member
end

function Mock.setConfigured(self, configured: boolean)
	self._configured = configured
end

function Mock.failNext(self, count: number)
	self._fail = count
end

return GroupAdapter
