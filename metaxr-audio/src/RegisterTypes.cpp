#include "MetaXRAudioServer.hpp"
#include "MetaXRAudioStream.hpp"

#include <gdextension_interface.h>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

namespace
{
Xenu::MetaXRAudioServer* g_server = nullptr;
}

void initialize_metaxr_audio(ModuleInitializationLevel p_level)
{
    if (p_level != ModuleInitializationLevel::MODULE_INITIALIZATION_LEVEL_SCENE)
        return;

    ClassDB::register_class<Xenu::MetaXRAudioPlayback>();
    ClassDB::register_class<Xenu::MetaXRAudioStream>();
    ClassDB::register_internal_class<Xenu::MetaXRAudioMixer>();
    ClassDB::register_class<Xenu::MetaXRAudioServer>();

    // Exposed to GDScript as `MetaXRAudio`. The constructor tries to load the
    // native library and returns cleanly if it cannot, so the singleton always
    // exists and callers branch on is_available().
    g_server = memnew(Xenu::MetaXRAudioServer);
    Engine::get_singleton()->register_singleton("MetaXRAudio", g_server);
}

void uninitialize_metaxr_audio(ModuleInitializationLevel p_level)
{
    if (p_level != ModuleInitializationLevel::MODULE_INITIALIZATION_LEVEL_SCENE)
        return;

    if (g_server)
    {
        Engine::get_singleton()->unregister_singleton("MetaXRAudio");
        memdelete(g_server);
        g_server = nullptr;
    }
}

extern "C"
{
GDExtensionBool GDE_EXPORT metaxr_audio_library_init(GDExtensionInterfaceGetProcAddress p_gde_get_proc_address,
                                                     const GDExtensionClassLibraryPtr p_library,
                                                     GDExtensionInitialization* r_initialization)
{
    godot::GDExtensionBinding::InitObject init_obj(p_gde_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_metaxr_audio);
    init_obj.register_terminator(uninitialize_metaxr_audio);
    init_obj.set_minimum_library_initialization_level(godot::ModuleInitializationLevel::MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
