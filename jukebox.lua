-- area_music:jukebox / jukebox_broken — bind to smallest unbound containing area

local api = area_music.api

local FORMNAME = "area_music:jukebox"

local function pos_equal(a, b)
	if not a or not b then
		return false
	end
	return a.x == b.x and a.y == b.y and a.z == b.z
end

--- Smallest-volume cuboid containing `pos` that has no jukebox, or this pos.
function area_music.find_bindable_area(pos)
	local best, best_vol
	for _, area in ipairs(area_music.areas) do
		if area_music.in_cuboid(pos, area.pos1, area.pos2) then
			local jp = area.jukebox_pos
			if not jp or pos_equal(jp, pos) then
				local vol = area_music.cuboid_volume(area.pos1, area.pos2)
				if not best or vol < best_vol then
					best = area
					best_vol = vol
				end
			end
		end
	end
	return best
end

function area_music.get_area_by_jukebox(pos)
	for _, area in ipairs(area_music.areas) do
		if area.jukebox_pos and pos_equal(area.jukebox_pos, pos) then
			return area
		end
	end
	return nil
end

local function set_infotext(meta, linked, area)
	if linked and area then
		meta:set_string("infotext", "Area Music Jukebox\nLinked: " .. area.name)
		meta:set_string("area_id", tostring(area.id))
	else
		meta:set_string("infotext", "Area Music Jukebox (broken)\nNot linked to an area")
		meta:set_string("area_id", "")
	end
end

function area_music.bind_jukebox_at(pos)
	local node = api.get_node(pos)
	if node.name ~= "area_music:jukebox" and node.name ~= "area_music:jukebox_broken" then
		return
	end
	local meta = api.get_meta(pos)
	local area = area_music.find_bindable_area(pos)
	if area then
		-- Unbind any previous claim of this exact pos from other areas (safety)
		for _, a in ipairs(area_music.areas) do
			if a ~= area and a.jukebox_pos and pos_equal(a.jukebox_pos, pos) then
				a.jukebox_pos = nil
			end
		end
		area.jukebox_pos = { x = pos.x, y = pos.y, z = pos.z }
		area_music.save()
		if node.name ~= "area_music:jukebox" then
			api.swap_node(pos, { name = "area_music:jukebox", param2 = node.param2 })
		end
		set_infotext(meta, true, area)
	else
		-- Clear if we had claimed something that no longer qualifies
		local old = area_music.get_area_by_jukebox(pos)
		if old then
			old.jukebox_pos = nil
			area_music.save()
		end
		if node.name ~= "area_music:jukebox_broken" then
			api.swap_node(pos, { name = "area_music:jukebox_broken", param2 = node.param2 })
		end
		set_infotext(meta, false, nil)
	end
end

function area_music.refresh_jukeboxes()
	-- Re-check all known jukebox positions from areas + scan is expensive;
	-- walk areas' jukebox_pos and also leave nodes to rebind on punch/timer.
	for _, area in ipairs(area_music.areas) do
		if area.jukebox_pos then
			local n = api.get_node(area.jukebox_pos)
			if n.name == "area_music:jukebox" or n.name == "area_music:jukebox_broken" then
				area_music.bind_jukebox_at(area.jukebox_pos)
			else
				area.jukebox_pos = nil
			end
		end
	end
	area_music.save()
end

function area_music.on_area_removed(area)
	if area.jukebox_pos then
		local pos = area.jukebox_pos
		local n = api.get_node(pos)
		if n.name == "area_music:jukebox" or n.name == "area_music:jukebox_broken" then
			area.jukebox_pos = nil
			area_music.bind_jukebox_at(pos)
		end
	end
end

------------------------------------------------------------------------
-- Formspec for linked jukebox
------------------------------------------------------------------------

local player_jb_ctx = {} -- name -> { pos, area_id, avail_sel, list_sel }

local function join_textlist(items)
	local out = {}
	for i, item in ipairs(items) do
		out[i] = api.formspec_escape(item)
	end
	return table.concat(out, ",")
end

local function jukebox_formspec(player_name, area, pos)
	-- Use cached track list/lengths from last scan (/am_reload or load)
	if not next(area_music.known_tracks or {}) then
		area_music.scan_tracks()
	end
	local tracks_avail = area_music.list_track_names()
	local pl = area.playlist or { tracks = {}, mode = "loop", gap = 0, fade_in = false }
	area_music.sync_playlist_mode(pl)
	local in_list = pl.tracks or {}

	local avail_str = join_textlist(tracks_avail)
	local list_str = join_textlist(in_list)

	local gap = tonumber(pl.gap) or 0
	local fade_in = pl.fade_in == true
	local mode_note
	if #in_list == 0 then
		mode_note = "Mode: (empty)"
	elseif #in_list == 1 then
		mode_note = "Mode: loop (1 track)"
	else
		mode_note = "Mode: shuffle (" .. #in_list .. " tracks)"
	end

	-- Preserve selection across refresh
	local prev = player_jb_ctx[player_name]
	local avail_sel = 1
	local list_sel = 1
	if prev and prev.area_id == area.id then
		avail_sel = tonumber(prev.avail_sel) or 1
		list_sel = tonumber(prev.list_sel) or 1
	end
	if avail_sel < 1 then avail_sel = 1 end
	if list_sel < 1 then list_sel = 1 end
	if #tracks_avail > 0 and avail_sel > #tracks_avail then
		avail_sel = #tracks_avail
	end
	if #in_list > 0 and list_sel > #in_list then
		list_sel = #in_list
	end

	local fs = {
		"formspec_version[4]",
		"size[12,9.5]",
		"label[0.3,0.35;Jukebox - Area: ", api.formspec_escape(area.name), "]",
		"label[0.3,0.85;", api.formspec_escape(mode_note),
			"  |  1 track = loop, 2+ = shuffle (auto)]",
		"label[0.3,1.35;Available tracks]",
		"textlist[0.3,1.65;5.2,5.2;avail;", avail_str, ";",
			tostring(avail_sel), ";false]",
		"label[6.5,1.35;Playlist]",
		"textlist[6.5,1.65;5.2,5.2;plist;", list_str, ";",
			tostring(list_sel), ";false]",
		"button[0.3,7.1;2.6,0.8;add;Add ->]",
		"button[6.5,7.1;2.6,0.8;remove;<- Remove]",
		"label[0.3,8.2;", api.formspec_escape("Gap (seconds after enter / between shuffle tracks; 0 = none)"), "]",
		"field[0.3,8.55;2.0,0.7;gap;;", tostring(gap), "]",
		"button[2.5,8.55;2.0,0.7;setgap;Set gap]",
		"checkbox[4.7,8.7;fadein;",
			api.formspec_escape("Fade in"), ";",
			fade_in and "true" or "false", "]",
		"button_exit[9.5,8.55;2.2,0.7;close;Close]",
	}
	player_jb_ctx[player_name] = {
		pos = { x = pos.x, y = pos.y, z = pos.z },
		area_id = area.id,
		avail = tracks_avail,
		plist = in_list,
		avail_sel = avail_sel,
		list_sel = list_sel,
	}
	return table.concat(fs)
end

local function open_jukebox(player_name, pos, area)
	api.show_formspec(player_name, FORMNAME, jukebox_formspec(player_name, area, pos))
end

api.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME then
		return
	end
	local name = player:get_player_name()
	local ctx = player_jb_ctx[name]
	if not ctx then
		return true
	end
	local area = area_music.get_area_by_key(ctx.area_id)
	if not area then
		api.chat_send_player(name, "[area_music] Area no longer exists.")
		return true
	end
	area.playlist = area.playlist or { tracks = {}, mode = "loop", gap = 0, fade_in = false }

	if fields.avail then
		local event = api.explode_textlist_event(fields.avail)
		if event.type == "CHG" or event.type == "DCL" then
			ctx.avail_sel = event.index
		end
	end
	if fields.plist then
		local event = api.explode_textlist_event(fields.plist)
		if event.type == "CHG" or event.type == "DCL" then
			ctx.list_sel = event.index
		end
	end

	local dirty = false

	if fields.add and ctx.avail_sel and ctx.avail[ctx.avail_sel] then
		local t = ctx.avail[ctx.avail_sel]
		if area_music.is_valid_track_name and not area_music.is_valid_track_name(t) then
			api.chat_send_player(name,
				"[area_music] Track name has invalid characters (Luanti allows a-z A-Z 0-9 _ . - only).")
		else
			local exists = false
			for _, x in ipairs(area.playlist.tracks) do
				if x == t then exists = true break end
			end
			if not exists then
				area.playlist.tracks[#area.playlist.tracks + 1] = t
				dirty = true
			end
		end
	end

	if fields.remove and ctx.list_sel and area.playlist.tracks[ctx.list_sel] then
		table.remove(area.playlist.tracks, ctx.list_sel)
		dirty = true
	end

	if fields.setgap and fields.gap then
		local g = tonumber(fields.gap) or 0
		if g < 0 then g = 0 end
		g = math.floor(g)
		area.playlist.gap = g
		dirty = true
	end

	if fields.fadein ~= nil then
		local v = fields.fadein == "true"
		if area.playlist.fade_in ~= v then
			area.playlist.fade_in = v
			dirty = true
		end
	end

	if dirty then
		area_music.sync_playlist_mode(area.playlist)
		area_music.save()
		-- Same as walking into the area: fade, enter gap, reshuffle
		if area_music.reenter_players_in_area then
			area_music.reenter_players_in_area(area)
		else
			for _, p in ipairs(api.get_connected_players()) do
				area_music.update_player(p)
			end
		end
	end

	if fields.close or fields.quit then
		player_jb_ctx[name] = nil
		return true
	end

	-- Refresh after edits / selection (preserve avail_sel/list_sel via ctx)
	if dirty or fields.add or fields.remove or fields.setgap
		or fields.avail or fields.plist or fields.fadein
	then
		open_jukebox(name, ctx.pos, area)
	end
	return true
end)

------------------------------------------------------------------------
-- Node defs
------------------------------------------------------------------------

local function jukebox_on_construct(pos)
	api.get_meta(pos):set_string("infotext", "Area Music Jukebox")
	api.after(0, function()
		area_music.bind_jukebox_at(pos)
	end)
end

local function jukebox_on_destruct(pos)
	local area = area_music.get_area_by_jukebox(pos)
	if not area then
		return
	end
	-- Unlink, wipe playlist, stop anyone hearing this area
	area.jukebox_pos = nil
	area.playlist = area.playlist or { tracks = {}, mode = "loop", gap = 0, fade_in = false }
	area.playlist.tracks = {}
	area.playlist.mode = "loop"
	area_music.sync_playlist_mode(area.playlist)
	area_music.save()
	if area_music.stop_players_in_area then
		area_music.stop_players_in_area(area)
	end
end

local function jukebox_on_punch(pos, node, puncher)
	area_music.bind_jukebox_at(pos)
end

local function jukebox_on_rightclick(pos, node, clicker)
	if not clicker or not clicker:is_player() then
		return
	end
	local name = clicker:get_player_name()
	area_music.bind_jukebox_at(pos)
	local n = api.get_node(pos)
	if n.name == "area_music:jukebox_broken" then
		api.chat_send_player(name, "[area_music] Jukebox is broken — place it inside an unbound music area.")
		return
	end
	local area = area_music.get_area_by_jukebox(pos)
	if not area then
		api.chat_send_player(name, "[area_music] Jukebox is not linked.")
		return
	end
	open_jukebox(name, pos, area)
end

local function wood_sounds()
	local def = rawget(_G, "default")
	if def and def.node_sound_wood_defaults then
		return def.node_sound_wood_defaults()
	end
	return nil
end

-- Creative-visible placeable jukebox (broken variant stays hidden).
api.register_node("area_music:jukebox", {
	description = "Area Music Jukebox\nPlace inside a music area; right-click to edit playlist",
	short_description = "Area Music Jukebox",
	tiles = {
		"area_music_jukebox.png", "area_music_jukebox.png",
		"area_music_jukebox.png", "area_music_jukebox.png",
		"area_music_jukebox.png", "area_music_jukebox.png",
	},
	inventory_image = "area_music_jukebox.png",
	wield_image = "area_music_jukebox.png",
	paramtype2 = "facedir",
	is_ground_content = false,
	-- Visible in creative: do not set not_in_creative_inventory
	groups = {
		choppy = 2,
		oddly_breakable_by_hand = 2,
		flammable = 1,
		-- Common cross-game creative / dig groups (harmless if unused)
		handy = 1,
		axey = 1,
		building_block = 1,
		deco_block = 1,
		material_wood = 1,
	},
	sounds = wood_sounds(),
	on_construct = jukebox_on_construct,
	on_destruct = jukebox_on_destruct,
	on_punch = jukebox_on_punch,
	on_rightclick = jukebox_on_rightclick,
	on_timer = function(pos)
		area_music.bind_jukebox_at(pos)
		return true
	end,
	after_place_node = function(pos)
		local timer = api.get_node_timer(pos)
		timer:start(5)
		area_music.bind_jukebox_at(pos)
	end,
})

api.register_node("area_music:jukebox_broken", {
	description = "Area Music Jukebox (broken — not linked)",
	short_description = "Area Music Jukebox (broken)",
	tiles = {
		"area_music_jukebox_broken.png", "area_music_jukebox_broken.png",
		"area_music_jukebox_broken.png", "area_music_jukebox_broken.png",
		"area_music_jukebox_broken.png", "area_music_jukebox_broken.png",
	},
	inventory_image = "area_music_jukebox_broken.png",
	wield_image = "area_music_jukebox_broken.png",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {
		choppy = 2,
		oddly_breakable_by_hand = 2,
		not_in_creative_inventory = 1, -- only the working item is creatable
		handy = 1,
		axey = 1,
	},
	sounds = wood_sounds(),
	drop = "area_music:jukebox",
	on_construct = jukebox_on_construct,
	on_destruct = jukebox_on_destruct,
	on_punch = jukebox_on_punch,
	on_rightclick = jukebox_on_rightclick,
	on_timer = function(pos)
		area_music.bind_jukebox_at(pos)
		return true
	end,
	after_place_node = function(pos)
		local timer = api.get_node_timer(pos)
		timer:start(5)
		area_music.bind_jukebox_at(pos)
	end,
})

-- Creative / give alias
api.register_alias("area_music:jukebox_item", "area_music:jukebox")

api.register_craft({
	output = "area_music:jukebox",
	recipe = {
		{ "group:wood", "group:wood", "group:wood" },
		{ "group:wood", "group:wood", "group:wood" },
		{ "group:wood", "group:wood", "group:wood" },
	},
})
