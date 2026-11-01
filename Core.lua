-- FishLog :: Core
-- Namespace, saved variables (late-loading safe), event dispatch, formatting helpers, slash commands.

local ADDON_NAME, FL = ...
_G.FishLog = FL

FL.name = ADDON_NAME
FL.CALLER_ID = ADDON_NAME
-- Filled in at PLAYER_LOGIN (end of this file): on build 69977 asking the client for our own TOC metadata
-- while the addon is still loading keeps it from handing back our SavedVariables.
FL.version = "dev"
FL.DB_VERSION = 1

FL.defaults = {
	autoStart = true,     -- start a session on the first fishing cast when none is running
	autoShow = true,      -- show the panel when a session starts
	idlePause = 300,      -- seconds without a cast before the session pauses itself (0 = never)
	applyCut = true,      -- AH values net of the auction house cut
	ahCut = 0.05,
	source = "auto",      -- auto | craftprofit | auctionator | tsm | vendor
	lootRows = 10,        -- loot lines shown in the panel
	locked = false,       -- panel cannot be dragged
	pos = nil,            -- { point, x, y } saved panel position
	zonesPos = nil,       -- { point, x, y } saved zone window position
	zoneSort = "gph",     -- zone window order: gph | time | name | last
	debug = false,
}

FL.COLORS = {
	gold   = "ffd100",
	body   = "e8dcc8",
	label  = "c8b78a",
	muted  = "8a7d64",
	gray   = "9d9d9d",
	green  = "4cd137",
	red    = "ff5b4b",
	blue   = "6fb7ff",
}

---------------------------------------------------------------------------
-- Output helpers
---------------------------------------------------------------------------

function FL:Print(msg, ...)
	if select("#", ...) > 0 then msg = string.format(msg, ...) end
	(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cff6fb7ffFishLog:|r " .. tostring(msg))
end

function FL:Debug(msg, ...)
	if self.settings and self.settings.debug then
		if select("#", ...) > 0 then msg = string.format(msg, ...) end
		(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cff8a7d64FishLog[dbg]:|r " .. tostring(msg))
	end
end

function FL:Color(hex, text)
	return "|cff" .. hex .. tostring(text) .. "|r"
end

---------------------------------------------------------------------------
-- Pub/sub and game events
---------------------------------------------------------------------------

local listeners = {}
function FL:On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

function FL:Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, ...)
		if not ok then self:Print("listener error (%s): %s", event, tostring(err)) end
	end
end

local eventFrame = CreateFrame("Frame")
local handlers = {}
FL.rejectedEvents = {}
function FL:RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
		if not ok then
			self.rejectedEvents[#self.rejectedEvents + 1] = event
		end
	end
	table.insert(handlers[event], fn)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, event, ...)
		if not ok then FL:Print("error in %s handler: %s", event, tostring(err)) end
	end
end)

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------
-- Build 69913 hands the saved global back late or not at all, and appears to skip a global that is
-- already set. So: work on a local table, never assign the global at load, poll for the client filling
-- it, merge this session's data into it when it shows up, and assign it at PLAYER_LOGOUT so the file
-- is written. Two copies are declared (account-wide and per character); the first to arrive is adopted.

local function ApplyDefaults(tbl, defaults)
	for k, v in pairs(defaults) do
		if tbl[k] == nil then tbl[k] = v end
	end
end

local function InitDB(existing)
	local db = existing or FL.db or {}
	db.version = db.version or FL.DB_VERSION
	db.settings = db.settings or {}
	db.history = db.history or {}   -- finished sessions, oldest first
	-- db.current: the running/paused session (kept so /reload resumes it)
	ApplyDefaults(db.settings, FL.defaults)
	-- db.zones: lifetime per-zone totals (Zones.lua), rebuilt from the history when missing
	if FL.Zones then FL.Zones:EnsureDB(db) end
	FL.db = db
	FL.settings = db.settings
end
FL.InitDB = InitDB

FL.touched = {}
FL.loadInfo = { hadDB = nil, adopted = 0, from = nil }

function FL:SetSetting(key, value)
	self.settings[key] = value
	self.touched[key] = true
	self:Fire("SETTINGS_CHANGED", key, value)
end

-- loaded: the table the client assigned; session: what we worked on so far this login.
local function AdoptDB(loaded, session, reason)
	loaded.settings = loaded.settings or {}
	loaded.history = loaded.history or {}
	-- zone totals: build the file's from its own history, then add this login's finished sessions it lacks
	if FL.Zones then FL.Zones:PrepareAdopt(loaded) end
	-- settings: the loaded file wins except for keys changed this session
	for k, v in pairs(session.settings or {}) do
		if loaded.settings[k] == nil or FL.touched[k] then loaded.settings[k] = v end
	end
	-- history: append this session's finished sessions the file does not have
	local seen = {}
	for _, rec in ipairs(loaded.history) do seen[rec.startedAt or 0] = true end
	for _, rec in ipairs(session.history or {}) do
		if not seen[rec.startedAt or 0] then table.insert(loaded.history, rec) end
	end
	-- current session: this login's session wins when it has casts; the file's one is closed into history
	if session.current and (session.current.casts or 0) > 0 then
		if loaded.current and FL.Session and FL.Session.Finish then
			local rec = FL.Session:Finish(loaded.current)
			if rec then
				if FL.Zones then FL.Zones:Fold(loaded, loaded.current, rec.endedAt) end
				table.insert(loaded.history, rec)
			end
		end
		loaded.current = session.current
	end
	table.sort(loaded.history, function(a, b) return (a.startedAt or 0) < (b.startedAt or 0) end)
	InitDB(loaded)
	FL:Fire("DB_ADOPTED", reason)
end

local SV_NAMES = { "FishLogDB", "FishLogCharDB" }
local lastAssigned = {}

-- Console vault: build 69977 never opens per-account or per-character SavedVariables files at load (ETW file
-- trace, 2026-09-24); only the machine-wide WTF\SavedVariables\Blizzard_Console.lua comes back. So a copy of
-- the database lives at Blizzard_Console_SavedVars.AddOnVault.FishLog (shared with CraftProfit's vault).
local function Vault(create)
	local console = _G.Blizzard_Console_SavedVars
	if type(console) ~= "table" then return nil end
	if type(console.AddOnVault) ~= "table" then
		if not create then return nil end
		console.AddOnVault = {}
	end
	return console.AddOnVault
end
local vaultTried

function FL:CheckSavedVariables(reason)
	if not self.db then return end
	if reason == "logout" then
		local vault = Vault(true)
		if vault then vault.FishLog = self.db end
	elseif not vaultTried and self.loadInfo.adopted == 0 and not self.loadInfo.hadDB then
		local vault = Vault(false)
		local copy = vault and vault.FishLog
		if type(copy) == "table" and copy ~= self.db then
			vaultTried = true
			local ok, err = pcall(AdoptDB, copy, self.db, "console vault")
			if ok then
				self.loadInfo.adopted = self.loadInfo.adopted + 1
				self.loadInfo.adoptedAt = reason .. " via console vault"
				self:Print("saved data loaded from the console vault.")
			else
				self:Print("could not adopt the saved data from the console vault (%s); keeping this session's data. %s", tostring(reason), tostring(err))
			end
		end
	end
	for _, name in ipairs(SV_NAMES) do
		local g = _G[name]
		if reason == "logout" then
			_G[name] = self.db
			lastAssigned[name] = self.db
		elseif g == nil then
			-- leave unset so a late fill is not skipped
		elseif g ~= self.db and g ~= lastAssigned[name] then
			if self.loadInfo.adopted > 0 then
				-- the sibling copy already arrived; this is the same data
				_G[name] = self.db
				lastAssigned[name] = self.db
			else
				local ok, err = pcall(AdoptDB, g, self.db, reason)
				if ok then
					self.loadInfo.adopted = self.loadInfo.adopted + 1
					self.loadInfo.adoptedAt = reason .. " via " .. name
					for _, n2 in ipairs(SV_NAMES) do
						_G[n2] = self.db
						lastAssigned[n2] = self.db
					end
					self:Print("saved data arrived late (%s) and was merged with this session.", tostring(reason))
				else
					self:Print("could not adopt the late saved data (%s); keeping this session's data. %s", tostring(reason), tostring(err))
					_G[name] = self.db
					lastAssigned[name] = self.db
				end
			end
		end
	end
end

function FL:SavedVariableStatus()
	if self.loadInfo.adopted > 0 then return string.format("saved data arrived late and was adopted (%s)", tostring(self.loadInfo.adoptedAt)) end
	if self.loadInfo.hadDB then return "saved data present at load (" .. tostring(self.loadInfo.from) .. ")" end
	return "no saved data at load, none seen later (session table, assigned at logout)"
end

local svTicker
local function StartSavedVariableWatch()
	FL:CheckSavedVariables("login")
	if svTicker or not (C_Timer and C_Timer.NewTicker) then return end
	local polls = 0
	svTicker = C_Timer.NewTicker(1, function()
		polls = polls + 1
		FL:CheckSavedVariables("poll " .. polls .. "s")
		if polls >= 300 and svTicker then
			svTicker:Cancel()
			svTicker = nil
		end
	end)
end

local function LoadDB()
	local from
	local loaded = _G.FishLogDB
	if loaded ~= nil then from = "account file" end
	if loaded == nil and _G.FishLogCharDB ~= nil then
		loaded = _G.FishLogCharDB
		from = "per-character file"
	end
	FL.loadInfo.hadDB = loaded ~= nil
	FL.loadInfo.from = from
	if type(loaded) ~= "table" then loaded = nil end
	InitDB(loaded)
	if loaded then
		-- the loader has run; from here on the live table is the global for both copies
		for _, name in ipairs(SV_NAMES) do
			_G[name] = FL.db
			lastAssigned[name] = FL.db
		end
	end
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local COIN = {
	g = "|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:2:0|t",
	s = "|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:2:0|t",
	c = "|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:2:0|t",
}

-- g s c with coin icons. opts.compact drops copper when >= 1g and silver when >= 100g.
function FL:FormatMoney(copper, opts)
	opts = opts or {}
	copper = tonumber(copper) or 0
	local size = opts.size or 0
	local negative = copper < 0
	local value = math.floor(math.abs(copper) + 0.5)
	local g = math.floor(value / 10000)
	local s = math.floor((value % 10000) / 100)
	local c = value % 100
	local parts = {}
	if g > 0 then
		parts[#parts + 1] = g .. string.format(COIN.g, size, size)
		if s > 0 and not (opts.compact and g >= 100) then parts[#parts + 1] = s .. string.format(COIN.s, size, size) end
		if c > 0 and not opts.compact then parts[#parts + 1] = c .. string.format(COIN.c, size, size) end
	else
		if s > 0 then parts[#parts + 1] = s .. string.format(COIN.s, size, size) end
		if c > 0 or #parts == 0 then parts[#parts + 1] = c .. string.format(COIN.c, size, size) end
	end
	local text = table.concat(parts, " ")
	if negative then text = "-" .. text end
	return text
end

-- One denomination: 128g, 12.4g, 79s, 95c.
function FL:FormatMoneyShort(copper, opts)
	opts = opts or {}
	copper = tonumber(copper) or 0
	local size = opts.size or 0
	local value = math.abs(copper)
	local text
	if value >= 1000000 then
		text = string.format("%d", math.floor(value / 10000 + 0.5)) .. string.format(COIN.g, size, size)
	elseif value >= 10000 then
		text = (string.format("%.1f", value / 10000):gsub("%.0$", "")) .. string.format(COIN.g, size, size)
	elseif value >= 100 then
		text = string.format("%d", math.floor(value / 100 + 0.5)) .. string.format(COIN.s, size, size)
	else
		text = string.format("%d", math.floor(value + 0.5)) .. string.format(COIN.c, size, size)
	end
	if copper < 0 then text = "-" .. text end
	return text
end

-- Plain text money for chat lines: 12g 34s 56c
function FL:FormatMoneyPlain(copper)
	copper = math.floor((tonumber(copper) or 0) + 0.5)
	local neg = copper < 0
	copper = math.abs(copper)
	local g, s, c = math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 or g > 0 then parts[#parts + 1] = s .. "s" end
	parts[#parts + 1] = c .. "c"
	return (neg and "-" or "") .. table.concat(parts, " ")
end

function FL:FormatDuration(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = seconds % 60
	if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
	return string.format("%d:%02d", m, s)
end

function FL:FormatAge(seconds)
	if not seconds then return "never" end
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then return "just now" end
	if seconds < 3600 then return string.format("%d min ago", math.floor(seconds / 60)) end
	if seconds < 86400 then return string.format("%d h ago", math.floor(seconds / 3600)) end
	return string.format("%d d ago", math.floor(seconds / 86400))
end

function FL:ItemIDFromLink(link)
	if type(link) ~= "string" then return nil end
	local id = link:match("item:(%d+)")
	return id and tonumber(id) or nil
end

-- Server epoch seconds: survives /reload and client restarts (GetTime() does not).
function FL:Now()
	return time()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function PrintStatus()
	FL:Print("v%s. SavedVariables: %s.", FL.version, FL:SavedVariableStatus())
	if FL.Session then FL.Session:PrintStatus() end
	if FL.Prices then FL:Print("value source: %s.", FL.Prices:Describe()) end
	if #FL.rejectedEvents > 0 then
		FL:Print("events this client rejected: %s", table.concat(FL.rejectedEvents, ", "))
	end
end

local function PrintHelp()
	FL:Print("commands:")
	FL:Print("  /fish              toggle the session panel")
	FL:Print("  /fish start | stop | pause | resume | reset")
	FL:Print("  /fish status       session numbers, price source, saved-variable state")
	FL:Print("  /fish history      the last finished sessions")
	FL:Print("  /fish zones [zone]       zone window: every zone you fished, its loot and gold / hour")
	FL:Print("  /fish zones forget <zone>  delete a zone's saved totals")
	FL:Print("  /fish zones demo         preview the zone window with made-up zones (toggle, not saved)")
	FL:Print("  /fish autostart on|off   start a session on the first cast (now: %s)", FL.settings.autoStart and "on" or "off")
	FL:Print("  /fish idle <minutes>     pause after this long without a cast, 0 = never (now: %d)", math.floor((FL.settings.idlePause or 0) / 60))
	FL:Print("  /fish cut on|off|<pct>   AH values net of the cut (now: %s, %d%%)", FL.settings.applyCut and "on" or "off", math.floor((FL.settings.ahCut or 0) * 100 + 0.5))
	FL:Print("  /fish source auto|craftprofit|auctionator|tsm|vendor  (now: %s)", FL.settings.source)
	FL:Print("  /fish rows <n>           loot lines in the panel (now: %d)", FL.settings.lootRows)
	FL:Print("  /fish lock | unlock      panel dragging")
	FL:Print("  /fish debug              toggle debug chat lines")
end

local function HandleSlash(input)
	input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = input:match("^(%S+)%s*(.-)$")
	cmd = (cmd or ""):lower()
	rest = rest or ""
	local S = FL.Session
	if cmd == "" then
		if FL.UI then FL.UI:Toggle() end
	elseif cmd == "show" then
		if FL.UI then FL.UI:Show() end
	elseif cmd == "hide" then
		if FL.UI then FL.UI:Hide() end
	elseif cmd == "start" then
		S:Start("slash")
	elseif cmd == "stop" or cmd == "end" then
		S:Stop("slash")
	elseif cmd == "pause" then
		S:Pause(false)
	elseif cmd == "resume" then
		S:Resume()
	elseif cmd == "reset" or cmd == "clear" then
		S:Reset()
	elseif cmd == "zones" or cmd == "zone" then
		local sub, arg = rest:match("^(%S+)%s*(.-)$")
		if sub and sub:lower() == "demo" then
			local on = not FL.Zones.demo
			FL.ZonesUI:SetDemo(on)
			FL:Print(on and "zone window shows made-up demo zones (not saved). /fish zones demo again to go back." or "zone window shows your own zones again.")
		elseif sub and sub:lower() == "forget" and arg ~= "" then
			local target
			for zone in pairs(FL.db.zones or {}) do
				if zone:lower() == arg:lower() then target = zone end
			end
			if target and FL.Zones:Forget(target) then
				FL:Print("zone totals for %s deleted.", target)
				FL:Fire("SESSION_CHANGED", "zones", S:Current())
			else
				FL:Print("no saved totals for \"%s\" (use the zone name as shown in the zone window).", arg)
			end
		elseif rest ~= "" then
			if FL.ZonesUI then FL.ZonesUI:Show(rest) end
		elseif FL.ZonesUI then
			FL.ZonesUI:Toggle()
		end
	elseif cmd == "status" then
		PrintStatus()
	elseif cmd == "history" or cmd == "hist" then
		S:PrintHistory(tonumber(rest) or 10)
	elseif cmd == "autostart" then
		local on = rest:lower()
		if on == "on" or on == "off" then
			FL:SetSetting("autoStart", on == "on")
		else
			FL:SetSetting("autoStart", not FL.settings.autoStart)
		end
		FL:Print("auto-start %s.", FL.settings.autoStart and "on" or "off")
	elseif cmd == "idle" then
		local minutes = tonumber(rest)
		if minutes then
			FL:SetSetting("idlePause", math.max(0, math.floor(minutes * 60)))
			FL:Print("idle pause: %s.", minutes > 0 and ("after " .. minutes .. " min without a cast") or "never")
		else
			FL:Print("usage: /fish idle <minutes>")
		end
	elseif cmd == "cut" then
		local on = rest:lower()
		local pct = tonumber(rest)
		if pct then
			FL:SetSetting("ahCut", math.max(0, math.min(0.5, pct / 100)))
			FL:SetSetting("applyCut", true)
		elseif on == "on" or on == "off" then
			FL:SetSetting("applyCut", on == "on")
		else
			FL:SetSetting("applyCut", not FL.settings.applyCut)
		end
		if FL.Prices then FL.Prices:Invalidate() end
		FL:Print("AH cut %s (%d%%).", FL.settings.applyCut and "applied" or "ignored", math.floor(FL.settings.ahCut * 100 + 0.5))
	elseif cmd == "source" then
		local key = rest:lower()
		if key == "auto" or key == "craftprofit" or key == "auctionator" or key == "tsm" or key == "vendor" then
			FL:SetSetting("source", key)
			if FL.Prices then FL.Prices:Invalidate() end
			FL:Print("value source: %s.", FL.Prices and FL.Prices:Describe() or key)
		else
			FL:Print("usage: /fish source auto|craftprofit|auctionator|tsm|vendor")
		end
	elseif cmd == "rows" then
		local n = tonumber(rest)
		if n then
			FL:SetSetting("lootRows", math.max(1, math.min(30, math.floor(n))))
		else
			FL:Print("usage: /fish rows <n>")
		end
	elseif cmd == "lock" then
		FL:SetSetting("locked", true)
		FL:Print("panel locked.")
	elseif cmd == "unlock" then
		FL:SetSetting("locked", false)
		FL:Print("panel unlocked.")
	elseif cmd == "debug" then
		FL:SetSetting("debug", not FL.settings.debug)
		FL:Print("debug %s.", FL.settings.debug and "on" or "off")
	else
		PrintHelp()
	end
end

SLASH_FISHLOG1 = "/fishlog"
SLASH_FISHLOG2 = "/fish"
SlashCmdList["FISHLOG"] = HandleSlash
FL.HandleSlash = HandleSlash

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

FL:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == ADDON_NAME then
		LoadDB()
		FL:Debug("loaded v%s", FL.version)
	elseif FL.db then
		FL:CheckSavedVariables("addon " .. tostring(name))
	end
end)

FL:RegisterEvent("PLAYER_LOGIN", function()
	if not FL.db then LoadDB() end
	StartSavedVariableWatch()
	FL:Fire("READY")
end)
FL:RegisterEvent("PLAYER_ENTERING_WORLD", function() FL:CheckSavedVariables("entering world") end)
FL:RegisterEvent("PLAYER_LOGOUT", function()
	if FL.Session and FL.Session.OnLogout then FL.Session:OnLogout() end
	FL:CheckSavedVariables("logout")
end)

FL:RegisterEvent("PLAYER_LOGIN", function()
	if C_AddOns and C_AddOns.GetAddOnMetadata then FL.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or FL.version end
end)
