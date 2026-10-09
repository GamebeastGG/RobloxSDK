--[[
    Unit tests for how the statusPollRate setting and the polling object returned by the bootstrap and
    status endpoints combine into the delay between status polls. No dashboard interaction required.
]]

return function()
    local DataCache = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast").Infra.Shared.Modules.DataCache)
    local Updater = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast").Infra.Server.Modules.Updater)

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

        -- The backend's normal response: jitter only, with an interval added just to shed load
        it("should spread polls on the setting when Gamebeast sends only a jitter ratio", function()
            Updater:SetPollingDirective({ jitterRatio = 0.5 })
            expect(Updater:GetPollDelay(0)).to.equal(POLL_RATE)
            expect(Updater:GetPollDelay(1)).to.equal(POLL_RATE * 1.5)

            -- A low setting takes effect, since nothing is holding servers back
            settings.statusPollRate = 5
            expect(Updater:GetPollDelay(0)).to.equal(5)
        end)

        it("should slow down to a load-shedding interval and recover when it is withdrawn", function()
            Updater:SetPollingDirective({ jitterRatio = 0.2 })
            expect(Updater:GetPollDelay(0)).to.equal(POLL_RATE)

            Updater:SetPollingDirective({ intervalSeconds = 300, jitterRatio = 0.2 })
            expect(Updater:GetPollDelay(0)).to.equal(300)

            Updater:SetPollingDirective({ jitterRatio = 0.2 })
            expect(Updater:GetPollDelay(0)).to.equal(POLL_RATE)
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

    describe("GetConnectionRetryDelay", function()
        it("should double from 10s up to 5 minutes", function()
            expect(Updater:GetConnectionRetryDelay(1, nil, 0)).to.equal(10)
            expect(Updater:GetConnectionRetryDelay(2, nil, 0)).to.equal(20)
            expect(Updater:GetConnectionRetryDelay(3, nil, 0)).to.equal(40)
            expect(Updater:GetConnectionRetryDelay(10, nil, 0)).to.equal(300)
        end)

        it("should go straight to the longest wait when the key is rejected", function()
            expect(Updater:GetConnectionRetryDelay(1, 401, 0)).to.equal(300)
            expect(Updater:GetConnectionRetryDelay(1, 403, 0)).to.equal(300)
        end)

        it("should only ever add jitter", function()
            expect(Updater:GetConnectionRetryDelay(1, nil, 1)).to.equal(12.5)
            for _ = 1, 100 do
                local delay = Updater:GetConnectionRetryDelay(2)
                expect(delay >= 20 and delay <= 25).to.equal(true)
            end
        end)
    end)

    describe("IsVersionOutdated", function()
        it("should compare version parts as numbers", function()
            expect(Updater:IsVersionOutdated("v1.9.0", "v1.10.0")).to.equal(true)
            expect(Updater:IsVersionOutdated("v1.10.0", "v1.9.0")).to.equal(false)
            expect(Updater:IsVersionOutdated("v1.0.0", "v1.0.1")).to.equal(true)
            expect(Updater:IsVersionOutdated("v1.0.0", "v1.0.0")).to.equal(false)
        end)

        it("should accept versions with or without the v prefix", function()
            expect(Updater:IsVersionOutdated("v1.0.0", "1.1.0")).to.equal(true)
        end)

        it("should not warn when a version can't be read", function()
            expect(Updater:IsVersionOutdated("v1.0.0", "latest")).to.equal(false)
            expect(Updater:IsVersionOutdated("v1.0.0", nil)).to.equal(false)
        end)
    end)
end
