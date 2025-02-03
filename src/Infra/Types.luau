type SDKSettings = {
	-- Enables SDK warnings for API misuse, internal errors, etc.
	sdkWarningsEnabled : boolean,
	-- Enables stack trace inclusion with warning messages.
	includeWarningStackTrace : boolean,
}
export type ServerSetupConfig = {
	key : string | Secret,
	sdkSettings : SDKSettings?
}

--NOTE: The actual JSON type doesnt get represented cleanly in Roblox's intellesense. This is a simplified version for now.
export type JSON = any
--[[{
    [string] : (number | string | boolean | JSON)
} | { number | string | boolean | JSON }
 ]]

--// Service subtypes
export type HeatmapWaypointAppearanceInfo = {
    color : Color3,
    shape : "Square" | "Circle"
}

--// Public API Types

export type ConfigsService = {
	Get : (self : ConfigsService, path : string | { string }) -> any,
	OnChanged : (self : ConfigsService, targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) -> RBXScriptConnection,
	OnReady : (self : ConfigsService, callback : (configs : any) -> ()) -> RBXScriptSignal,
	IsReady : (self : ConfigsService) -> boolean,
}

export type MarkersService = {
	SendMarker : (self : MarkersService, marker : string, data : JSON, position : Vector3?) -> (),
	SendPlayerMarker : (server : MarkersService, player : Player, marker : string, data : JSON, position : Vector3?) -> (),
}

export type EventsService = {
	GetEventData : (self : EventsService, event : string) -> JSON,
	OnStart : (self : EventsService, event : string, callback : (data : JSON) -> ()) -> RBXScriptConnection,
	OnEnd : (self : EventsService, event : string, callback : (data : JSON) -> ()) -> RBXScriptConnection,
}

export type HeatmapsService = {
	RegisterHeatmap : (self : HeatmapsService, heatmapName : string, positionA : Vector3, positionB : Vector3) -> (),
	AddHeatmapWaypoint : (self : HeatmapsService, heatmapName : string, waypointName : string, position : Vector3, appearanceInfo : HeatmapWaypointAppearanceInfo) -> (),
}

export type Service = ConfigsService | MarkersService | EventsService | HeatmapsService

return true