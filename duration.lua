-- Ogg Vorbis duration: last-page granule position / identification-header sample rate, plus optional ffprobe.
-- Lengths are computed only during track-list refresh (scan_tracks), never per-play.

local api = area_music.api

area_music.track_lengths = area_music.track_lengths or {} -- basename -> seconds (number)

local function lengths_path()
	return api.get_worldpath() .. DIR_DELIM .. "area_music_track_lengths.dat"
end

local function u32le_str(s, i)
	-- little-endian uint32 from string at 1-based index i
	local b1, b2, b3, b4 = s:byte(i, i + 3)
	if not b4 then
		return nil
	end
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function u64le_str(s, i)
	local lo = u32le_str(s, i)
	local hi = u32le_str(s, i + 4)
	if not lo or not hi then
		return nil
	end
	return hi * 4294967296.0 + lo
end

--- Parse Ogg Vorbis duration from filepath. Returns seconds or nil, err.
function area_music.parse_ogg_duration(path)
	local f = io.open(path, "rb")
	if not f then
		return nil, "open failed"
	end

	local head = f:read(16384) or ""
	local vorbis_pos = head:find("vorbis", 1, true)
	if not vorbis_pos then
		f:close()
		return nil, "no vorbis header"
	end
	-- After "vorbis" (6) + version (4) + channels (1) => sample rate at vorbis_pos+11
	local rate = u32le_str(head, vorbis_pos + 11)
	if not rate or rate < 1000 or rate > 384000 then
		f:close()
		return nil, "bad sample rate"
	end

	local size = f:seek("end")
	if not size or size < 27 then
		f:close()
		return nil, "file too small"
	end

	local tail_len = math.min(65536, size)
	f:seek("set", size - tail_len)
	local tail = f:read(tail_len) or ""
	f:close()

	local last_granule = nil
	local search = 1
	while true do
		local i = tail:find("OggS", search, true)
		if not i then
			break
		end
		if i + 13 <= #tail then
			local granule = u64le_str(tail, i + 6)
			-- granule -1 (all 0xFF) means no packet end; skip
			if granule and granule > 0 and granule < 1e15 then
				last_granule = granule
			end
		end
		search = i + 1
	end

	if not last_granule then
		return nil, "no granule position"
	end

	local duration = last_granule / rate
	if duration <= 0 or duration > 86400 * 14 then
		return nil, "duration out of range"
	end
	return math.floor(duration * 100 + 0.5) / 100
end

local function ffprobe_duration(path)
	-- Optional PATH tool; never required
	local esc = path:gsub('"', '\\"')
	local cmd = 'ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "'
		.. esc .. '" 2>/dev/null'
	local p = io.popen(cmd)
	if not p then
		return nil
	end
	local line = p:read("*l")
	p:close()
	local n = tonumber(line)
	if n and n > 0 and n < 86400 * 14 then
		return math.floor(n * 100 + 0.5) / 100
	end
	return nil
end

--- Resolve duration for one file: Lua parse, then ffprobe, else default + warning.
function area_music.measure_track_duration(name, path)
	local dur, err = area_music.parse_ogg_duration(path)
	if dur then
		return dur, "ogg"
	end
	local fp = ffprobe_duration(path)
	if fp then
		area_music.log("action", "ffprobe duration for '" .. name .. "': " .. fp .. "s (ogg parse: "
			.. tostring(err) .. ")")
		return fp, "ffprobe"
	end
	local fallback = area_music.default_track_length or 180
	area_music.log("warning", "Could not read duration for '" .. name
		.. "' (" .. tostring(err) .. "); using default_track_length=" .. fallback)
	return fallback, "default"
end

function area_music.save_track_lengths()
	local ok = api.safe_file_write(lengths_path(), api.serialize(area_music.track_lengths or {}))
	if not ok then
		area_music.log("warning", "Failed to persist track length table")
	end
	return ok
end

function area_music.load_track_lengths()
	local f = io.open(lengths_path(), "r")
	if not f then
		return false
	end
	local content = f:read("*all")
	f:close()
	if not content or content == "" then
		return false
	end
	local ok, data = pcall(api.deserialize, content)
	if ok and type(data) == "table" then
		area_music.track_lengths = data
		return true
	end
	return false
end

--- Length for playback scheduling (seconds). Never re-parses the file.
function area_music.get_track_length(name)
	local t = area_music.track_lengths and area_music.track_lengths[name]
	if type(t) == "number" and t > 0 then
		return t
	end
	return area_music.default_track_length or 180
end
