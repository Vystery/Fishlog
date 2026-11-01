-- FishLog :: UI
-- The session panel, built from Blizzard's own frame templates so it reads as part of the default UI:
--   PortraitFrameTemplate window with the Fishing icon (FL:CreateWindow, shared with the zone window)
--     zone line, right of the portrait
--     status line: Running / Paused (state carried by the font color), active-time timer at the right
--     2 x 2 stat groups (label over value, no extra borders): Casts | Catches, Loot value | Gold / hour
--     Fishing skill row
--     loot list inside the window's Inset, three columns: icon + name | count | value (hover for the tooltip)
--     Stop / Pause / Reset / Zones (UIPanelButtonTemplate; Zones opens the zone window, ZonesUI.lua)
-- Everything shares one content column (PAD from both window edges) so the edges line up.
-- Colors come from Blizzard font objects (GameFontNormalSmall, GameFontHighlightLarge, GameFontGreenSmall,
-- GameFontDisableSmall); the only color codes used are item quality colors on item names.
-- Refreshes on session events and once a second while a session runs.

local _, FL = ...
local UI = {}
FL.UI = UI

local WIDTH = 270
local PAD = 12            -- one content column: everything is PAD from both window edges
local TOP = 30            -- first content line below the title bar
local TILE_H = 34         -- a stat group: small label over a large value
local TILE_GAP = 8
local SECTION_GAP = 8     -- vertical gap between sections
local ROW_H = 18          -- loot row
local LINE_H = 14         -- one small text line
local BUTTON_H = 22
local INSET_PAD = 5       -- padding inside the loot inset
local COUNT_W = 30        -- loot row count column
local VALUE_W = 50        -- loot row value column

local frame
local widgets = {}
local lootRows = {}

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

-- CreateFrame with a Blizzard template, falling back to a plain frame when the template is missing on this build.
local function TemplateFrame(kind, name, parent, template)
	local ok, f = pcall(CreateFrame, kind, name, parent, template)
	if ok and type(f) == "table" then return f, true end
	return CreateFrame(kind, name, parent), false
end

local function SetTitle(f, title)
	if type(f.SetTitle) == "function" then pcall(f.SetTitle, f, title) end
	if type(f.TitleText) == "table" then f.TitleText:SetText(title) end
	if type(f.TitleContainer) == "table" and type(f.TitleContainer.TitleText) == "table" then f.TitleContainer.TitleText:SetText(title) end
end

-- SetFontObject with a font that may not exist on this build; keeps the font from construction otherwise.
local function TrySetFont(fs, fontName)
	if _G[fontName] then pcall(fs.SetFontObject, fs, fontName) end
end

-- A default UI window: PortraitFrameTemplate (the stone-and-metal frame of the character / profession windows)
-- with the Fishing icon in the portrait, falling back to ButtonFrameTemplate, BasicFrameTemplateWithInset and a
-- dialog-box backdrop when a template is missing on this build. Always has TitleText or SetTitle, CloseButton
-- and an Inset. Returns the frame and whether it has a portrait (content then starts right of / below it).
local PORTRAIT_ICON = "Interface\\Icons\\Trade_Fishing"
FL.PORTRAIT_W = 64        -- content right of the portrait starts here
FL.PORTRAIT_H = 62        -- content below the portrait starts here

function FL:CreateWindow(name, title, onClose)
	local f
	for _, template in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate", "BasicFrameTemplateWithInset" }) do
		local ok, made = pcall(CreateFrame, "Frame", name, UIParent, template)
		if ok and type(made) == "table" then f = made break end
	end
	if not f then
		f = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
				tile = true, tileSize = 32, edgeSize = 32,
				insets = { left = 11, right = 12, top = 12, bottom = 11 },
			})
		end
	end
	if type(f.TitleText) ~= "table" and type(f.SetTitle) ~= "function" then
		f.TitleText = NewText(f, "GameFontNormal", "CENTER")
		f.TitleText:SetPoint("TOP", f, "TOP", 0, -6)
	end
	if type(f.CloseButton) ~= "table" then
		f.CloseButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		f.CloseButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", 3, 3)
		f.CloseButton:SetScript("OnClick", onClose)
	end
	-- PortraitFrameTemplate has no Inset of its own; the callers place this one
	if type(f.Inset) ~= "table" then f.Inset = TemplateFrame("Frame", nil, f, "InsetFrameTemplate") end
	SetTitle(f, title)
	local portrait = (type(f.PortraitContainer) == "table" and f.PortraitContainer.portrait) or f.portrait
	if type(f.SetPortraitToAsset) == "function" then
		pcall(f.SetPortraitToAsset, f, PORTRAIT_ICON)
	elseif type(portrait) == "table" and SetPortraitToTexture then
		pcall(SetPortraitToTexture, portrait, PORTRAIT_ICON)
	end
	return f, type(portrait) == "table"
end

-- List styling shared with the zone window, same as CraftShuffle's lists: the Auction House browse art on an
-- InsetFrameTemplate (instead of its bare black background), AH row highlight / selection atlases, and
-- AuctionHouseTableHeaderStringTemplate column headers sitting on the window background above the inset.
function FL:StyleInset(inset)
	if type(inset) ~= "table" or inset.flArt or not inset.CreateTexture then return end
	local art = inset:CreateTexture(nil, "BACKGROUND", nil, 2)
	if art.SetAtlas and pcall(art.SetAtlas, art, "auctionhouse-background-index") then
		art:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
		art:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3)
	else
		art:Hide()
	end
	inset.flArt = art
end

local function Atlas(tex, atlas, r, g, b, a)
	if not (tex.SetAtlas and pcall(tex.SetAtlas, tex, atlas)) then tex:SetColorTexture(r, g, b, a) end
end

-- Hover highlight and an optional selection texture (row:SetSelected) for a list row button.
function FL:StyleRow(row, selectable)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(row)
	Atlas(hl, "auctionhouse-ui-row-highlight", 1, 1, 1, 0.08)
	if hl.SetBlendMode then pcall(hl.SetBlendMode, hl, "ADD") end
	if selectable then
		local sel = row:CreateTexture(nil, "BACKGROUND")
		sel:SetAllPoints(row)
		Atlas(sel, "auctionhouse-ui-row-select", 1, 0.82, 0, 0.12)
		sel:Hide()
		row.SetSelected = function(_, on) sel:SetShown(on and true or false) end
	end
end

-- An AH column header. justify "RIGHT" right-aligns the text over a right-aligned number column.
-- h:SetLabel(text, sorted, desc) sets the text and the sort arrow.
function FL:CreateHeader(parent, justify)
	local ok, h = pcall(CreateFrame, "Button", nil, parent, "AuctionHouseTableHeaderStringTemplate")
	if not ok or type(h) ~= "table" then h = CreateFrame("Button", nil, parent) end
	local text = h.GetFontString and h:GetFontString()
	if type(text) ~= "table" then
		text = NewText(h, "GameFontHighlightSmall", "LEFT")
		if h.SetFontString then h:SetFontString(text) end
	end
	text:ClearAllPoints()
	if justify == "RIGHT" then
		text:SetPoint("RIGHT", h, "RIGHT", -6, 0)
	else
		text:SetPoint("LEFT", h, "LEFT", 8, 0)
	end
	text:SetJustifyH(justify or "LEFT")
	if type(h.Arrow) == "table" then
		h.Arrow:ClearAllPoints()
		if justify == "RIGHT" then
			h.Arrow:SetPoint("RIGHT", text, "LEFT", -1, 0)
		else
			h.Arrow:SetPoint("LEFT", text, "RIGHT", 1, 0)
		end
		h.Arrow:Hide()
	end
	h.SetLabel = function(self, label, sorted, desc)
		local arrow = type(self.Arrow) == "table" and self.Arrow or nil
		if arrow then
			arrow:SetShown(sorted and true or false)
			if sorted and arrow.SetTexCoord then
				if desc then arrow:SetTexCoord(0, 1, 0, 1) else arrow:SetTexCoord(0, 1, 1, 0) end
			end
		elseif sorted then
			label = label .. (desc and " v" or " ^")
		end
		text:SetText(label)
	end
	-- the template's own OnClick sorts its AH owner table, which these headers do not have
	h:SetScript("OnClick", nil)
	h:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	return h
end

local function SavePosition()
	if not frame or not frame.GetPoint then return end
	local ok, point, _, _, x, y = pcall(frame.GetPoint, frame, 1)
	if ok and point then FL:SetSetting("pos", { point = point, x = x, y = y }) end
end

local function SetButtonEnabled(b, enabled)
	if not b then return end
	if enabled then b:Enable() else b:Disable() end
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- A stat group: small gold label over a large white value, optional small note after the value. No border of
-- its own; the window background and the loot Inset below give the section its shape.
local function StatTile(label)
	local tile = CreateFrame("Frame", nil, frame)
	tile:SetHeight(TILE_H)
	tile.label = NewText(tile, "GameFontNormalSmall", "LEFT")
	tile.label:SetPoint("TOPLEFT", tile, "TOPLEFT", 0, 0)
	tile.label:SetPoint("RIGHT", tile, "RIGHT", 0, 0)
	tile.label:SetText(label)
	tile.value = NewText(tile, "GameFontHighlightLarge", "LEFT")
	tile.value:SetPoint("BOTTOMLEFT", tile, "BOTTOMLEFT", 0, 0)
	tile.note = NewText(tile, "GameFontGreenSmall", "LEFT")
	tile.note:SetPoint("LEFT", tile.value, "RIGHT", 4, -1)
	tile.note:SetPoint("RIGHT", tile, "RIGHT", 0, 0)
	return tile
end

local function NewLootRow()
	local row = CreateFrame("Button", nil, frame.Inset)
	row:SetHeight(ROW_H)
	FL:StyleRow(row)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	-- three columns: name fills the left, count and value are narrow right-aligned columns
	row.value = NewText(row, "GameFontHighlightSmall", "RIGHT")
	row.value:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.value:SetWidth(VALUE_W)
	row.count = NewText(row, "GameFontDisableSmall", "RIGHT")
	row.count:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
	row.count:SetWidth(COUNT_W)
	row.name = NewText(row, "GameFontHighlightSmall", "LEFT")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
	row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	row:SetScript("OnEnter", function(self)
		if not self.entry or not GameTooltip then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local shown = false
		if self.entry.link and GameTooltip.SetHyperlink then
			shown = pcall(GameTooltip.SetHyperlink, GameTooltip, self.entry.link)
		end
		if not shown then GameTooltip:AddLine(self.entry.name) end
		local e = self.entry
		-- CraftProfit's own tooltip block (auction price, scan status) is added by its TooltipDataProcessor
		-- hook when SetHyperlink runs; this line says which value FishLog is counting.
		if e.unit then
			local basis = e.kind == "ah" and "auction price" or e.kind == "vendor" and "vendor price, no higher auction price known" or "no value"
			GameTooltip:AddLine(string.format("FishLog counts %s each (%s), %s for %d", FL:FormatMoneyPlain(e.unit),
				basis, FL:FormatMoneyPlain(e.total or 0), e.n), 0.43, 0.72, 1, true)
		else
			GameTooltip:AddLine("FishLog: value unknown yet (item data loading)", 0.43, 0.72, 1)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	return row
end

local function Build()
	if frame then return end
	local hasPortrait
	frame, hasPortrait = FL:CreateWindow("FishLogPanel", "FishLog", function() UI:Hide() end)
	-- zone and status lines sit right of the portrait; the stat groups below start under it
	local x0 = hasPortrait and FL.PORTRAIT_W or PAD

	frame:SetSize(WIDTH, 300)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) if not FL.settings.locked then self:StartMoving() end end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)
	local pos = FL.settings.pos
	if pos and pos.point then
		frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 300, 100)
	end

	-- zone
	widgets.zone = NewText(frame, "GameFontDisableSmall", "LEFT")
	widgets.zone:SetPoint("TOPLEFT", frame, "TOPLEFT", x0, -TOP)
	widgets.zone:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)

	-- status line: state text at the left (color = state), timer at the right, both on one baseline
	local statusY = -(TOP + LINE_H + 4)
	widgets.timer = NewText(frame, "GameFontHighlightLarge", "RIGHT")
	widgets.timer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, statusY)
	widgets.state = NewText(frame, "GameFontGreenSmall", "LEFT")
	widgets.state:SetPoint("LEFT", frame, "LEFT", x0, 0)
	widgets.state:SetPoint("RIGHT", widgets.timer, "LEFT", -6, 0)
	widgets.state:SetPoint("BOTTOM", widgets.timer, "BOTTOM", 0, 1)

	-- stat groups, 2 x 2, all values in the same font
	local tilesY = statusY - 16 - SECTION_GAP - 2
	local tileW = (WIDTH - 2 * PAD - TILE_GAP) / 2
	widgets.casts = StatTile("Casts")
	widgets.catches = StatTile("Catches")
	widgets.value = StatTile("Loot value")
	widgets.gph = StatTile("Gold / hour")
	TrySetFont(widgets.value.note, "GameFontDisableSmall")
	TrySetFont(widgets.gph.note, "GameFontDisableSmall")
	for i, tile in ipairs({ widgets.casts, widgets.catches, widgets.value, widgets.gph }) do
		local col, rowIdx = (i - 1) % 2, math.floor((i - 1) / 2)
		tile:SetWidth(tileW)
		tile:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + col * (tileW + TILE_GAP), tilesY - rowIdx * (TILE_H + TILE_GAP))
	end
	local tilesBottom = tilesY - 2 * TILE_H - TILE_GAP

	-- fishing skill row
	local skillY = tilesBottom - SECTION_GAP
	widgets.skillLabel = NewText(frame, "GameFontNormalSmall", "LEFT")
	widgets.skillLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, skillY)
	widgets.skillLabel:SetText("Fishing skill")
	widgets.skillGain = NewText(frame, "GameFontGreenSmall", "RIGHT")
	widgets.skillGain:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
	widgets.skillGain:SetPoint("TOP", widgets.skillLabel, "TOP", 0, 0)
	widgets.skill = NewText(frame, "GameFontHighlightSmall", "RIGHT")
	widgets.skill:SetPoint("RIGHT", widgets.skillGain, "LEFT", 0, 0)
	widgets.skill:SetPoint("TOP", widgets.skillLabel, "TOP", 0, 0)

	-- loot list inset: top fixed under the skill row, bottom follows the buttons
	widgets.insetTop = skillY - LINE_H - SECTION_GAP
	FL:StyleInset(frame.Inset)
	frame.Inset:ClearAllPoints()
	frame.Inset:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, widgets.insetTop)
	frame.Inset:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, widgets.insetTop)

	widgets.more = NewText(frame.Inset, "GameFontDisableSmall", "LEFT")
	widgets.empty = NewText(frame.Inset, "GameFontDisableSmall", "CENTER")
	widgets.empty:SetText("Nothing looted yet.")

	-- buttons
	local function Btn(text, onClick)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetHeight(BUTTON_H)
		b:SetText(text)
		b:SetScript("OnClick", onClick)
		return b
	end
	widgets.startStop = Btn("Start", function()
		if FL.Session:Current() then FL.Session:Stop("button") else FL.Session:Start("button") end
	end)
	widgets.pause = Btn("Pause", function()
		if FL.Session:IsRunning() then FL.Session:Pause(false) else FL.Session:Resume() end
	end)
	widgets.reset = Btn("Reset", function() FL.Session:Reset() end)
	widgets.zones = Btn("Zones", function() if FL.ZonesUI then FL.ZonesUI:Toggle() end end)
	local btnGap = 4
	local btnW = math.floor((WIDTH - 2 * PAD - 3 * btnGap) / 4)
	widgets.startStop:SetWidth(btnW)
	widgets.pause:SetWidth(btnW)
	widgets.reset:SetWidth(btnW)
	widgets.zones:SetWidth(WIDTH - 2 * PAD - 3 * (btnW + btnGap))
	widgets.startStop:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
	widgets.pause:SetPoint("LEFT", widgets.startStop, "RIGHT", btnGap, 0)
	widgets.reset:SetPoint("LEFT", widgets.pause, "RIGHT", btnGap, 0)
	widgets.zones:SetPoint("LEFT", widgets.reset, "RIGHT", btnGap, 0)
	frame.Inset:SetPoint("BOTTOM", widgets.startStop, "TOP", 0, SECTION_GAP)

	frame:SetScript("OnShow", function() UI:Refresh() end)
	frame:Hide()
	UI.frame = frame
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local STATE_FONT = { running = "GameFontGreenSmall", paused = "GameFontNormalSmall", none = "GameFontDisableSmall" }

function UI:Refresh()
	if not frame or not frame:IsShown() then return end
	local S = FL.Session
	local s = S:Current()
	local now = FL:Now()
	local sum = s and S:Summary(s, now) or nil

	-- zone and status
	local stateKey = "none"
	if s then
		local where = table.concat(s.zones or { s.zone or "" }, ", ")
		if s.subzone and s.subzone ~= "" and #(s.zones or {}) <= 1 then where = where .. " - " .. s.subzone end
		widgets.zone:SetText(where ~= "" and where or "Unknown zone")
		stateKey = s.state == "running" and "running" or "paused"
		widgets.state:SetText(stateKey == "running" and "Running" or (s.autoPaused and "Paused (idle)" or "Paused"))
		widgets.timer:SetText(FL:FormatDuration(sum.active))
	else
		widgets.zone:SetText(FL.settings.autoStart and "Cast your line to start a session." or "Click Start to begin a session.")
		local h = FL.db.history or {}
		local last = h[#h]
		widgets.state:SetText(last and string.format("Last: %s, %s/h", FL:FormatMoneyPlain(last.value or 0),
			last.gph and FL:FormatMoneyPlain(last.gph) or "n/a") or "No session")
		widgets.timer:SetText(last and FL:FormatDuration(last.active or 0) or "0:00")
	end
	TrySetFont(widgets.state, STATE_FONT[stateKey])

	-- tiles
	widgets.casts.value:SetText(sum and sum.casts or 0)
	widgets.casts.note:SetText("")
	widgets.catches.value:SetText(sum and sum.catches or 0)
	widgets.catches.note:SetText(sum and sum.catchRate and string.format("%d%%", math.floor(sum.catchRate * 100 + 0.5)) or "")
	widgets.value.value:SetText(FL:FormatMoney(sum and sum.value or 0, { compact = true }))
	widgets.value.note:SetText(sum and sum.unpriced > 0 and string.format("+%d?", sum.unpriced) or "")
	if sum and sum.gph then
		widgets.gph.value:SetText(FL:FormatMoney(sum.gph, { compact = true }))
		widgets.gph.note:SetText("")
	else
		widgets.gph.value:SetText("")
		widgets.gph.note:SetText(sum and "after 1 min" or "-")
	end

	-- skill
	if s and s.skillStart then
		local endSkill = s.skillEnd or s.skillStart
		local gained = endSkill - s.skillStart
		widgets.skill:SetText(tostring(endSkill))
		widgets.skillGain:SetText(gained > 0 and string.format(" +%d", gained) or "")
	else
		local level = S:FishingSkill()
		widgets.skill:SetText(level and tostring(level) or "-")
		widgets.skillGain:SetText("")
	end

	-- loot list
	local inset = frame.Inset
	local y = -INSET_PAD
	local list = s and S:SortedLoot(s) or {}
	local maxRows = FL.settings.lootRows or 10
	local shown = math.min(#list, maxRows)
	for i = 1, shown do
		local row = lootRows[i]
		if not row then
			row = NewLootRow()
			lootRows[i] = row
		end
		local e = list[i]
		row.entry = e
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", inset, "TOPLEFT", INSET_PAD, y)
		row:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -INSET_PAD, y)
		if e.icon then
			row.icon:SetTexture(e.icon)
			row.icon:Show()
		else
			row.icon:Hide()
		end
		row.name:SetText(FL:Color(QualityHex(e.q), e.name))
		row.count:SetText("x" .. e.n)
		row.count:SetShown(e.n ~= 1)
		if e.total then
			row.value:SetText(FL:FormatMoneyShort(e.total) .. (e.kind == "vendor" and FL:Color("9d9d9d", " v") or ""))
		else
			row.value:SetText(FL:Color("9d9d9d", "?"))
		end
		row:Show()
		y = y - ROW_H
	end
	for i = shown + 1, #lootRows do
		lootRows[i]:Hide()
		lootRows[i].entry = nil
	end
	if #list > shown then
		widgets.more:ClearAllPoints()
		widgets.more:SetPoint("TOPLEFT", inset, "TOPLEFT", INSET_PAD + 4, y - 2)
		widgets.more:SetText(string.format("+%d more item(s)", #list - shown))
		widgets.more:Show()
		y = y - LINE_H
	else
		widgets.more:Hide()
	end
	if #list == 0 then
		widgets.empty:ClearAllPoints()
		widgets.empty:SetPoint("TOP", inset, "TOP", 0, y - 4)
		widgets.empty:Show()
		y = y - LINE_H - 4
	else
		widgets.empty:Hide()
	end
	local insetHeight = -y + INSET_PAD

	-- buttons
	widgets.startStop:SetText(s and "Stop" or "Start")
	widgets.pause:SetText((s and s.state == "running") and "Pause" or "Resume")
	SetButtonEnabled(widgets.pause, s ~= nil)
	SetButtonEnabled(widgets.reset, s ~= nil)

	-- window height: everything above the inset + inset + gap + buttons + bottom padding
	frame:SetHeight(-widgets.insetTop + insetHeight + SECTION_GAP + BUTTON_H + PAD)
end

---------------------------------------------------------------------------
-- Show / hide
---------------------------------------------------------------------------

function UI:Show()
	Build()
	frame:Show()
	self:Refresh()
end

function UI:Hide()
	if frame then frame:Hide() end
end

function UI:Toggle()
	Build()
	if frame:IsShown() then self:Hide() else self:Show() end
end

function UI:IsShown()
	return frame ~= nil and frame:IsShown()
end

FL:On("SESSION_CHANGED", function() UI:Refresh() end)
FL:On("LOOT_RECORDED", function() UI:Refresh() end)
FL:On("PRICES_UPDATED", function() UI:Refresh() end)
FL:On("SETTINGS_CHANGED", function(key)
	if key ~= "pos" then UI:Refresh() end
end)
FL:On("TICK", function()
	if frame and frame:IsShown() and FL.Session:IsRunning() then UI:Refresh() end
end)
FL:On("READY", function()
	if FL.Session:Current() and FL.settings.autoShow then UI:Show() end
end)
