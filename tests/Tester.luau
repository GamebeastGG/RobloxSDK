--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Tester.luau
    
    Description:
        Runs the TestEZ specs. In Studio:
        1. Press play and switch to the server context
        2. Set RunServerTest or RunClientTest on ReplicatedStorage.TestRunnerRemote to true
        3. Check the output for the results
--]]

--= Root =--
local Tester = { }

--= Roblox Services =--
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")

--= Object References =--

local TestsFolder = ReplicatedFirst:WaitForChild("Tests")

--= Dependencies =--

local TestEZ = require(TestsFolder:WaitForChild("DevPackages"):WaitForChild("testez"))

--= Variables =--

local ToRun = {}

--= Public Variables =--

--= Internal Functions =--

local function CheckForTests(modulesFolder : Folder, exempt : {string})
    for _, module in ipairs(modulesFolder:GetChildren()) do
        if module:IsA("ModuleScript") then
            local moduleName = module.Name

            local isExempt = false
            for _, exemptedModule in ipairs(exempt) do
                if (exemptedModule..".spec") == moduleName then
                    isExempt = true
                    break
                end
            end

            if not isExempt then
                table.insert(ToRun, module)
            else
                warn("Exempted test: "..moduleName)
            end
        end
    end
end

--= API Functions =--

function Tester:Run(exemptTests : {string})
    local IsServer = RunService:IsServer()

    CheckForTests(TestsFolder.Shared, exemptTests)
    CheckForTests(IsServer and TestsFolder.Server or TestsFolder.Client, exemptTests)

    TestEZ.TestBootstrap:run(ToRun)
end

--= Return Module =--
return Tester