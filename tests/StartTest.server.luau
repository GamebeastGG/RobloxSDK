local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tester = require(ReplicatedFirst.Tests.Tester)

local ClientTestRemote = Instance.new("RemoteEvent", ReplicatedStorage)
ClientTestRemote.Name = "TestRunnerRemote"

ClientTestRemote:SetAttribute("RunServerTest", false)
ClientTestRemote:SetAttribute("RunClientTest", false)

ClientTestRemote:GetAttributeChangedSignal("RunServerTest"):Connect(function()
    local run = ClientTestRemote:GetAttribute("RunServerTest")
    if not run then return end

    Tester:Run({
        "Changesets",
        "Markers"
    })

    ClientTestRemote:SetAttribute("RunServerTest", false)
end)

ClientTestRemote:GetAttributeChangedSignal("RunClientTest"):Connect(function()
    local run = ClientTestRemote:GetAttribute("RunClientTest")
    if not run then return end

    ClientTestRemote:FireAllClients()

    ClientTestRemote:SetAttribute("RunClientTest", false)
end)