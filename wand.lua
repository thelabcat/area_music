-- area_music:wand — punch = pos1, place = pos2 (server priv to use)
-- Appears in creative inventory; /am_wand is optional convenience.

local api = area_music.api

api.register_tool("area_music:wand", {
	description = "Area Music Wand\nLeft-click: pos1  |  Right-click: pos2\n(Requires server priv to use)",
	short_description = "Area Music Wand",
	inventory_image = "area_music_wand.png",
	wield_image = "area_music_wand.png",
	wield_scale = { x = 1, y = 1, z = 1 },
	stack_max = 1,
	range = 10,
	liquids_pointable = false,
	-- Do NOT set not_in_creative_inventory — must show in creative
	groups = {
		tool = 1,
	},

	on_use = function(itemstack, user, pointed_thing)
		if not user or not user:is_player() then
			return itemstack
		end
		local name = user:get_player_name()
		if not area_music.has_server_priv(name) then
			api.chat_send_player(name, "[area_music] server privilege required.")
			return itemstack
		end
		local pos
		if pointed_thing and pointed_thing.type == "node" and pointed_thing.under then
			pos = vector.round(pointed_thing.under)
		else
			pos = vector.round(user:get_pos())
		end
		area_music.set_pos(name, 1, pos)
		api.chat_send_player(name, "[area_music] pos1 = " .. api.pos_to_string(pos))
		return itemstack
	end,

	on_place = function(itemstack, placer, pointed_thing)
		if not placer or not placer:is_player() then
			return itemstack
		end
		local name = placer:get_player_name()
		if not area_music.has_server_priv(name) then
			api.chat_send_player(name, "[area_music] server privilege required.")
			return itemstack
		end
		local pos
		if pointed_thing and pointed_thing.type == "node" and pointed_thing.under then
			pos = vector.round(pointed_thing.under)
		else
			pos = vector.round(placer:get_pos())
		end
		area_music.set_pos(name, 2, pos)
		api.chat_send_player(name, "[area_music] pos2 = " .. api.pos_to_string(pos))
		return itemstack
	end,

	on_secondary_use = function(itemstack, user, pointed_thing)
		if not user or not user:is_player() then
			return itemstack
		end
		local name = user:get_player_name()
		if not area_music.has_server_priv(name) then
			api.chat_send_player(name, "[area_music] server privilege required.")
			return itemstack
		end
		local pos = vector.round(user:get_pos())
		area_music.set_pos(name, 2, pos)
		api.chat_send_player(name, "[area_music] pos2 = " .. api.pos_to_string(pos))
		return itemstack
	end,
})

-- Optional craft so survival/creative craft guides list it (stick + any wood)
api.register_craft({
	output = "area_music:wand",
	recipe = {
		{ "", "", "group:stick" },
		{ "", "group:wood", "" },
		{ "group:stick", "", "" },
	},
})
