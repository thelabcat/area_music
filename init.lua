-- area_music v2: cuboid area BGM with playlists, fade, jukebox, wand, GUI.
-- Prefers core.*; falls back to minetest.* for older engines.
-- Music lives in world/area_music/*.ogg (not bundled).

local api = rawget(_G, "core") or minetest
local MP = api.get_modpath("area_music")

area_music = {
	api = api,
	pos1 = {},
	pos2 = {},
	marker_obj = {}, -- player_name -> { pos1 = ObjectRef|nil, pos2 = ObjectRef|nil }
	areas = {},
	next_id = 1,
	known_tracks = {}, -- basename -> absolute path
	track_lengths = {}, -- basename -> seconds (filled on scan only)
	-- Per-player playback (see playback.lua)
	player_state = {},
	check_interval = tonumber(api.settings:get("area_music.check_interval")) or 1.0,
	default_gain = tonumber(api.settings:get("area_music.default_gain")) or 0.5,
	fade_duration = tonumber(api.settings:get("area_music.fade_duration")) or 2.0,
	default_track_length = tonumber(api.settings:get("area_music.default_track_length")) or 180,
}

function area_music.log(level, msg)
	api.log(level, "[area_music] " .. msg)
end

function area_music.music_dir()
	return api.get_worldpath() .. DIR_DELIM .. "area_music"
end

function area_music.areas_path()
	return api.get_worldpath() .. DIR_DELIM .. "area_music_areas.dat"
end

function area_music.ensure_music_dir()
	local dir = area_music.music_dir()
	if api.mkdir then
		api.mkdir(dir)
	else
		os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '"')
	end
	return dir
end

function area_music.has_server_priv(name)
	return api.check_player_privs(name, { server = true })
end

-- Geometry helpers (shared)
function area_music.in_cuboid(pos, pos1, pos2)
	local minp = {
		x = math.min(pos1.x, pos2.x),
		y = math.min(pos1.y, pos2.y),
		z = math.min(pos1.z, pos2.z),
	}
	local maxp = {
		x = math.max(pos1.x, pos2.x),
		y = math.max(pos1.y, pos2.y),
		z = math.max(pos1.z, pos2.z),
	}
	return pos.x >= minp.x and pos.x <= maxp.x
		and pos.y >= minp.y and pos.y <= maxp.y
		and pos.z >= minp.z and pos.z <= maxp.z
end

function area_music.cuboid_volume(pos1, pos2)
	return (math.abs(pos1.x - pos2.x) + 1)
		* (math.abs(pos1.y - pos2.y) + 1)
		* (math.abs(pos1.z - pos2.z) + 1)
end

function area_music.normalize_corners(pos1, pos2)
	return {
		x = math.min(pos1.x, pos2.x),
		y = math.min(pos1.y, pos2.y),
		z = math.min(pos1.z, pos2.z),
	}, {
		x = math.max(pos1.x, pos2.x),
		y = math.max(pos1.y, pos2.y),
		z = math.max(pos1.z, pos2.z),
	}
end

--- Prefer highest priority; on ties, prefer smaller volume.
function area_music.find_area_at(pos)
	local best, best_vol
	for _, area in ipairs(area_music.areas) do
		if area_music.in_cuboid(pos, area.pos1, area.pos2) then
			local vol = area_music.cuboid_volume(area.pos1, area.pos2)
			local pri = area.priority or 0
			if not best
				or pri > (best.priority or 0)
				or (pri == (best.priority or 0) and vol < best_vol)
			then
				best = area
				best_vol = vol
			end
		end
	end
	return best
end

function area_music.get_area_by_key(key)
	local id = tonumber(key)
	for _, a in ipairs(area_music.areas) do
		if (id and a.id == id) or a.name == key then
			return a
		end
	end
	return nil
end

function area_music.corners_match_existing(pos1, pos2)
	local n1a, n1b = area_music.normalize_corners(pos1, pos2)
	for _, a in ipairs(area_music.areas) do
		local n2a, n2b = area_music.normalize_corners(a.pos1, a.pos2)
		if n1a.x == n2a.x and n1a.y == n2a.y and n1a.z == n2a.z
			and n1b.x == n2b.x and n1b.y == n2b.y and n1b.z == n2b.z
		then
			return a
		end
	end
	return nil
end

-- Load modules (order matters: storage/media before playback/gui)
dofile(MP .. DIR_DELIM .. "storage.lua")
dofile(MP .. DIR_DELIM .. "duration.lua")
dofile(MP .. DIR_DELIM .. "media.lua")
dofile(MP .. DIR_DELIM .. "markers.lua")
dofile(MP .. DIR_DELIM .. "playback.lua")
dofile(MP .. DIR_DELIM .. "jukebox.lua")
dofile(MP .. DIR_DELIM .. "wand.lua")
dofile(MP .. DIR_DELIM .. "gui.lua")
dofile(MP .. DIR_DELIM .. "commands.lua")

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

area_music.ensure_music_dir()
area_music.load()
area_music.scan_tracks()

local accum = 0
api.register_globalstep(function(dtime)
	accum = accum + dtime
	if accum < area_music.check_interval then
		return
	end
	accum = 0
	for _, player in ipairs(api.get_connected_players()) do
		area_music.update_player(player)
	end
end)

api.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	-- Do not wait solely on media: spawn-in-area must start even if push is slow.
	api.after(0.25, function()
		local p = api.get_player_by_name(name)
		if p then
			area_music.reenter_player(p)
		end
	end)
	area_music.push_media_to_player(name, function()
		api.after(0.4, function()
			local p = api.get_player_by_name(name)
			if p then
				-- Media just arrived: treat as a fresh enter so playback can actually start
				area_music.reenter_player(p)
			end
		end)
	end)
end)

api.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	area_music.invalidate_player(name)
	area_music.unmark(name)
end)

area_music.log("action", "v2 loaded. Put .ogg files in " .. area_music.music_dir())
