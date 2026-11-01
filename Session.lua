-- FishLog :: Session
-- The fishing session: start / pause / resume / stop, cast counting from the Fishing channel, loot capture
-- from the fishing loot window, value and gold-per-hour math, idle pausing and the finished-session history.
--
-- A session lives in FL.db.current (so /reload resumes it) and looks like:
--   { startedAt, endedAt, state = "running"|"paused", active = <seconds banked while running>,
--     resumedAt = <epoch when it last went running, nil while paused>, autoPaused = bool,
--     zone, subzone, zones = { ... }, casts, catches, money, lastActivityAt,
--     loot = { [itemID] = { n, name, link, icon, q } }, skillStart, skillEnd }

local _, FL = ...
local Session = {}
FL.Session = Session

local HISTORY_MAX = 50
local HISTORY_ITEMS = 15
local IDLE_GRACE = 20        -- seconds credited after the last activity when the session pauses itself
local LOOT_WINDOW = 3        -- seconds after the Fishing channel ends during which a loot window is fishing loot
local OFFLINE_IDLE = 600     -- a running session found at login idle longer than this is treated as paused

-- Fishing spell IDs seen across expansions (Classic ranks first). Name matching covers anything else.
local FISHING_SPELLS = {
	[7620] = true, [7731] = true, [7732] = true, [18248] = true, [33095] = true, [51294] = true,
	[88868] = true, [110410] = true, [131474] = true, [131476] = true, [131490] = true,
	[7733] = true, [7734] = true, [18249] = true, [33100] = true, [51293] = true, [88869] = true, [110412] = true,
}

Session.stats = {
	channelStarts = 0, channelStops = 0, succeeded = 0, lootReady = 0, lootOpened = 0,
	recorded = 0, ignored = 0, lastIgnored = nil, lastStage = "idle",
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local spellNameCache = {}
local function SpellName(spellID)
	if spellNameCache[spellID] ~= nil then return spellNameCache[spellID] or nil end
	local name
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, spellID)
		if ok and type(n) == "string" then name = n end
	end
	if not name and C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
		if ok and type(info) == "table" then name = info.name end
	end
	if not name and type(GetSpellInfo) == "function" then
		local ok, n = pcall(GetSpellInfo, spellID)
		if ok and type(n) == "string" then name = n end
	end
	spellNameCache[spellID] = name or false
	return name
end

local fishingCache = {}
function Session:IsFishingSpell(spellID)
	if not spellID then return false end
	if FISHING_SPELLS[spellID] then return true end
	if fishingCache[spellID] ~= nil then return fishingCache[spellID] end
	local name = SpellName(spellID)
	local fishing = _G.PROFESSIONS_FISHING or "Fishing"
	local is = name ~= nil and (name == fishing or name == "Fishing")
	fishingCache[spellID] = is
	return is
end

local function Zone()
	local zone = (GetZoneText and GetZoneText()) or ""
	local sub = (GetSubZoneText and GetSubZoneText()) or ""
	if zone == "" then zone = (GetRealZoneText and GetRealZoneText()) or "" end
	return zone, sub
end

-- Current fishing skill: level, max (nil when the API is missing or the character has no Fishing).
function Session:FishingSkill()
	if not (GetProfessions and GetProfessionInfo) then return nil end
	local ok, _, _, _, fishing = pcall(GetProfessions)
	if not ok or not fishing then return nil end
	local ok2, _, _, level, max = pcall(GetProfessionInfo, fishing)
	if ok2 and type(level) == "number" then return level, max end
	return nil
end

local function ParseMoneyName(name)
	if type(name) ~= "string" then return 0 end
	local function amount(pattern)
		if type(pattern) ~= "string" then return 0 end
		local p = pattern:gsub("%%d", "(%%d+)")
		local n = name:match(p)
		return tonumber(n) or 0
	end
	local g = amount(_G.GOLD_AMOUNT or "%d Gold")
	local s = amount(_G.SILVER_AMOUNT or "%d Silver")
	local c = amount(_G.COPPER_AMOUNT or "%d Copper")
	return g * 10000 + s * 100 + c
end

---------------------------------------------------------------------------
-- Session state
---------------------------------------------------------------------------

function Session:Current()
	return FL.db and FL.db.current or nil
end

function Session:IsRunning()
	local s = self:Current()
	return s ~= nil and s.state == "running"
end

-- Seconds the session has been running (excluding pauses).
function Session:ActiveSeconds(s, now)
	s = s or self:Current()
	if not s then return 0 end
	now = now or FL:Now()
	local active = s.active or 0
	if s.state == "running" and s.resumedAt then active = active + math.max(0, now - s.resumedAt) end
	return active
end

local function NewSession(now)
	local zone, sub = Zone()
	local skill = Session:FishingSkill()
	local s = {
		startedAt = now, state = "running", active = 0, resumedAt = now,
		zone = zone, subzone = sub, zones = { zone },
		casts = 0, catches = 0, money = 0, lastActivityAt = now,
		loot = {}, skillStart = skill, skillEnd = skill,
	}
	if FL.Zones then FL.Zones:Init(s) end
	return s
end

function Session:Start(reason)
	local s = self:Current()
	if s then
		if s.state == "paused" then return self:Resume() end
		FL:Print("a session is already running (%s). /fish stop to finish it.", FL:FormatDuration(self:ActiveSeconds(s)))
		return s
	end
	local now = FL:Now()
	s = NewSession(now)
	FL.db.current = s
	local where = s.zone ~= "" and (" in " .. s.zone) or ""
	FL:Print("session started%s%s.", where, reason == "auto" and " (auto-start on your first cast)" or "")
	FL:Fire("SESSION_CHANGED", "start", s)
	if FL.settings.autoShow and FL.UI then FL.UI:Show() end
	return s
end

function Session:Pause(auto)
	local s = self:Current()
	if not s or s.state ~= "running" then return end
	local now = FL:Now()
	if auto then
		-- credit only up to the last cast/loot plus a short grace; the idle time itself is not fishing
		local until_ = math.min(now, (s.lastActivityAt or now) + IDLE_GRACE)
		s.active = (s.active or 0) + math.max(0, until_ - (s.resumedAt or now))
		s.autoPaused = true
	else
		s.active = self:ActiveSeconds(s, now)
		s.autoPaused = nil
	end
	s.state = "paused"
	s.resumedAt = nil
	FL:Print(auto and "no cast for a while, session paused (resumes on your next cast)." or "session paused.")
	FL:Fire("SESSION_CHANGED", "pause", s)
end

function Session:Resume()
	local s = self:Current()
	if not s then
		FL:Print("no session to resume. /fish start")
		return
	end
	if s.state == "running" then return end
	local now = FL:Now()
	s.state = "running"
	s.resumedAt = now
	s.lastActivityAt = now
	local wasAuto = s.autoPaused
	s.autoPaused = nil
	FL:Print(wasAuto and "session resumed." or "session resumed.")
	FL:Fire("SESSION_CHANGED", "resume", s)
end

-- Aggregates for a session: active seconds, value in copper, gold per hour, unpriced item count.
function Session:Summary(s, now)
	s = s or self:Current()
	if not s then return nil end
	now = now or FL:Now()
	local active = self:ActiveSeconds(s, now)
	local value, unpriced, distinct = s.money or 0, 0, 0
	for itemID, entry in pairs(s.loot or {}) do
		distinct = distinct + 1
		local unit = FL.Prices:GetValue(itemID)
		if unit then value = value + unit * (entry.n or 0) else unpriced = unpriced + 1 end
	end
	local gph = active >= 60 and (value / active * 3600) or nil
	return {
		active = active, casts = s.casts or 0, catches = s.catches or 0, money = s.money or 0,
		value = value, gph = gph, unpriced = unpriced, distinct = distinct,
		catchRate = (s.casts or 0) > 0 and (s.catches or 0) / s.casts or nil,
	}
end

-- Loot entries sorted by total value (desc), then count, then name.
function Session:SortedLoot(s)
	s = s or self:Current()
	local list = {}
	if not s then return list end
	for itemID, entry in pairs(s.loot or {}) do
		local unit, kind = FL.Prices:GetValue(itemID)
		list[#list + 1] = { itemID = itemID, n = entry.n or 0, name = entry.name or ("item " .. itemID),
			link = entry.link, icon = entry.icon, q = entry.q, unit = unit, kind = kind, total = unit and unit * (entry.n or 0) or nil }
	end
	table.sort(list, function(a, b)
		local ta, tb = a.total or -1, b.total or -1
		if ta ~= tb then return ta > tb end
		if a.n ~= b.n then return a.n > b.n end
		return a.name < b.name
	end)
	return list
end

-- Builds the compact history record for a session (also used when a late-loaded file carries a session).
function Session:Finish(s, now)
	if not s then return nil end
	now = now or FL:Now()
	local sum = self:Summary(s, now)
	local rec = {
		startedAt = s.startedAt, endedAt = now, active = sum.active,
		zone = s.zone, subzone = s.subzone, zones = s.zones,
		casts = sum.casts, catches = sum.catches, money = sum.money, value = sum.value, gph = sum.gph,
		skillStart = s.skillStart, skillEnd = s.skillEnd or self:FishingSkill(),
		items = {},
	}
	local sorted = self:SortedLoot(s)
	for i = 1, math.min(#sorted, HISTORY_ITEMS) do
		local e = sorted[i]
		rec.items[i] = { id = e.itemID, n = e.n, name = e.name, value = e.total }
	end
	return rec
end

function Session:Stop(reason)
	local s = self:Current()
	if not s then
		FL:Print("no session running.")
		return
	end
	local now = FL:Now()
	local rec = self:Finish(s, now)
	FL.db.current = nil
	-- zone totals first: EnsureDB would otherwise rebuild them from a history that already holds this record
	if FL.Zones then FL.Zones:Fold(FL.db, s, now) end
	table.insert(FL.db.history, rec)
	while #FL.db.history > HISTORY_MAX do table.remove(FL.db.history, 1) end
	FL:Print("session finished: %s fishing, %d casts, %d catches, %s looted (%s/h).",
		FL:FormatDuration(rec.active), rec.casts, rec.catches, FL:FormatMoneyPlain(rec.value),
		rec.gph and FL:FormatMoneyPlain(rec.gph) or "n/a")
	FL:Fire("SESSION_CHANGED", "stop", nil, rec)
	return rec
end

function Session:Reset()
	local s = self:Current()
	if not s then
		FL:Print("nothing to reset.")
		return
	end
	FL.db.current = nil
	FL:Print("session discarded (%d casts, not saved to history).", s.casts or 0)
	FL:Fire("SESSION_CHANGED", "reset", nil)
end

---------------------------------------------------------------------------
-- Casts
---------------------------------------------------------------------------

local channelActive = false
local channelStartAt = 0  -- GetTime() of the last Fishing channel start
local channelStopAt = 0   -- GetTime() of the last Fishing channel end
local CHANNEL_MAX = 45    -- a Fishing channel never lasts longer; guards against a missed CHANNEL_STOP
local seenCasts = {}      -- castGUID -> true (SUCCEEDED and CHANNEL_START carry the same GUID)
local seenCount = 0
local currentCastGUID     -- GUID of the last Fishing cast; one loot record per bobber
local lastCastCountedAt = -100 -- GetTime() of the last counted cast
local CAST_DEDUPE = 2     -- seconds: SUCCEEDED and CHANNEL_START fire for the same cast with different GUIDs on Forever

local function Touch(s, now)
	s.lastActivityAt = now
	if s.state == "paused" and s.autoPaused then Session:Resume() end
end

local function OnFishingCast(castGUID, stage)
	local st = Session.stats
	if castGUID and seenCasts[castGUID] then return end
	if (GetTime() - lastCastCountedAt) < CAST_DEDUPE then
		st.lastStage = "duplicate cast event (" .. tostring(stage) .. ") ignored"
		if castGUID then currentCastGUID = castGUID end
		return
	end
	lastCastCountedAt = GetTime()
	if castGUID then
		seenCasts[castGUID] = true
		seenCount = seenCount + 1
		if seenCount > 500 then seenCasts, seenCount = {}, 0 end
		currentCastGUID = castGUID
	end
	local s = Session:Current()
	if not s then
		if not FL.settings.autoStart then return end
		s = Session:Start("auto")
	end
	local now = FL:Now()
	if s.state == "paused" then
		if s.autoPaused then Session:Resume() else return end -- a manual pause means "do not count"
	end
	if FL.Zones then FL.Zones:OnCast(s, now) end -- before Touch: a zone switch credits the old zone up to its last activity
	s.casts = (s.casts or 0) + 1
	Touch(s, now)
	if s.zone ~= nil then
		local zone = Zone()
		if zone ~= "" and zone ~= s.zones[#s.zones] then
			local known = false
			for _, z in ipairs(s.zones) do if z == zone then known = true end end
			if not known then s.zones[#s.zones + 1] = zone end
		end
	end
	st.lastStage = "cast " .. tostring(stage)
	FL:Fire("SESSION_CHANGED", "cast", s)
end

FL:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START", function(_, unit, castGUID, spellID)
	if unit ~= "player" then return end
	FL:Debug("channel start spell %s (%s)", tostring(spellID), tostring(SpellName(spellID)))
	if not Session:IsFishingSpell(spellID) then return end
	Session.stats.channelStarts = Session.stats.channelStarts + 1
	channelActive = true
	channelStartAt = GetTime()
	OnFishingCast(castGUID, "channel")
end)

FL:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP", function(_, unit, castGUID, spellID)
	if unit ~= "player" then return end
	if not Session:IsFishingSpell(spellID) then return end
	Session.stats.channelStops = Session.stats.channelStops + 1
	channelActive = false
	channelStopAt = GetTime()
end)

-- Some builds fire SUCCEEDED (at channel start) without CHANNEL_START; the GUID keeps this from double counting.
FL:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, castGUID, spellID)
	if unit ~= "player" then return end
	if not Session:IsFishingSpell(spellID) then return end
	Session.stats.succeeded = Session.stats.succeeded + 1
	channelActive = true
	channelStartAt = GetTime()
	OnFishingCast(castGUID, "succeeded")
end)

---------------------------------------------------------------------------
-- Loot
---------------------------------------------------------------------------

local lootRecordedAt = nil -- GetTime() when the open loot window was recorded (nil = not yet)
local recordedCastGUID = nil -- the cast whose bobber was already recorded

local function IsFishingLootWindow(isFromItem)
	if isFromItem then return false, "loot from an item" end
	if type(IsFishingLoot) == "function" then
		local ok, fishing = pcall(IsFishingLoot)
		if ok and fishing then return true end
	end
	local t = GetTime()
	if channelActive and (t - channelStartAt) <= CHANNEL_MAX then return true end
	if (t - channelStopAt) <= LOOT_WINDOW then return true end
	return false, "not fishing loot"
end

local SLOT_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or _G.LOOT_SLOT_ITEM or 1
local SLOT_MONEY = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or _G.LOOT_SLOT_MONEY or 2

-- Reads the open loot window into the session. Returns items recorded, copper recorded and the items of this
-- window ({ [itemID] = { n, name } }, for the zone totals).
function Session:RecordLootWindow(s)
	local n = (GetNumLootItems and GetNumLootItems()) or 0
	local items, copper = 0, 0
	local got = {}
	for i = 1, n do
		local slotType = SLOT_ITEM
		if GetLootSlotType then
			local ok, t = pcall(GetLootSlotType, i)
			if ok and t then slotType = t end
		end
		local texture, name, quantity, _, quality
		if GetLootSlotInfo then
			local ok, a, b, c, d, e = pcall(GetLootSlotInfo, i)
			if ok then texture, name, quantity, quality = a, b, c, e end
		end
		if slotType == SLOT_MONEY then
			local amount = ParseMoneyName(name)
			copper = copper + amount
		elseif slotType == SLOT_ITEM then
			local link = GetLootSlotLink and GetLootSlotLink(i) or nil
			local itemID = FL:ItemIDFromLink(link)
			if itemID then
				quantity = tonumber(quantity) or 1
				if quantity < 1 then quantity = 1 end
				local entry = s.loot[itemID]
				if not entry then
					entry = { n = 0, name = name or (link and link:match("%[(.-)%]")) or ("item " .. itemID), link = link, icon = texture, q = quality }
					s.loot[itemID] = entry
				end
				entry.n = entry.n + quantity
				if not entry.link and link then entry.link = link end
				got[itemID] = got[itemID] or { n = 0, name = entry.name }
				got[itemID].n = got[itemID].n + quantity
				items = items + quantity
				FL:Debug("loot %s x%d", tostring(link), quantity)
			end
		end
	end
	s.money = (s.money or 0) + copper
	return items, copper, got
end

local function OnLoot(event, autoLoot, isFromItem)
	local st = Session.stats
	if event == "LOOT_READY" then st.lootReady = st.lootReady + 1 else st.lootOpened = st.lootOpened + 1 end
	if lootRecordedAt and (GetTime() - lootRecordedAt) < 10 then return end -- same window, second event
	local fishing, why = IsFishingLootWindow(isFromItem)
	if fishing and currentCastGUID and recordedCastGUID == currentCastGUID and (GetTime() - channelStopAt) <= LOOT_WINDOW then
		st.lastStage = "same bobber already recorded"
		return
	end
	if not fishing then
		st.ignored = st.ignored + 1
		st.lastIgnored = why
		st.lastStage = "loot ignored: " .. tostring(why)
		return
	end
	local s = Session:Current()
	if not s then
		if not FL.settings.autoStart then return end
		s = Session:Start("auto")
	elseif s.state == "paused" and not s.autoPaused then
		st.lastStage = "loot while paused"
		return
	end
	local now = FL:Now()
	if s.state == "paused" then Session:Resume() end
	local items, copper, got = Session:RecordLootWindow(s)
	lootRecordedAt = GetTime()
	recordedCastGUID = currentCastGUID
	if items > 0 or copper > 0 then
		if FL.Zones then FL.Zones:OnCatch(s, got, copper, now) end
		s.catches = (s.catches or 0) + 1
		st.recorded = st.recorded + 1
		Touch(s, now)
		st.lastStage = string.format("recorded %d item(s) via %s", items, event)
		FL:Fire("LOOT_RECORDED", s, items, copper)
		FL:Fire("SESSION_CHANGED", "loot", s)
	else
		st.lastStage = "empty fishing loot window"
	end
end

FL:RegisterEvent("LOOT_READY", OnLoot)
FL:RegisterEvent("LOOT_OPENED", OnLoot)
FL:RegisterEvent("LOOT_CLOSED", function() lootRecordedAt = nil end)

---------------------------------------------------------------------------
-- Skill, zones, idle ticker
---------------------------------------------------------------------------

FL:RegisterEvent("SKILL_LINES_CHANGED", function()
	local s = Session:Current()
	if not s then return end
	local level = Session:FishingSkill()
	if level then
		if not s.skillStart then s.skillStart = level end
		s.skillEnd = level
		if FL.Zones then FL.Zones:OnSkill(s, level) end
	end
end)

FL:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
	local s = Session:Current()
	if not s then return end
	local zone = Zone()
	if zone ~= "" then
		local known = false
		for _, z in ipairs(s.zones or {}) do if z == zone then known = true end end
		if not known then
			s.zones = s.zones or {}
			s.zones[#s.zones + 1] = zone
		end
	end
	FL:Fire("SESSION_CHANGED", "zone", s)
end)

-- Called once a second: idle pausing and a tick for the panel timer.
function Session:Tick(now)
	now = now or FL:Now()
	local s = self:Current()
	if s and s.state == "running" then
		local idle = FL.settings.idlePause or 0
		if idle > 0 and (now - (s.lastActivityAt or now)) > idle then
			self:Pause(true)
		end
	end
	FL:Fire("TICK", now)
end

local ticker
local function StartTicker()
	if ticker or not (C_Timer and C_Timer.NewTicker) then return end
	ticker = C_Timer.NewTicker(1, function() Session:Tick() end)
end

-- A running session left over from a previous login: do not count the time away as fishing.
local function ReconcileAfterLogin()
	local s = Session:Current()
	if not s then return end
	local now = FL:Now()
	if s.state == "running" then
		local idle = FL.settings.idlePause or 0
		if idle <= 0 then idle = OFFLINE_IDLE end
		if (now - (s.lastActivityAt or now)) > idle then
			local until_ = math.min(now, (s.lastActivityAt or now) + IDLE_GRACE)
			s.active = (s.active or 0) + math.max(0, until_ - (s.resumedAt or now))
			s.state, s.resumedAt, s.autoPaused = "paused", nil, true
		end
	end
	FL:Print("session resumed from your last login: %s fishing, %d casts, %d catches%s. /fish stop to finish it.",
		FL:FormatDuration(Session:ActiveSeconds(s, now)), s.casts or 0, s.catches or 0, s.state == "paused" and " (paused)" or "")
end

FL:On("READY", function()
	ReconcileAfterLogin()
	StartTicker()
end)
FL:On("DB_ADOPTED", function() FL:Fire("SESSION_CHANGED", "adopted", Session:Current()) end)

function Session:OnLogout()
	local s = self:Current()
	if s and s.state == "running" then
		-- bank the time so a restart hours later does not count it (ReconcileAfterLogin covers the rest)
		s.active = self:ActiveSeconds(s)
		s.resumedAt = FL:Now()
	end
end

---------------------------------------------------------------------------
-- Chat output
---------------------------------------------------------------------------

function Session:PrintStatus()
	local s = self:Current()
	if not s then
		FL:Print("no session running (%d in history).", #(FL.db.history or {}))
	else
		local sum = self:Summary(s)
		FL:Print("session %s in %s: %s fishing, %d casts, %d catches (%s), %s looted%s, %s/h.",
			s.state, table.concat(s.zones or { s.zone or "?" }, ", "), FL:FormatDuration(sum.active), sum.casts, sum.catches,
			sum.catchRate and string.format("%d%%", math.floor(sum.catchRate * 100 + 0.5)) or "-",
			FL:FormatMoneyPlain(sum.value), sum.unpriced > 0 and string.format(" (%d unpriced)", sum.unpriced) or "",
			sum.gph and FL:FormatMoneyPlain(sum.gph) or "n/a")
		if s.skillStart then FL:Print("fishing skill %d -> %d.", s.skillStart, s.skillEnd or s.skillStart) end
	end
	local st = self.stats
	FL:Print("events this session: channel start %d / stop %d, succeeded %d, loot ready %d / opened %d, recorded %d, ignored %d%s. Last: %s.",
		st.channelStarts, st.channelStops, st.succeeded, st.lootReady, st.lootOpened, st.recorded, st.ignored,
		st.lastIgnored and (" (" .. st.lastIgnored .. ")") or "", st.lastStage)
end

function Session:PrintHistory(count)
	local h = FL.db.history or {}
	if #h == 0 then
		FL:Print("no finished sessions yet.")
		return
	end
	count = math.max(1, math.min(count or 10, #h))
	FL:Print("last %d session(s):", count)
	for i = #h, #h - count + 1, -1 do
		local r = h[i]
		local top = r.items and r.items[1] and (", top: " .. r.items[1].name .. " x" .. r.items[1].n) or ""
		FL:Print("  %s  %s  %s  %d casts / %d catches  %s (%s/h)%s",
			date and date("%m-%d %H:%M", r.startedAt) or tostring(r.startedAt), r.zone or "?", FL:FormatDuration(r.active or 0),
			r.casts or 0, r.catches or 0, FL:FormatMoneyPlain(r.value or 0), r.gph and FL:FormatMoneyPlain(r.gph) or "n/a", top)
	end
end
