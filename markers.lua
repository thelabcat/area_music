-- WorldEdit-style visual corner markers

local api = area_music.api

local function remove_marker_near(pos, entity_name)
	if not pos then
		return
	end
	local objs = api.get_objects_inside_radius(pos, 0.75) or {}
	for _, obj in ipairs(objs) do
		local ent = obj:get_luaentity()
		if ent and ent.name == entity_name then
			obj:remove()
		end
	end
end

local function clear_marker_ref(player_name, which)
	local bag = area_music.marker_obj[player_name]
	if not bag then
		return
	end
	local key = which == 1 and "pos1" or "pos2"
	local obj = bag[key]
	bag[key] = nil
	if not obj then
		return
	end
	pcall(function()
		obj:remove()
	end)
end

function area_music.set_pos(player_name, which, pos)
	local key = which == 1 and "pos1" or "pos2"
	local entity = which == 1 and "area_music:pos1" or "area_music:pos2"

	clear_marker_ref(player_name, which)
	local old = area_music[key][player_name]
	if old then
		remove_marker_near(old, entity)
	end

	area_music[key][player_name] = pos
	if not pos then
		return
	end

	local obj = api.add_entity(pos, entity)
	area_music.marker_obj[player_name] = area_music.marker_obj[player_name] or {}
	area_music.marker_obj[player_name][key] = obj
end

function area_music.unmark(player_name)
	area_music.set_pos(player_name, 1, nil)
	area_music.set_pos(player_name, 2, nil)
	area_music.marker_obj[player_name] = nil
end

api.register_entity("area_music:pos1", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = 1.05, y = 1.05, z = 1.05 },
		textures = {
			"area_music_pos1.png", "area_music_pos1.png", "area_music_pos1.png",
			"area_music_pos1.png", "area_music_pos1.png", "area_music_pos1.png",
		},
		physical = false,
		collide_with_objects = false,
		pointable = true,
		is_visible = true,
		static_save = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		selectionbox = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 },
	},
})

api.register_entity("area_music:pos2", {
	initial_properties = {
		visual = "cube",
		visual_size = { x = 1.05, y = 1.05, z = 1.05 },
		textures = {
			"area_music_pos2.png", "area_music_pos2.png", "area_music_pos2.png",
			"area_music_pos2.png", "area_music_pos2.png", "area_music_pos2.png",
		},
		physical = false,
		collide_with_objects = false,
		pointable = true,
		is_visible = true,
		static_save = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		selectionbox = { -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 },
	},
})
