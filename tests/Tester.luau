--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    Tester.luau
    
    Description:
        Tester module to run tests.

        Run tests in studio.
        1. Press play
        2. Switch to server context
        3. Go to replicatedStorage and find the Test remote event
        4. Look for the RunTest attributes
        5. Set the attributes to true to run the test.
        6. Check the output for the test results.    
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