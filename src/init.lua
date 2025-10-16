--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	Gamebeast.lua
	
	Description:
		Primary SDK entry point and module loader.
	
--]]

--= Root =--

local Gamebeast = { }

--= Roblox Services =--

local RunService = game:GetService("RunService")

--= Dependencies =--

local Types = require(script.Infra.Types)

--= Types =--

export type ServerSetupConfig = Types.ServerSetupConfig
export type JSON = Types.JSON

-- Services
export type ConfigsService = Types.ConfigsService
export type MarkersService = Types.MarkersService
export type JobsService = Types.JobsService
export type EventsService = Types.EventsService
export type ExperimentsService = Types.ExperimentsService

type ModuleData = {
	Name : string,
	Instance : ModuleScript,
	Loaded : boolean,
	Module : { [string] : any } | nil
}

type PublicModuleData = {
	Name : string,
	Instance : ModuleScript,
}

--= Constants =--

local DEFAULT_SETTINGS = {
	sdkWarningsEnabled = true,
	includeWarningStackTrace = false,
	sdkDebugEnabled = false,
	customUrl = nil, -- Custom domain for the SDK, if any
}

--= Object References =--

--= Variables =--

local Modules = {} :: { [string] : ModuleData }
local PublicModules = {} :: { [string] : ModuleData }
local Initializing = false
local DidRequire = false
local IsServer = RunService:IsServer()

--= Internal Functions =--

local function RequireModule(moduleData : ModuleData)
	if moduleData.Loaded then
		return moduleData.Module
	end

	local module = require(moduleData.Instance)
	moduleData.Module = module
	moduleData.Loaded = true

	return module
end

local function AddModule(module : ModuleScript, isPublic : boolean?)
	if isPublic then
		PublicModules[module.Name] = {
			Name = module.Name,
			Instance = module,
		}
	else
		local moduleData = {
			Name = module.Name,
			Instance = module,
			Loaded = false,
			Module = nil,
		}

		Modules[module.Name] = moduleData
	end
end

local function AddModuleFolder(modulesFolder : Instance)

	local function search(folder : Folder, isPublic : boolean?)
		for _, module in ipairs(folder:GetChildren()) do
			if module:IsA("ModuleScript") then
				AddModule(module, isPublic)
			end
			search(module, isPublic)
		end
	end

	search(modulesFolder:WaitForChild("Modules"))
	search(modulesFolder:WaitForChild("Public"), true)

	local function moduleAddedLate(module : ModuleScript, public : boolean?)
		if module:IsA("ModuleScript") then
			AddModule(module, public)
			if DidRequire and not public then
				RequireModule(Modules[module.Name])
			end
		end
	end

	modulesFolder.Modules.DescendantAdded:Connect(moduleAddedLate)
	modulesFolder.Public.DescendantAdded:Connect(function(module : ModuleScript)
		moduleAddedLate(module, true)
	end)
end

local function FindModule(moduleCache : {[string] : ModuleData | PublicModuleData}, name : string, timeout : number?)
	local startTime = tick()
	while (tick() - startTime < (timeout or 5)) do
		if moduleCache[name] then
			return moduleCache[name]
		end
		task.wait()
	end

	error("Gamebeast service \"".. name.. "\" not found!")
end

local function GetModule(name : string) : ModuleData?
	return FindModule(Modules, name)
end

local function GetPublicModule(name : string) : PublicModuleData?
	return FindModule(PublicModules, name)
end

local function StartSDK()
	if Initializing then
		return
	end

	Initializing = true

	local targetModules = IsServer and script.Infra.Server or script.Infra.Client

	AddModuleFolder(targetModules)
	AddModuleFolder(script.Infra.Shared)

	AddModule(script.Infra:WaitForChild("MetaData"))

	-- Set settings

	local dataCacheModule = RequireModule(GetModule("DataCache"))
	--NOTE: All modules that use settings should await them if they are needed during init.
	dataCacheModule:Set("Settings", table.clone(DEFAULT_SETTINGS))

	-- Require all modules
	for _, moduleData in (Modules) do
		--local startTime = tick()
		RequireModule(moduleData)

		--[[if tick() - startTime > 0.1 then
			warn("Required module", moduleData.Name, "in", tick() - startTime)
		end]]
	end
	DidRequire = true

	-- Initialize all modules
	--TODO: Priority system
	for _, moduleData in (Modules) do
		if type(moduleData.Module) ~= "table" then
			continue
		end

		local InitMethod = rawget(moduleData.Module, "Init")
		if InitMethod then
			task.spawn(InitMethod, moduleData.Module)
		end
	end
end

--= Object References =--

--= Constants =--

--= Variables =--

--= Public Variables =--

--= API Functions =--

function Gamebeast:GetService(name : string) : Types.Service
	StartSDK()
	name = string.gsub(name, "Service", "")

	local module = GetPublicModule(name)
	if module then
		return require(module.Instance)
	else
		error("Gamebeast service \"".. name.. "\" not found!")
	end
end

function Gamebeast:Setup(setupConfig : ServerSetupConfig?)
	if IsServer == true then
		assert(setupConfig, "Gamebeast SDK requires a setup config on the server.")
		assert(setupConfig.key, "Gamebeast SDK requires a key to be set in the setup config.")
	end
	if IsServer == false then
		setupConfig = setupConfig or {}
		assert(setupConfig.key == nil, "Gamebeast SDK key should not be set on the client.")
	end

	local sdkSettings = setupConfig.sdkSettings or {}

	for key, value in DEFAULT_SETTINGS do
		if sdkSettings[key] == nil then
			sdkSettings[key] = value
		end
	end

	StartSDK()

	local dataCacheModule = RequireModule(GetModule("DataCache"))
	dataCacheModule:Set("Key", setupConfig.key)
	dataCacheModule:Set("Settings", sdkSettings)
end

--= Initializers =--
do
	shared.GBMod = function(name : string)
		local moduleData = GetModule(name)
		if moduleData then
			return RequireModule(moduleData)
		else
			--Utilities.GBWarn("Gamebeast module \"".. name.. "\" not found!")
		end
	end
end

--= Return Module =--

return Gamebeast