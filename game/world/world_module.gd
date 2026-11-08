extends RefCounted
## Spec #501 `world` module launcher (frontdoor shell -> `world`).
##
## Deliberately engine-free: this script never names an engine class, so it parses and
## runs on a machine where the Stalag GDExtension has not been built. The shell asks
## available() first and prints an in-register failure line instead of crashing; only
## when the engine is present does instantiate_world() load the world scene (whose
## scripts do name the engine classes and would fail to parse without it).

const WORLD_SCENE_PATH := "res://game/world/world.tscn"


## True when the engine module's classes are registered (the library was built and loaded).
static func available() -> bool:
	return ClassDB.class_exists("StalagWorld") and ClassDB.class_exists("StalagChunkMesher")


## Instantiates the world scene, or returns null when the engine is missing.
static func instantiate_world() -> Node:
	if not available():
		return null
	var packed: PackedScene = load(WORLD_SCENE_PATH)
	if packed == null:
		return null
	return packed.instantiate()
