--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    GetRemote.luau
    
    Description:
        A utility module for retrieving or creating remote functions or events.
    
--]]

--= Roblox Services =--

local RunService = game:GetService("RunService")

--= Dependencies =--

--= Types =--

--= Internal Functions =--

-- Some experiences load slowly, so this waits 30s before its own infinite yield warning
local function WaitForRemoteFolder()
    local didWarn = false
    repeat
        local remoteFolder = script:WaitForChild("Remotes", 30)
        if remoteFolder then
            return remoteFolder
        end

        if not didWarn then
            warn("[Gamebeast] Remote folder not found after 30 seconds, infinite yield is possible.")
            didWarn = true
        end
    until remoteFolder ~= nil
end


--= Object References =--

local RemotesFolder = RunService:IsClient() and WaitForRemoteFolder() or Instance.new("Folder", script)
RemotesFolder.Name = "Remotes"

--= Constants =--

local IS_SERVER = RunService:IsServer()

--= Variables =--

--= Public Variables =--


--= API Functions =--

--= Initializers =--

--= Return Module =--
return function(remoteType : "Function" | "Event", name : string) : RemoteFunction | RemoteEvent
    local remote = if IS_SERVER then RemotesFolder:FindFirstChild(remoteType..name) else RemotesFolder:WaitForChild(remoteType..name)
	if not remote then
		remote = Instance.new("Remote"..remoteType, RemotesFolder)
		remote.Name = remoteType..name
	end

	return remote
end