-- Persistence + v1 -> v2 area migration

local api = area_music.api

function area_music.sync_playlist_mode(pl)
	if type(pl) ~= "table" then
		return
	end
	pl.tracks = pl.tracks or {}
	if #pl.tracks <= 1 then
		pl.mode = "loop"
	else
		pl.mode = "shuffle"
	end
	-- Per-jukebox fade-in; default OFF so existing areas keep full-volume starts
	pl.fade_in = pl.fade_in == true
end

local function migrate_area(a)
	if type(a) ~= "table" then
		return a
	end
	-- Ensure playlist shape
	if type(a.playlist) ~= "table" then
		a.playlist = { tracks = {}, mode = "loop", gap = 0, fade_in = false }
	end
	a.playlist.tracks = a.playlist.tracks or {}
	a.playlist.gap = tonumber(a.playlist.gap) or 0
	a.playlist.fade_in = a.playlist.fade_in == true
	if a.playlist.gap < 0 then
		a.playlist.gap = 0
	end

	-- Migrate legacy .track into playlist
	if a.track and a.track ~= "" then
		local found = false
		for _, t in ipairs(a.playlist.tracks) do
			if t == a.track then
				found = true
				break
			end
		end
		if not found then
			-- Put legacy track first for loop-one behavior
			table.insert(a.playlist.tracks, 1, a.track)
		end
		a.track = nil
	end

	area_music.sync_playlist_mode(a.playlist)

	a.priority = a.priority or 0
	a.gain = a.gain or area_music.default_gain
	a.jukebox_pos = a.jukebox_pos -- may be nil; keep as-is (table or nil)
	if a.jukebox_pos and type(a.jukebox_pos) == "table" then
		-- Ensure plain vector table
		a.jukebox_pos = {
			x = tonumber(a.jukebox_pos.x) or 0,
			y = tonumber(a.jukebox_pos.y) or 0,
			z = tonumber(a.jukebox_pos.z) or 0,
		}
	else
		a.jukebox_pos = nil
	end

	if a.pos1 then
		a.pos1 = { x = a.pos1.x, y = a.pos1.y, z = a.pos1.z }
	end
	if a.pos2 then
		a.pos2 = { x = a.pos2.x, y = a.pos2.y, z = a.pos2.z }
	end
	return a
end

function area_music.save()
	local data = {
		version = 2,
		areas = area_music.areas,
		next_id = area_music.next_id,
	}
	local ok = api.safe_file_write(area_music.areas_path(), api.serialize(data))
	if not ok then
		area_music.log("error", "Failed to save areas")
	end
	return ok
end

function area_music.load()
	local f = io.open(area_music.areas_path(), "r")
	if not f then
		return false
	end
	local content = f:read("*all")
	f:close()
	if not content or content == "" then
		return false
	end
	local ok, data = pcall(api.deserialize, content)
	if not ok or type(data) ~= "table" then
		area_music.log("error", "Failed to deserialize areas file")
		return false
	end
	local areas = data.areas or {}
	for i, a in ipairs(areas) do
		areas[i] = migrate_area(a)
	end
	area_music.areas = areas
	area_music.next_id = data.next_id or 1
	-- Persist playlist migration / cleanup
	if (data.version or 1) < 2 then
		area_music.save()
		area_music.log("action", "Migrated areas file to v2 playlist format")
	end
	area_music.log("action", "Loaded " .. #area_music.areas .. " area(s)")
	return true
end

--- Create area without a track (playlist empty until jukebox/GUI edits).
function area_music.add_area(name, priority, pos1, pos2)
	if not name or not pos1 or not pos2 then
		return false, "name, pos1, and pos2 are required"
	end
	for _, a in ipairs(area_music.areas) do
		if a.name == name then
			return false, "Area name already exists: " .. name
		end
	end
	local dup = area_music.corners_match_existing(pos1, pos2)
	if dup then
		return false, "An area with the same corners already exists: " .. dup.name
	end
	local id = area_music.next_id
	area_music.next_id = id + 1
	area_music.areas[#area_music.areas + 1] = {
		id = id,
		name = name,
		gain = area_music.default_gain,
		priority = priority or 0,
		pos1 = vector.copy(pos1),
		pos2 = vector.copy(pos2),
		playlist = {
			tracks = {},
			mode = "loop",
			gap = 0,
			fade_in = false,
		},
		jukebox_pos = nil,
	}
	area_music.save()
	if area_music.refresh_jukeboxes then
		area_music.refresh_jukeboxes()
	end
	return true, ("Area '%s' (id %d) created — configure playlist via jukebox"):format(name, id)
end

function area_music.remove_area(key)
	for i, a in ipairs(area_music.areas) do
		local id = tonumber(key)
		if (id and a.id == id) or a.name == key then
			-- Clear jukebox node if linked
			if a.jukebox_pos and area_music.on_area_removed then
				area_music.on_area_removed(a)
			end
			table.remove(area_music.areas, i)
			area_music.save()
			-- Force playback re-eval
			for _, player in ipairs(api.get_connected_players()) do
				area_music.update_player(player)
			end
			return true, ("Removed area '%s' (id %d)"):format(a.name, a.id)
		end
	end
	return false, "Area not found: " .. tostring(key)
end

function area_music.set_priority(key, priority)
	local a = area_music.get_area_by_key(key)
	if not a then
		return false, "Area not found: " .. tostring(key)
	end
	a.priority = tonumber(priority) or 0
	area_music.save()
	return true, ("Area '%s' priority = %d"):format(a.name, a.priority)
end
