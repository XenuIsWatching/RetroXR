#pragma once

// Binding for the Meta XR Audio SDK v85 native C API (the `mxra_*` symbols in
// MetaXRAudioUnity.dll / libMetaXRAudioUnity.so).
//
// Meta ships no headers for this API and no reference documentation. Every
// declaration below was reconstructed from the shipped binaries:
//   - the Windows DLL exports MSVC-mangled C++ entry points, and MSVC mangling
//     encodes full parameter types, so `undname.exe` recovers the type vocabulary
//   - the Android .so retains Itanium-mangled internals (llvm-cxxfilt)
//   - the `mxra_*` C entry points themselves were disassembled to fix arity,
//     argument order and which pointers are optional
//
// The `mxra_*` set is 103 symbols and is byte-identical between the Windows and
// Android binaries, which is what makes it the right binding target: the
// `ovrAudio_*` exports are mangled differently per platform and are internal.
// Structurally this API is the index-based v47 design under new names, so the
// published v47 reference describes its semantics even though it does not
// describe these names.
//
// Everything uncertain is confined to this file. Nothing here is guaranteed by
// Meta; the SDK is feature-frozen as of v85 (2026-02-10). Treat a non-zero
// mxra_result at load or init as "fall back to the engine's own panning", never
// as an assertion failure.

#include <cstdint>
#include <type_traits>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace MetaXRAudio
{

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

struct mxra_context;

// Observed return codes. 0 is success; 2001/2005 are emitted by the argument
// validation prologues of every entry point (null handle, out-of-range source
// index, uninitialised context). The full enum is not recoverable, so treat any
// non-zero value as failure rather than switching on it.
enum mxra_result : uint32_t
{
    MXRA_SUCCESS          = 0,
    MXRA_INVALID_PARAM    = 2001,
    MXRA_INVALID_CONTEXT  = 2005,
};

/// A 3-component vector, passed BY VALUE wherever the API takes one.
///
/// This matters more than it looks. It is a 3-member homogeneous float aggregate,
/// and the two ABIs disagree about how such a thing is passed: Windows x64 hands
/// it over by hidden pointer, while AAPCS64 puts it in s0/s1/s2. Declaring it by
/// value lets each compiler apply its own rule. Hard-coding a pointer is correct
/// on Windows and silently spatialises garbage on arm64.
struct mxra_vector_3f
{
    float x, y, z;
};

/// Listener/source pose. mxra_listener_set_pose validates exactly nine floats at
/// offsets 0x00..0x20 and rejects any non-finite component, which fixes both the
/// layout and the element count. Maps onto a Godot Transform3D as
/// { origin, -basis.z, basis.y } — Godot looks down -Z, this API wants +forward.
///
/// Also passed by value, but at 36 bytes it exceeds both ABIs' register
/// thresholds, so both pass it indirectly and a pointer happened to work.
struct mxra_pose
{
    mxra_vector_3f position;
    mxra_vector_3f forward;
    mxra_vector_3f up;
};
static_assert(sizeof(mxra_pose) == 36, "mxra_listener_set_pose validates nine floats");

/// Context parameters. Accepted by both mxra_context_create (as an optional
/// second argument — passing null creates an uninitialised context) and
/// mxra_context_init, which is the same code path: create() forwards straight to
/// ovrAudio_InitializeContext.
///
/// Every field and bound below was read off mxra_context_init's validation chain,
/// which rejects with MXRA_INVALID_PARAM before touching anything else. Note this
/// is NOT the v47 ovrAudioContextConfiguration: `size` is 32-bit, not 64-bit, and
/// there is no `provider` field.
///
/// `buffer_length` is the fixed block size for the whole context — mxra_source_process
/// takes no frame count and reads it from here instead.
struct mxra_context_params
{
    uint32_t size;             ///< [0x00] must be exactly sizeof(mxra_context_params) == 28
    uint32_t max_num_sources;  ///< [0x04] >= 1
    uint32_t sample_rate;      ///< [0x08] 16000 .. 48000 inclusive
    uint32_t buffer_length;    ///< [0x0c] 128 .. 65536, and must be <= sample_rate
    uint32_t flags;            ///< [0x10] read as a byte; bit 4 forces a mutex re-create. 0 is fine.
    uint32_t mode;             ///< [0x14] must be <= 8. 0 is the default renderer.
    uint32_t reserved;         ///< [0x18] not validated; keep zero.
};
static_assert(sizeof(mxra_context_params) == 28, "mxra_context_init rejects any size but 28");

/// Second argument of mxra_source_process: interleaved stereo vs planar L|R.
enum mxra_output_layout : int32_t
{
    MXRA_OUTPUT_PLANAR_LR   = 0,  ///< out[0..n) = L, out[n..2n) = R
    MXRA_OUTPUT_INTERLEAVED = 1,  ///< out[2i] = L, out[2i+1] = R
};

/// Shoebox room parameters. Layout read off mxra_shoebox_set_params' validation
/// chain: it rejects anything whose `size` is not 0x90, then range-checks the
/// three dimensions. The 96-byte material block matches the packing Meta's own
/// Unity C# documents -- six walls (right, left, ceiling, floor, front, back),
/// four frequency-dependent reflection coefficients each, in increasing
/// frequency order.
struct mxra_shoebox_params
{
    uint32_t size;              ///< [0x00] must be exactly 144 (0x90)
    uint32_t reserved0;         ///< [0x04]
    float    materials[24];     ///< [0x08] 6 walls x 4 bands, each 0..1
    float    width;             ///< [0x68] metres, > 0
    float    height;            ///< [0x6c] metres, > 0
    float    depth;             ///< [0x70] metres, > 0
    float    position[3];       ///< [0x74] room centre
    float    clutter[4];        ///< [0x80] per-band clutter, 0..1
};
static_assert(sizeof(mxra_shoebox_params) == 144, "mxra_shoebox_set_params rejects any size but 144");

/// Context-wide toggles. Values lifted verbatim from the shipped Unity C#
/// (`Runtime/scripts/MetaXRAudioNativeInterface.cs`, `enum EnableFlag`), which is
/// the one part of this API Meta documents.
enum mxra_feature : int32_t
{
    MXRA_FEATURE_SIMPLE_ROOM_MODELING = 2,
    MXRA_FEATURE_LATE_REVERBERATION   = 3,
    MXRA_FEATURE_RANDOMIZE_REVERB     = 4,
    MXRA_FEATURE_PERFORMANCE_COUNTERS = 5,
};

/// Per-source feature bits, for mxra_source_set_feature. A bit mask rather than
/// an index, unlike mxra_feature above.
///
/// Sources are omnidirectional until directivity is switched on: with the bit
/// clear, turning a source to face away from the listener changes the rendered
/// output by 0.000 dB. With it set, the same turn measures 17.7 dB down at full
/// intensity, so the facing in mxra_source_set_pose is only consulted once this
/// is on. Both figures measured against the shipped library.
enum mxra_source_feature : int32_t
{
    MXRA_SOURCE_ENABLE_DIRECTIVITY = 0x0400,
};

/// Per-source float parameters, for mxra_source_set_param. 0..1; scales how
/// sharply the directivity pattern above cuts as a source turns away.
/// mxra_source_set_directivity_pattern is NOT exported by the shipped library,
/// so the pattern itself cannot be chosen -- this is the only control over it.
enum mxra_source_param : int32_t
{
    MXRA_SOURCE_PARAM_DIRECTIVITY_INTENSITY = 8,
};

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

extern "C"
{
    // Returns a version string; each out-pointer is optional. v85 reports 1.117.0.
    // Cheap and unambiguous — call it first to prove the library actually loaded.
    typedef const char* (*PFN_mxra_get_version)(int32_t* major, int32_t* minor, int32_t* patch);

    typedef mxra_result (*PFN_mxra_context_create)(mxra_context** out_ctx, const mxra_context_params* params);
    typedef mxra_result (*PFN_mxra_context_init)(mxra_context* ctx, const mxra_context_params* params);
    typedef mxra_result (*PFN_mxra_context_shutdown)(mxra_context* ctx);
    typedef mxra_result (*PFN_mxra_context_destroy)(mxra_context* ctx);
    typedef mxra_result (*PFN_mxra_context_get_max_source_count)(mxra_context* ctx, uint32_t* out_count);
    typedef mxra_result (*PFN_mxra_context_set_feature)(mxra_context* ctx, mxra_feature feature, int32_t enabled);
    typedef mxra_result (*PFN_mxra_context_set_param)(mxra_context* ctx, int32_t param, float value);

    typedef mxra_result (*PFN_mxra_listener_set_pose)(mxra_context* ctx, mxra_pose pose);

    typedef mxra_result (*PFN_mxra_source_set_pose)(mxra_context* ctx, int32_t index, mxra_pose pose);

    /// By value — see mxra_vector_3f. Passing a pointer here is correct on
    /// Windows and wrong on arm64, where the callee reads s0/s1/s2 (visible in
    /// the shipped .so as `fabs s3, s0` / `fabs s3, s2` right after the index
    /// bounds check) and would otherwise spatialise whatever those registers
    /// happened to hold.
    typedef mxra_result (*PFN_mxra_source_set_position)(mxra_context* ctx, int32_t index, mxra_vector_3f position);
    typedef mxra_result (*PFN_mxra_source_set_param)(mxra_context* ctx, int32_t index, int32_t param, float value);
    typedef mxra_result (*PFN_mxra_source_set_feature)(mxra_context* ctx, int32_t index, int32_t feature, int32_t enabled);
    typedef mxra_result (*PFN_mxra_source_set_attenuation)(mxra_context* ctx, int32_t index, int32_t mode, float min_range, float max_range);
    typedef mxra_result (*PFN_mxra_source_reset)(mxra_context* ctx, int32_t index);

    /// The spatializer. Mono in, stereo out, one source per call.
    ///
    /// Frame count is NOT a parameter — it is the context's buffer_length.
    /// `out_status` and `in_mono` are both optional (null-checked); `out` is not.
    /// Argument order was read off the disassembly: arg2 receives a status word,
    /// arg3 is the input, arg4 the output.
    typedef mxra_result (*PFN_mxra_source_process)(mxra_context* ctx,
                                                   int32_t index,
                                                   uint32_t* out_status,
                                                   const float* in_mono,
                                                   float* out,
                                                   mxra_output_layout layout);

    /// Global reverb tail. The v85 engine has no per-source tail flush; reflections
    /// and late reverb accumulate into one shared bus that is mixed in once per
    /// block, after every source has been processed.
    typedef mxra_result (*PFN_mxra_context_mix_in_shared_reverb_lr)(mxra_context* ctx, uint32_t* out_status, float* out_left, float* out_right);
    typedef mxra_result (*PFN_mxra_context_reset_shared_reverb)(mxra_context* ctx);

    typedef mxra_result (*PFN_mxra_shoebox_set_params)(mxra_context* ctx, const mxra_shoebox_params* params);
}

/// Resolved entry points. Any member may be null if the symbol was missing —
/// check `loaded` before use.
struct ABI
{
    PFN_mxra_get_version                     get_version                 = nullptr;
    PFN_mxra_context_create                  context_create              = nullptr;
    PFN_mxra_context_init                    context_init                = nullptr;
    PFN_mxra_context_shutdown                context_shutdown            = nullptr;
    PFN_mxra_context_destroy                 context_destroy             = nullptr;
    PFN_mxra_context_get_max_source_count    context_get_max_source_count = nullptr;
    PFN_mxra_context_set_feature             context_set_feature         = nullptr;
    PFN_mxra_context_set_param               context_set_param           = nullptr;
    PFN_mxra_listener_set_pose               listener_set_pose           = nullptr;
    PFN_mxra_source_set_pose                 source_set_pose             = nullptr;
    PFN_mxra_source_set_position             source_set_position         = nullptr;
    PFN_mxra_source_set_param                source_set_param            = nullptr;
    PFN_mxra_source_set_feature              source_set_feature          = nullptr;
    PFN_mxra_source_set_attenuation          source_set_attenuation      = nullptr;
    PFN_mxra_source_reset                    source_reset                = nullptr;
    PFN_mxra_source_process                  source_process              = nullptr;
    PFN_mxra_context_mix_in_shared_reverb_lr mix_in_shared_reverb_lr     = nullptr;
    PFN_mxra_context_reset_shared_reverb     reset_shared_reverb         = nullptr;
    PFN_mxra_shoebox_set_params              shoebox_set_params          = nullptr;

    void* handle = nullptr;
    bool  loaded = false;
};

inline void* SymbolLookup(void* handle, const char* name)
{
#if defined(_WIN32)
    return reinterpret_cast<void*>(GetProcAddress(static_cast<HMODULE>(handle), name));
#else
    return dlsym(handle, name);
#endif
}

/// Loads the library and resolves every entry point. Returns false and leaves
/// `abi.loaded` false if the library is absent or any required symbol is missing,
/// which is the signal for callers to use the engine's built-in panning instead.
inline bool Load(ABI& abi, const char* library_path)
{
#if defined(_WIN32)
    abi.handle = static_cast<void*>(LoadLibraryA(library_path));
#else
    abi.handle = dlopen(library_path, RTLD_LAZY | RTLD_LOCAL);
#endif
    if (!abi.handle)
        return false;

    bool ok = true;
    auto bind = [&](auto& fn, const char* name)
    {
        void* sym = SymbolLookup(abi.handle, name);
        if (!sym)
            ok = false;
        fn = reinterpret_cast<std::decay_t<decltype(fn)>>(sym);
    };

    bind(abi.get_version,                  "mxra_get_version");
    bind(abi.context_create,               "mxra_context_create");
    bind(abi.context_init,                 "mxra_context_init");
    bind(abi.context_shutdown,             "mxra_context_shutdown");
    bind(abi.context_destroy,              "mxra_context_destroy");
    bind(abi.context_get_max_source_count, "mxra_context_get_max_source_count");
    bind(abi.context_set_feature,          "mxra_context_set_feature");
    bind(abi.context_set_param,            "mxra_context_set_param");
    bind(abi.listener_set_pose,            "mxra_listener_set_pose");
    bind(abi.source_set_pose,              "mxra_source_set_pose");
    bind(abi.source_set_position,          "mxra_source_set_position");
    bind(abi.source_set_param,             "mxra_source_set_param");
    bind(abi.source_set_feature,           "mxra_source_set_feature");
    bind(abi.source_set_attenuation,       "mxra_source_set_attenuation");
    bind(abi.source_reset,                 "mxra_source_reset");
    bind(abi.source_process,               "mxra_source_process");
    bind(abi.mix_in_shared_reverb_lr,      "mxra_context_mix_in_shared_reverb_lr");
    bind(abi.reset_shared_reverb,          "mxra_context_reset_shared_reverb");
    bind(abi.shoebox_set_params,           "mxra_shoebox_set_params");

    abi.loaded = ok;
    return ok;
}

inline void Unload(ABI& abi)
{
    if (!abi.handle)
        return;
#if defined(_WIN32)
    FreeLibrary(static_cast<HMODULE>(abi.handle));
#else
    dlclose(abi.handle);
#endif
    abi = ABI{};
}

} // namespace MetaXRAudio
