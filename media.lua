-- World-folder .ogg scan + dynamic_add_media push

local api = area_music.api

-- Luanti media names may only use: a-z A-Z 0-9 _ . -
-- Spaces and other characters are an engine limit (dynamic_add_media / sound_play),
-- not a formspec quirk — files with invalid names are never registered.
local MEDIA_NAME_OK = "^[A-Za-z0-9_.%-]+$"

function area_music.is_valid_track_name(name)
	return type(name) == "string" and name ~= "" and name:match(MEDIA_NAME_OK) ~= nil
end

local function list_ogg_files(dir)
	local files = {}
	local skipped = {}
	local names
	if api.get_dir_list then
		names = api.get_dir_list(dir, false) or {}
	else
		names = {}
		local p = io.popen('ls -1 "' .. dir:gsub('"', '\\"') .. '" 2>/dev/null')
		if p then
			for line in p:lines() do
				names[#names + 1] = line
			end
			p:close()
		end
	end
	for _, fname in ipairs(names) do
		local base = fname:match("^(.*)%.[Oo][Gg][Gg]$")
		if base then
			if not area_music.is_valid_track_name(base) then
				skipped[#skipped + 1] = fname
				area_music.log("warning",
					"Skipping '" .. fname
					.. "': Luanti media names may only use a-z, A-Z, 0-9, _, ., - "
					.. "(no spaces). Rename the file and /am_reload.")
			else
				files[#files + 1] = {
					path = dir .. DIR_DELIM .. fname,
					name = base,
				}
			end
		end
	end
	table.sort(files, function(a, b) return a.name < b.name end)
	return files, skipped
end

function area_music.scan_tracks()
	local dir = area_music.ensure_music_dir()
	area_music.known_tracks = {}
	area_music.track_lengths = {}
	local files, skipped = list_ogg_files(dir)
	for _, f in ipairs(files) do
		area_music.known_tracks[f.name] = f.path
		-- Measure once per refresh; never again at play time
		local dur = area_music.measure_track_duration(f.name, f.path)
		area_music.track_lengths[f.name] = dur
	end
	area_music.save_track_lengths()
	local msg = "Found " .. #files .. " track(s) in " .. dir .. " (durations cached)"
	if skipped and #skipped > 0 then
		msg = msg .. "; skipped " .. #skipped .. " invalid filename(s)"
	end
	area_music.log("action", msg)
	return files
end

--- Drop playlist entries whose files are gone (or were never valid media names).
--- Logs one notice per removal. Returns prune count.
function area_music.prune_missing_playlist_tracks()
	local known = area_music.known_tracks or {}
	local pruned = 0
	local dirty_areas = {}
	for _, area in ipairs(area_music.areas or {}) do
		local pl = area.playlist
		if type(pl) == "table" and type(pl.tracks) == "table" then
			local kept = {}
			local changed = false
			for _, track in ipairs(pl.tracks) do
				if known[track] then
					kept[#kept + 1] = track
				else
					pruned = pruned + 1
					changed = true
					local where = ("area '%s' (id %d)"):format(
						tostring(area.name), tonumber(area.id) or -1)
					if area.jukebox_pos then
						where = where .. (" jukebox @ %s"):format(
							api.pos_to_string(area.jukebox_pos))
					end
					area_music.log("info",
						"Pruned missing track '" .. tostring(track)
						.. "' from " .. where)
				end
			end
			if changed then
				pl.tracks = kept
				if area_music.sync_playlist_mode then
					area_music.sync_playlist_mode(pl)
				end
				dirty_areas[#dirty_areas + 1] = area
			end
		end
	end
	if pruned > 0 then
		area_music.save()
		if area_music.reenter_players_in_area then
			for _, area in ipairs(dirty_areas) do
				area_music.reenter_players_in_area(area)
			end
		end
		area_music.log("action",
			("Pruned %d missing playlist track entry(ies)"):format(pruned))
	end
	return pruned
end

function area_music.list_track_names()
	local tracks = {}
	for t, _ in pairs(area_music.known_tracks) do
		tracks[#tracks + 1] = t
	end
	table.sort(tracks)
	return tracks
end

--- Push one file with modern options-table API, else legacy filepath string.
local function dynamic_add_one(filepath, player_name, callback)
	if not api.dynamic_add_media then
		area_music.log("error", "dynamic_add_media is unavailable on this engine")
		return false
	end

	local cb = callback or function() end

	local opts = {
		filepath = filepath,
		ephemeral = false,
	}
	if player_name then
		opts.to_player = player_name
	end

	local ok_call, ok_ret = pcall(api.dynamic_add_media, opts, cb)
	if ok_call and ok_ret then
		return true
	end

	ok_call, ok_ret = pcall(api.dynamic_add_media, filepath, cb)
	if ok_call and ok_ret then
		return true
	end

	area_music.log("error", "dynamic_add_media failed for " .. filepath
		.. (ok_call and "" or (" (" .. tostring(ok_ret) .. ")")))
	return false
end

function area_music.push_media_to_player(player_name, callback)
	-- Do not remeasure durations here — only push already-scanned paths.
	if not next(area_music.known_tracks or {}) then
		area_music.scan_tracks()
	end
	local files = {}
	for name, path in pairs(area_music.known_tracks) do
		files[#files + 1] = { name = name, path = path }
	end
	table.sort(files, function(a, b) return a.name < b.name end)
	if #files == 0 then
		if callback then callback() end
		return
	end

	local remaining = #files
	local function one_done()
		remaining = remaining - 1
		if remaining <= 0 and callback then
			callback()
		end
	end

	for _, f in ipairs(files) do
		local accepted = dynamic_add_one(f.path, player_name, function(_name)
			one_done()
		end)
		if not accepted then
			one_done()
		end
	end
end
