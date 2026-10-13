--[[
    Exercises the public Configs service against whatever configurations this place's project has.
    Runs on both server and client, so it only touches the public service. The project needs at
    least one configuration, asserted up front so an empty project fails with a clear reason.

    NOTE: Config paths begin with the configuration's alias or name.
]]

return function()
    local Gamebeast = require(game:GetService("ReplicatedStorage"):WaitForChild("Gamebeast"))
    local ConfigsService = Gamebeast:GetService("Configs") :: Gamebeast.ConfigsService

    local RESOLVE_TIMEOUT = 10
    local CALLBACK_TIMEOUT = 5
    local MISSING_KEY = "__gbKeyThatDoesNotExist"

    -- OnReady passes every configuration keyed by identifier, so it doubles as discovery of what to test
    local function resolveConfigs() : any
        local resolved = nil
        ConfigsService:OnReady(function(configs)
            resolved = configs
        end)

        local waited = 0
        while resolved == nil and waited < RESOLVE_TIMEOUT do
            waited += task.wait(0.1)
        end

        return resolved
    end

    -- Finds a path to a scalar so the nested-path test works with any document shape. String keys
    -- only, so the order is stable. Array paths are covered by the server's ConfigPaths spec.
    local function findScalarPath(document : any) : ({ string }?, any)
        local keys = {}
        for key in document do
            if type(key) == "string" then
                table.insert(keys, key)
            end
        end
        table.sort(keys)

        for _, key in keys do
            local value = document[key]
            if type(value) ~= "table" then
                return { key }, value
            end

            local nestedPath, nestedValue = findScalarPath(value)
            if nestedPath then
                table.insert(nestedPath, 1, key)
                return nestedPath, nestedValue
            end
        end

        return nil, nil
    end

    local function sortedKeys(document : any) : string
        local keys = {}
        for key in document do
            table.insert(keys, tostring(key))
        end
        table.sort(keys)
        return table.concat(keys, ",")
    end

    -- Resolved once, on first use, so the yields stay inside test bodies
    local resolved = nil
    local function context()
        if not resolved then
            local configs = resolveConfigs()

            local identifiers = {}
            for identifier, document in configs or {} do
                if type(document) == "table" then
                    table.insert(identifiers, identifier)
                end
            end
            table.sort(identifiers)

            local identifier = identifiers[1]
            resolved = {
                configs = configs,
                identifier = identifier,
                document = identifier and configs[identifier],
            }
        end

        return resolved
    end

    describe("Config", function()
        it("should get config ready status", function()
            expect(ConfigsService:IsReady()).to.be.a("boolean")
        end)

        it("should be ready with a configuration to test against", function()
            expect(ConfigsService:IsReady()).to.equal(true)
            expect(context().identifier).to.be.ok()
        end)

        it("should get a whole config", function()
            local ctx = context()
            local config = ConfigsService:Get(ctx.identifier)

            expect(config).to.be.ok()
            expect(type(config)).to.equal("table")
            -- Get and the OnReady payload must describe the same document
            expect(sortedKeys(config)).to.equal(sortedKeys(ctx.document))
        end)

        it("should get a config value", function()
            local ctx = context()

            local topLevelKey = nil
            for key in ctx.document do
                if type(key) == "string" and (topLevelKey == nil or key < topLevelKey) then
                    topLevelKey = key
                end
            end

            expect(topLevelKey).to.be.ok()

            -- Compared by type, so a top-level false or nested table passes too
            local value = ConfigsService:Get({ ctx.identifier, topLevelKey })
            expect(type(value)).to.equal(type(ctx.document[topLevelKey]))
        end)

        it("should get a config value from a nested path", function()
            local ctx = context()
            local path, value = findScalarPath(ctx.document)

            expect(path).to.be.ok()

            local fullPath = { ctx.identifier }
            for _, segment in path do
                table.insert(fullPath, segment)
            end

            expect(ConfigsService:Get(fullPath)).to.equal(value)
        end)

        it("should return nothing for a path that does not exist", function()
            local ctx = context()
            expect(ConfigsService:Get({ ctx.identifier, MISSING_KEY })).never.to.be.ok()
            expect(ConfigsService:Get({ ctx.identifier, MISSING_KEY, MISSING_KEY })).never.to.be.ok()
        end)

        it("should return nothing for a path that runs past a plain value", function()
            local ctx = context()
            local path = findScalarPath(ctx.document)
            expect(path).to.be.ok()

            local fullPath = { ctx.identifier }
            for _, segment in path do
                table.insert(fullPath, segment)
            end
            table.insert(fullPath, MISSING_KEY)

            local ok, value = pcall(function()
                return ConfigsService:Get(fullPath)
            end)
            expect(ok).to.equal(true)
            expect(value).never.to.be.ok()
        end)

        it("should hand an observer the current value", function()
            local ctx = context()

            local observed = nil
            local didObserve = false
            local connection = ConfigsService:Observe(ctx.identifier, function(newValue)
                observed = newValue
                didObserve = true
            end)

            local waited = 0
            while not didObserve and waited < CALLBACK_TIMEOUT do
                waited += task.wait(0.1)
            end

            connection:Disconnect()

            expect(didObserve).to.equal(true)
            expect(type(observed)).to.equal("table")
        end)

        it("should listen to a config changing", function()
            local ctx = context()

            -- Only a dashboard edit fires this, so only the subscription itself is checked
            local connection = ConfigsService:OnChanged(ctx.identifier, function() end)

            expect(connection).to.be.ok()
            expect(connection.Connected).to.equal(true)

            connection:Disconnect()
            expect(connection.Connected).to.equal(false)
        end)

        it("should listen to a config changing from table", function()
            local ctx = context()
            local path = findScalarPath(ctx.document)

            expect(path).to.be.ok()

            local fullPath = { ctx.identifier }
            for _, segment in path do
                table.insert(fullPath, segment)
            end

            local connection = ConfigsService:OnChanged(fullPath, function() end)

            expect(connection).to.be.ok()
            expect(connection.Connected).to.equal(true)

            connection:Disconnect()
            expect(connection.Connected).to.equal(false)
        end)
    end)
end
