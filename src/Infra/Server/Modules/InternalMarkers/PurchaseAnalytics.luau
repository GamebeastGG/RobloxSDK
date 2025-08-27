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

local Utilities = shared.GBMod("Utilities") ---@module Utilities
local EngagementMarkers = shared.GBMod("EngagementMarkers") ---@module Markers
local ServerClientInfoHandler = shared.GBMod("ServerClientInfoHandler") ---@module ServerClientInfoHandler

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

local function GetProductInfo(itemId : number, itemType : Enum.InfoType)
	-- Check if we've already retrieved product info
	if not ProductInfoCacheMap[itemType] then
		ProductInfoCacheMap[itemType] = {}
	end

	local itemInfo = ProductInfoCacheMap[itemType][itemId]
	if not itemInfo then
		itemInfo = Utilities.getProductInfo(itemId, itemType)

		-- In case of service failure even with retries
		if not itemInfo then return end
		ProductInfoCacheMap[itemType][itemId] = itemInfo
	end

	return itemInfo
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

	local itemInfo = GetProductInfo(itemId, itemType)
	if not itemInfo then
		return
	end

	--NOTE: In the event the client holds onto the request forever, we dont want to block the server.
	local clientPrice = if itemInfo.PriceInRobux then ServerClientInfoHandler:GetProductPriceForPlayer(player, itemId, itemType) else nil

	-- Sanity check the client price
	if clientPrice then
		-- Price can only be a minimum of 30% the base price.
		if clientPrice/itemInfo.PriceInRobux < 0.3 then
			clientPrice = nil
		end

		-- Price cant be greater than the base price.
		if clientPrice > itemInfo.PriceInRobux then
			clientPrice = nil
		end
	end

	-- Don't send redundant information over the wire
	local args = {
		["fromReceipt"] = fromReceipt,
		["type"] = ENUM_TO_TYPE[itemType] or "unknown",
		["id"] = itemId,
		["price"] = clientPrice or itemInfo.PriceInRobux,
		["basePrice"] = itemInfo.PriceInRobux,
		["name"] = itemInfo.Name,
		["description"] = itemInfo.Description,
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
	local productInfo = GetProductInfo(itemId, Enum.InfoType.Product)
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
	-- Purchase records handler for gamepasses
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if wasPurchased then
			self:UpdatePlayerSpend(player, false, gamePassId, Enum.InfoType.GamePass)
		end
	end)

	-- Purchase records handler for assets / other
	MarketplaceService.PromptPurchaseFinished:Connect(function(player, assetId, wasPurchased)
		if wasPurchased then
			self:UpdatePlayerSpend(player, false, assetId, Enum.InfoType.Asset)
		end
	end)

	-- Purchase records for subscriptions
	MarketplaceService.PromptSubscriptionPurchaseFinished:Connect(function(player, subscriptionId, didTryPurchasing)
		if didTryPurchasing then
			local success, subscriptionStatus = pcall(function()
				return MarketplaceService:GetUserSubscriptionStatusAsync(player, subscriptionId)
			end)

			if success and subscriptionStatus.IsSubscribed then
				self:UpdatePlayerSpend(player, false, subscriptionId, Enum.InfoType.Subscription)
			end
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

	Players.PlayerRemoving:Connect(FlushProductPurchaseCache)
end

--= Return Module =--
return PurchaseAnalytics