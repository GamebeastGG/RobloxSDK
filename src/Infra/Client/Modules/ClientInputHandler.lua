--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.

    ClientInputHandler.luau

    Description:
        Tracks the current input type and device type of the client.
]]

--= Root =--
local ClientInputHandler = { }

--= Roblox Services =--

local UserInputService = game:GetService("UserInputService")
local VRService = game:GetService("VRService")

--= Dependencies =--

local ClientInfoHandler = shared.GBMod("ClientInfoHandler") ---@module ClientInfoHandler
local Signal = shared.GBMod("Signal") ---@module Signal

--= Types =--

--= Object References =--

local InputTypeChangedSignal = Signal.new()

--= Constants =--

--= Variables =--

local CurrentInputType = nil

--= Public Variables =--

--= Internal Functions =--

local function DetermineInputTypeString(inputEnum) 
    if inputEnum == Enum.UserInputType.Keyboard then
        return "keyboard"
    elseif inputEnum == Enum.UserInputType.Touch then
        return "touch"
    elseif string.match(tostring(inputEnum),"Gamepad") then
        return "gamepad"
    end
end
--= API Functions =--

--= API Functions =--

function ClientInputHandler:GetDeviceType() : (string, string)
    -- Determine device type
    local deviceType = "unknown"
    if UserInputService.VREnabled or VRService.VREnabled then
        deviceType = "vr"
    elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		deviceType = "mobile"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		deviceType = "console"
	elseif UserInputService.KeyboardEnabled then
		deviceType = "pc"
	end

    -- Determine device subtype
    local deviceSubType = "unknown"
    if deviceType == "mobile" then
        local camera = workspace.CurrentCamera
        if camera then
            local longestSide = math.max(camera.ViewportSize.X, camera.ViewportSize.Y)
            local shortestSide = math.min(camera.ViewportSize.X, camera.ViewportSize.Y)
            local aspectRatio = longestSide / shortestSide
            if aspectRatio > 1.8 then
                deviceSubType = "phone"
            elseif aspectRatio <= 1.7 then
                deviceSubType = "tablet"
            else -- Devices in this range can be either phone or tablet equally. Older devices share the 16:9 aspect ratio.
                deviceSubType = "phone" -- We'll assume phone for now, since phone users are more common.
            end
        end
    elseif deviceType == "console" then
        local imageUrl = UserInputService:GetImageForKeyCode(Enum.KeyCode.ButtonX)
        if string.find(imageUrl, "Xbox") then
            deviceSubType = "xbox"
        elseif string.find(imageUrl, "PlayStation") then
            deviceSubType = "playstation"
        else
            deviceSubType = "unknown"
        end
    elseif deviceType == "vr" then
        deviceSubType = "unknown" -- No reliable way to determine VR headset type in Roblox.
    elseif deviceType == "pc" then
        deviceSubType = "unknown" -- No reliable way to determine PC type in Roblox
    end

    return deviceType, deviceSubType
end

function ClientInputHandler:OnInputTypeChanged(callback : (string) -> ()) : RBXScriptConnection
    return InputTypeChangedSignal:Connect(callback)
end

function ClientInputHandler:GetCurrentInputType() : string
    if not CurrentInputType then
        if UserInputService.GamepadEnabled then
            CurrentInputType = "gamepad"
        elseif UserInputService.TouchEnabled then
            CurrentInputType = "touch"
        else
            CurrentInputType = "keyboard"
        end
    end
    return CurrentInputType
end

--= Initializers =--
function ClientInputHandler:Init()
    local function inputTypeChanged(inputType : string)
        if CurrentInputType ~= inputType then
            CurrentInputType = inputType
            InputTypeChangedSignal:Fire(CurrentInputType)
            ClientInfoHandler:UpdateClientInfo("inputType", CurrentInputType)
        end
    end

    local deviceType, deviceSubType = self:GetDeviceType()
    ClientInfoHandler:UpdateClientInfo("inputType", ClientInputHandler:GetCurrentInputType())
    ClientInfoHandler:UpdateClientInfo("deviceSubType", deviceSubType)
    ClientInfoHandler:UpdateClientInfo("device", deviceType)

    --// Detect CurrentInputType changes from 'LastInputType'
    UserInputService.LastInputTypeChanged:Connect(function(lastType)
        local newType = DetermineInputTypeString(lastType)
        if newType and newType ~= CurrentInputType then
            inputTypeChanged(newType)
        end
    end)

    UserInputService.InputChanged:Connect(function(InputObject)
        if InputObject.UserInputType == Enum.UserInputType.MouseMovement then
            inputTypeChanged("keyboard")
        end
    end)
end

--= Return Module =--
return ClientInputHandler