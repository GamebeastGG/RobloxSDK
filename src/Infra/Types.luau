type SDKSettings = {
	-- Enables SDK warnings for API misuse, internal errors, etc.
	sdkWarningsEnabled : boolean,
	-- Enables stack trace inclusion with warning messages.
	includeWarningStackTrace : boolean,
	-- Enables SDK debug messages for internal state changes, etc.
	sdkDebugEnabled : boolean,
	-- Custom URL for the SDK, if any.
	customUrl : string | nil,
	-- Environment the SDK is set to: "production", "studio", "development",
	-- or the alias of a custom environment configured in the dashboard.
	environment : string | nil,
	-- Seconds between engagement marker batch flushes to the backend.
	markerFlushRate : number,
	-- Seconds between status polls checking for configuration and experiment changes.
	statusPollRate : number
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
	OnMarkersFailed : (self : MarkersService, callback : (failedMarkers : { {[string] : any} } ) -> ()) -> RBXScriptConnection,
	RetryFailedMarkersAsync : (self : MarkersService, failedMarkers : { {[string] : any} } ) -> boolean,
}

-- Developer-defined experiment targeting property: a scalar or a list of scalars (max 100 items).
export type ExperimentPropertyValue = string | number | boolean | { string | number | boolean }

export type ExperimentsService = {
	SetPlayerProperties: (self: ExperimentsService, player: Player, properties: { [string]: ExperimentPropertyValue }) -> (),
	SetPlayerProperty: (self: ExperimentsService, player: Player, key: string, value: ExperimentPropertyValue?) -> (),
	GetPlayerProperties: (self: ExperimentsService, player: Player) -> { [string]: ExperimentPropertyValue },
	SetServerProperties: (self: ExperimentsService, properties: { [string]: ExperimentPropertyValue }) -> (),
	SetServerProperty: (self: ExperimentsService, key: string, value: ExperimentPropertyValue?) -> (),
	GetServerProperties: (self: ExperimentsService) -> { [string]: ExperimentPropertyValue },
	GetAssignmentsForPlayer: (self: ExperimentsService, player: Player) -> { ExperimentAssignment },
	GetServerAssignments: (self: ExperimentsService) -> { ExperimentAssignment },
	OnAssignmentsChangedForPlayer: (self: ExperimentsService, player: Player, callback: (assignments: { ExperimentAssignment }) -> ()) -> RBXScriptConnection,
	OnServerAssignmentsChanged: (self: ExperimentsService, callback: (assignments: { ExperimentAssignment }) -> ()) -> RBXScriptConnection,
	ObserveAssignmentsForPlayer: (self: ExperimentsService, player: Player, callback: (assignments: { ExperimentAssignment }) -> ()) -> RBXScriptConnection,
	-- Deprecated: use GetAssignmentsForPlayer / GetServerAssignments instead.
	GetGroupForPlayer: (self: ExperimentsService, player: Player) -> ExperimentGroupMetadata?,
}
export type ExperimentAssignment = {
	experimentId: number,
	experimentName: string,
	groupId: number,
	groupLabel: string,
	unitType: "user" | "server",
	source: string?,
}
export type ExperimentGroupMetadata = {
	experimentName: string,
	groupName: string,
}

export type CohortsService = {
	GetCohortMembershipStatusAsync : (self : CohortsService, cohortName : string, userIds : { number }) -> { [ number ] : boolean }
}

export type Service = ConfigsService | MarkersService | ExperimentsService | CohortsService

return true