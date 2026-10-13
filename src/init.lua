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

--= Setting Validators =--

-- For error messages. Strings are quoted so an empty one is visible
local function DescribeValue(val : any) : string
	if type(val) == "string" then
		return `"{val}"`
	end
	return `{tostring(val)} ({typeof(val)})`
end

local function BooleanValidator(val : any) : (boolean, string?)
	if type(val) ~= "boolean" then
		return false, `Expected true or false, got {DescribeValue(val)}.`
	end
	return true
end

-- `minimum` keeps request volume sane. `maximum` is for data the backend needs at least that often
local function SecondsValidator(minimum : number, maximum : number?) : (val : any) -> (boolean, string?)
	return function(val)
		if type(val) ~= "number" or val ~= val then
			return false, `Expected a number of seconds, got {DescribeValue(val)}.`
		end
		if val < minimum then
			return false, `Expected at least {minimum} seconds, got {val}.`
		end
		if maximum and val > maximum then
			return false, `Expected at most {maximum} seconds, got {val}.`
		end
		return true
	end
end

--= Constants =--

--[[
	`studioValue` is the default in Studio, so dashboard edits show up quickly while testing. It only
	fills in settings left out of Setup, and the validators still apply.
]]
local DEFAULT_SETTINGS = {
	sdkWarningsEnabled = {
		value = true,
		validator = BooleanValidator,
	},
	includeWarningStackTrace = {
		value = false,
		validator = BooleanValidator,
	},
	sdkDebugEnabled = {
		value = false,
		validator = BooleanValidator,
	},
	customUrl = {
		value = nil,
		validator = function(val)
			if val ~= nil and type(val) ~= "string" then
				return false, `Expected a URL string or nil, got {DescribeValue(val)}.`
			end
			return true
		end
	},
	environment = {
		value = nil,
		validator = function(val)
			-- Markers, server reports and cohorts only know these two, so a custom one would split a game's data
			if val ~= nil and val ~= "production" and val ~= "studio" then
				return false, `Expected "production", "studio" or nil, got {DescribeValue(val)}.`
			end
			return true
		end
	},
	markerFlushRate = {
		value = 10,
		studioValue = 2,
		validator = SecondsValidator(1),
	},
	statusPollRate = {
		value = 30,
		studioValue = 5,
		validator = SecondsValidator(5),
	},
	assignmentRefreshRate = {
		value = 30,
		studioValue = 10,
		validator = SecondsValidator(10),
	},
	serverReportRate = {
		value = 30,
		studioValue = 10,
		-- Capped under a minute, since concurrent player counts are built per minute from these reports
		validator = SecondsValidator(10, 45),
	},
}

-- Refused by :UpdateSettings(). They pick the backend, and data already loaded stays keyed to the old one.
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
local IsStudio = RunService:IsStudio()

--= Internal Functions =--

local function GetDefaultValue(settingData : { value : any, studioValue : any? }) : any
	if IsStudio and settingData.studioValue ~= nil then
		return settingData.studioValue
	end
	return settingData.value
end

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
		defaultSettings[key] = GetDefaultValue(settingData)
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
			sdkSettings[key] = GetDefaultValue(settingData)
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
	Changes settings on a running SDK. Omitted settings keep their value, and nothing is applied unless
	every given setting is valid. Changes apply from each setting's next use, so the polling and flush
	loops pick theirs up within a few seconds. `environment` and `customUrl` are Setup only.
]]
function Gamebeast:UpdateSettings(sdkSettings : RuntimeSDKSettings)
	assert(type(sdkSettings) == "table", "Gamebeast:UpdateSettings expects a table of settings.")
	assert(DidSetup, "Gamebeast:UpdateSettings can only be used after Gamebeast:Setup().")

	-- Validated up front so one bad value applies nothing
	for key, value in sdkSettings do
		if SETUP_ONLY_SETTINGS[key] then
			error(`The Gamebeast SDK setting "{key}" can only be set in Gamebeast:Setup().`, 2)
		end

		ValidateSetting(key, value)
	end

	-- Written into the live table, so references to it stay current
	local settings = RequireModule(GetModule("DataCache")):Get("Settings")
	for key, value in sdkSettings do
		settings[key] = value
	end
end

--= Return Module =--

return Gamebeast