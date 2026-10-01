--[[
    Unit tests for developer-defined experiment targeting properties; no dashboard
    interaction required. The Gamebeast SDK must be running so internal modules
    are loaded.

    Server properties are exercised directly. Player properties need a Player and
    are only exercised when one is present in the server.
]]

return function()
    local Players = game:GetService("Players")
    local AssignmentContext = shared.GBMod("AssignmentContext")

    local function clearServerProperties()
        for key in AssignmentContext:GetServerProperties() do
            AssignmentContext:SetServerProperty(key, nil)
        end
    end

    describe("Server properties", function()
        beforeEach(clearServerProperties)
        afterAll(clearServerProperties)

        it("should store scalar and list values", function()
            local didChange = AssignmentContext:SetServerProperties({
                region = "eu",
                capacity = 50,
                ranked = true,
                tags = { "a", "b" },
            })
            expect(didChange).to.equal(true)

            local properties = AssignmentContext:GetServerProperties()
            expect(properties.region).to.equal("eu")
            expect(properties.capacity).to.equal(50)
            expect(properties.ranked).to.equal(true)
            expect(properties.tags[1]).to.equal("a")
            expect(properties.tags[2]).to.equal("b")
        end)

        it("should report no change when values are unchanged", function()
            AssignmentContext:SetServerProperties({ region = "eu", tags = { "a" } })
            expect(AssignmentContext:SetServerProperties({ region = "eu", tags = { "a" } })).to.equal(false)
            expect(AssignmentContext:SetServerProperty("region", "eu")).to.equal(false)
        end)

        it("should merge per key and clear with nil", function()
            AssignmentContext:SetServerProperties({ region = "eu", mode = "ranked" })
            AssignmentContext:SetServerProperties({ mode = "casual" })
            expect(AssignmentContext:GetServerProperties().region).to.equal("eu")
            expect(AssignmentContext:GetServerProperties().mode).to.equal("casual")

            expect(AssignmentContext:SetServerProperty("mode", nil)).to.equal(true)
            expect(AssignmentContext:GetServerProperties().mode).never.to.be.ok()
            expect(AssignmentContext:SetServerProperty("mode", nil)).to.equal(false)
        end)

        it("should reject unsupported values", function()
            expect(AssignmentContext:SetServerProperties({ nested = { a = 1 } })).to.equal(false)
            expect(AssignmentContext:SetServerProperties({ mixed = { 1, "a", {} } })).to.equal(false)
            expect(AssignmentContext:SetServerProperties({ nan = 0 / 0 })).to.equal(false)
            expect(AssignmentContext:SetServerProperties({ inf = math.huge })).to.equal(false)
            expect(AssignmentContext:SetServerProperties({ vector = Vector3.zero })).to.equal(false)
            expect(AssignmentContext:SetServerProperties({ [1] = "numeric key" })).to.equal(false)
            expect(AssignmentContext:SetServerProperties({ [""] = "empty key" })).to.equal(false)
            expect(next(AssignmentContext:GetServerProperties())).never.to.be.ok()
        end)

        it("should reject lists longer than the backend limit", function()
            local tooLong = table.create(101, 1)
            expect(AssignmentContext:SetServerProperties({ list = tooLong })).to.equal(false)

            local atLimit = table.create(100, 1)
            expect(AssignmentContext:SetServerProperties({ list = atLimit })).to.equal(true)
        end)

        it("should copy lists so caller mutation does not leak into the store", function()
            local tags = { "a" }
            AssignmentContext:SetServerProperties({ tags = tags })
            table.insert(tags, "b")
            expect(#AssignmentContext:GetServerProperties().tags).to.equal(1)

            local returned = AssignmentContext:GetServerProperties()
            returned.tags[1] = "z"
            expect(AssignmentContext:GetServerProperties().tags[1]).to.equal("a")
        end)

        it("should include properties in the server context", function()
            expect(AssignmentContext:GetForServer({})).never.to.be.ok()

            AssignmentContext:SetServerProperties({ region = "eu" })
            local context = AssignmentContext:GetForServer({})
            expect(context).to.be.ok()
            expect(context.properties.region).to.equal("eu")
            expect(context.roblox).never.to.be.ok()
        end)

        it("should gather nothing for paths the shared context or the backend covers", function()
            expect(AssignmentContext:GetForServer({ "roblox.placeId", "roblox.placeVersion", "unit.distinctId" })).never.to.be.ok()
        end)

        it("should include properties in the shared context", function()
            local shared = AssignmentContext:GetShared()
            expect(shared.schemaVersion).to.equal(1)
            expect(shared.roblox.placeId).to.equal(game.PlaceId)
            expect(shared.properties).never.to.be.ok()

            AssignmentContext:SetServerProperties({ region = "eu" })
            expect(AssignmentContext:GetShared().properties.region).to.equal("eu")
        end)
    end)

    describe("Player properties", function()
        local player = Players:GetPlayers()[1]

        if not player then
            itSKIP("requires a player in the server", function() end)
            return
        end

        local function clearPlayerProperties()
            for key in AssignmentContext:GetPlayerProperties(player) do
                AssignmentContext:SetPlayerProperty(player, key, nil)
            end
        end

        beforeEach(clearPlayerProperties)
        afterAll(clearPlayerProperties)

        it("should store, merge and clear values", function()
            expect(AssignmentContext:SetPlayerProperties(player, { vip = true, level = 1 })).to.equal(true)
            expect(AssignmentContext:SetPlayerProperty(player, "level", 2)).to.equal(true)
            expect(AssignmentContext:SetPlayerProperty(player, "level", 2)).to.equal(false)

            local properties = AssignmentContext:GetPlayerProperties(player)
            expect(properties.vip).to.equal(true)
            expect(properties.level).to.equal(2)

            expect(AssignmentContext:SetPlayerProperty(player, "vip", nil)).to.equal(true)
            expect(AssignmentContext:GetPlayerProperties(player).vip).never.to.be.ok()
        end)

        it("should include properties in the player context", function()
            AssignmentContext:SetPlayerProperties(player, { vip = true })
            local contextByPlayerId = AssignmentContext:GetForPlayers({ player.UserId }, {})
            expect(contextByPlayerId[player.UserId]).to.be.ok()
            expect(contextByPlayerId[player.UserId].properties.vip).to.equal(true)
        end)

        -- Targeting names what it reads by context path; this is the shape the backend sends
        it("should gather standard properties named by their context path", function()
            local contextByPlayerId = AssignmentContext:GetForPlayers({ player.UserId }, { "roblox.country", "roblox.language" })
            local context = contextByPlayerId[player.UserId]
            expect(context).to.be.ok()
            expect(context.roblox).to.be.ok()
            expect(type(context.roblox.country)).to.equal("string")
            expect(type(context.roblox.language)).to.equal("string")
        end)

        it("should only report a player as awaiting client info when targeting needs it", function()
            local _, awaiting = AssignmentContext:GetForPlayers({ player.UserId }, { "roblox.country" })
            expect(#awaiting).to.equal(0)

            local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler")
            local contextByPlayerId, awaitingInput = AssignmentContext:GetForPlayers({ player.UserId }, { "roblox.inputType" })
            if ServerClientInfoHandler:IsClientInfoResolved(player) then
                expect(#awaitingInput).to.equal(0)
                expect(contextByPlayerId[player.UserId].roblox.inputType).to.be.ok()
            else
                expect(awaitingInput[1]).to.equal(player)
            end
        end)

        it("should not treat a bare property name as a standard property", function()
            local contextByPlayerId = AssignmentContext:GetForPlayers({ player.UserId }, { "country" })
            expect(contextByPlayerId[player.UserId]).never.to.be.ok()
        end)

        it("should gather nothing per player for paths the shared context or the backend covers", function()
            local contextByPlayerId = AssignmentContext:GetForPlayers({ player.UserId }, { "roblox.placeId", "unit.isNewUser" })
            expect(contextByPlayerId[player.UserId]).never.to.be.ok()
        end)

        it("should omit players without any context", function()
            local contextByPlayerId = AssignmentContext:GetForPlayers({ player.UserId }, {})
            expect(contextByPlayerId[player.UserId]).never.to.be.ok()
        end)
    end)
end
