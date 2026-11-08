extends Node
func _ready() -> void:
	var bad := 0
	var n := 0
	for p in OS.get_cmdline_user_args():
		n += 1
		var s = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
		if s == null or not (s is GDScript) or not (s as GDScript).can_instantiate():
			bad += 1
			print("NOFAB_BAD ", p)
	print("NOFAB_RESULT scripts=%d bad=%d" % [n, bad])
	get_tree().quit(0 if bad == 0 else 1)
