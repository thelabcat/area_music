-- Management GUI: /am_gui + optional sfinv / unified_inventory tab (areas only)

local api = area_music.api

local FORM_MAIN = "area_music:gui"
local FORM_NAME = "area_music:gui_name"

local player_gui = {} -- name -> { selected_index }

local function pos_str(p)
	if not p then
		return "(unset)"
	end
	return api.pos_to_string(p)
end

--- textlist items are comma-separated; escape each cell. Never use "#" (color codes).
local function join_textlist(items)
	local out = {}
	for i, item in ipairs(items) do
		out[i] = api.formspec_escape(item)
	end
	return table.concat(out, ",")
end

local function area_list_entries()
	-- Areas only — no track/playlist noise in the list (that belongs in details / jukebox).
	local entries = {}
	for i, a in ipairs(area_music.areas) do
		entries[i] = ("%d. %s"):format(a.id, a.name)
	end
	return entries
end

local function can_create(name)
	local p1 = area_music.pos1[name]
	local p2 = area_music.pos2[name]
	if not p1 or not p2 then
		return false, "Set both pos1 and pos2 first (wand or /am_pos1 /am_pos2)"
	end
	local dup = area_music.corners_match_existing(p1, p2)
	if dup then
		return false, "Corners already match area: " .. dup.name
	end
	return true, ""
end

local function detail_label(area)
	if not area then
		return "Select an area"
	end
	local pl = area.playlist or { tracks = {}, mode = "loop", gap = 0 }
	local n = #(pl.tracks or {})
	local jb = "not linked"
	if area.jukebox_pos then
		jb = api.pos_to_string(area.jukebox_pos)
	end
	local mode_note
	if n == 0 then
		mode_note = "empty (place a jukebox inside to add tracks)"
	elseif n == 1 then
		mode_note = "1 track (auto loop)"
	else
		mode_note = n .. " tracks (auto shuffle)"
	end
	return table.concat({
		("Name: %s"):format(area.name),
		("Id: %d"):format(area.id),
		("Corners: %s .. %s"):format(pos_str(area.pos1), pos_str(area.pos2)),
		("Priority: %d"):format(area.priority or 0),
		("Jukebox: %s"):format(jb),
		("Playlist: %s"):format(mode_note),
		("Fade in: %s"):format((pl.fade_in and "on") or "off"),
		"",
		"Playlists are edited only at the jukebox.",
	}, "\n")
end

--- Build manager formspec. opts.embedded = true omits version/size (for inventory tabs).
function area_music.build_gui_formspec(player_name, opts)
	opts = opts or {}
	local p1 = area_music.pos1[player_name]
	local p2 = area_music.pos2[player_name]
	local ok_create, why = can_create(player_name)
	local entries = area_list_entries()
	local list_str = join_textlist(entries)

	local ctx = player_gui[player_name] or { selected_index = 0 }
	player_gui[player_name] = ctx
	local sel = ctx.selected_index or 0
	if sel > #area_music.areas then
		sel = 0
		ctx.selected_index = 0
	end
	local area = (sel >= 1) and area_music.areas[sel] or nil

	local add_btn = ok_create
		and "button[0.3,1.7;2.0,0.7;add;+ Create]"
		or "button[0.3,1.7;2.0,0.7;add_disabled;+ Create]"
	local del_btn = area
		and "button[2.4,1.7;2.0,0.7;del;- Delete]"
		or "button[2.4,1.7;2.0,0.7;del_disabled;- Delete]"
	local reload_btn = "button[4.5,1.7;2.6,0.7;reload;Refresh tracks]"

	local n_tracks = 0
	for _ in pairs(area_music.known_tracks or {}) do
		n_tracks = n_tracks + 1
	end

	local reason = ""
	if not ok_create then
		reason = why
	elseif not area then
		reason = "Select an area for details / delete"
	end
	if reason ~= "" then
		reason = reason .. "  |  "
	end
	reason = reason .. ("%d world track(s)"):format(n_tracks)

	local fs = {}
	if not opts.embedded then
		fs[#fs + 1] = "formspec_version[4]"
		fs[#fs + 1] = "size[11,9.2]"
	end
	fs[#fs + 1] = "label[0.3,0.25;Area Music — Areas]"
	fs[#fs + 1] = "label[0.3,0.85;pos1: "
		.. api.formspec_escape(pos_str(p1))
		.. "   pos2: "
		.. api.formspec_escape(pos_str(p2))
		.. "]"
	fs[#fs + 1] = add_btn
	fs[#fs + 1] = del_btn
	fs[#fs + 1] = reload_btn
	fs[#fs + 1] = "label[7.3,1.9;" .. api.formspec_escape(reason) .. "]"
	fs[#fs + 1] = "label[0.3,2.6;Areas]"
	fs[#fs + 1] = "textlist[0.3,2.95;5.2,5.8;alist;"
		.. list_str
		.. ";"
		.. tostring(math.max(1, sel))
		.. ";false]"
	fs[#fs + 1] = "label[5.8,2.6;Details]"
	fs[#fs + 1] = "textarea[5.8,2.95;4.9,5.8;;;"
		.. api.formspec_escape(detail_label(area))
		.. "]"
	return table.concat(fs)
end

function area_music.show_gui(player_name)
	if not area_music.has_server_priv(player_name) then
		api.chat_send_player(player_name, "[area_music] server privilege required.")
		return
	end
	api.show_formspec(player_name, FORM_MAIN, area_music.build_gui_formspec(player_name))
end

local function show_name_dialog(player_name)
	local fs = table.concat({
		"formspec_version[4]",
		"size[6,3.2]",
		"label[0.3,0.35;New area name]",
		"field[0.3,1.0;5.4,0.8;aname;;]",
		"field_close_on_enter[aname;true]",
		"button[0.3,2.1;2.5,0.75;ok;Create]",
		"button[3.2,2.1;2.5,0.75;cancel;Cancel]",
	})
	api.show_formspec(player_name, FORM_NAME, fs)
end

local function refresh_inv_pages(player)
	if rawget(_G, "sfinv") and sfinv.set_player_inventory_formspec then
		sfinv.set_player_inventory_formspec(player)
	end
	if rawget(_G, "unified_inventory") and unified_inventory.set_inventory_formspec then
		unified_inventory.set_inventory_formspec(player, "area_music")
	end
end

--- Shared field handler for standalone formspec and inventory tabs.
function area_music.handle_gui_fields(player, fields, opts)
	opts = opts or {}
	local name = player:get_player_name()
	if not area_music.has_server_priv(name) then
		return true
	end

	local ctx = player_gui[name] or { selected_index = 0 }
	player_gui[name] = ctx

	if fields.alist then
		local event = api.explode_textlist_event(fields.alist)
		if event.type == "CHG" or event.type == "DCL" then
			ctx.selected_index = event.index
		end
	end

	if fields.add then
		local ok = can_create(name)
		if ok then
			show_name_dialog(name)
			return true
		end
	end

	if fields.del then
		local area = area_music.areas[ctx.selected_index]
		if area then
			local ok, msg = area_music.remove_area(area.id)
			api.chat_send_player(name, "[area_music] " .. msg)
			ctx.selected_index = 0
		end
	end

	if fields.reload then
		local ok, msg = area_music.reload_tracks()
		api.chat_send_player(name, "[area_music] " .. (msg or "reload done"))
	end

	if fields.quit and not opts.embedded then
		return true
	end

	if opts.embedded then
		refresh_inv_pages(player)
	else
		area_music.show_gui(name)
	end
	return true
end

api.register_on_player_receive_fields(function(player, formname, fields)
	local name = player:get_player_name()

	if formname == FORM_NAME then
		local submit = fields.ok
			or fields.key_enter_field == "aname"
			or (fields.key_enter and fields.aname)
		-- Enter with text should create (not treat as cancel via quit)
		if submit and fields.aname and fields.aname:match("%S") then
			local aname = fields.aname:match("^%s*(.-)%s*$")
			local p1 = area_music.pos1[name]
			local p2 = area_music.pos2[name]
			local ok, msg = area_music.add_area(aname, 0, p1, p2)
			api.chat_send_player(name, "[area_music] " .. msg)
			if ok then
				area_music.unmark(name)
			end
			area_music.show_gui(name)
			refresh_inv_pages(player)
		elseif fields.cancel or fields.quit then
			area_music.show_gui(name)
		end
		return true
	end

	if formname == FORM_MAIN then
		return area_music.handle_gui_fields(player, fields, { embedded = false })
	end
end)

------------------------------------------------------------------------
-- sfinv / unified_inventory: manager lives IN the tab (no open-button)
------------------------------------------------------------------------

local function try_sfinv()
	if not rawget(_G, "sfinv") or not sfinv.register_page then
		return false
	end
	-- unified_inventory typically leaves the sfinv global but sets enabled=false
	if sfinv.enabled == false then
		return false
	end
	sfinv.register_page("area_music:manager", {
		title = "Area Music",
		is_in_nav = function(self, player, context)
			return area_music.has_server_priv(player:get_player_name())
		end,
		get = function(self, player, context)
			local name = player:get_player_name()
			local body = area_music.build_gui_formspec(name, { embedded = true })
			return sfinv.make_formspec(player, context, body, false, "size[11,9.5]")
		end,
		on_player_receive_fields = function(self, player, context, fields)
			area_music.handle_gui_fields(player, fields, { embedded = true })
		end,
	})
	area_music.log("action", "Registered sfinv Area Music tab")
	return true
end

local function try_unified_inventory()
	if not rawget(_G, "unified_inventory") or not unified_inventory.register_page then
		return false
	end
	unified_inventory.register_page("area_music", {
		get_formspec = function(player, perplayer_formspec)
			local name = player:get_player_name()
			if not area_music.has_server_priv(name) then
				local hx, hy = 0.3, 0.3
				if perplayer_formspec then
					hx = perplayer_formspec.form_header_x or hx
					hy = perplayer_formspec.form_header_y or hy
				end
				return {
					formspec = "label[" .. hx .. "," .. hy .. ";Area Music: server priv required]",
					draw_inventory = false,
					draw_item_list = false,
				}
			end
			local body = area_music.build_gui_formspec(name, { embedded = true })
			-- Offset into UI page if layout hints exist
			if perplayer_formspec and perplayer_formspec.form_header_x then
				body = "container["
					.. (perplayer_formspec.form_header_x or 0) .. ","
					.. ((perplayer_formspec.form_header_y or 0) + 0.3) .. "]"
					.. body
					.. "container_end[]"
			end
			return {
				formspec = body,
				draw_inventory = false,
				draw_item_list = false,
			}
		end,
	})
	unified_inventory.register_button("area_music", {
		type = "image",
		image = "area_music_jukebox.png",
		tooltip = "Area Music",
		condition = function(player)
			return area_music.has_server_priv(player:get_player_name())
		end,
	})
	api.register_on_player_receive_fields(function(player, formname, fields)
		if not fields.alist and not fields.add and not fields.del
			and not fields.add_disabled and not fields.del_disabled
		then
			return
		end
		if not area_music.has_server_priv(player:get_player_name()) then
			return
		end
		if formname == FORM_MAIN or formname == FORM_NAME then
			return
		end
		area_music.handle_gui_fields(player, fields, { embedded = true })
	end)
	area_music.log("action", "Registered unified_inventory Area Music tab")
	return true
end

api.register_on_mods_loaded(function()
	-- Register both: sfinv may exist while unified_inventory owns the inventory
	local sfinv_ok = try_sfinv()
	local ui_ok = try_unified_inventory()
	if not sfinv_ok and not ui_ok then
		area_music.log("action", "No inventory tab (use /am_gui)")
	end
end)
