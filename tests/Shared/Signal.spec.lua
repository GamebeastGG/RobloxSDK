--[[
    Unit tests for the SDK's Signal class, focused on listeners that connect or disconnect while the
    signal is firing. No dashboard interaction required.
]]

return function()
    local Signal = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast").Infra.Shared.Modules.Signal)

    -- Listeners run through task.spawn, which starts them immediately, so a fire has fully
    -- delivered by the time it returns unless a listener yields
    local function fireAndCollect(signal, fired : { string }, ...) : string
        signal:Fire(...)
        table.sort(fired)
        return table.concat(fired, ",")
    end

    describe("Fire", function()
        it("should call every listener when one connects another while firing", function()
            local signal = Signal.new()
            local fired = {}

            signal:Connect(function()
                table.insert(fired, "a")
                signal:Connect(function() end)
            end)
            signal:Connect(function() table.insert(fired, "b") end)
            signal:Connect(function() table.insert(fired, "c") end)

            expect(fireAndCollect(signal, fired)).to.equal("a,b,c")
        end)

        it("should call every Once listener when one connects another while firing", function()
            local signal = Signal.new()
            local fired = {}

            signal:Once(function()
                table.insert(fired, "a")
                signal:Once(function() end)
            end)
            signal:Once(function() table.insert(fired, "b") end)
            signal:Once(function() table.insert(fired, "c") end)

            expect(fireAndCollect(signal, fired)).to.equal("a,b,c")
        end)

        it("should not call a listener connected while firing until the next fire", function()
            local signal = Signal.new()
            local lateCalls = 0

            signal:Once(function()
                signal:Connect(function()
                    lateCalls += 1
                end)
            end)

            signal:Fire()
            expect(lateCalls).to.equal(0)

            signal:Fire()
            expect(lateCalls).to.equal(1)
        end)

        it("should not call a listener an earlier one disconnected during the same fire", function()
            local signal = Signal.new()
            local fired = {}
            local laterConnection

            signal:Connect(function()
                table.insert(fired, "a")
                laterConnection:Disconnect()
            end)
            laterConnection = signal:Connect(function() table.insert(fired, "b") end)
            signal:Connect(function() table.insert(fired, "c") end)

            expect(fireAndCollect(signal, fired)).to.equal("a,c")
        end)

        it("should call a Once listener once, even when its callback fires the signal again", function()
            local signal = Signal.new()
            local calls = 0

            signal:Once(function()
                calls += 1
                signal:Fire()
            end)

            signal:Fire()
            signal:Fire()
            expect(calls).to.equal(1)
        end)

        it("should remove every Once listener after one fire, however many there are", function()
            local signal = Signal.new()
            local calls = 0
            local connections = {}

            for _ = 1, 2000 do
                table.insert(connections, signal:Once(function()
                    calls += 1
                end))
            end

            signal:Fire()
            signal:Fire()

            expect(calls).to.equal(2000)
            expect(connections[1].Connected).to.equal(false)
            expect(connections[2000].Connected).to.equal(false)
        end)

        it("should share arguments between listeners when built without copies", function()
            local signal = Signal.new({ copyArguments = false })
            local received = {}

            signal:Connect(function(data) table.insert(received, data) end)
            signal:Connect(function(data) table.insert(received, data) end)

            local original = { value = "original" }
            signal:Fire(original)

            expect(received[1]).to.equal(original)
            expect(received[2]).to.equal(original)
        end)

        it("should pass each listener its own copy of table arguments", function()
            local signal = Signal.new()
            local received = {}

            signal:Connect(function(data) data.value = "changed" table.insert(received, data) end)
            signal:Connect(function(data) table.insert(received, data) end)

            local original = { value = "original" }
            signal:Fire(original)

            expect(original.value).to.equal("original")
            expect(received[2].value).to.equal("original")
        end)
    end)

    describe("Wait", function()
        it("should resume every waiter with the fired arguments", function()
            local signal = Signal.new()
            local results = {}

            for index = 1, 3 do
                task.spawn(function()
                    local value = signal:Wait()
                    results[index] = value
                end)
            end

            signal:Fire("ready")
            task.wait(0.1)

            expect(results[1]).to.equal("ready")
            expect(results[2]).to.equal("ready")
            expect(results[3]).to.equal("ready")
        end)

        -- Waiters used to poll a flag every frame, so none resumed until the frame after the fire
        it("should resume waiters during the fire itself, without polling", function()
            local signal = Signal.new()
            local resumed = 0

            for _ = 1, 50 do
                task.spawn(function()
                    signal:Wait()
                    resumed += 1
                end)
            end

            signal:Fire()
            expect(resumed).to.equal(50)
        end)

        it("should skip a waiter whose thread was cancelled", function()
            local signal = Signal.new()
            local resumed = false

            local cancelled = task.spawn(function()
                signal:Wait()
            end)
            task.spawn(function()
                signal:Wait()
                resumed = true
            end)
            task.cancel(cancelled)

            expect(function()
                signal:Fire()
            end).never.to.throw()
            expect(resumed).to.equal(true)
        end)

        it("should keep the first fire's arguments when fired twice before resuming", function()
            local signal = Signal.new()
            local result

            task.spawn(function()
                result = signal:Wait()
            end)

            signal:Fire("first")
            signal:Fire("second")
            task.wait(0.1)

            expect(result).to.equal("first")
        end)
    end)
end
