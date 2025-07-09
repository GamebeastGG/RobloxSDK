--[[
    The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
    All rights reserved.

    Schema.lua
    
    Description:
        No description provided.
    
--]]

--= Root =--

local Schema = {}
Schema.__index = Schema

--= Roblox Services =--

--= Dependencies =--

--= Types =--

--= Object References =--

--= Constants =--

--= Variables =--

--= Internal Functions =--

--= Constructor =--

function Schema.new(structure : {[string] : {default : any | () -> any, type : string | {string}}})
    local self = setmetatable({}, Schema)

    for _, valueSchema in structure do
        if type(valueSchema.type) == "string" then
            valueSchema.type = {valueSchema.type} -- Ensure type is a table of types
        end

        local dictonary = {}
        for _, typeName in ipairs(valueSchema.type) do
            dictonary[typeName] = true -- Create a dictionary for fast type checking
        end

        valueSchema.type = dictonary
    end

    self._structure = structure

    return self
end

--= Methods =--

function Schema:GetDefault() : {[string] : any}
    local defaults = {}

    for key, value in pairs(self._structure) do
        if type(value.default) == "function" then
            defaults[key] = value.default()
        else
            defaults[key] = value.default
        end
    end

    return defaults
end

function Schema:GetDefaultForKey(key : string) : any
    local field = self._structure[key]
    if not field then
        error("Key '" .. key .. "' does not exist in schema.")
    end

    if type(field.default) == "function" then
        return field.default()
    else
        return field.default
    end
end

function Schema:HasKey(key : string) : boolean
    return self._structure[key] ~= nil
end

function Schema:Sanitize(data : {[string] : any})
    for key, value in pairs(data) do
        if self._structure[key] == nil then
            data[key] = nil -- Remove keys not in the schema
        end

        if not self._structure[key].type[type(value)] then
            data[key] = nil -- Remove keys with incorrect type
        end
    end

    return data
end

function Schema:Destroy()
    -- Nothing to clean up in this case
end

return Schema