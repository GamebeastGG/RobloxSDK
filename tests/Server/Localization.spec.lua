--[[
    Unit tests for player localization lookups. The engine calls behind them yield, so what matters
    here is that starting one never yields the caller: engagement markers are fired from threads that
    must not yield, which is what SendPlayerMarker used to do.
]]

return function()
    local LocalizationCache = shared.GBMod("LocalizationCache")

    -- Resolves to "unknown" for both fields when the test server is empty, which covers the same
    -- paths without needing a player.
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
