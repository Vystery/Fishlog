-- FishLog :: Prices
-- What a looted item is worth: an auction price from CraftProfit, Auctionator or TSM when one of them is
-- installed and knows the item, otherwise the vendor sell price. The vendor price also wins when it is
-- higher than the auction price (you would sell to the vendor). Every third-party call is pcall'd.

local _, FL = ...
local Prices = {}
FL.Prices = Prices

local CACHE_TTL = 60 -- seconds; the panel refreshes twice a second, price sources do not move that fast
local cache = {}     -- itemID -> { value, kind, at }
local pendingLoad = {} -- itemID -> true while C_Item data is being requested

function Prices:Invalidate()
	cache = {}
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------

local function CraftProfitPrice(itemID)
	local cp = _G.CraftProfit
	if not (cp and type(cp.GetSalePrice) == "function") then return nil end
	local ok, price = pcall(cp.GetSalePrice, cp, itemID)
	if ok and type(price) == "number" and price > 0 then return price end
	return nil
end

local function AuctionatorPrice(itemID)
	local a = _G.Auctionator
	local api = a and a.API and a.API.v1
	if not (api and type(api.GetAuctionPriceByItemID) == "function") then return nil end
	local ok, price = pcall(api.GetAuctionPriceByItemID, FL.CALLER_ID, itemID)
	if ok and type(price) == "number" and price > 0 then return price end
	return nil
end

local function TSMPrice(itemID)
	local api = _G.TSM_API
	if not (api and type(api.GetCustomPriceValue) == "function") then return nil end
	local ok, price = pcall(api.GetCustomPriceValue, "DBMarket", "i:" .. itemID)
	if ok and type(price) == "number" and price > 0 then return price end
	return nil
end

local SOURCES = {
	craftprofit = { name = "CraftProfit", fn = CraftProfitPrice, available = function() return _G.CraftProfit ~= nil and type(_G.CraftProfit.GetSalePrice) == "function" end },
	auctionator = { name = "Auctionator", fn = AuctionatorPrice, available = function() local a = _G.Auctionator; return a and a.API and a.API.v1 and type(a.API.v1.GetAuctionPriceByItemID) == "function" or false end },
	tsm         = { name = "TSM",         fn = TSMPrice,         available = function() local t = _G.TSM_API; return t and type(t.GetCustomPriceValue) == "function" or false end },
}
local AUTO_ORDER = { "craftprofit", "auctionator", "tsm" }

-- Returns the auction source definition in use, or nil when the setting is "vendor" or none is installed.
local function ResolveSource()
	local want = (FL.settings and FL.settings.source) or "auto"
	if want == "vendor" then return nil end
	if want ~= "auto" then
		local def = SOURCES[want]
		if def and def.available() then return def, want end
		return nil
	end
	for _, key in ipairs(AUTO_ORDER) do
		local def = SOURCES[key]
		if def.available() then return def, key end
	end
	return nil
end

function Prices:Describe()
	local def, key = ResolveSource()
	local want = (FL.settings and FL.settings.source) or "auto"
	if def then
		local cut = FL.settings.applyCut and string.format(" net of %d%% cut", math.floor(FL.settings.ahCut * 100 + 0.5)) or ""
		return string.format("%s auction prices%s, vendor price when higher or unknown%s", def.name, cut, want == "auto" and " (auto)" or "")
	end
	if want == "vendor" then return "vendor sell prices only" end
	if want ~= "auto" then return want .. " is not loaded; vendor sell prices only" end
	return "vendor sell prices only (no CraftProfit / Auctionator / TSM loaded)"
end

---------------------------------------------------------------------------
-- Vendor price (C_Item data can arrive late)
---------------------------------------------------------------------------

function Prices:VendorPrice(itemID)
	if not (C_Item and C_Item.GetItemInfo) then return nil end
	local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(C_Item.GetItemInfo, itemID)
	if ok and name then
		pendingLoad[itemID] = nil
		if type(sellPrice) == "number" and sellPrice > 0 then return sellPrice end
		return 0
	end
	if not pendingLoad[itemID] and C_Item.RequestLoadItemDataByID then
		pendingLoad[itemID] = true
		pcall(C_Item.RequestLoadItemDataByID, itemID)
	end
	return nil
end

FL:RegisterEvent("ITEM_DATA_LOAD_RESULT", function(_, itemID, success)
	if pendingLoad[itemID] then
		pendingLoad[itemID] = nil
		cache[itemID] = nil
		FL:Fire("PRICES_UPDATED", itemID)
	end
end)

---------------------------------------------------------------------------
-- Unified lookup
---------------------------------------------------------------------------

-- Returns copper per unit (or nil while nothing is known yet) and kind: "ah" | "vendor" | "none".
-- "none" means the item has data but is worth nothing (no vendor price, no auction price).
function Prices:GetValue(itemID)
	if not itemID then return nil end
	local now = FL:Now()
	local c = cache[itemID]
	if c and (now - c.at) < CACHE_TTL then return c.value, c.kind end

	local vendor = self:VendorPrice(itemID)
	local def = ResolveSource()
	local ah = def and def.fn(itemID) or nil
	if ah and FL.settings.applyCut then
		ah = math.floor(ah * (1 - (FL.settings.ahCut or 0)) + 0.5)
	end

	local value, kind
	if ah and (not vendor or ah >= vendor) then
		value, kind = ah, "ah"
	elseif vendor and vendor > 0 then
		value, kind = vendor, "vendor"
	elseif vendor == 0 then
		value, kind = 0, "none"
	else
		-- item data not loaded yet and no auction price: unknown for now
		return nil
	end
	cache[itemID] = { value = value, kind = kind, at = now }
	return value, kind
end
