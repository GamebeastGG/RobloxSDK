--[[
    Unit tests for reading Overwolf launcher launch data. The launcher sends
    `{ source = "overwolf", placeId = "<id>", streak = <day>? }`, and anyone can put launch data on a
    Roblox link, so anything else has to be ignored or dropped. No dashboard interaction required.
]]

return function()
    local Players = game:GetService("Players")
    local Gamebeast = game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast")
    local InternalOverwolf = require(Gamebeast.Infra.Server.Modules.InternalOverwolf)
    local Overwolf = require(Gamebeast.Infra.Server.Public.Overwolf)

    local function normalize(launchData)
        return InternalOverwolf:Normalize(launchData)
    end

    describe("Normalize", function()
        it("should pass through what the launcher sends", function()
            local data = normalize({ source = "overwolf", placeId = "123", streak = 3 })
            expect(data).to.be.ok()
            expect(data.source).to.equal("overwolf")
            expect(data.placeId).to.equal("123")
            expect(data.streak).to.equal(3)
        end)

        it("should treat a launch with no streak campaign as an Overwolf launch", function()
            local data = normalize({ source = "overwolf", placeId = "123" })
            expect(data).to.be.ok()
            expect(data.streak).to.equal(nil)
        end)

        it("should ignore launch data from anything but an Overwolf launcher", function()
            expect(normalize(nil)).to.equal(nil)
            expect(normalize("overwolf")).to.equal(nil)
            expect(normalize({ placeId = "123", streak = 3 })).to.equal(nil)
            expect(normalize({ source = "web", streak = 3 })).to.equal(nil)
            expect(normalize({ _gbDeeplink = { deeplinkId = "abc" } })).to.equal(nil)
        end)

        it("should keep fields from newer launchers", function()
            local data = normalize({ source = "overwolf", placeId = "123", pass = { tier = 2 } })
            expect(data.pass.tier).to.equal(2)
        end)

        it("should turn a numeric place id into a string", function()
            expect(normalize({ source = "overwolf", placeId = 123 }).placeId).to.equal("123")
            expect(normalize({ source = "overwolf", placeId = { 1 } }).placeId).to.equal(nil)
        end)

        it("should only keep a streak that is a whole number of days", function()
            expect(normalize({ source = "overwolf", streak = "4" }).streak).to.equal(4)
            expect(normalize({ source = "overwolf", streak = 0 }).streak).to.equal(nil)
            expect(normalize({ source = "overwolf", streak = -2 }).streak).to.equal(nil)
            expect(normalize({ source = "overwolf", streak = 1.5 }).streak).to.equal(nil)
            expect(normalize({ source = "overwolf", streak = math.huge }).streak).to.equal(nil)
            expect(normalize({ source = "overwolf", streak = 0 / 0 }).streak).to.equal(nil)
            expect(normalize({ source = "overwolf", streak = "lots" }).streak).to.equal(nil)
        end)

        it("should not change the table it was given", function()
            local raw = { source = "overwolf", placeId = 123, streak = "2" }
            normalize(raw)
            expect(raw.placeId).to.equal(123)
            expect(raw.streak).to.equal("2")
        end)
    end)

    describe("OnLaunchData", function()
        it("should require a callback", function()
            expect(function()
                Overwolf:OnLaunchData(nil)
            end).to.throw()
        end)

        it("should fire for simulated launches, including ones before it connected", function()
            local player = Players:GetPlayers()[1]
            if not player then
                return -- Needs a player in the Studio test session
            end

            Overwolf:SimulateLaunchData(player, { streak = 2 })

            local received = {}
            local connection = Overwolf:OnLaunchData(function(launchedPlayer, launchData)
                if launchedPlayer == player then
                    table.insert(received, launchData.streak)
                end
            end)

            Overwolf:SimulateLaunchData(player, { streak = 3 })
            task.wait()
            connection:Disconnect()

            expect(received[1]).to.equal(2)
            expect(received[2]).to.equal(3)
            expect(Overwolf:GetLaunchDataAsync(player).streak).to.equal(3)
            expect(Overwolf:GetLaunchDataAsync(player).placeId).to.equal(tostring(game.PlaceId))
        end)

        it("should give each callback its own copy", function()
            local player = Players:GetPlayers()[1]
            if not player then
                return
            end

            Overwolf:SimulateLaunchData(player, { streak = 5 })

            local connection = Overwolf:OnLaunchData(function(_, launchData)
                launchData.streak = 99
            end)
            task.wait()
            connection:Disconnect()

            expect(Overwolf:GetLaunchDataAsync(player).streak).to.equal(5)
        end)
    end)
end
