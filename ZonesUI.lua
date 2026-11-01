-- FishLog :: Zones window
-- Every zone you have fished, with its lifetime numbers (Zones.lua) and the running session included.
--   PortraitFrameTemplate window "FishLog - Zones" (FishLogZones, FL:CreateWindow in UI.lua), closes with Escape
--     left:  heading and zone count right of the portrait; the window's Inset below holds the zone list: Zone | Time | Gold/h (click a header to sort), wheel scrolls
--     right: the selected zone: name, sessions / last fished, 3 x 2 stats (Fishing time, Gold / hour, Loot value,
--            Catches, Catches / hour, Per catch), best session, skill range, coin, best spots,
--            and an InsetFrameTemplate item list: Item | Count | Drop | Value (hover for the tooltip)
-- Same styling rules as the panel: Blizzard templates and font objects only, item quality colors on names.

local _, FL = ...
local ZUI = {}
FL.ZonesUI = ZUI

local WIDTH, HEIGHT = 620, 470
local PAD = 12
local TOP = 30
local LIST_TOP = 64       -- the zone list starts under the window portrait
local FOOT_H = 28          -- space under the insets for the footer lines
local LIST_W = 236         -- zone list inset width
local INSET_PAD = 5
local HEADER_H = 19        -- AH column headers, on the window background above each inset
local ROW_H = 18
local LINE_H = 14
local TILE_H = 30
local TILE_GAP = 8
local ZONE_TIME_W, ZONE_GPH_W = 46, 58
local ITEM_COUNT_W, ITEM_DROP_W, ITEM_VALUE_W = 42, 40, 54

local frame
local w = {}               -- widgets
local zoneRows, itemRows = {}, {}
local zoneList, itemList = {}, {}
local listOffset, itemOffset = 0, 0
ZUI.selected = nil

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function QualityHex(q)
	local colors = _G.ITEM_QUALITY_COLORS
	if colors and q and colors[q] then
		local col = colors[q]
		if col.hex then return (col.hex:gsub("^|c%x%x", "")) end
		if col.color and col.color.GenerateHexColor then return (col.color:GenerateHexColor():gsub("^%x%x", "")) end
	end
	return "ffffff"
end

local function NewText(parent, font, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	return fs
end

local function TemplateFrame(kind, name, parent, template)
	local ok, f = pcall(CreateFrame, kind, name, parent, template)
	if ok and type(f) == "table" then return f, true end
	return CreateFrame(kind, name, parent), false
end

local function TrySetFont(fs, fontName)
	if _G[fontName] then pcall(fs.SetFontObject, fs, fontName) end
end

local function SetTitle(f, title)
	if type(f.SetTitle) == "function" then pcall(f.SetTitle, f, title) end
	if type(f.TitleText) == "table" then f.TitleText:SetText(title) end
	if type(f.TitleContainer) == "table" and type(f.TitleContainer.TitleText) == "table" then f.TitleContainer.TitleText:SetText(title) end
end

local function Pct(x) return x and string.format("%d%%", math.floor(x * 100 + 0.5)) or "-" end
local function Money(c) return c and FL:FormatMoney(c, { compact = true }) or "-" end

-- Fishing time as 2h 05m / 12m / 45s: long totals read better than h:mm:ss here.
local function Hours(seconds)
	seconds = math.floor(seconds or 0)
	if seconds >= 3600 then return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)) end
	if seconds >= 60 then return string.format("%dm", math.floor(seconds / 60)) end
	return string.format("%ds", seconds)
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- An AH column header over inset columns x0..x1 (inset coordinates), sitting just above the inset. Headers of
-- one list run edge to edge and overlap by 2 px, as the AH's own table builder lays them out.
local function Header(inset, text, justify, x0, x1, sortKey)
	local b = FL:CreateHeader(inset:GetParent(), justify)
	b:SetPoint("BOTTOMLEFT", inset, "TOPLEFT", x0, 0)
	b:SetSize(x1 - x0, HEADER_H)
	b.label = text
	b:SetLabel(text)
	b.sortKey = sortKey
	if sortKey then
		b:SetScript("OnClick", function()
			FL:SetSetting("zoneSort", sortKey)
			listOffset = 0
			ZUI:Refresh()
		end)
	end
	return b
end

local function ZoneTooltip(row)
	local e = row.entry
	if not e or not GameTooltip then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(e.name, 1, 0.82, 0)
	GameTooltip:AddDoubleLine("Fishing time", Hours(e.active), 1, 1, 1, 1, 1, 1)
	GameTooltip:AddDoubleLine("Gold / hour", e.gph and FL:FormatMoneyPlain(e.gph) or "n/a", 1, 1, 1, 1, 1, 1)
	GameTooltip:AddDoubleLine("Catches", string.format("%d of %d casts", e.catches or 0, e.casts or 0), 1, 1, 1, 1, 1, 1)
	GameTooltip:AddDoubleLine("Sessions", tostring(e.sessions or 0), 1, 1, 1, 1, 1, 1)
	if e.live then
		GameTooltip:AddLine("Fishing here now", 0.25, 1, 0.25)
	elseif e.last then
		GameTooltip:AddLine("Last fished " .. FL:FormatAge(FL:Now() - e.last), 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function NewZoneRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_H)
	FL:StyleRow(row, true)
	row.gph = NewText(row, "GameFontHighlightSmall", "RIGHT")
	row.gph:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.gph:SetWidth(ZONE_GPH_W)
	row.time = NewText(row, "GameFontDisableSmall", "RIGHT")
	row.time:SetPoint("RIGHT", row.gph, "LEFT", -4, 0)
	row.time:SetWidth(ZONE_TIME_W)
	row.name = NewText(row, "GameFontNormalSmall", "LEFT")
	row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.name:SetPoint("RIGHT", row.time, "LEFT", -4, 0)
	row:SetScript("OnClick", function(self)
		if not self.entry then return end
		ZUI.selected = self.entry.name
		itemOffset = 0
		ZUI:Refresh()
	end)
	row:SetScript("OnEnter", ZoneTooltip)
	row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	return row
end

local function ItemTooltip(row)
	local e = row.entry
	if not e or not GameTooltip then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	local shown = false
	local link = e.link or ("item:" .. e.itemID)
	if GameTooltip.SetHyperlink then shown = pcall(GameTooltip.SetHyperlink, GameTooltip, link) end
	if not shown then GameTooltip:AddLine(e.name) end
	GameTooltip:AddLine(string.format("FishLog: %d looted here in %d catch(es)%s", e.n, e.c,
		e.dropRate and string.format(", %s of catches", Pct(e.dropRate)) or ""), 0.43, 0.72, 1, true)
	if e.unit then
		GameTooltip:AddLine(string.format("%s each (%s), %s in total", FL:FormatMoneyPlain(e.unit),
			e.kind == "ah" and "auction price" or e.kind == "vendor" and "vendor price" or "no value",
			FL:FormatMoneyPlain(e.total or 0)), 0.43, 0.72, 1, true)
	else
		GameTooltip:AddLine("value unknown yet (item data loading)", 0.43, 0.72, 1)
	end
	GameTooltip:Show()
end

local function NewItemRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_H)
	FL:StyleRow(row)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.value = NewText(row, "GameFontHighlightSmall", "RIGHT")
	row.value:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.value:SetWidth(ITEM_VALUE_W)
	row.drop = NewText(row, "GameFontDisableSmall", "RIGHT")
	row.drop:SetPoint("RIGHT", row.value, "LEFT", -4, 0)
	row.drop:SetWidth(ITEM_DROP_W)
	row.count = NewText(row, "GameFontHighlightSmall", "RIGHT")
	row.count:SetPoint("RIGHT", row.drop, "LEFT", -4, 0)
	row.count:SetWidth(ITEM_COUNT_W)
	row.name = NewText(row, "GameFontHighlightSmall", "LEFT")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
	row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	row:SetScript("OnEnter", ItemTooltip)
	row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	return row
end

-- A stat: small gold label over a white value, same as the panel's stat groups.
local function Stat(label)
	local t = CreateFrame("Frame", nil, frame)
	t:SetHeight(TILE_H)
	t.label = NewText(t, "GameFontNormalSmall", "LEFT")
	t.label:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
	t.label:SetPoint("RIGHT", t, "RIGHT", 0, 0)
	t.label:SetText(label)
	t.value = NewText(t, "GameFontHighlight", "LEFT")
	t.value:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 0, 0)
	t.value:SetPoint("RIGHT", t, "RIGHT", 0, 0)
	return t
end

-- A "label   value" line of the detail block.
local function InfoLine(label, x, y)
	local l = NewText(frame, "GameFontNormalSmall", "LEFT")
	l:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
	l:SetWidth(82)
	l:SetText(label)
	local v = NewText(frame, "GameFontHighlightSmall", "LEFT")
	v:SetPoint("TOPLEFT", l, "TOPRIGHT", 4, 0)
	v:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
	v.label = l
	return v
end

local function VisibleRows(insetHeight)
	return math.max(1, math.floor((insetHeight - 2 * INSET_PAD) / ROW_H))
end
local ZONE_ROWS = VisibleRows(HEIGHT - LIST_TOP - HEADER_H - FOOT_H)

local function Build()
	if frame then return end
	local hasPortrait
	frame, hasPortrait = FL:CreateWindow("FishLogZones", "FishLog - Zones", function() ZUI:Hide() end)
	local headX = hasPortrait and FL.PORTRAIT_W or PAD + 4

	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("MEDIUM")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local ok, point, _, _, x, y = pcall(self.GetPoint, self, 1)
		if ok and point then FL:SetSetting("zonesPos", { point = point, x = x, y = y }) end
	end)
	local pos = FL.settings.zonesPos
	if pos and pos.point then
		frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", -120, 40)
	end
	if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "FishLogZones") end

	-- zone list in the window's Inset
	local list = frame.Inset
	list:ClearAllPoints()
	list:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -LIST_TOP - HEADER_H)
	list:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, FOOT_H)
	list:SetWidth(LIST_W)
	FL:StyleInset(list)
	-- header spans follow the row columns: Gold/h and Time are right-aligned numbers, Zone takes the rest
	local gphX = LIST_W - INSET_PAD - 4 - ZONE_GPH_W - 4
	local timeX = gphX - ZONE_TIME_W - 4
	w.hZone = Header(list, "Zone", "LEFT", 0, timeX + 2, "name")
	w.hTime = Header(list, "Time", "RIGHT", timeX, gphX + 2, "time")
	w.hGph = Header(list, "Gold/h", "RIGHT", gphX, LIST_W, "gph")
	for i = 1, ZONE_ROWS do
		local row = NewZoneRow(list)
		row:SetPoint("TOPLEFT", list, "TOPLEFT", INSET_PAD, -INSET_PAD - (i - 1) * ROW_H)
		row:SetPoint("TOPRIGHT", list, "TOPRIGHT", -INSET_PAD, -INSET_PAD - (i - 1) * ROW_H)
		row:Hide()
		zoneRows[i] = row
	end
	w.listEmpty = NewText(list, "GameFontDisableSmall", "CENTER")
	w.listEmpty:SetPoint("TOPLEFT", list, "TOPLEFT", INSET_PAD + 4, -INSET_PAD - 6)
	w.listEmpty:SetPoint("RIGHT", list, "RIGHT", -INSET_PAD - 4, 0)
	w.listEmpty:SetWordWrap(true)
	w.listEmpty:SetText("No fishing recorded yet. Cast your line and the zone shows up here.")
	if list.EnableMouseWheel then list:EnableMouseWheel(true) end
	list:SetScript("OnMouseWheel", function(_, delta) ZUI:ScrollZones(-delta * 3) end)
	-- heading and zone count right of the portrait, above the list
	w.listHead = NewText(frame, "GameFontNormal", "LEFT")
	w.listHead:SetPoint("TOPLEFT", frame, "TOPLEFT", headX, -TOP - 2)
	w.listHead:SetPoint("RIGHT", list, "RIGHT", -4, 0)
	w.listHead:SetText("Zones fished")
	w.listFoot = NewText(frame, "GameFontDisableSmall", "LEFT")
	w.listFoot:SetPoint("TOPLEFT", w.listHead, "BOTTOMLEFT", 0, -4)
	w.listFoot:SetPoint("RIGHT", list, "RIGHT", -4, 0)

	-- detail column
	local x0 = PAD + LIST_W + 12
	local detailW = WIDTH - x0 - PAD
	w.title = NewText(frame, "GameFontNormalLarge", "LEFT")
	w.title:SetPoint("TOPLEFT", frame, "TOPLEFT", x0, -TOP - 2)
	w.title:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
	w.sub = NewText(frame, "GameFontDisableSmall", "LEFT")
	w.sub:SetPoint("TOPLEFT", frame, "TOPLEFT", x0, -TOP - 22)
	w.sub:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)

	local tilesY = -TOP - 42
	local tileW = (detailW - 2 * TILE_GAP) / 3
	w.stats = {
		time = Stat("Fishing time"), gph = Stat("Gold / hour"), value = Stat("Loot value"),
		catches = Stat("Catches"), cph = Stat("Catches / hour"), per = Stat("Per catch"),
	}
	for i, key in ipairs({ "time", "gph", "value", "catches", "cph", "per" }) do
		local col, rowIdx = (i - 1) % 3, math.floor((i - 1) / 3)
		local t = w.stats[key]
		t:SetWidth(tileW)
		t:SetPoint("TOPLEFT", frame, "TOPLEFT", x0 + col * (tileW + TILE_GAP), tilesY - rowIdx * (TILE_H + 6))
	end
	local infoY = tilesY - 2 * TILE_H - 6 - 10
	w.best = InfoLine("Best session", x0, infoY)
	w.skill = InfoLine("Fishing skill", x0, infoY - LINE_H)
	w.coin = InfoLine("Coin looted", x0, infoY - 2 * LINE_H)
	w.spots = InfoLine("Best spots", x0, infoY - 3 * LINE_H)

	-- shown instead of the detail block while there is no zone to show
	w.detailEmpty = NewText(frame, "GameFontDisableSmall", "CENTER")
	w.detailEmpty:SetPoint("TOPLEFT", frame, "TOPLEFT", x0, -TOP - 60)
	w.detailEmpty:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
	w.detailEmpty:SetWordWrap(true)

	-- item list
	local itemsTop = infoY - 4 * LINE_H - 8
	local items = TemplateFrame("Frame", nil, frame, "InsetFrameTemplate")
	items:SetPoint("TOPLEFT", frame, "TOPLEFT", x0, itemsTop - HEADER_H)
	items:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOT_H)
	w.items = items
	frame.itemsInset = items
	w.itemRowsN = VisibleRows(HEIGHT + itemsTop - HEADER_H - FOOT_H)
	FL:StyleInset(items)
	local itemsW = WIDTH - x0 - PAD
	local valueX = itemsW - INSET_PAD - 4 - ITEM_VALUE_W - 4
	local dropX = valueX - ITEM_DROP_W - 4
	local countX = dropX - ITEM_COUNT_W - 4
	w.hItem = Header(items, "Item", "LEFT", 0, countX + 2)
	w.hCount = Header(items, "Count", "RIGHT", countX, dropX + 2)
	w.hDrop = Header(items, "Drop", "RIGHT", dropX, valueX + 2)
	w.hValue = Header(items, "Value", "RIGHT", valueX, itemsW)
	for i = 1, w.itemRowsN do
		local row = NewItemRow(items)
		row:SetPoint("TOPLEFT", items, "TOPLEFT", INSET_PAD, -INSET_PAD - (i - 1) * ROW_H)
		row:SetPoint("TOPRIGHT", items, "TOPRIGHT", -INSET_PAD, -INSET_PAD - (i - 1) * ROW_H)
		row:Hide()
		itemRows[i] = row
	end
	w.itemsEmpty = NewText(items, "GameFontDisableSmall", "CENTER")
	w.itemsEmpty:SetPoint("TOP", items, "TOP", 0, -INSET_PAD - 6)
	if items.EnableMouseWheel then items:EnableMouseWheel(true) end
	items:SetScript("OnMouseWheel", function(_, delta) ZUI:ScrollItems(-delta * 3) end)
	w.itemsFoot = NewText(frame, "GameFontDisableSmall", "RIGHT")
	w.itemsFoot:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 4, 10)
	w.itemsFoot:SetPoint("LEFT", frame, "LEFT", x0, 0)

	frame:SetScript("OnShow", function() ZUI:Refresh() end)
	frame:Hide()
	ZUI.frame = frame
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function RenderZones()
	local n = #zoneList
	listOffset = math.max(0, math.min(listOffset, n - ZONE_ROWS))
	for i = 1, ZONE_ROWS do
		local row = zoneRows[i]
		local e = zoneList[listOffset + i]
		row.entry = e
		if e then
			row.name:SetText(e.name)
			TrySetFont(row.name, e.live and "GameFontGreenSmall" or "GameFontNormalSmall")
			row.time:SetText(Hours(e.active))
			row.gph:SetText(e.gph and FL:FormatMoneyShort(e.gph) or "-")
			row:SetSelected(e.name == ZUI.selected)
			row:Show()
		else
			row:Hide()
		end
	end
	w.listEmpty:SetShown(n == 0)
	local sortKey = FL.settings.zoneSort or "gph"
	for _, h in ipairs({ w.hZone, w.hTime, w.hGph }) do
		-- arrow on the sorted column: zone names A-Z, the numbers highest first
		h:SetLabel(h.label, h.sortKey == sortKey, sortKey ~= "name")
	end
	if n > ZONE_ROWS then
		w.listFoot:SetText(string.format("%d-%d of %d zones (wheel scrolls)", listOffset + 1, math.min(n, listOffset + ZONE_ROWS), n))
	else
		w.listFoot:SetText(n == 1 and "1 zone" or string.format("%d zones", n))
	end
end

local function RenderItems()
	local n = #itemList
	local rowsN = w.itemRowsN
	itemOffset = math.max(0, math.min(itemOffset, n - rowsN))
	for i = 1, rowsN do
		local row = itemRows[i]
		local e = itemList[itemOffset + i]
		row.entry = e
		if e then
			if e.icon then
				row.icon:SetTexture(e.icon)
				row.icon:Show()
			else
				row.icon:Hide()
			end
			row.name:SetText(FL:Color(QualityHex(e.q), e.name))
			row.count:SetText(tostring(e.n))
			row.drop:SetText(Pct(e.dropRate))
			if e.total then
				row.value:SetText(FL:FormatMoneyShort(e.total) .. (e.kind == "vendor" and FL:Color("9d9d9d", " v") or ""))
			else
				row.value:SetText(FL:Color("9d9d9d", "?"))
			end
			row:Show()
		else
			row:Hide()
		end
	end
	local e = ZUI.selectedEntry
	w.itemsEmpty:SetText(e and "Nothing looted here yet." or "")
	w.itemsEmpty:SetShown(n == 0)
	local foot = "Current prices, v = vendor"
	if n > rowsN then
		foot = string.format("%d-%d of %d items (wheel scrolls). %s", itemOffset + 1, math.min(n, itemOffset + rowsN), n, foot)
	end
	w.itemsFoot:SetText(foot)
end

local function SetDetailShown(shown)
	for _, t in pairs(w.stats) do t:SetShown(shown) end
	for _, v in ipairs({ w.best, w.skill, w.coin, w.spots }) do
		v:SetShown(shown)
		v.label:SetShown(shown)
	end
	w.items:SetShown(shown)
	for _, h in ipairs({ w.hItem, w.hCount, w.hDrop, w.hValue }) do h:SetShown(shown) end
	w.itemsFoot:SetShown(shown)
	w.detailEmpty:SetShown(not shown)
end

local function RenderDetail(e)
	SetDetailShown(e ~= nil)
	if not e then
		w.title:SetText("")
		w.sub:SetText("")
		w.detailEmpty:SetText(#zoneList > 0 and "Select a zone at the left." or
			"Zones appear here once you fish: the one you are fishing in right away, and every zone with a finished session. Pick one to see its loot, gold per hour and catch numbers.")
		itemList = {}
		return
	end
	w.title:SetText(e.name)
	local parts = { e.sessions == 1 and "1 session" or string.format("%d sessions", e.sessions or 0) }
	if e.live then
		parts[#parts + 1] = "fishing here now"
	elseif e.last then
		parts[#parts + 1] = "last fished " .. FL:FormatAge(FL:Now() - e.last)
	end
	if (e.partial or 0) > 0 then parts[#parts + 1] = "older sessions list their top items only" end
	w.sub:SetText(table.concat(parts, ", "))

	w.stats.time.value:SetText(Hours(e.active))
	w.stats.gph.value:SetText(e.gph and Money(e.gph) or "-")
	w.stats.value.value:SetText(Money(e.value) .. (e.unpriced > 0 and string.format(" +%d?", e.unpriced) or ""))
	w.stats.catches.value:SetText(string.format("%d  (%s)", e.catches or 0, Pct(e.catchRate)))
	w.stats.cph.value:SetText(e.catchesPerHour and string.format("%d", math.floor(e.catchesPerHour + 0.5)) or "-")
	w.stats.per.value:SetText(e.perCatch and Money(e.perCatch) or "-")

	if e.bestGph then
		w.best:SetText(string.format("%s/h%s", FL:FormatMoneyPlain(e.bestGph), e.bestAt and date and ("  (" .. date("%m-%d", e.bestAt) .. ")") or ""))
	else
		w.best:SetText("after a session of 10+ min here")
	end
	if e.skillMin then
		w.skill:SetText(e.skillMax and e.skillMax ~= e.skillMin and string.format("%d - %d", e.skillMin, e.skillMax) or tostring(e.skillMin))
	else
		w.skill:SetText("-")
	end
	w.coin:SetText(FL:FormatMoneyPlain(e.money or 0))
	local spots = {}
	for _, sp in ipairs(FL.Zones:TopSubzones(e, 3)) do spots[#spots + 1] = string.format("%s (%d)", sp.name, sp.n) end
	w.spots:SetText(#spots > 0 and table.concat(spots, ", ") or "-")

	itemList = FL.Zones:SortedLoot(e)
end

function ZUI:Refresh()
	if not frame or not frame:IsShown() then return end
	SetTitle(frame, FL.Zones.demo and "FishLog - Zones (demo data)" or "FishLog - Zones")
	zoneList = FL.Zones:Sorted(FL.settings.zoneSort or "gph")
	-- keep the selection; default to the zone being fished, then the top of the list
	local selected
	for _, e in ipairs(zoneList) do if e.name == self.selected then selected = e end end
	if not selected then
		for _, e in ipairs(zoneList) do if e.live then selected = e end end
		selected = selected or zoneList[1]
		self.selected = selected and selected.name or nil
		itemOffset = 0
	end
	self.selectedEntry = selected
	RenderZones()
	RenderDetail(selected)
	RenderItems()
end

function ZUI:ScrollZones(step)
	local before = listOffset
	listOffset = math.max(0, math.min(math.max(0, #zoneList - ZONE_ROWS), listOffset + step))
	if listOffset ~= before then RenderZones() end
end

function ZUI:ScrollItems(step)
	local before = itemOffset
	itemOffset = math.max(0, math.min(math.max(0, #itemList - w.itemRowsN), itemOffset + step))
	if itemOffset ~= before then RenderItems() end
end

---------------------------------------------------------------------------
-- Show / hide
---------------------------------------------------------------------------

-- zone: optional zone name (case-insensitive prefix) to select.
function ZUI:Show(zone)
	Build()
	if zone and zone ~= "" then
		local want = zone:lower()
		for _, e in ipairs(FL.Zones:Collect()) do
			if e.name:lower():sub(1, #want) == want then
				self.selected = e.name
				itemOffset = 0
				break
			end
		end
	end
	frame:Show()
	self:Refresh()
end

-- Demo data on / off (in memory only, see Zones:DemoZones).
function ZUI:SetDemo(on)
	FL.Zones.demo = on or nil
	self.selected = nil
	listOffset, itemOffset = 0, 0
	self:Show()
end

function ZUI:Hide()
	if frame then frame:Hide() end
end

function ZUI:Toggle()
	Build()
	if frame:IsShown() then self:Hide() else self:Show() end
end

function ZUI:IsShown()
	return frame ~= nil and frame:IsShown()
end

local lastTickRefresh = 0
FL:On("SESSION_CHANGED", function() ZUI:Refresh() end)
FL:On("LOOT_RECORDED", function() ZUI:Refresh() end)
FL:On("PRICES_UPDATED", function() ZUI:Refresh() end)
FL:On("DB_ADOPTED", function() ZUI:Refresh() end)
FL:On("TICK", function(now)
	-- the live zone's time and gold / hour move while fishing; every 5 s is plenty
	if frame and frame:IsShown() and FL.Session:IsRunning() and (now or 0) - lastTickRefresh >= 5 then
		lastTickRefresh = now or 0
		ZUI:Refresh()
	end
end)
