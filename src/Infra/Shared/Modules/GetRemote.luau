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

--= Object References =--

local RemotesFolder = RunService:IsClient() and script:WaitForChild("Remotes") or Instance.new("Folder", script)
RemotesFolder.Name = "Remotes"

--= Constants =--

local IS_SERVER = RunService:IsServer()

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

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