--!nocheck
-- Foundation utilities: Signal, Trove, Clock, DeepFreeze, TableUtil.

return function(describe, it, expect)
	local Shared = game:GetService("ReplicatedStorage").Shared
	local Signal = require(Shared.Util.Signal)
	local Trove = require(Shared.Util.Trove)
	local Clock = require(Shared.Clock)
	local DeepFreeze = require(Shared.Util.DeepFreeze)
	local TableUtil = require(Shared.Util.TableUtil)

	describe("Signal", function()
		it("fires connected handlers in order and supports disconnect", function()
			local signal = Signal.new()
			local log = {}
			local a = signal:Connect(function(v)
				table.insert(log, "a" .. v)
			end)
			signal:Connect(function(v)
				table.insert(log, "b" .. v)
			end)
			signal:Fire(1)
			a:Disconnect()
			signal:Fire(2)
			expect(log).toEqual({ "a1", "b1", "b2" })
			expect(signal:ConnectionCount()).toBe(1)
		end)

		it("Once disconnects after the first fire", function()
			local signal = Signal.new()
			local count = 0
			signal:Once(function()
				count += 1
			end)
			signal:Fire()
			signal:Fire()
			expect(count).toBe(1)
			expect(signal:ConnectionCount()).toBe(0)
		end)

		it("Destroy drops all handlers", function()
			local signal = Signal.new()
			signal:Connect(function() end)
			signal:Destroy()
			expect(signal:ConnectionCount()).toBe(0)
		end)
	end)

	describe("Trove", function()
		it("cleans functions, signals-like objects, and nested troves in reverse order", function()
			local trove = Trove.new()
			local order = {}
			trove:add(function()
				table.insert(order, "first")
			end)
			local fake = {
				Destroy = function()
					table.insert(order, "destroyable")
				end,
			}
			trove:add(fake)
			local child = trove:extend()
			child:add(function()
				table.insert(order, "child")
			end)
			expect(trove:count()).toBe(3)
			trove:destroy()
			expect(order).toEqual({ "child", "destroyable", "first" })
			expect(trove:count()).toBe(0)
		end)

		it("remove cleans a single item", function()
			local trove = Trove.new()
			local hit = false
			local fn = trove:add(function()
				hit = true
			end)
			expect(trove:remove(fn)).toBe(true)
			expect(hit).toBe(true)
			expect(trove:remove(fn)).toBe(false)
		end)
	end)

	describe("Clock", function()
		it("fake clock advances wall and monotonic time together", function()
			local clock = Clock.fake(1000)
			expect(clock:now()).toBe(1000)
			expect(clock:monotonic()).toBe(0)
			clock:advance(2.5)
			expect(clock:now()).toBe(1002.5)
			expect(clock:nowMs()).toBe(1002500)
			expect(clock:monotonic()).toBe(2.5)
			clock:set(5)
			expect(clock:now()).toBe(5)
			expect(clock:monotonic()).toBe(2.5)
		end)

		it("real clock cannot be manipulated", function()
			local clock = Clock.real()
			expect(clock.isFake).toBe(false)
			expect(function()
				clock:advance(1)
			end).toThrow()
			expect(clock:now()).toBeGreaterThan(0)
		end)
	end)

	describe("DeepFreeze", function()
		it("freezes nested tables and tolerates cycles", function()
			local t = { a = { b = { c = 1 } } }
			t.a.self = t
			DeepFreeze.freeze(t)
			expect(DeepFreeze.isDeepFrozen(t)).toBe(true)
			expect(function()
				t.a.b.c = 2
			end).toThrow()
		end)
	end)

	describe("TableUtil", function()
		it("deepCopy produces an independent copy", function()
			local a = { x = { y = 1 }, list = { 1, 2 } }
			local b = TableUtil.deepCopy(a)
			b.x.y = 2
			expect(a.x.y).toBe(1)
			expect(TableUtil.deepEqual(a, b)).toBe(false)
		end)

		it("with returns a new table sharing untouched keys", function()
			local a = { k = 1, other = { 2 } }
			local b = TableUtil.with(a, "k", 5)
			expect(a.k).toBe(1)
			expect(b.k).toBe(5)
			expect(b.other).toBe(a.other)
		end)

		it("isArray distinguishes arrays from dictionaries", function()
			expect(TableUtil.isArray({ 1, 2, 3 })).toBe(true)
			expect(TableUtil.isArray({ a = 1 })).toBe(false)
			expect(TableUtil.isArray({})).toBe(true)
		end)
	end)
end
