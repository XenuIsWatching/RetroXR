#pragma once

#include "../external/metaxraudio/MetaXRAudioABI.hpp"

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/audio_stream_player.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

namespace Xenu
{

class MetaXRAudioStream;

/// One spatialised mono voice. Audio is pushed from whichever thread produced it
/// (emulation thread, VLC thread, main thread) and consumed on the audio thread,
/// so the ring is a lock-free SPSC queue and the pose is published through a
/// seqlock. A mutex here would be a priority inversion against the audio thread.
struct Voice
{
    static constexpr uint32_t kRingFrames = 1 << 15;   ///< 32768 frames, ~0.68 s at 48 kHz

    std::atomic<bool>     active{false};
    std::atomic<bool>     retiring{false};   ///< set by the main thread, cleared by the mixer once flushed

    /// Whether the owner has described this voice yet. Claiming a slot and
    /// entering the mix are separate events: CreateVoice hands back an id, and
    /// the owner sets a position, a gain and a directivity afterwards — from
    /// another thread, in the libretro case, a frame or more later. Every
    /// default below is wrong for a voice nobody has described (full gain, the
    /// world origin, omnidirectional), so the mixer must not render one until
    /// its first pose lands. Set by SetVoicePosition / SetVoicePose: a source
    /// with no position cannot be spatialised, which makes that the moment the
    /// voice becomes renderable.
    std::atomic<bool>     ready{false};

    std::vector<float>    ring;
    std::atomic<uint32_t> write_pos{0};
    std::atomic<uint32_t> read_pos{0};

    // Seqlock-published pose. Odd sequence = a write is in progress. Facing is
    // carried alongside the position because the SDK takes them together, and
    // only matters once directivity is on.
    std::atomic<uint32_t> pose_seq{0};
    float                 pose[3] = { 0.0f, 0.0f, 0.0f };
    float                 forward[3] = { 0.0f, 0.0f, -1.0f };
    float                 up[3] = { 0.0f, 1.0f, 0.0f };

    std::atomic<float>    gain{1.0f};

    /// 0 disables directivity and makes the source omnidirectional, which is how
    /// the SDK starts every source. Above 0 the facing above starts to matter.
    std::atomic<float>    directivity{0.0f};

    /// Last position actually handed to the SDK, so the mixer can skip redundant
    /// calls. Purely an optimisation: mxra_source_set_position takes a recursive
    /// mutex like the rest of the context API, and most emitters here rewrite a
    /// position that has not moved every single frame.
    ///
    /// It was originally added as a correctness workaround for what looked like an
    /// arm64 defect. That turned out to be our own ABI error (the position is
    /// passed by value, so it goes in s0/s1/s2 on AArch64, not behind a pointer);
    /// redundant calls are harmless once the signature is right. Kept because the
    /// saved lock is still worth having.
    float                 last_sent[3] = { 1e30f, 1e30f, 1e30f };
    float                 last_forward[3] = { 1e30f, 1e30f, 1e30f };
    float                 last_directivity = -1.0f;
    bool                  ever_sent = false;

    Voice() : ring(kRingFrames, 0.0f) {}

    uint32_t Available() const   ///< frames waiting to be mixed
    {
        return write_pos.load(std::memory_order_acquire) - read_pos.load(std::memory_order_relaxed);
    }
    uint32_t Space() const       ///< frames that can still be pushed
    {
        return kRingFrames - Available() - 1;
    }
};

/// Owns the Meta XR Audio context and the single output player everything mixes
/// into. Registered as an Engine singleton so GDScript reaches it as
/// `MetaXRAudio`.
///
/// Deliberately not a Node: it has no per-frame work of its own. The listener
/// pose is pushed in from whatever script owns the XR camera.
class MetaXRAudioServer : public godot::Object
{
    GDCLASS(MetaXRAudioServer, godot::Object)

public:
    static constexpr int      kMaxVoices    = 32;
    static constexpr uint32_t kBlockFrames  = 256;

    /// Default queue depth producers aim for: 2048 frames, ~43 ms at 48 kHz.
    ///
    /// This is the dominant term in the whole latency budget -- the SDK itself
    /// measures at 0.15-0.6 ms, so everything else is our choice. It is a
    /// straight trade against underruns: producers refill from _process, so the
    /// queue has to survive the longest main-thread stall the app suffers. At a
    /// steady 72 Hz a frame is 13.9 ms and 43 ms is comfortable; if the frame
    /// rate collapses the queue has to cover the longer gap or the stream
    /// clicks. Tunable at runtime via set_target_latency_ms, and
    /// get_underrun_count() says whether the current value is holding.
    static constexpr uint32_t kDefaultTargetFill = 2048;

    MetaXRAudioServer();
    ~MetaXRAudioServer();

    static MetaXRAudioServer* GetSingleton() { return s_singleton; }

    /// False when the native library is missing or refused to initialise, which
    /// is the signal for callers to fall back to AudioStreamPlayer3D. A frozen,
    /// undocumented dependency must never be able to stop the app starting.
    /// Triggers initialisation on first call. Deliberately lazy: the AudioServer
    /// singleton does not exist yet at MODULE_INITIALIZATION_LEVEL_SCENE, so
    /// reading the mix rate from the constructor dereferences null and takes the
    /// whole engine down before any script runs.
    bool IsAvailable();

    /// Whether anything CHOOSING a backend should pick this one. Turning it off
    /// makes IsAvailable report false, so the next thing to choose takes Godot's
    /// own panning instead -- which is what the desktop switch between the two
    /// is built on.
    ///
    /// Deliberately not a shutdown. Voices already bound keep playing, because
    /// the libretro audio handler owns its pair and picks its backend when a
    /// core boots; pulling them mid-game would silence it. So a running emulator
    /// keeps what it started with and everything else swaps over at once.
    void SetEnabled(bool enabled);
    bool IsEnabled() const { return m_enabled; }

    /// Ignores the enable flag: the mixer has to keep serving voices that are
    /// still playing through it. Only reached once initialisation has happened,
    /// so unlike IsAvailable it does not trigger any.
    bool IsRunning() const { return m_available; }

    /// Set before Shutdown() touches anything, so the audio thread can bail out
    /// of _mix while the context is still alive. m_available is a plain bool
    /// written on the main thread and is not safe to race on.
    bool IsShuttingDown() const { return m_shutting_down.load(std::memory_order_acquire); }

    godot::String GetVersion();
    godot::String GetLastError();

    void SetListenerTransform(const godot::Transform3D& xform);

    /// Shoebox room reverb. `size` is the room's full extent in metres and
    /// `centre` its middle; `reflectivity` is 0 (dead) to 1 (bare hard walls),
    /// applied to all six surfaces and all four bands. Enables the SDK's simple
    /// room modelling and late reverb the first time it is called.
    void SetRoom(const godot::Vector3& size, const godot::Vector3& centre, float reflectivity, float clutter);
    void ClearRoom();

    int  CreateVoice();
    void DestroyVoice(int id);
    void SetVoicePosition(int id, const godot::Vector3& pos);
    /// Position and facing together, for a source that has been given
    /// directivity. `forward` is the direction the thing radiates towards.
    void SetVoicePose(int id, const godot::Vector3& pos, const godot::Vector3& forward,
                      const godot::Vector3& up);
    /// 0 leaves the source omnidirectional, which is how the SDK starts it and
    /// what every source here was until now. Above 0 the facing given to
    /// SetVoicePose starts to attenuate the source as it turns away: at 1.0 the
    /// difference between facing the listener and facing away measures 17.7 dB,
    /// which is far more than a small speaker in a plastic shell manages, so
    /// callers should expect to want a fraction of it.
    void SetVoiceDirectivity(int id, float intensity);
    void SetVoiceGain(int id, float gain);
    int  VoiceFramesAvailable(int id) const;
    int  VoiceSpace(int id) const;
    /// How many frames a producer should push right now to sit at the target
    /// fill level, rather than however much room the ring happens to have.
    ///
    /// This distinction is the whole latency story. The existing GDScript pumps
    /// call get_frames_available() and push that much, which keeps Godot's
    /// generator permanently full — 250 ms of queued audio for the VLC players.
    /// Queue depth *is* latency, so filling a big buffer to the brim is the
    /// worst thing a producer can do. Push to this instead and the queue stays
    /// at kTargetFillFrames regardless of how large the ring is.
    int  VoiceFramesWanted(int id) const;

    /// Queue depth aimed for, in milliseconds. Lower is tighter but underruns
    /// sooner; watch get_underrun_count() after changing it.
    void  SetTargetLatencyMs(float ms);
    float GetTargetLatencyMs() const;
    /// Blocks where a voice had less than a full block queued. Non-zero means
    /// the target is too low for this device's frame pacing.
    int   GetUnderrunCount() const;
    /// Diagnostics: how much work the mixer actually did.
    godot::Dictionary GetMixStats() const;
    void  ResetUnderrunCount();
    void PushVoiceFrames(int id, const godot::PackedFloat32Array& frames);
    /// Deinterleaves a stereo buffer into two voices in one call, so the common
    /// "device with left and right speakers" case does not pay two Variant
    /// marshals per audio block.
    void PushStereoFrames(int left_id, int right_id, const godot::PackedVector2Array& frames,
                          int src_mode = 0);
    void FlushVoice(int id);

    int  GetActiveVoiceCount() const;

    /// Stops and frees the output player. EnsurePlayer builds a new one the next
    /// time a voice is created, so this is a pause in the mix rather than an end
    /// to it. Driven by MetaXRAudioMixer, which explains the timing.
    void ReleaseMixer();

    /// Releases the mixer while the main loop still has a frame left to run,
    /// which is the only window in which the playback can be handed back safely.
    /// See the definition for the shutdown ordering this exists to beat.
    void PrepareForQuit();

    /// Renders `frames` of the mix synchronously, bypassing the audio device.
    /// Godot's headless mode uses the dummy audio driver and never calls _mix,
    /// so this is the only way to test the mixer in a headless probe.
    godot::PackedVector2Array RenderOffline(int frames);

    // --- audio thread ---
    /// Mixes into an interleaved stereo buffer. Called from AudioStreamPlayback.
    void MixInto(float* out_interleaved, int frames);

protected:
    static void _bind_methods();

private:
    bool Initialise();
    void EnsureInitialised();
    void Shutdown();
    void EnsurePlayer();
    bool m_room_enabled = false;
    void ProcessBlock(float* out_interleaved);   ///< exactly kBlockFrames

    static MetaXRAudioServer* s_singleton;

    MetaXRAudio::ABI          m_abi;
    MetaXRAudio::mxra_context* m_ctx = nullptr;
    bool                      m_available = false;
    bool                      m_quit_prepared = false;
    std::atomic<bool>         m_shutting_down{false};
    bool                      m_enabled = true;
    bool                      m_init_done = false;
    godot::String             m_version;
    godot::String             m_last_error;

    std::unique_ptr<Voice>    m_voices[kMaxVoices];

    // Listener pose, seqlock-published from the main thread.
    std::atomic<uint32_t>     m_listener_seq{0};
    MetaXRAudio::mxra_pose    m_listener{};

    // Block adapter: the SDK renders a fixed block, Godot asks for arbitrary
    // frame counts, so whole blocks are produced and the remainder carried over.
    std::vector<float>        m_block;        ///< kBlockFrames * 2, interleaved
    std::vector<float>        m_scratch_mono; ///< kBlockFrames
    std::vector<float>        m_scratch_out;  ///< kBlockFrames * 2
    uint32_t                  m_block_used = kBlockFrames;   ///< starts drained
    std::atomic<uint32_t>     m_target_fill{kDefaultTargetFill};
    std::atomic<uint32_t>     m_underruns{0};
    std::atomic<uint64_t>     m_mix_calls{0};
    std::atomic<uint64_t>     m_mix_frames{0};
    std::atomic<uint64_t>     m_blocks{0};
    std::atomic<uint64_t>     m_proc_ok{0};
    std::atomic<uint64_t>     m_proc_fail{0};

    /// The mixer node is parented to the scene root, so the SceneTree owns it and
    /// destroys it at shutdown before this server tears down. A raw pointer then
    /// dangles and is_inside_tree() faults inside Godot; held by id, a freed node
    /// simply resolves to null.
    godot::AudioStreamPlayer* LivePlayer() const;
    uint64_t m_player_id = 0;
    godot::Ref<MetaXRAudioStream> m_stream;
};

} // namespace Xenu
