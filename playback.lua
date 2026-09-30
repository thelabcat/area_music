-- Per-player playback: fade-out, loop fade-in, auto loop/shuffle, enter + between-track gaps.
--
-- Diagnosis (v2.x failure): mid-stay shuffle often never advanced because
-- (1) deadlines used os.time() while wakes used core.after (different clocks),
-- (2) a loop=true handle could remain forever if mode flipped or track_ends_at
--     was missing — re-enter re-rolled shuffle (looked “random”) but one stay
--     never left track 1. This rewrite uses ONE monotonic clock + a tick()
--     that always re-derives loop vs shuffle from #tracks.

local api = area_music.api

--- Monotonic seconds (prefer engine us-time; falls back to os.clock).
local function mono()
	if api.get_us_time then
		return api.get_us_time() / 1e6
	end
	return os.clock()
end

local function get_state(name)
	local st = area_music.player_state[name]
	if not st then
		st = {
			area_id = nil,
			track = nil,
			handle = nil,
			fading = {},
			fade_gen = 0,
			epoch = 0, -- bumped to invalidate all pending after() callbacks
			shuffle_queue = {},
			last_track = nil,
			fade_in_pending = false, -- first play after enter when playlist.fade_in
			-- deadline (mono seconds) for current wait
			deadline = nil, -- absolute mono time
			wait = nil, -- "enter_gap" | "track" | "between_gap" | nil
		}
		area_music.player_state[name] = st
	end
	return st
end

local function bump_epoch(st)
	st.epoch = (st.epoch or 0) + 1
	return st.epoch
end

local function playlist_of(area)
	local pl = area.playlist or { tracks = {}, mode = "loop", gap = 0 }
	pl.tracks = pl.tracks or {}
	if area_music.sync_playlist_mode then
		area_music.sync_playlist_mode(pl)
	else
		pl.mode = (#pl.tracks <= 1) and "loop" or "shuffle"
	end
	pl.gap = math.max(0, math.floor(tonumber(pl.gap) or 0))
	pl.fade_in = pl.fade_in == true
	area.playlist = pl
	return pl
end

--- True shuffle when 2+ distinct usable tracks (don’t trust stale mode alone).
local function is_shuffle(pl)
	return #(pl.tracks or {}) >= 2
end

local function fade_out_handle(name, handle, gain)
	if not handle then
		return
	end
	local st = get_state(name)
	local duration = math.max(0, area_music.fade_duration or 2.0)
	st.fade_gen = (st.fade_gen or 0) + 1
	local gen = st.fade_gen
	st.fading[handle] = gen
	local g = gain or area_music.default_gain or 0.5

	if duration <= 0 then
		pcall(api.sound_stop, handle)
		st.fading[handle] = nil
		return
	end
	if api.sound_fade then
		local step = math.max(0.01, g / duration)
		pcall(api.sound_fade, handle, step, 0)
	end
	api.after(duration + 0.05, function()
		local cur = area_music.player_state[name]
		if cur and cur.fading[handle] == gen then
			pcall(api.sound_stop, handle)
			cur.fading[handle] = nil
		end
	end)
end

local function stop_sound(name, do_fade)
	local st = get_state(name)
	local handle = st.handle
	st.handle = nil
	st.track = nil
	if handle then
		if do_fade ~= false then
			fade_out_handle(name, handle, area_music.default_gain)
		else
			pcall(api.sound_stop, handle)
		end
	end
end

local function clear_wait(st)
	st.deadline = nil
	st.wait = nil
end

function area_music.invalidate_player(name)
	local st = area_music.player_state[name]
	if not st then
		return
	end
	bump_epoch(st)
	if st.handle then
		pcall(api.sound_stop, st.handle)
	end
	st.fading = {}
	area_music.player_state[name] = nil
end

function area_music.stop_for(player_name)
	local st = get_state(player_name)
	bump_epoch(st)
	stop_sound(player_name, true)
	st.area_id = nil
	st.shuffle_queue = {}
	st.last_track = nil
	clear_wait(st)
end

------------------------------------------------------------------------
-- Shuffle pick: never returns last_track when ≥2 tracks
------------------------------------------------------------------------

local function next_shuffle_track(st, tracks)
	if #tracks == 0 then
		return nil
	end
	if #tracks == 1 then
		return tracks[1]
	end
	local avoid = st.last_track

	local function rebuild()
		local bag = {}
		for _, t in ipairs(tracks) do
			if t ~= avoid then
				bag[#bag + 1] = t
			end
		end
		if #bag == 0 then
			for _, t in ipairs(tracks) do
				bag[#bag + 1] = t
			end
		end
		for i = #bag, 2, -1 do
			local j = math.random(i)
			bag[i], bag[j] = bag[j], bag[i]
		end
		st.shuffle_queue = bag
	end

	if not st.shuffle_queue or #st.shuffle_queue == 0 then
		rebuild()
	end

	for _ = 1, math.max(16, #tracks * 3) do
		if #st.shuffle_queue == 0 then
			rebuild()
		end
		local t = table.remove(st.shuffle_queue, 1)
		if t and t ~= avoid then
			return t
		end
	end

	for _, t in ipairs(tracks) do
		if t ~= avoid then
			return t
		end
	end
	return tracks[1]
end

------------------------------------------------------------------------
-- Scheduling: mono deadline + after() wake with epoch guard
------------------------------------------------------------------------

local tick -- forward

local function arm_wait(name, seconds, kind)
	local st = get_state(name)
	local epoch = bump_epoch(st)
	local delay = math.max(0.05, seconds)
	st.wait = kind
	st.deadline = mono() + delay
	api.after(delay, function()
		local cur = area_music.player_state[name]
		if not cur or cur.epoch ~= epoch then
			return
		end
		tick(name)
	end)
end

local function play_sound(name, track, gain, should_loop, fade_in)
	local st = get_state(name)
	-- Always stop previous handle so we never leave a loop=true ghost running
	if st.handle then
		-- hard-stop previous when changing; fade only if different track still audible
		if st.track and st.track ~= track then
			fade_out_handle(name, st.handle, gain)
		else
			pcall(api.sound_stop, st.handle)
		end
		st.handle = nil
	end

	local target = gain or area_music.default_gain or 0.5
	local fade_dur = math.max(0, area_music.fade_duration or 2.0)
	local start_gain = target
	if fade_in and fade_dur > 0 then
		start_gain = 0.001
	end

	-- Explicit boolean — never omit loop (engine defaults have bitten us)
	local handle = api.sound_play({ name = track }, {
		to_player = name,
		gain = start_gain,
		loop = should_loop and true or false,
	})
	if not handle then
		-- Fallback older signature
		handle = api.sound_play(track, {
			to_player = name,
			gain = start_gain,
			loop = should_loop and true or false,
		})
	end
	if handle then
		st.handle = handle
		st.track = track
		st.last_track = track
		if fade_in and fade_dur > 0 and api.sound_fade then
			local step = math.max(0.01, target / fade_dur)
			pcall(api.sound_fade, handle, step, target)
		end
		return true
	end
	area_music.log("warning", "sound_play failed for '" .. tostring(track) .. "'")
	st.handle = nil
	st.track = nil
	return false
end

local function clamped_length(track)
	local len = area_music.get_track_length(track)
	len = tonumber(len) or (area_music.default_track_length or 180)
	-- Keep scheduling sane even if Ogg parse is wrong
	if len < 3 then
		len = 3
	end
	if len > 1800 then
		area_music.log("warning", "Track '" .. tostring(track) .. "' length "
			.. tostring(len) .. "s clamped to 1800s for shuffle timing")
		len = 1800
	end
	return len
end

local function start_track(name, area)
	local st = get_state(name)
	local pl = playlist_of(area)
	local tracks = pl.tracks
	local gain = area.gain or area_music.default_gain

	if #tracks == 0 then
		bump_epoch(st)
		stop_sound(name, true)
		clear_wait(st)
		return
	end

	if not is_shuffle(pl) then
		-- Engine loop=true. Fade-in only on enter (fade_in_pending), not on later loops.
		local track = tracks[1]
		local do_fade = pl.fade_in and st.fade_in_pending
		st.fade_in_pending = false
		clear_wait(st)
		bump_epoch(st)
		play_sound(name, track, gain, true, do_fade)
		return
	end

	-- 2+: shuffle, never loop
	local track = next_shuffle_track(st, tracks)
	if not track then
		bump_epoch(st)
		stop_sound(name, true)
		clear_wait(st)
		return
	end
	if track == st.last_track then
		-- Absolute refusal
		for _, t in ipairs(tracks) do
			if t ~= st.last_track then
				track = t
				break
			end
		end
	end

	-- Shuffle: fade-in only the first track after enter (or playlist-edit reenter)
	local do_fade = pl.fade_in and st.fade_in_pending
	st.fade_in_pending = false
	if not play_sound(name, track, gain, false, do_fade) then -- loop=false ALWAYS for shuffle
		clear_wait(st)
		return
	end
	local len = clamped_length(track)
	area_music.log("verbose", "shuffle play '" .. track .. "' for " .. len .. "s"
		.. (do_fade and " (enter fade-in)" or ""))
	arm_wait(name, len, "track")
end

local function begin_in_area(name, area)
	local st = get_state(name)
	local pl = playlist_of(area)

	st.area_id = area.id
	st.shuffle_queue = {}
	st.fade_in_pending = pl.fade_in == true
	-- stop whatever was playing (cancels via bump inside arm/start)
	bump_epoch(st)
	stop_sound(name, true)
	clear_wait(st)

	if #pl.tracks == 0 then
		return
	end

	local gap = pl.gap
	if gap > 0 then
		arm_wait(name, gap, "enter_gap")
	else
		start_track(name, area)
	end
end

--- Central state machine. Safe to call from after() or globalstep.
tick = function(name)
	local st = area_music.player_state[name]
	if not st or not st.area_id then
		return
	end
	local area = area_music.get_area_by_key(st.area_id)
	if not area then
		return
	end
	local pl = playlist_of(area)
	local now = mono()

	-- Waiting on a deadline?
	if st.wait and st.deadline then
		if now < st.deadline then
			return -- not yet
		end
		-- Deadline hit
		local finished = st.wait
		clear_wait(st)

		if finished == "enter_gap" then
			start_track(name, area)
			return
		end

		if finished == "between_gap" then
			start_track(name, area)
			return
		end

		if finished == "track" then
			if not is_shuffle(pl) then
				-- Playlist shrunk to 1 mid-play: switch to engine loop
				start_track(name, area)
				return
			end
			-- End of shuffle track → fade-out → optional between gap → next
			stop_sound(name, true)
			local gap = pl.gap
			if gap > 0 then
				arm_wait(name, gap, "between_gap")
			else
				start_track(name, area)
			end
			return
		end
	end

	-- No active wait — recover stuck states.
	-- IMPORTANT: if st.wait is set (enter_gap / between_gap / track), do nothing here.
	-- A previous bug treated "no handle" during gaps as idle and called start_track,
	-- which skipped gaps and could leave a loop=true ghost until re-entry.
	if st.wait then
		return
	end

	if #pl.tracks == 0 then
		if st.handle then
			stop_sound(name, true)
		end
		return
	end

	if is_shuffle(pl) then
		-- Idle, or playing with no deadline (e.g. leftover loop=true from 1-track mode)
		start_track(name, area)
	else
		local want = pl.tracks[1]
		if not st.handle or st.track ~= want then
			start_track(name, area)
		end
	end
end

--- Fresh enter: fade current, optional enter gap, reshuffle. Same path as walking in.
function area_music.reenter_player(player)
	if not player or not player:is_player() then
		return
	end
	local name = player:get_player_name()
	local pos = vector.round(player:get_pos())
	local area = area_music.find_area_at(pos)
	if not area then
		area_music.stop_for(name)
		return
	end
	begin_in_area(name, area)
end

--- Re-run enter path for everyone currently inside `area` (playlist edit).
function area_music.reenter_players_in_area(area)
	if not area then
		return
	end
	for _, player in ipairs(api.get_connected_players()) do
		local pos = vector.round(player:get_pos())
		local here = area_music.find_area_at(pos)
		if here and here.id == area.id then
			begin_in_area(player:get_player_name(), area)
		end
	end
end

--- Stop (fade) anyone whose current area is this one.
function area_music.stop_players_in_area(area)
	if not area then
		return
	end
	for _, player in ipairs(api.get_connected_players()) do
		local name = player:get_player_name()
		local st = area_music.player_state[name]
		if st and st.area_id == area.id then
			area_music.stop_for(name)
		end
	end
end

function area_music.update_player(player)
	local name = player:get_player_name()
	local pos = vector.round(player:get_pos())
	local area = area_music.find_area_at(pos)
	local st = get_state(name)

	if not area then
		if st.area_id then
			area_music.stop_for(name)
		end
		return
	end

	playlist_of(area)

	if st.area_id ~= area.id then
		begin_in_area(name, area)
		return
	end

	-- Same area: drive the state machine (deadline poll + stuck recovery)
	tick(name)
end

area_music._tick_playback = tick
