#include <godot_cpp/core/class_db.hpp>

#include "rl_bindings.h"

using namespace godot;

extern "C" {

GDExtensionBool GDE_EXPORT rl_core_library_init(GDExtensionInterfaceGetProcAddress p_get_proc,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc, p_library, r_initialization);
	init_obj.register_initializer([](ModuleInitializationLevel p_level) -> void {
		if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
		register_rl_core_types();
	});
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
