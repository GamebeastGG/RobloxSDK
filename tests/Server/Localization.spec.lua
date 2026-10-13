--[[
    Unit tests for player localization lookups. The engine calls behind them yield, but starting one
    must never yield the caller, since engagement markers fire from threads that must not yield.
]]

return function()
    local LocalizationCache = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast").Infra.Server.Modules.LocalizationCache)

    -- Nil in an empty server, which resolves both fields to "unknown" and covers the same paths
    local player = game.Players:GetPlayers()[1]

    describe("OnResolved", function()
        it("should not yield the caller", function()
            local thread = coroutine.create(function()
                LocalizationCache:OnResolved(player, function() end)
            end)

            local didRun, err = coroutine.resume(thread)
            assert(didRun, err)

            expect(coroutine.status(thread)).to.equal("dead")
        end)

        it("should resolve a locale and a region", function()
            local localization = LocalizationCache:Get(player)

            expect(type(localization.localeId)).to.equal("string")
            expect(type(localization.regionId)).to.equal("string")
        end)

        it("should call back before returning once it is cached", function()
            LocalizationCache:Get(player)

            local resolved = nil
            local connection = LocalizationCache:OnResolved(player, function(localization)
                resolved = localization
            end)

            expect(resolved).to.be.ok()
            expect(connection).never.to.be.ok()
        end)
    end)
end
