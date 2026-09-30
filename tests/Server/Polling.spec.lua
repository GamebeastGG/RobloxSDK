--[[
    Unit tests for how the statusPollRate setting and the polling object returned by the bootstrap and
    status endpoints combine into the delay between status polls. No dashboard interaction required.
]]

return function()
    local DataCache = shared.GBMod("DataCache")
    local Updater = shared.GBMod("Updater")

    local settings = DataCache:Get("Settings")
    local POLL_RATE = 30

    describe("GetPollDelay", function()
        local previousPollRate

        beforeAll(function()
            previousPollRate = settings.statusPollRate
        end)

        beforeEach(function()
            settings.statusPollRate = POLL_RATE
            Updater:SetPollingDirective(nil)
        end)

        afterAll(function()
            settings.statusPollRate = previousPollRate
            -- There is no getter for the directive in force, so this leaves the running SDK
            -- without one until the next status poll re-applies it from the payload
            Updater:SetPollingDirective(nil)
        end)

        it("should poll on the setting when Gamebeast has not asked for anything", function()
            expect(Updater:GetPollDelay()).to.equal(POLL_RATE)
        end)

        it("should follow an interval longer than the setting", function()
            Updater:SetPollingDirective({ intervalSeconds = POLL_RATE * 10 })
            expect(Updater:GetPollDelay()).to.equal(POLL_RATE * 10)
        end)

        it("should ignore an interval shorter than the setting", function()
            Updater:SetPollingDirective({ intervalSeconds = 0.01 })
            expect(Updater:GetPollDelay()).to.equal(POLL_RATE)

            Updater:SetPollingDirective({ intervalSeconds = POLL_RATE - 1 })
            expect(Updater:GetPollDelay()).to.equal(POLL_RATE)
        end)

        it("should keep comparing against the setting as it changes", function()
            Updater:SetPollingDirective({ intervalSeconds = 60 })
            expect(Updater:GetPollDelay()).to.equal(60)

            -- The setting is the floor, so raising it past the interval takes over
            settings.statusPollRate = 120
            expect(Updater:GetPollDelay()).to.equal(120)
        end)

        it("should spread polls over the jitter window, never below the interval", function()
            Updater:SetPollingDirective({ intervalSeconds = POLL_RATE, jitterRatio = 0.5 })

            expect(Updater:GetPollDelay(0)).to.equal(POLL_RATE)
            expect(Updater:GetPollDelay(1)).to.equal(POLL_RATE * 1.5)

            for _ = 1, 100 do
                local delay = Updater:GetPollDelay()
                expect(delay >= POLL_RATE).to.equal(true)
                expect(delay <= POLL_RATE * 1.5).to.equal(true)
            end
        end)

        it("should ignore a jitter ratio outside 0-1", function()
            Updater:SetPollingDirective({ jitterRatio = 5 })
            expect(Updater:GetPollDelay(1)).to.equal(POLL_RATE)

            Updater:SetPollingDirective({ jitterRatio = -0.5 })
            expect(Updater:GetPollDelay(1)).to.equal(POLL_RATE)
        end)

        it("should ignore values that are not finite numbers", function()
            Updater:SetPollingDirective({ intervalSeconds = "600", jitterRatio = "0.5" })
            expect(Updater:GetPollDelay(1)).to.equal(POLL_RATE)

            Updater:SetPollingDirective({ intervalSeconds = math.huge })
            expect(Updater:GetPollDelay()).to.equal(POLL_RATE)

            Updater:SetPollingDirective({ intervalSeconds = 0 / 0 })
            expect(Updater:GetPollDelay()).to.equal(POLL_RATE)
        end)

        it("should drop a directive that is not an object", function()
            Updater:SetPollingDirective({ intervalSeconds = 600 })
            Updater:SetPollingDirective("600")
            expect(Updater:GetPollDelay()).to.equal(POLL_RATE)
        end)

        it("should forget a directive that is no longer sent", function()
            Updater:SetPollingDirective({ intervalSeconds = 600, jitterRatio = 1 })
            Updater:SetPollingDirective(nil)
            expect(Updater:GetPollDelay(1)).to.equal(POLL_RATE)
        end)
    end)
end
