--[[
	The Gamebeast SDK is Copyright © 2023 Gamebeast, Inc. to present.
	All rights reserved.
	
	PurchaseAnalytics.luau
	
	Description:
		Handles tracking purchases made by players in the server.
	
--]]

--= Root =--
local PurchaseAnalytics = { }

--= Roblox Services =--

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

--= Dependencies =--

local Utilities = require(script.Parent.Parent.Utilities) ---@module Utilities
local EngagementMarkers = require(script.Parent.Parent.EngagementMarkers) ---@module Markers
local ServerClientInfoHandler = require(script.Parent.Parent.ServerClientInfoHandler) ---@module ServerClientInfoHandler

--= Types =--

--= Object References =--

--= Constants =--

local FLUSH_THRESHOLD = 3
local ENUM_TO_TYPE = {
	[Enum.InfoType.GamePass] = "gamepass",
	[Enum.InfoType.Product] = "devproduct",
	[Enum.InfoType.Asset] = "asset",
	[Enum.InfoType.Subscription] = "subscription",
}

--= Variables =--

local ProductInfoCacheMap = {}
local UsingProductReceipts = false
local DevProductEventCache = {}
local DevProductEventDebounce = {}

--= Public Variables =--

--= Internal Functions =--

local function IsString(value : any, maxLength : number) : boolean
	return type(value) == "string" and #value <= maxLength
end

--[[
	Product info a client reported, keeping only the fields the Purchase marker uses and only if
	they're well formed; nil if nothing usable is left. The client is untrusted: its price feeds
	revenue (for subscriptions it is the only source), and a non-numeric one errored the price check.
]]
local function SanitizeClientProductInfo(data : any) : {[string] : any}?
	if type(data) ~= "table" then
		return nil
	end

	local price = data.PriceInRobux
	if price ~= nil and not (type(price) == "number" and price == price and price >= 0 and price ~= math.huge) then
		return nil
	end

	return {
		PriceInRobux = price,
		DisplayPrice = if IsString(data.DisplayPrice, 32) then data.DisplayPrice else nil,
		Name = if IsString(data.Name, 200) then data.Name else nil,
		Description = if IsString(data.Description, 1000) then data.Description else nil,
	}
end

-- Asks the player's client for product info, sanitized
local function GetClientProductInfo(player : Player | number, itemId : number, itemType : Enum.InfoType) : {[string] : any}?
	return SanitizeClientProductInfo(ServerClientInfoHandler:GetProductInfoForPlayer(player, itemId, itemType))
end

local function GetProductInfo(player : Player | number, itemId : number, itemType : Enum.InfoType) : {FromClient : boolean, Data : {[string] : any}}?
	-- Check if we've already retrieved product info
	if not ProductInfoCacheMap[itemType] then
		ProductInfoCacheMap[itemType] = {}
	end

	local fromClient = false
	local itemInfo = ProductInfoCacheMap[itemType][itemId]
	if not itemInfo then
		if itemType ~= Enum.InfoType.Subscription then
			itemInfo = Utilities.getProductInfo(itemId, itemType)
		end

		-- Only a player still in the server has a client to ask
		if not itemInfo and Utilities.resolvePlayerObject(player) then
			itemInfo = GetClientProductInfo(player, itemId, itemType)
			fromClient = true
		end
		
		-- In case of service failure even with retries
		if not itemInfo then return end
		if not fromClient then
			ProductInfoCacheMap[itemType][itemId] = itemInfo
		end
	end

	return {FromClient = fromClient, Data = itemInfo}
end

local function FlushProductPurchaseCache(player : Player)
	local playerCache = DevProductEventCache[player]
	if not playerCache then
		return
	end

	for _, data in ipairs(playerCache) do
		task.spawn(function()
			PurchaseAnalytics:UpdatePlayerSpend(player, false, data.itemId, Enum.InfoType.Product, {position = data.position, timestampOverride = data.timestamp})
		end)
	end

	DevProductEventCache[player] = nil
end

--= API Functions =--

function PurchaseAnalytics:UpdatePlayerSpend(player : Player | number, fromReceipt : boolean, itemId : number, itemType : Enum.InfoType, metadataOverride : {[string] : any}?)
	local player = Utilities.resolvePlayerObject(player)

	-- Nothing to report without product info. Subscriptions used to be let through here and then
	-- errored indexing the missing info, so the marker was lost anyway.
	local itemInfo = GetProductInfo(player, itemId, itemType)
	if not itemInfo then
		return
	end

	--NOTE: In the event the client holds onto the request forever, we dont want to block the server.
	-- Nil when the client can't answer (no client SDK, or the request failed); the base price is used then.
	-- A receipt can be processed after the player has left, leaving no client to ask.
	local clientData = if itemInfo.FromClient then itemInfo.Data
		elseif player then GetClientProductInfo(player, itemId, itemType)
		else nil

	-- Sanity check the client price: it can't be greater than the base price
	local basePrice = itemInfo.Data.PriceInRobux
	if clientData and clientData.PriceInRobux and basePrice and basePrice > 0 then
		if clientData.PriceInRobux > basePrice then
			clientData = nil
		end
	end

	-- Don't send redundant information over the wire
	local args = {
		["fromReceipt"] = fromReceipt,
		["type"] = ENUM_TO_TYPE[itemType] or "unknown",
		["id"] = itemId,
		["price"] = clientData and clientData.PriceInRobux or itemInfo.Data.PriceInRobux,
		["basePrice"] = itemInfo.Data.PriceInRobux,
		["localPrice"] = if clientData then clientData.DisplayPrice else nil,
		["name"] = itemInfo.Data.Name,
		["description"] = itemInfo.Data.Description,
		["imageId"] = "https://assetdelivery.roblox.com/v1/asset?id=".. itemId
	}

	-- Collect where player made purchase
	local metaData = metadataOverride or {}
	metaData.player = player

	local char = player and player.Character
	if metaData.position == nil and char and char.PrimaryPart then
		metaData.position = char.PrimaryPart.Position
	end
	
	EngagementMarkers:SDKMarker("Purchase", args, metaData)
end

function PurchaseAnalytics:DevProductPurchased(fromReceipt : boolean, playerId : number, itemId : number, position : Vector3? )
	-- If we've validated that the dev is using the method with receipts, we don't need to rely on our internal method
	if UsingProductReceipts and fromReceipt == false then
		return
	end

	-- Ensure the player actually exists
	local player = Players:GetPlayerByUserId(playerId)
	if not player then
		return
	end

	-- Get the product info ahead of time.
	local productInfo = GetProductInfo(player, itemId, Enum.InfoType.Product)
	if not productInfo then
		return
	end

	if fromReceipt then
		UsingProductReceipts = true
		DevProductEventCache[player] = nil
		self:UpdatePlayerSpend(playerId, true, itemId, Enum.InfoType.Product, {position = position})
	else
		DevProductEventCache[player] = DevProductEventCache[player] or {}
		local playerCache = DevProductEventCache[player]

		table.insert(playerCache, {
			itemId = itemId, 
			position = position, 
			timestamp = DateTime.now().UnixTimestampMillis
		})

		if #playerCache >= FLUSH_THRESHOLD then
			FlushProductPurchaseCache(player)
		end
	end
end

--= Initializers =--
function PurchaseAnalytics:Init()
	-- The prompt-finished events aren't proof of a purchase on their own (they have been fired by
	-- exploits without one), so a pass or asset is only recorded once the player is seen to own it.
	-- Subscriptions are checked the same way below.

	-- Purchase records handler for gamepasses
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then
			return
		end

		local success, ownsPass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
		end)
		if success and ownsPass then
			self:UpdatePlayerSpend(player, false, gamePassId, Enum.InfoType.GamePass)
		end
	end)

	-- Purchase records handler for assets / other
	MarketplaceService.PromptPurchaseFinished:Connect(function(player, assetId, wasPurchased)
		if not wasPurchased then
			return
		end

		local success, ownsAsset = pcall(function()
			return MarketplaceService:PlayerOwnsAsset(player, assetId)
		end)
		if success and ownsAsset then
			self:UpdatePlayerSpend(player, false, assetId, Enum.InfoType.Asset)
		end
	end)

	-- Purchase records for subscriptions
	Players.UserSubscriptionStatusChanged:Connect(function(player, subscriptionId)
		local success, subscriptionStatus = pcall(function()
			return MarketplaceService:GetUserSubscriptionStatusAsync(player, subscriptionId)
		end)

		if success and subscriptionStatus.IsSubscribed then
			self:UpdatePlayerSpend(player, false, subscriptionId, Enum.InfoType.Subscription)
		end
	end)

	-- Purchase records handler for products
	--NOTE: Disabled due to PromptProductPurchaseFinished being unreliable. Too many false positives.
	--[[MarketplaceService.PromptProductPurchaseFinished:Connect(function(playerId : number, productId : number, wasPurchased : boolean)
		if DevProductEventDebounce[playerId] then
			return
		end

		if wasPurchased then
			DevProductEventDebounce[playerId] = true
			self:DevProductPurchased(false, playerId, productId)

			task.wait(3)
			DevProductEventDebounce[playerId] = nil
		end
	end)]]

	Players.PlayerRemoving:Connect(FlushProductPurchaseCache) --NOTE: DEPRECATED, UPDATE IF ABOVE IS RE-ENABLED
end

--= Return Module =--
return PurchaseAnalytics