#pragma once

// VlcPlayer — a libVLC-backed video/DVD engine exposed to GDScript.
//
// Owns a libVLC instance + media player, decodes into a CPU RGBA buffer via
// libVLC's video callbacks, and hands the latest frame to Godot as an
// ImageTexture (poll get_texture() after calling update_frame() each frame).
// For DVDs it opens dvd:// (dvdnav) so real disc menus render into the picture;
// menu navigation and chapter/title control are forwarded to libVLC.
//
// libVLC types are kept out of this header (handles stored as void*, callbacks
// declared with the raw C signatures) so RegisterTypes and other TUs need not
// see <vlc/vlc.h>.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace Xenu
{
class VlcPlayer : public godot::RefCounted
{
    GDCLASS(VlcPlayer, godot::RefCounted);

public:
    VlcPlayer();
    ~VlcPlayer();

    // Open a DVD image (VIDEO_TS folder or .iso) via dvd:// (menus), or a plain
    // media path when is_dvd is false. A string that already carries a URI
    // scheme ("http://", "rtsp://", "udp://", ...) is passed to libVLC verbatim
    // and is_dvd is ignored. Returns true on success -- but note that for a URL
    // that only means the MRL parsed: an unreachable host or a stream that never
    // decodes reports itself later through the "error" signal, not here.
    bool open(const godot::String &path, bool is_dvd = true);

    // Build the libVLC instance on a worker thread. The first open() in a process
    // does it inline, and it walks the whole plugin tree to do it -- 55 ms with
    // every plugin already in the OS file cache, seconds cold. Idempotent, and
    // safe to leave uncalled: open() still builds one, it just blocks.
    void warm_up();
    // False while warm_up() is still working. A caller that can wait (a tuner
    // showing static, say) should park its open() until this turns true; one that
    // cannot may call open() regardless and take the wait.
    bool is_ready() const;

    // Tear the player down with a time budget, for a node that is going away.
    //
    // The destructor cannot be bounded. libVLC 3 has no async stop, so
    // ~VlcPlayer() blocks in libvlc_media_player_stop for as long as that takes,
    // and on a source that has stopped answering (an unreachable tuner URL) that
    // is an unbounded block on whichever thread frees the object -- in this app,
    // the main thread during a room change.
    //
    // So the stop runs on a worker and the caller waits at most budget_ms for it.
    // Past that the player is ABANDONED: a reference is parked in a graveyard so
    // the object outlives the room, and the worker is left to finish whenever it
    // does. It must outlive it -- `this` is the opaque pointer libVLC hands back
    // to every video and audio callback, so freeing it while the media player is
    // still alive is a use-after-free, which is worse than the hitch. Abandoning
    // leaks the object, its libVLC instance and one thread for the process
    // lifetime; it mirrors Libretro::AbandonWrapper, for the same reason.
    //
    // Idempotent, and safe to skip: the destructor still tears down, unbounded.
    void shutdown(int budget_ms = 2000);

    void play();
    void pause();
    void stop();
    void set_paused(bool paused);
    bool is_playing() const;

    // Copy the most recently decoded frame into the texture. Call once per frame
    // from the owning node's _process; cheap when no new frame arrived.
    void update_frame();
    godot::Ref<godot::Texture2D> get_texture() const;
    godot::Vector2i get_video_size() const;

    // Pictures libVLC has delivered since this media was opened. Reset by
    // open()/stop(). A live source makes this climb every frame; a source that
    // has died mid-stream leaves it stuck while the last picture stays on the
    // texture, which is otherwise indistinguishable from a working still frame.
    int64_t get_frame_count() const;

    // DVD menu navigation (modes: activate=0,up=1,down=2,left=3,right=4,popup=5).
    void navigate(int mode);
    void menu_up();
    void menu_down();
    void menu_left();
    void menu_right();
    void menu_activate();
    void menu_popup();
    // Return to the disc's root menu (the "Menu" button). libVLC 3's navigate()
    // has no root-menu mode, so jump to the first menu-flagged title instead.
    void go_to_menu();

    void next_chapter();
    void prev_chapter();
    void set_chapter(int chapter);
    int get_chapter() const;
    int get_chapter_count() const;

    void set_title(int title);
    int get_title() const;
    int get_title_count() const;
    bool is_in_menu() const;

    double get_position() const;   // 0..1
    void set_position(double pos);
    int64_t get_length() const;    // ms
    int64_t get_time() const;      // ms
    void set_volume(int volume);   // 0..100 (libVLC internal gain)
    void set_rate(float rate);     // 1.0 = the media's own speed
    float get_rate() const;

    // Godot-routed audio: libVLC decodes to a PCM ring buffer here; the owner
    // pulls frames each _process into an AudioStreamGenerator on a 3D player, so
    // DVD sound is spatialised at the TV and follows Godot's volume/attenuation.
    int get_audio_rate() const;        // Hz (we request 48000)
    int get_audio_channels() const;    // channels (we request stereo = 2)
    // Pop up to max_frames stereo frames (L,R in -1..1); returns what was ready.
    godot::PackedVector2Array read_audio(int max_frames);

    // PCM libVLC has handed over and we have not served yet, in milliseconds.
    // This is occupancy, not latency: libVLC decodes audio far ahead of the play
    // dates it stamps on it, so a healthy stream sits near that run-ahead.
    int get_audio_backlog_ms() const;

    // How far ahead of its own play date the next sample we would serve is, in
    // milliseconds, and the figure read_audio steers that to. Setting it is how
    // the audio is dialled against the video path's own latency; see read_audio
    // for what the number means physically.
    int get_audio_lead_ms() const;
    int get_audio_lead_target_ms() const;
    void set_audio_lead_ms(int ms);

    // Audio-track + subtitle (spu) selection for the options panel. Each entry is
    // { "id": int, "name": String }; id -1 disables (subtitles off).
    godot::Array get_audio_tracks() const;
    int get_audio_track() const;
    void set_audio_track(int id);
    godot::Array get_subtitle_tracks() const;
    int get_subtitle() const;
    void set_subtitle(int id);

protected:
    static void _bind_methods();

private:
    void ensure_instance();
    void attach_events();
    void release_player();

    // libVLC video callbacks (raw C signatures matching the libvlc typedefs).
    static void *cb_lock(void *opaque, void **planes);
    static void cb_unlock(void *opaque, void *picture, void *const *planes);
    static void cb_display(void *opaque, void *picture);
    static unsigned cb_format(void **opaque, char *chroma, unsigned *width,
                              unsigned *height, unsigned *pitches, unsigned *lines);
    static void cb_cleanup(void *opaque);
    // End-of-media event → deferred "finished" signal.
    static void cb_event(const void *event, void *data);
    // libVLC audio callbacks (VLC-free signatures matching the typedefs).
    static void cb_audio_play(void *data, const void *samples, unsigned count, int64_t pts);
    static void cb_audio_flush(void *data, int64_t pts);

    void *m_vlc = nullptr;   // libvlc_instance_t*
    void *m_mp = nullptr;    // libvlc_media_player_t*

    // shutdown() has run. The destructor then has nothing left to block on.
    bool m_shutdown_started = false;

    // Instance construction, which warm_up() may be running on its own thread
    // while the main thread calls open(). m_instance_ready reports that the
    // attempt has finished, success or not -- a caller waiting on it must not be
    // left waiting by a libvlc_new that failed.
    std::thread m_warm_thread;
    std::mutex m_instance_mutex;
    std::atomic<bool> m_instance_ready{false};
    // Resolved once at construction: globalize_path is a Godot call, and the
    // warm thread must not make one.
    std::string m_plugin_path;

    mutable std::mutex m_mutex;
    std::vector<uint8_t> m_decode;   // VLC writes here (single plane, RGBA)
    godot::PackedByteArray m_shared; // last complete frame, mutex-guarded
    unsigned m_width = 0;
    unsigned m_height = 0;
    bool m_frame_dirty = false;
    bool m_size_dirty = false;
    int64_t m_frame_count = 0;   // pictures delivered since open(); see get_frame_count

    godot::Ref<godot::Image> m_image;
    godot::Ref<godot::ImageTexture> m_texture;

    // Audio PCM ring buffer (interleaved int16), filled on VLC's audio thread.
    mutable std::mutex m_audio_mutex;
    std::vector<int16_t> m_audio_ring;
    size_t m_audio_head = 0;
    size_t m_audio_tail = 0;
    size_t m_audio_count = 0;
    // Playback rate, kept because open() builds a new media player that would
    // otherwise start back at 1.0.
    float m_rate = 1.0f;

    int m_audio_rate = 48000;
    int m_audio_channels = 2;

    // Play-date bookkeeping, all read under m_audio_mutex. libVLC stamps every
    // PCM block with the time it should be heard, on the same clock the video
    // output schedules pictures against, so the two are directly comparable --
    // but only if we keep track of which sample is which. m_frames_out counts
    // frames that have left the head; the anchor is the newest block's play date
    // and the frame index it started at, so the play date of the sample now at
    // the head is one subtraction away no matter how much has been served.
    int64_t m_frames_out = 0;
    int64_t m_anchor_index = 0;
    int64_t m_anchor_pts = 0;
    bool m_pts_anchored = false;
    int m_audio_lead_ms = 40;
};
} // namespace Xenu
