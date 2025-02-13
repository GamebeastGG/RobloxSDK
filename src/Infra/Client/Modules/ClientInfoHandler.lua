--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.
    
    ClientInfoHandler.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--
local ClientInfoHandler = { }

--= Roblox Services =--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VRService = game:GetService("VRService")

--= Dependencies =--

local GetRemote = shared.GBMod("GetRemote")

--= Types =--

--= Object References =--

local ClientInfoRemote = GetRemote("Event", "ClientInfoChanged")

--= Constants =--

--= Variables =--

--= Public Variables =--

--= Internal Functions =--

--= API Functions =--

function ClientInfoHandler:GetDeviceType() : string
    if UserInputService.VREnabled or VRService.VREnabled then
        return "vr"
    elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "mobile"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "console"
	elseif UserInputService.KeyboardEnabled then
		return "pc"
	else
		return "unknown"
	end
end

--= Initializers =--
function ClientInfoHandler:Init()
    ClientInfoRemote:FireServer({
        device = self:GetDeviceType()
    })
end

--= Return Module =--
return ClientInfoHandler