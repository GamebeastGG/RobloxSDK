return function()
    local Gamebeast = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast"))
    local MarkersService = Gamebeast:GetService("Markers") :: Gamebeast.MarkersService

    describe("Markers", function()
        it("should send a marker", function()
            MarkersService:SendMarker("TestMarker", 1, Vector3.one * math.random())
        end)

        it("should send a player marker", function()
            MarkersService:SendPlayerMarker(game.Players:GetPlayers()[1], "TestMarker", 1, Vector3.one * math.random())
        end)

        it("should send a player marker without yielding the caller", function()
            local thread = coroutine.create(function()
                MarkersService:SendPlayerMarker(game.Players:GetPlayers()[1], "TestMarker", 1)
            end)

            local didRun, err = coroutine.resume(thread)
            assert(didRun, err)

            expect(coroutine.status(thread)).to.equal("dead")
        end)
    end)
end