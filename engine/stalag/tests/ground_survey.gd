extends SceneTree
## SPDX-License-Identifier: AGPL-3.0-only
## Spec #551 phase 2 -- the world survey behind the ground fields. Walks every 0.5 m column of the
## +-112 m seed-7 world through the engine's own bound queries (surface_height, water_level_at,
## course_level_at, get_sf, spawn_feet_y), all of which already exist at the engine's HEAD, and dumps
## three arrays for tools/bake_ground_fields.mjs. It is the port of the design lab's survey script
## (same author, same licence). The frozen Stalag prototype (tag prototype-final) is the origin of
## the world these queries describe; nothing here changes the engine.
##
## Env: GFIELDS_SURVEY_DIR (required)  directory that receives height.f32, lake.i32, course.i32, meta.json
##
## height.f32   top-of-ground world y (m) per column, row-major (z rows, x columns), little-endian f32
## lake.i32     water level of the lake/spring plan per column (the dry sentinel when dry), i32
## course.i32   water level of the river/fall plan per column (the dry sentinel when dry), i32
## meta.json    {plan_hash, columns, half, sf, spawn_feet_y, dry}

const HALF := 224  # columns per side of the origin (0.5 m each) = 112 m


func _fail(msg: String) -> void:
	push_error("ground_survey: " + msg)
	quit(2)


func _initialize() -> void:
	var dir := OS.get_environment("GFIELDS_SURVEY_DIR")
	if dir.is_empty() or not ClassDB.class_exists("StalagWorld"):
		_fail("GFIELDS_SURVEY_DIR is required and StalagWorld must be loaded")
		return
	StalagWorld.start_plan()
	while StalagWorld.plan_status() == 1:
		OS.delay_msec(20)
	if StalagWorld.plan_status() != 2:
		_fail("plan solve failed: " + StalagWorld.plan_error())
		return
	var n := HALF * 2
	var sf := StalagWorld.get_sf()
	var hb := PackedFloat32Array()
	hb.resize(n * n)
	var wl := PackedInt32Array()
	wl.resize(n * n)
	var cl := PackedInt32Array()
	cl.resize(n * n)
	for j in range(n):
		var gz := j - HALF
		for i in range(n):
			var gx := i - HALF
			var cx := (gx * 0.5 + 0.25) / sf
			var cz := (gz * 0.5 + 0.25) / sf
			var h := StalagWorld.surface_height(cx, cz)
			hb[j * n + i] = (floor(h / 4.0) * 4.0 + 2.0) * sf  # the terrace the column's cap sits on
			wl[j * n + i] = StalagWorld.water_level_at(gx, gz)
			cl[j * n + i] = StalagWorld.course_level_at(gx, gz)
	DirAccess.make_dir_recursive_absolute(dir)
	for pair in [["height.f32", hb.to_byte_array()], ["lake.i32", wl.to_byte_array()], ["course.i32", cl.to_byte_array()]]:
		var f := FileAccess.open(dir.path_join(pair[0]), FileAccess.WRITE)
		f.store_buffer(pair[1])
		f.close()
	var meta := {"plan_hash": StalagWorld.plan_hash(), "columns": n * n, "half": HALF, "sf": sf,
		"spawn_feet_y": StalagWorld.spawn_feet_y(), "dry": StalagWorld.water_dry_sentinel()}
	var fm := FileAccess.open(dir.path_join("meta.json"), FileAccess.WRITE)
	fm.store_string(JSON.stringify(meta))
	fm.close()
	print("GROUND_SURVEY_DONE columns=%d plan_hash=%s" % [n * n, StalagWorld.plan_hash()])
	quit(0)
