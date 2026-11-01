-- FishLog :: Zones
-- Per-zone fishing statistics. A running session splits its numbers by zone (s.byZone) as you fish; when the
-- session finishes, its buckets are folded into the lifetime totals at FL.db.zones, which are not capped like
-- the session history. The zone window (ZonesUI.lua) shows db.zones plus the running session.
--
-- A bucket (session side and lifetime side share the shape):
--   { active = <seconds fishing in the zone>, casts, catches, money = <copper looted as coin>,
--     loot = { [itemID] = { n = <quantity>, c = <catches that contained it>, name } },
--     subzones = { [subzone] = <catches> }, skillMin, skillMax }
-- Lifetime buckets also carry: sessions, first, last (epoch), bestGph (copper/h of the best session in the zone,
-- valued when that session ended), partial (sessions rebuilt from old history records: top 15 items only).
--
-- Time: the session's active time is credited to the zone of the current cast (s.zoneCur). s.zoneMark is the
-- session's active seconds when that zone started. On a cast in a new zone the old zone is credited up to its
-- last cast or catch plus a short grace, so travel between zones counts for neither.

local _, FL = ...
local Zones = {}
FL.Zones = Zones

local SWITCH_GRACE = 20     -- seconds credited to the old zone after its last activity
local BEST_MIN_ACTIVE = 600 -- a session counts for "best session" in a zone after 10 minutes there

-- Sessions folded this login, by startedAt: merged into a saved file that arrives late (see Core AdoptDB).
Zones.foldedThisLogin = {}

---------------------------------------------------------------------------
-- Buckets
---------------------------------------------------------------------------

local function NewBucket()
	return { active = 0, casts = 0, catches = 0, money = 0, loot = {}, subzones = {} }
end

local function CurrentZone()
	local zone = (GetZoneText and GetZoneText()) or ""
	if zone == "" then zone = (GetRealZoneText and GetRealZoneText()) or "" end
	local sub = (GetSubZoneText and GetSubZoneText()) or ""
	return zone, sub
end

local function AddSkill(b, level)
	if type(level) ~= "number" then return end
	if not b.skillMin or level < b.skillMin then b.skillMin = level end
	if not b.skillMax or level > b.skillMax then b.skillMax = level end
end

-- Adds bucket src into dst (both bucket-shaped).
local function AddBucket(dst, src)
	dst.active = (dst.active or 0) + (src.active or 0)
	dst.casts = (dst.casts or 0) + (src.casts or 0)
	dst.catches = (dst.catches or 0) + (src.catches or 0)
	dst.money = (dst.money or 0) + (src.money or 0)
	dst.loot = dst.loot or {}
	for id, e in pairs(src.loot or {}) do
		local d = dst.loot[id]
		if not d then
			d = { n = 0, c = 0, name = e.name }
			dst.loot[id] = d
		end
		d.n = d.n + (e.n or 0)
		d.c = d.c + (e.c or e.n or 0)
		if not d.name then d.name = e.name end
	end
	dst.subzones = dst.subzones or {}
	for sub, n in pairs(src.subzones or {}) do dst.subzones[sub] = (dst.subzones[sub] or 0) + n end
	AddSkill(dst, src.skillMin)
	AddSkill(dst, src.skillMax)
end
Zones.AddBucket = AddBucket

-- Copper value of a bucket at current prices, plus the number of item kinds with no known price.
function Zones:Value(b)
	local value, unpriced = b.money or 0, 0
	for id, e in pairs(b.loot or {}) do
		local unit = FL.Prices:GetValue(id)
		if unit then value = value + unit * (e.n or 0) else unpriced = unpriced + 1 end
	end
	return value, unpriced
end

---------------------------------------------------------------------------
-- Session side
---------------------------------------------------------------------------

-- Makes sure a session has per-zone buckets. A session from before this feature (or from an old saved file)
-- gets one bucket for its start zone holding everything it has so far.
function Zones:Ensure(s)
	if s.byZone then return end
	s.byZone = {}
	local zone = (s.zone and s.zone ~= "") and s.zone or "Unknown"
	local b = NewBucket()
	b.casts, b.catches, b.money = s.casts or 0, s.catches or 0, s.money or 0
	for id, e in pairs(s.loot or {}) do b.loot[id] = { n = e.n or 0, c = e.n or 0, name = e.name } end
	if s.subzone and s.subzone ~= "" and b.catches > 0 then b.subzones[s.subzone] = b.catches end
	AddSkill(b, s.skillStart)
	AddSkill(b, s.skillEnd)
	s.byZone[zone] = b
	s.zoneCur = zone
	s.zoneMark = 0 -- all active time so far belongs to the start zone
end

-- Called for a new session.
function Zones:Init(s)
	s.byZone = {}
	local zone = (s.zone and s.zone ~= "") and s.zone or "Unknown"
	s.byZone[zone] = NewBucket()
	AddSkill(s.byZone[zone], s.skillStart)
	s.zoneCur = zone
	s.zoneMark = 0
end

-- Credits the session's active time since s.zoneMark to the current zone. switching = the player moved on:
-- only credit up to the last activity plus a grace, the rest is travel.
local function Bank(s, now, switching)
	local b = s.byZone[s.zoneCur]
	if not b then
		b = NewBucket()
		s.byZone[s.zoneCur] = b
	end
	local S = FL.Session
	local untilT = now
	if switching and s.state == "running" and s.resumedAt then
		untilT = math.max(s.resumedAt, math.min(now, (s.lastActivityAt or now) + SWITCH_GRACE))
	end
	b.active = (b.active or 0) + math.max(0, S:ActiveSeconds(s, untilT) - (s.zoneMark or 0))
	s.zoneMark = S:ActiveSeconds(s, now)
	return b
end

-- Active seconds of a zone in a running session, including the part not banked yet.
function Zones:SessionZoneActive(s, zone, now)
	local b = s.byZone and s.byZone[zone]
	local active = b and b.active or 0
	if zone == s.zoneCur then
		active = active + math.max(0, FL.Session:ActiveSeconds(s, now) - (s.zoneMark or 0))
	end
	return active
end

-- The bucket for the zone the player is in now; banks the previous zone when it changed.
local function ZoneBucket(s, now)
	Zones:Ensure(s)
	local zone = CurrentZone()
	if zone == "" then zone = s.zoneCur end
	if zone ~= s.zoneCur then
		Bank(s, now, true)
		s.zoneCur = zone
	end
	local b = s.byZone[zone]
	if not b then
		b = NewBucket()
		s.byZone[zone] = b
	end
	return b
end

-- A counted cast. Runs before the session's lastActivityAt moves to now.
function Zones:OnCast(s, now)
	local b = ZoneBucket(s, now)
	b.casts = (b.casts or 0) + 1
end

-- A skill-up: widens the skill range of the zone being fished.
function Zones:OnSkill(s, level)
	self:Ensure(s)
	local b = s.byZone[s.zoneCur]
	if b then AddSkill(b, level) end
end

-- A recorded catch. got = { [itemID] = { n, name } } from the loot window.
function Zones:OnCatch(s, got, copper, now)
	local b = ZoneBucket(s, now)
	b.catches = (b.catches or 0) + 1
	b.money = (b.money or 0) + (copper or 0)
	for id, e in pairs(got or {}) do
		local d = b.loot[id]
		if not d then
			d = { n = 0, c = 0, name = e.name }
			b.loot[id] = d
		end
		d.n = d.n + (e.n or 0)
		d.c = d.c + 1
	end
	local _, sub = CurrentZone()
	if sub and sub ~= "" then b.subzones[sub] = (b.subzones[sub] or 0) + 1 end
	AddSkill(b, FL.Session:FishingSkill())
end

---------------------------------------------------------------------------
-- Lifetime totals
---------------------------------------------------------------------------

-- A lifetime bucket rebuilt from a finished-session history record (records keep the top 15 items only).
local function BucketFromRecord(rec)
	local b = NewBucket()
	b.active, b.casts, b.catches, b.money = rec.active or 0, rec.casts or 0, rec.catches or 0, rec.money or 0
	for _, it in ipairs(rec.items or {}) do
		if it.id then b.loot[it.id] = { n = it.n or 0, c = it.n or 0, name = it.name } end
	end
	if rec.subzone and rec.subzone ~= "" and b.catches > 0 then b.subzones[rec.subzone] = b.catches end
	AddSkill(b, rec.skillStart)
	AddSkill(b, rec.skillEnd)
	return b
end

local function LifetimeBucket(db, zone)
	local z = db.zones[zone]
	if not z then
		z = NewBucket()
		z.sessions = 0
		db.zones[zone] = z
	end
	return z
end

local function FoldBucket(db, zone, b, startedAt, endedAt, value, partial)
	if (b.casts or 0) == 0 and (b.catches or 0) == 0 then return end
	local z = LifetimeBucket(db, zone)
	AddBucket(z, b)
	z.sessions = (z.sessions or 0) + 1
	if partial then z.partial = (z.partial or 0) + 1 end
	if startedAt and (not z.first or startedAt < z.first) then z.first = startedAt end
	local last = endedAt or startedAt
	if last and (not z.last or last > z.last) then z.last = last end
	if value and (b.active or 0) >= BEST_MIN_ACTIVE then
		local gph = value / b.active * 3600
		if not z.bestGph or gph > z.bestGph then
			z.bestGph = gph
			z.bestAt = startedAt
		end
	end
end

-- Builds db.zones from the history when the saved data predates zone tracking.
function Zones:EnsureDB(db)
	if type(db.zones) == "table" then return end
	db.zones = {}
	for _, rec in ipairs(db.history or {}) do
		local zone = (rec.zone and rec.zone ~= "") and rec.zone or "Unknown"
		FoldBucket(db, zone, BucketFromRecord(rec), rec.startedAt, rec.endedAt, rec.value, true)
	end
end

-- Closes a finished session's zone buckets into db.zones. Called once per session, after Session:Finish.
function Zones:Fold(db, s, now)
	if not (db and s) then return end
	now = now or FL:Now()
	self:EnsureDB(db)
	self:Ensure(s)
	Bank(s, now, false)
	for zone, b in pairs(s.byZone) do
		local value = self:Value(b)
		FoldBucket(db, zone, b, s.startedAt, now, value, false)
	end
	if db == FL.db and s.startedAt then
		self.foldedThisLogin[s.startedAt] = { byZone = s.byZone, endedAt = now }
	end
end

-- Core's AdoptDB calls this before merging the history: loaded = the table the client handed back.
-- Rebuilds its totals when it has none, then adds the sessions this login finished that the file lacks.
function Zones:PrepareAdopt(loaded)
	local seen = {}
	for _, rec in ipairs(loaded.history or {}) do seen[rec.startedAt or 0] = true end
	self:EnsureDB(loaded)
	for startedAt, f in pairs(self.foldedThisLogin) do
		if not seen[startedAt] then
			for zone, b in pairs(f.byZone) do
				FoldBucket(loaded, zone, b, startedAt, f.endedAt, self:Value(b), false)
			end
		end
	end
end

---------------------------------------------------------------------------
-- View model for the zone window
---------------------------------------------------------------------------

-- Every zone with its numbers: db.zones plus the running session. Returns a list of entries:
--   { name, active, casts, catches, money, loot, subzones, sessions, first, last, bestGph, bestAt, skillMin,
--     skillMax, partial, live (the session is fishing here now), value, unpriced, gph, catchRate, catchesPerHour,
--     perCatch }
function Zones:Collect(now)
	now = now or FL:Now()
	local byName = {}
	local zonesSource = FL.db.zones or {}
	if self.demo then zonesSource = self:DemoZones(now) end
	for zone, z in pairs(zonesSource) do
		local e = { name = zone, sessions = z.sessions or 0, first = z.first, last = z.last, bestGph = z.bestGph,
			bestAt = z.bestAt, partial = z.partial }
		AddBucket(e, z)
		byName[zone] = e
	end
	local s = not self.demo and FL.Session:Current() or nil
	if s then
		self:Ensure(s)
		for zone, b in pairs(s.byZone) do
			if (b.casts or 0) > 0 or (b.catches or 0) > 0 or zone == s.zoneCur then
				local e = byName[zone]
				if not e then
					e = { name = zone, sessions = 0 }
					byName[zone] = e
				end
				local live = { casts = b.casts, catches = b.catches, money = b.money, loot = b.loot, subzones = b.subzones,
					skillMin = b.skillMin, skillMax = b.skillMax, active = self:SessionZoneActive(s, zone, now) }
				AddBucket(e, live)
				e.sessions = e.sessions + 1
				if not e.first or s.startedAt < e.first then e.first = s.startedAt end
				e.last = now
				e.inSession = true
				if zone == s.zoneCur and s.state == "running" then e.live = true end
			end
		end
	end
	local list = {}
	for _, e in pairs(byName) do
		if self.demo and e.name == "The Barrens" then e.live = true end
		e.value, e.unpriced = self:Value(e)
		e.gph = (e.active or 0) >= 60 and (e.value / e.active * 3600) or nil
		e.catchRate = (e.casts or 0) > 0 and e.catches / e.casts or nil
		e.catchesPerHour = (e.active or 0) >= 60 and (e.catches / e.active * 3600) or nil
		e.perCatch = (e.catches or 0) > 0 and e.value / e.catches or nil
		list[#list + 1] = e
	end
	return list
end

local SORTS = {
	gph = function(a, b)
		local ga, gb = a.gph or -1, b.gph or -1
		if ga ~= gb then return ga > gb end
		return a.name < b.name
	end,
	time = function(a, b)
		if (a.active or 0) ~= (b.active or 0) then return (a.active or 0) > (b.active or 0) end
		return a.name < b.name
	end,
	name = function(a, b) return a.name < b.name end,
	last = function(a, b)
		if (a.last or 0) ~= (b.last or 0) then return (a.last or 0) > (b.last or 0) end
		return a.name < b.name
	end,
}
Zones.SORT_KEYS = { "gph", "time", "name", "last" }

function Zones:Sorted(key, now)
	local list = self:Collect(now)
	table.sort(list, SORTS[key] or SORTS.gph)
	return list
end

-- Items of a zone entry sorted by total value, then quantity. Item data comes from C_Item when cached.
function Zones:SortedLoot(e)
	local list = {}
	for id, it in pairs(e.loot or {}) do
		local unit, kind = FL.Prices:GetValue(id)
		local name, link, quality, icon = it.name, nil, nil, nil
		if C_Item and C_Item.GetItemInfo then
			local ok, n, l, q, _, _, _, _, _, _, tex = pcall(C_Item.GetItemInfo, id)
			if ok and n then name, link, quality, icon = n, l, q, tex end
		end
		if not icon and C_Item and C_Item.GetItemIconByID then
			local ok, tex = pcall(C_Item.GetItemIconByID, id)
			if ok then icon = tex end
		end
		list[#list + 1] = { itemID = id, n = it.n or 0, c = it.c or it.n or 0, name = name or ("item " .. id), link = link,
			q = quality, icon = icon, unit = unit, kind = kind, total = unit and unit * (it.n or 0) or nil,
			dropRate = (e.catches or 0) > 0 and math.min(1, (it.c or it.n or 0) / e.catches) or nil }
	end
	table.sort(list, function(a, b)
		local ta, tb = a.total or -1, b.total or -1
		if ta ~= tb then return ta > tb end
		if a.n ~= b.n then return a.n > b.n end
		return a.name < b.name
	end)
	return list
end

-- Subzones of a zone entry by catches, most first: { { name, n }, ... }
function Zones:TopSubzones(e, count)
	local list = {}
	for sub, n in pairs(e.subzones or {}) do list[#list + 1] = { name = sub, n = n } end
	table.sort(list, function(a, b)
		if a.n ~= b.n then return a.n > b.n end
		return a.name < b.name
	end)
	while count and #list > count do table.remove(list) end
	return list
end

-- Removes a zone's lifetime totals (the running session's part stays until it finishes).
function Zones:Forget(zone)
	if FL.db.zones and FL.db.zones[zone] then
		FL.db.zones[zone] = nil
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- Demo data (/fish zones demo): made-up zones to preview the window. Kept in memory only, never saved and never
-- merged with db.zones. Real item IDs, so names, icons and prices come from the client.
---------------------------------------------------------------------------

local DEMO = {
	-- zone, hours, casts, catches, coin, skill min/max, sessions, days ago, best gph (copper), items { id, n, c }, subzones
	{ "Durotar", 1.6, 610, 402, 1250, 1, 75, 4, 9, 9500, { { 6291, 190, 180 }, { 6303, 168, 160 }, { 6289, 22, 20 }, { 6352, 3, 3 }, { 6351, 2, 2 } }, { ["Razor Hill"] = 150, ["Sen'jin Village"] = 140, ["Echo Isles"] = 112 } },
	{ "Orgrimmar", 0.4, 140, 88, 0, 20, 40, 1, 12, nil, { { 6291, 50, 48 }, { 6303, 40, 40 } }, { ["Valley of Strength"] = 88 } },
	{ "The Barrens", 3.2, 1180, 845, 8420, 60, 150, 7, 0, 21800, { { 6289, 260, 240 }, { 6308, 150, 140 }, { 6358, 180, 170 }, { 6522, 95, 90 }, { 6359, 70, 66 }, { 6352, 12, 12 }, { 6353, 6, 6 }, { 6351, 8, 8 } }, { ["The Crossroads"] = 300, ["Ratchet"] = 420, ["Lushwater Oasis"] = 125 } },
	{ "Ashenvale", 1.1, 420, 310, 3100, 130, 175, 2, 3, 26500, { { 6358, 120, 115 }, { 6359, 88, 84 }, { 6361, 40, 38 }, { 6362, 30, 29 }, { 6353, 4, 4 } }, { ["Mystral Lake"] = 180, ["Falfarren River"] = 130 } },
	{ "Stonetalon Mountains", 0.7, 250, 176, 900, 120, 140, 1, 5, 14200, { { 6358, 70, 66 }, { 6308, 60, 58 }, { 6359, 30, 30 } }, { ["Mirkfallon Lake"] = 176 } },
	{ "Hillsbrad Foothills", 2.4, 900, 655, 6200, 150, 205, 5, 1, 31800, { { 6362, 210, 200 }, { 6361, 160, 150 }, { 6359, 110, 105 }, { 6358, 90, 85 }, { 6317, 40, 40 }, { 6354, 5, 5 } }, { ["Southshore"] = 330, ["Tarren Mill"] = 205, ["Durnholde Keep"] = 120 } },
	{ "Stranglethorn Vale", 4.8, 1820, 1340, 21500, 205, 300, 9, 0.2, 48600, { { 4603, 520, 500 }, { 6362, 190, 180 }, { 13422, 110, 105 }, { 13758, 140, 130 }, { 8365, 90, 85 }, { 13754, 60, 58 }, { 21071, 70, 66 }, { 6361, 55, 50 }, { 7974, 30, 12 }, { 6353, 10, 10 }, { 6354, 8, 8 }, { 6352, 14, 14 }, { 6351, 6, 6 } }, { ["Booty Bay"] = 610, ["Grom'gol Base Camp"] = 380, ["Nesingwary's Expedition"] = 350 } },
	{ "Tanaris", 1.9, 720, 540, 9800, 255, 300, 3, 6, 52300, { { 13422, 150, 145 }, { 13758, 120, 115 }, { 13754, 90, 88 }, { 8365, 70, 66 }, { 6354, 6, 6 } }, { ["Steamwheedle Port"] = 320, ["Lost Rigger Cove"] = 220 } },
	{ "Feralas", 0.9, 330, 250, 2900, 240, 260, 2, 14, 38800, { { 13758, 90, 85 }, { 13754, 70, 66 }, { 8365, 55, 52 }, { 21071, 25, 24 } }, { ["Feathermoon Stronghold"] = 140, ["Camp Mojache"] = 110 } },
	{ "Desolace", 0.5, 190, 120, 700, 180, 190, 1, 21, nil, { { 6362, 50, 48 }, { 6361, 40, 38 }, { 21071, 20, 20 } }, { ["Shadowprey Village"] = 120 } },
	{ "Dustwallow Marsh", 1.3, 480, 360, 4100, 200, 230, 2, 30, 33700, { { 6362, 110, 105 }, { 4603, 120, 115 }, { 6359, 50, 48 }, { 6353, 5, 5 } }, { ["Brackenwall Village"] = 200, ["Theramore Isle"] = 160 } },
	{ "Thousand Needles", 0.3, 100, 70, 300, 175, 180, 1, 40, nil, { { 6362, 30, 30 }, { 6361, 25, 25 } }, { ["Freewind Post"] = 70 } },
}

function Zones:DemoZones(now)
	now = now or FL:Now()
	local out = {}
	for _, d in ipairs(DEMO) do
		local b = NewBucket()
		b.active = math.floor(d[2] * 3600)
		b.casts, b.catches, b.money = d[3], d[4], d[5]
		b.skillMin, b.skillMax = d[6], d[7]
		b.sessions = d[8]
		b.last = now - math.floor(d[9] * 86400)
		b.first = b.last - d[8] * 86400
		b.bestGph = d[10]
		b.bestAt = d[10] and b.last or nil
		for _, it in ipairs(d[11]) do b.loot[it[1]] = { n = it[2], c = it[3] } end
		for sub, n in pairs(d[12]) do b.subzones[sub] = n end
		if d[1] == "Desolace" then b.partial = 1 end
		out[d[1]] = b
	end
	return out
end
