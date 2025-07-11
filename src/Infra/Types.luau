type SDKSettings = {
	-- Enables SDK warnings for API misuse, internal errors, etc.
	sdkWarningsEnabled : boolean,
	-- Enables stack trace inclusion with warning messages.
	includeWarningStackTrace : boolean,
	-- Enables SDK debug messages for internal state changes, etc.
	sdkDebugEnabled : boolean,
	-- Custom URL for the SDK, if any.
	customUrl : string | nil,
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


--// Public API Types

export type ConfigsService = {
	Get : (self : ConfigsService, path : string | { string }) -> any,
	Observe : (self : ConfigsService, targetConfig : string | { string }, callback : (newValue : any, oldValue : any) -> ()) -> RBXScriptConnection,
	OnChanged : (self : ConfigsService, targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) -> RBXScriptConnection,
	OnReady : (self : ConfigsService, callback : (configs : any) -> ()) -> RBXScriptConnection,
	IsReady : (self : ConfigsService) -> boolean,
	GetForPlayer : (self : ConfigsService, player : Player, path : string | { string }) -> any,
	ObserveForPlayer : (self : ConfigsService, player : Player, targetConfig : string | { string }, callback : (newValue : any, oldValue : any) -> ()) -> RBXScriptConnection,
	OnChangedForPlayer : (self : ConfigsService, player : Player, targetConfig : string | {string}, callback : (newValue : any, oldValue : any) -> ()) -> RBXScriptConnection,
}

export type MarkersService = {
	SendMarker : (self : MarkersService, marker : string, data : JSON, position : Vector3?) -> (),
	SendPlayerMarker : (self : MarkersService, player : Player, marker : string, data : JSON, position : Vector3?) -> (),
	SendNewPurchaseGrantedMarker : (self : MarkersService, recieptInfo : {[string] : number | string}, position : Vector3?) -> (),
}

export type JobsService = {
	SetCallback : (self : JobsService, jobName : string, callback : (jobData : {[string] : any}) -> (any)) -> ()
}

export type EventsService = {
	GetEventData : (self : EventsService, event : string) -> JSON,
	OnStart : (self : EventsService, event : string, callback : (data : JSON) -> ()) -> RBXScriptConnection,
	OnEnd : (self : EventsService, event : string, callback : (data : JSON) -> ()) -> RBXScriptConnection,
}

export type ExperimentsService = {
	GetGroupForPlayer: (self: ExperimentsService, player: Player) -> ExperimentGroupMetadata?,
}
export type ExperimentGroupMetadata = {
	experimentName: string,
	groupName: string,
}

export type Service = ConfigsService | MarkersService | EventsService | JobsService | ExperimentsService

return true