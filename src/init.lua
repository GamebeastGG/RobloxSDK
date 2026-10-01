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
export type RuntimeSDKSettings = Types.RuntimeSDKSettings

-- Services
export type ConfigsService = Types.ConfigsService
export type MarkersService = Types.MarkersService
export type ExperimentsService = Types.ExperimentsService
export type ExperimentAssignment = Types.ExperimentAssignment
export type ExperimentPropertyValue = Types.ExperimentPropertyValue
export type CohortsService = Types.CohortsService

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
	sdkWarningsEnabled = {
		value = true,
		validator = function(val)
			return type(val) == "boolean"
		end
	},
	includeWarningStackTrace = {
		value = false,
		validator = function(val)
			return type(val) == "boolean"
		end
	},
	sdkDebugEnabled = {
		value = false,
		validator = function(val)
			return type(val) == "boolean"
		end
	},
	customUrl = {
		value = nil,
		validator = function(val)
			return type(val) == "string" or val == nil
		end
	},
	environment = {
		value = nil,
		validator = function(val)
			-- Built-in aliases are "production", "studio" and "development";
			-- any other non-empty string targets a custom environment by its alias.
			return val == nil or (type(val) == "string" and #val > 0)
		end
	},
	markerFlushRate = {
		value = 10,
		validator = function(val)
			return type(val) == "number" and val >= 1
		end
	},
	statusPollRate = {
		value = 30,
		validator = function(val)
			return type(val) == "number" and val >= 5
		end
	},
	assignmentRefreshRate = {
		value = 30,
		validator = function(val)
			return type(val) == "number" and val >= 10
		end
	},
}

-- Settings :UpdateSettings() refuses, because they decide which backend the SDK talks to: swapping
-- that mid-session would leave the configs, experiments and datastore backup it has already loaded
-- keyed to the environment they came from.
local SETUP_ONLY_SETTINGS = {
	customUrl = true,
	environment = true,
}

--= Object References =--

--= Variables =--

local Modules = {} :: { [string] : ModuleData }
local PublicModules = {} :: { [string] : ModuleData }
local Initializing = false
local DidRequire = false
local DidSetup = false
local IsServer = RunService:IsServer()

--= Internal Functions =--

local function ValidateSetting(key : string, value : any)
	local settingData = DEFAULT_SETTINGS[key]
	if not settingData then
		error(`"{key}" is not a Gamebeast SDK setting.`, 3)
	end

	local isValid, reason = settingData.validator(value)
	if isValid == false then
		error(`The value of the Gamebeast SDK setting "{key}" is invalid.{reason and " " .. reason or ""}`, 3)
	end
end

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
	local defaultSettings = {}
	for key, settingData in DEFAULT_SETTINGS do
		defaultSettings[key] = settingData.value
	end

	dataCacheModule:Set("Settings", defaultSettings)

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
	local sortedInit = {}
	for _, moduleData in (Modules) do
		if type(moduleData.Module) ~= "table" then
			continue
		end
		
		local InitMethod = rawget(moduleData.Module, "Init")
		if InitMethod then
			table.insert(sortedInit, {InitMethod = InitMethod, Module = moduleData.Module, Priority = rawget(moduleData.Module, "Priority") or 0})
		end
	end

	-- Lower the priority number, earlier it runs
	table.sort(sortedInit, function(a, b)
		return a.Priority < b.Priority
	end)

	for _, initData in ipairs(sortedInit) do
		task.spawn(initData.InitMethod, initData.Module)
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

	for key, settingData in DEFAULT_SETTINGS do
		if sdkSettings[key] == nil then
			sdkSettings[key] = settingData.value
		end

		ValidateSetting(key, sdkSettings[key])
	end

	StartSDK()

	local dataCacheModule = RequireModule(GetModule("DataCache"))
	dataCacheModule:Set("Key", setupConfig.key)
	dataCacheModule:Set("Settings", sdkSettings)

	DidSetup = true
end

--[[
	Changes SDK settings on a running SDK. Settings left out of the table keep their current value, and
	nothing is applied unless every setting given is valid.

	The SDK reads settings as it needs them rather than holding onto them, so a change takes effect
	from the next use: the status poll, assignment refresh and marker flush loops pick theirs up within a few seconds.

	`environment` and `customUrl` are refused here; they are only set in :Setup().
]]
function Gamebeast:UpdateSettings(sdkSettings : RuntimeSDKSettings)
	assert(type(sdkSettings) == "table", "Gamebeast:UpdateSettings expects a table of settings.")
	assert(DidSetup, "Gamebeast:UpdateSettings can only be used after Gamebeast:Setup().")

	-- Validated up front, so a bad value leaves the settings it was sent with untouched
	for key, value in sdkSettings do
		if SETUP_ONLY_SETTINGS[key] then
			error(`The Gamebeast SDK setting "{key}" can only be set in Gamebeast:Setup().`, 2)
		end

		ValidateSetting(key, value)
	end

	-- Written into the live table rather than replacing it, since the SDK reads fields off it
	local settings = RequireModule(GetModule("DataCache")):Get("Settings")
	for key, value in sdkSettings do
		settings[key] = value
	end
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