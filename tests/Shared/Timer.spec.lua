--[[
    Unit tests for the SDK's Timer, which now schedules its end with task.delay instead of checking
    the clock every frame. No dashboard interaction required.
]]

return function()
    local Timer = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast").Infra.Shared.Modules.Timer)

    describe("Timer", function()
        it("should call OnEnd once the time has passed", function()
            local timer = Timer.new(0.2)
            local ended = 0
            timer:OnEnd(function()
                ended += 1
            end)

            task.wait(0.1)
            expect(ended).to.equal(0)

            task.wait(0.3)
            expect(ended).to.equal(1)
        end)

        it("should never end once destroyed", function()
            local timer = Timer.new(0.1)
            local ended = false
            timer:OnEnd(function()
                ended = true
            end)

            timer:Destroy()
            task.wait(0.3)
            expect(ended).to.equal(false)
        end)

        it("should allow destroying from its own end callback", function()
            local timer
            timer = Timer.new(0.1)
            local ok = nil
            timer:OnEnd(function()
                ok = pcall(function()
                    timer:Destroy()
                end)
            end)

            task.wait(0.3)
            expect(ok).to.equal(true)
        end)
    end)
end
