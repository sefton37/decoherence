#include "register_types.h"

#include "stalag_chunk_mesher.h"
#include "stalag_flora.h"
#include "stalag_plan.h"
#include "stalag_trees.h"
#include "stalag_understory.h"
#include "stalag_wind.h"
#include "stalag_world.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_stalag_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(StalagWorld);
	GDREGISTER_CLASS(StalagChunkMesher);
	GDREGISTER_CLASS(StalagFlora);
	GDREGISTER_CLASS(StalagTrees);
	GDREGISTER_CLASS(StalagUnderstory);
	GDREGISTER_CLASS(StalagWind);
}

void uninitialize_stalag_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	stalag::shutdown_plan(); // the plan worker must not outlive the library
}

extern "C" {
GDExtensionBool GDE_EXPORT stalag_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_stalag_module);
	init_obj.register_terminator(uninitialize_stalag_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
