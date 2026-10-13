--[[
    Config paths into arrays. Paths are lists of strings, so an array element is addressed by a
    segment like "2". Registers a configuration of its own, since the project this place is set up
    with may not have a list in any of its documents. The Gamebeast SDK must be running so internal
    modules are loaded.
]]

return function()
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Gamebeast = require(ReplicatedStorage:WaitForChild("Gamebeast"))
    local InternalConfigs = require(ReplicatedStorage.Gamebeast.Infra.Server.Modules.InternalConfigs)
    local ConfigsService = Gamebeast:GetService("Configs") :: Gamebeast.ConfigsService

    local CONFIG_ID = 990002
    local ALIAS = "__gbConfigPathsSpec"
    local CALLBACK_TIMEOUT = 5

    local function document(secondName : string)
        return {
            Items = {
                { Name = "a", Tags = { "x", "y" } },
                { Name = secondName },
            },
        }
    end

    local function apply(view, init : boolean?)
        InternalConfigs:SetBaseConfig({
            id = CONFIG_ID,
            name = ALIAS,
            alias = ALIAS,
            hash = view.Items[2].Name,
            configuration = view,
            privacy = {},
        })
        InternalConfigs:ApplyConfigs(nil, CONFIG_ID, view, init)
    end

    describe("Paths into arrays", function()
        beforeAll(function()
            InternalConfigs:WaitForConfigsReady()
            apply(document("b"), true)
        end)

        afterAll(function()
            InternalConfigs:RemoveConfig(CONFIG_ID)
        end)

        it("should reach an array element through a string segment", function()
            expect(ConfigsService:Get({ ALIAS, "Items", "2", "Name" })).to.equal("b")
            expect(ConfigsService:Get({ ALIAS, "Items", "1", "Tags", "2" })).to.equal("y")
        end)

        it("should return nothing for an index past the end of an array", function()
            expect(ConfigsService:Get({ ALIAS, "Items", "3" })).never.to.be.ok()
        end)

        it("should hand OnChanged the new and old values of an array element", function()
            local newValue, oldValue
            local connection = ConfigsService:OnChanged({ ALIAS, "Items", "2", "Name" }, function(new, old)
                newValue, oldValue = new, old
            end)

            apply(document("c"))

            local waited = 0
            while newValue == nil and waited < CALLBACK_TIMEOUT do
                waited += task.wait(0.1)
            end
            connection:Disconnect()

            expect(newValue).to.equal("c")
            expect(oldValue).to.equal("b")
        end)
    end)
end
