-- Chat commands (server priv)

local api = area_music.api
local PRIVS = { server = true }

api.register_chatcommand("am_pos1", {
	params = "",
	privs = PRIVS,
	description = "Set area_music corner 1 to your position",
	func = function(name)
		local player = api.get_player_by_name(name)
		if not player then return false, "No player" end
		local pos = vector.round(player:get_pos())
		area_music.set_pos(name, 1, pos)
		return true, "pos1 = " .. api.pos_to_string(pos)
	end,
})

api.register_chatcommand("am_pos2", {
	params = "",
	privs = PRIVS,
	description = "Set area_music corner 2 to your position",
	func = function(name)
		local player = api.get_player_by_name(name)
		if not player then return false, "No player" end
		local pos = vector.round(player:get_pos())
		area_music.set_pos(name, 2, pos)
		return true, "pos2 = " .. api.pos_to_string(pos)
	end,
})

api.register_chatcommand("am_unmark", {
	params = "",
	privs = PRIVS,
	description = "Clear area_music corner markers",
	func = function(name)
		area_music.unmark(name)
		return true, "Markers cleared"
	end,
})

local function cmd_add_area(name, param)
	local aname, pri_s = param:match("^(%S+)%s*(%S*)$")
	if not aname then
		return false, "Usage: /am_add <area_name> [priority]"
	end
	local pos1 = area_music.pos1[name]
	local pos2 = area_music.pos2[name]
	if not pos1 or not pos2 then
		return false, "Set both pos1 and pos2 first (wand or /am_pos1 /am_pos2)"
	end
	local ok, msg = area_music.add_area(aname, tonumber(pri_s), pos1, pos2)
	if ok then
		area_music.unmark(name)
	end
	return ok, msg
end

api.register_chatcommand("am_add", {
	params = "<area_name> [priority]",
	privs = PRIVS,
	description = "Create a music area from pos1/pos2 (playlist via jukebox)",
	func = cmd_add_area,
})

api.register_chatcommand("am_create", {
	params = "<area_name> [priority]",
	privs = PRIVS,
	description = "Alias for /am_add",
	func = cmd_add_area,
})

api.register_chatcommand("am_remove", {
	params = "<area_name_or_id>",
	privs = PRIVS,
	description = "Remove a music area by name or id",
	func = function(_, param)
		local key = param:match("^(%S+)$")
		if not key then
			return false, "Usage: /am_remove <area_name_or_id>"
		end
		return area_music.remove_area(key)
	end,
})

api.register_chatcommand("am_list", {
	params = "",
	privs = PRIVS,
	description = "List music areas and known world tracks",
	func = function()
		area_music.scan_tracks()
		local lines = {}
		if #area_music.areas == 0 then
			lines[#lines + 1] = "No areas registered."
		else
			for _, a in ipairs(area_music.areas) do
				local pl = a.playlist or { tracks = {}, mode = "loop", gap = 0 }
				local tr = table.concat(pl.tracks or {}, ",")
				if tr == "" then tr = "-" end
				local jb = a.jukebox_pos and api.pos_to_string(a.jukebox_pos) or "-"
				lines[#lines + 1] = ("#%d %s mode=%s gap=%d fadein=%s pri=%d tracks=[%s] jb=%s %s .. %s"):format(
					a.id, a.name, pl.mode or "loop", tonumber(pl.gap) or 0,
					pl.fade_in and "on" or "off",
					a.priority or 0, tr, jb,
					api.pos_to_string(a.pos1), api.pos_to_string(a.pos2))
			end
		end
		local tracks = area_music.list_track_names()
		if #tracks == 0 then
			lines[#lines + 1] = "Tracks in world/area_music/: (none)"
		else
			local parts = {}
			for _, tr in ipairs(tracks) do
				local sec = area_music.get_track_length(tr)
				parts[#parts + 1] = ("%s (%.1fs)"):format(tr, sec)
			end
			lines[#lines + 1] = "Tracks in world/area_music/: " .. table.concat(parts, ", ")
		end
		return true, table.concat(lines, "\n")
	end,
})

--- Rescan world/area_music/*.ogg, refresh duration cache, push media to players.
--- Same work as /am_reload (and the areas-manager Refresh tracks button).
function area_music.reload_tracks()
	local files = area_music.scan_tracks()
	local pruned = 0
	if area_music.prune_missing_playlist_tracks then
		pruned = area_music.prune_missing_playlist_tracks() or 0
	end
	for _, player in ipairs(api.get_connected_players()) do
		area_music.push_media_to_player(player:get_player_name())
	end
	local msg = ("Rescanned %d track(s), durations refreshed; pushing media"):format(#files)
	if pruned > 0 then
		msg = msg .. (", pruned %d missing playlist entry(ies)"):format(pruned)
	end
	return true, msg
end

api.register_chatcommand("am_reload", {
	params = "",
	privs = PRIVS,
	description = "Rescan world music folder and push media to all players",
	func = function()
		return area_music.reload_tracks()
	end,
})

api.register_chatcommand("am_wand", {
	params = "",
	privs = PRIVS,
	description = "Give an Area Music wand (punch=pos1, place=pos2)",
	func = function(name)
		local player = api.get_player_by_name(name)
		if not player then return false, "No player" end
		local inv = player:get_inventory()
		local leftover = inv:add_item("main", ItemStack("area_music:wand"))
		if leftover:is_empty() then
			return true, "Gave Area Music wand"
		end
		return false, "Inventory full"
	end,
})

api.register_chatcommand("am_gui", {
	params = "",
	privs = PRIVS,
	description = "Open the Area Music areas manager",
	func = function(name)
		area_music.show_gui(name)
		return true, "Opened Area Music GUI"
	end,
})

api.register_chatcommand("am_priority", {
	params = "<area_name_or_id> <priority>",
	privs = PRIVS,
	description = "Set overlap priority for an area (higher wins)",
	func = function(_, param)
		local key, pri = param:match("^(%S+)%s+(%S+)$")
		if not key or not pri then
			return false, "Usage: /am_priority <area_name_or_id> <n>"
		end
		return area_music.set_priority(key, pri)
	end,
})

api.register_chatcommand("am_jukebox", {
	params = "",
	privs = PRIVS,
	description = "Give an Area Music jukebox node",
	func = function(name)
		local player = api.get_player_by_name(name)
		if not player then return false, "No player" end
		local inv = player:get_inventory()
		local leftover = inv:add_item("main", ItemStack("area_music:jukebox"))
		if leftover:is_empty() then
			return true, "Gave Area Music jukebox"
		end
		return false, "Inventory full"
	end,
})
