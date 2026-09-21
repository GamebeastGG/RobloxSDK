--[[
    Requires dashboard interaction.
    Create a configuration with the alias (or name) "TestConfig" containing:

    Test = {
        A = {
            B = "Hello"
        }
    }

    Then, run the test.

    NOTE: Config paths begin with the configuration's alias or name.
]]

return function()
    local Gamebeast = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast"))
    local ConfigsService = Gamebeast:GetService("Configs") :: Gamebeast.ConfigsService

    describe("Config", function()
        it("should get config ready status", function()
            local configReady = ConfigsService:IsReady()
            expect(configReady).to.be.a("boolean")
        end)

        it("should get a whole config", function()
            local config = ConfigsService:Get("TestConfig")
            expect(config).to.be.ok()
        end)

        it("should get a config value", function()
            local config = ConfigsService:Get({"TestConfig", "Test"})
            expect(config).to.be.ok()
        end)

        it("should get a config value from a nested path", function()
            local config = ConfigsService:Get({"TestConfig", "Test", "A", "B"})
            expect(config).to.be.equal("Hello")
        end)

        it("should listen to a config changing", function()
            ConfigsService:OnChanged("TestConfig", function(newValue)
                expect(newValue).to.be.ok()
            end)
        end)

        it("should listen to a config changing from table", function()
            ConfigsService:OnChanged({"TestConfig", "Test", "A", "B"}, function(newValue)
                expect(newValue).to.be.ok()
            end)
        end)
    end)
end
