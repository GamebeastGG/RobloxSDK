--[[
    Unit tests for validating client-reported info. The client is untrusted, and these values reach
    the experiment assignment request for the whole server and every marker the player fires.
    No dashboard interaction required.
]]

return function()
    local ServerClientInfoHandler = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast").Infra.Server.Modules.ServerClientInfoHandler)

    local function isValid(key, value)
        return ServerClientInfoHandler:IsValidClientInfo(key, value)
    end

    describe("IsValidClientInfo", function()
        it("should accept the values the SDK's client reports", function()
            expect(isValid("inputType", "touch")).to.equal(true)
            expect(isValid("device", "mobile")).to.equal(true)
            expect(isValid("deviceSubType", "phone")).to.equal(true)
            expect(isValid("sessionId", "8F0E2A3B-4C5D-4E6F-8A9B-0C1D2E3F4A5B")).to.equal(true)
            expect(isValid("joinTime", 1759000000)).to.equal(true)
            expect(isValid("hasFriendsOnline", false)).to.equal(true)
        end)

        it("should reject values outside the targeting vocabulary", function()
            expect(isValid("inputType", "mouse")).to.equal(false)
            expect(isValid("device", "toaster")).to.equal(false)
            expect(isValid("deviceSubType", "")).to.equal(false)
        end)

        it("should reject the wrong types", function()
            expect(isValid("inputType", 1)).to.equal(false)
            expect(isValid("device", { "pc" })).to.equal(false)
            expect(isValid("joinTime", "1759000000")).to.equal(false)
            expect(isValid("hasFriendsOnline", "true")).to.equal(false)
        end)

        it("should reject numbers JSON can't carry", function()
            expect(isValid("joinTime", 0 / 0)).to.equal(false)
            expect(isValid("totalFriendPlaytime", math.huge)).to.equal(false)
            expect(isValid("friendClockStart", -math.huge)).to.equal(false)
        end)

        it("should reject session ids the SDK didn't generate", function()
            expect(isValid("sessionId", "someone-elses-session")).to.equal(false)
            expect(isValid("sessionId", string.rep("a", 10000))).to.equal(false)
        end)

        it("should reject keys that aren't client info", function()
            expect(isValid("isAdmin", true)).to.equal(false)
        end)
    end)
end
