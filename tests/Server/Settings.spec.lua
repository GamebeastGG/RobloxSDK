--[[
    Unit tests for changing SDK settings on a running SDK. These run against the live settings table
    and put back what they found, so they need the SDK to have been set up.
]]

return function()
    local Gamebeast = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast"))
    local DataCache = shared.GBMod("DataCache")

    local settings = DataCache:Get("Settings")

    describe("UpdateSettings", function()
        local previous

        beforeEach(function()
            previous = table.clone(settings)
        end)

        afterEach(function()
            for key, value in previous do
                settings[key] = value
            end
        end)

        it("should change only the settings it is given", function()
            local markerFlushRate = settings.markerFlushRate

            Gamebeast:UpdateSettings({ statusPollRate = 123 })

            expect(settings.statusPollRate).to.equal(123)
            expect(settings.markerFlushRate).to.equal(markerFlushRate)
        end)

        it("should apply several settings at once", function()
            Gamebeast:UpdateSettings({ statusPollRate = 45, markerFlushRate = 3, sdkDebugEnabled = true })

            expect(settings.statusPollRate).to.equal(45)
            expect(settings.markerFlushRate).to.equal(3)
            expect(settings.sdkDebugEnabled).to.equal(true)
        end)

        it("should refuse a value its setting rejects", function()
            Gamebeast:UpdateSettings({ statusPollRate = 60 })

            expect(function()
                Gamebeast:UpdateSettings({ statusPollRate = 1 })
            end).to.throw()

            expect(settings.statusPollRate).to.equal(60)
        end)

        it("should refuse a key that is not a setting", function()
            expect(function()
                Gamebeast:UpdateSettings({ statusPollRates = 60 })
            end).to.throw()

            expect(settings.statusPollRates).never.to.be.ok()
        end)

        it("should refuse the settings only Setup can take", function()
            expect(function()
                Gamebeast:UpdateSettings({ environment = "development" })
            end).to.throw()

            expect(function()
                Gamebeast:UpdateSettings({ customUrl = "http://localhost:3001" })
            end).to.throw()
        end)

        it("should apply none of the settings when one of them is invalid", function()
            Gamebeast:UpdateSettings({ statusPollRate = 60, markerFlushRate = 10 })

            expect(function()
                Gamebeast:UpdateSettings({ statusPollRate = 0, markerFlushRate = 20 })
            end).to.throw()

            expect(settings.statusPollRate).to.equal(60)
            expect(settings.markerFlushRate).to.equal(10)
        end)
    end)
end
