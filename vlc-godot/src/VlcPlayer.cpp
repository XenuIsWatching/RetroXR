#include "VlcPlayer.hpp"

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <vlc/vlc.h>

#ifdef __ANDROID__
#include <godot_cpp/classes/java_class_wrapper.hpp>
#include <godot_cpp/classes/java_class.hpp>
#endif

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>

using namespace godot;

namespace Xenu
{

static void set_plugin_path_env(const char *path)
{
#ifdef _WIN32
    _putenv_s("VLC_PLUGIN_PATH", path);
#else
    setenv("VLC_PLUGIN_PATH", path, 1);
#endif
}

#ifdef __ANDROID__
// libvlc_new() aborts the whole process (assert s_jvm != NULL in libVLC's
// android/specific.c) unless libvlc.so's JNI_OnLoad has run — and Godot loads
// GDExtension dependencies with dlopen, which never calls JNI_OnLoad. Route a
// Java System.loadLibrary("vlc") through JavaClassWrapper instead: the managed
// caller frame under a Godot callback is GodotLib.step, whose classloader is
// the app's, so ART resolves libvlc.so from the APK's native lib dir, notices
// it is already loaded, and runs its JNI_OnLoad — handing libVLC the JavaVM.
static bool ensure_android_jvm()
{
    static bool s_done = false;
    if (s_done)
        return true;
    JavaClassWrapper *jcw = JavaClassWrapper::get_singleton();
    if (!jcw)
    {
        UtilityFunctions::push_error("VlcPlayer: JavaClassWrapper unavailable");
        return false;
    }
    Ref<JavaClass> system_class = jcw->wrap("java.lang.System");
    if (system_class.is_null())
    {
        UtilityFunctions::push_error("VlcPlayer: could not wrap java.lang.System");
        return false;
    }
    system_class->call("loadLibrary", "vlc");
    s_done = true;
    return true;
}
#endif

VlcPlayer::VlcPlayer()
{
    // Four seconds of stereo headroom. Not for stall tolerance -- it has to
    // outrun libVLC's decoder, which hands over PCM up to two seconds before its
    // play date. A two-second ring is exactly lapped by that, and the wrap
    // overwrites the very samples that are next to be served.
    m_audio_ring.assign((size_t)m_audio_rate * m_audio_channels * 4, 0);

    // Here rather than in ensure_instance: this runs on Godot's thread, and
    // ensure_instance may not.
    const String plugins = ProjectSettings::get_singleton()->globalize_path("res://vlc-godot/plugins");
    m_plugin_path = plugins.utf8().get_data();
}

VlcPlayer::~VlcPlayer()
{
    // A libvlc_new in flight owns members of this object.
    if (m_warm_thread.joinable())
        m_warm_thread.join();
    // Normally a no-op: shutdown() has already stopped and released the player,
    // so this only runs unbounded for an owner that never called it.
    release_player();
    if (m_vlc)
    {
        libvlc_release(static_cast<libvlc_instance_t *>(m_vlc));
        m_vlc = nullptr;
    }
}

namespace
{
// Players whose stop outran its budget. Holding a Ref keeps the object -- and so
// the opaque pointer libVLC's callbacks still carry -- alive for the process
// lifetime. Only ever touched on the thread that calls shutdown().
std::vector<godot::Ref<Xenu::VlcPlayer>> s_abandoned;
} // namespace

void VlcPlayer::shutdown(int budget_ms)
{
    if (m_shutdown_started)
        return;
    m_shutdown_started = true;

    // Building the instance is a local plugin-tree walk with no network in it, so
    // this join is bounded in practice -- and it has to happen before the stop:
    // the worker below writes m_vlc.
    if (m_warm_thread.joinable())
        m_warm_thread.join();
    if (!m_mp)
        return;

    // The worker holds no reference: either we wait it out below, or the
    // graveyard takes one, so `this` outlives the thread either way. A Ref
    // captured here could instead drop the last reference on the worker and
    // delete a Godot Object off the main thread.
    auto done = std::make_shared<std::atomic<bool>>(false);
    std::thread([this, done]() {
        release_player();
        done->store(true, std::memory_order_release);
    }).detach();

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(budget_ms);
    while (!done->load(std::memory_order_acquire))
    {
        if (std::chrono::steady_clock::now() >= deadline)
        {
            UtilityFunctions::push_warning(
                "VlcPlayer: stop exceeded ", budget_ms,
                " ms — abandoning the player (its thread and libVLC instance leak for this process)");
            s_abandoned.push_back(godot::Ref<VlcPlayer>(this));
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

void VlcPlayer::ensure_instance()
{
    // Held for the whole of libvlc_new: warm_up() and open() both come through
    // here, from different threads, and the loser must wait rather than build a
    // second instance.
    std::lock_guard<std::mutex> lock(m_instance_mutex);
    if (m_vlc)
        return;
#ifdef __ANDROID__
    if (!ensure_android_jvm())
    {
        UtilityFunctions::push_error("VlcPlayer: libVLC JavaVM handoff failed — DVD playback unavailable");
        return;
    }
#endif
    // Point libVLC at the plugin tree we ship next to the extension.
    const char *plugins = m_plugin_path.c_str();
    set_plugin_path_env(plugins);

    const char *args[] = {
        "--no-video-title-show",
        "--no-snapshot-preview",
        // Rate changes must bend PITCH, not preserve it. VLC's default is to
        // time-stretch audio so a faster rate keeps the same note, which is
        // right for watching a film at 1.5x and exactly backwards for a record
        // played at the wrong speed -- the whole point of a 33 on a 45 is that
        // it comes out high. Turning the stretcher off is what makes set_rate
        // sound like a turntable rather than a fast-forward button.
        "--no-audio-time-stretch",
#ifdef __ANDROID__
        // Debug builds: full module/demux tracing to logcat (tag "VLC") — the
        // Android pipeline is young; keep failures diagnosable over adb.
        "-vv",
#else
        "--quiet",
#endif
    };
    m_vlc = libvlc_new(sizeof(args) / sizeof(args[0]), args);
    if (!m_vlc)
        UtilityFunctions::push_error("VlcPlayer: libvlc_new failed (check VLC_PLUGIN_PATH: ", plugins, ")");
    m_instance_ready.store(true, std::memory_order_release);
}

void VlcPlayer::warm_up()
{
    if (m_instance_ready.load(std::memory_order_acquire) || m_warm_thread.joinable())
        return;
#ifdef __ANDROID__
    // The JavaVM handoff has to run on the thread Godot called us on: it resolves
    // libvlc.so through the calling frame's classloader, and a worker thread has
    // no Java frame to inherit one from. Cheap, and it only happens once per
    // process; libvlc_new is the part worth moving.
    if (!ensure_android_jvm())
    {
        UtilityFunctions::push_error("VlcPlayer: libVLC JavaVM handoff failed — DVD playback unavailable");
        m_instance_ready.store(true, std::memory_order_release);
        return;
    }
#endif
    m_warm_thread = std::thread([this]() {
        ensure_instance();
        // Also on the failure paths above: a caller parked on is_ready() must not
        // be left parked by a libvlc_new that never worked.
        m_instance_ready.store(true, std::memory_order_release);
    });
}

bool VlcPlayer::is_ready() const
{
    return m_instance_ready.load(std::memory_order_acquire);
}

void VlcPlayer::release_player()
{
    if (m_mp)
    {
        libvlc_media_player_stop(static_cast<libvlc_media_player_t *>(m_mp));
        libvlc_media_player_release(static_cast<libvlc_media_player_t *>(m_mp));
        m_mp = nullptr;
    }
    // Forget the old picture. Without this the previous media's dimensions
    // survive into the next open(), so a stream that never decodes still
    // reports a plausible get_video_size() and reads as live -- which is
    // exactly how a caller distinguishes a working source from a dead one.
    // The player is released above, so no VLC thread can be writing here.
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_width = 0;
        m_height = 0;
        m_frame_dirty = false;
        m_size_dirty = false;
        m_frame_count = 0;
        m_shared.resize(0);
        m_decode.clear();
    }
    {
        std::lock_guard<std::mutex> lock(m_audio_mutex);
        m_audio_head = 0;
        m_audio_tail = 0;
        m_audio_count = 0;
        m_frames_out = 0;
        m_anchor_index = 0;
        m_anchor_pts = 0;
        m_pts_anchored = false;
    }
}

// True when the string already carries a URI scheme -- "http://", "rtsp://",
// "udp://" and so on. Deliberately strict about the shape (RFC 3986 scheme:
// ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )) so a Windows path never matches:
// "C:/x" has no "//", and a bare "//server/share" has no scheme before it.
static bool has_uri_scheme(const String &p)
{
    int sep = p.find("://");
    if (sep <= 0)
        return false;
    const String scheme = p.substr(0, sep);
    for (int i = 0; i < scheme.length(); ++i)
    {
        const char32_t c = scheme[i];
        const bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        const bool rest = (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
        if (i == 0 ? !alpha : !(alpha || rest))
            return false;
    }
    return true;
}

bool VlcPlayer::open(const String &path, bool is_dvd)
{
    ensure_instance();
    if (!m_vlc)
        return false;
    release_player();

    libvlc_instance_t *inst = static_cast<libvlc_instance_t *>(m_vlc);
    String p = path.replace("\\", "/");
    // A URL is already an MRL -- pass it through untouched. Rewriting it the way
    // a path is rewritten below would yield "file:///http://host/..." and open
    // nothing. is_dvd is ignored here: a scheme names its own access module.
    const bool is_url = has_uri_scheme(p);
    String mrl;
    if (is_url)
    {
        mrl = p;
    }
    else
    {
        // Build an MRL. dvd:// for a DVD image (VIDEO_TS folder / .iso, dvdnav menus);
        // file:// for a plain media file (more robust on Windows than new_path).
        // Unix-style absolute paths already start with '/': adding another slash
        // makes VLC parse `//sdcard/...` as an authority and fail to stat it.
        if (!p.begins_with("/"))
            p = String("/") + p;
        mrl = (is_dvd ? String("dvd://") : String("file://")) + p;
    }
    libvlc_media_t *media = libvlc_media_new_location(inst, mrl.utf8().get_data());
    if (!media)
    {
        const char *err = libvlc_errmsg();
        UtilityFunctions::push_error("VlcPlayer: could not create media for ", mrl,
                                     " — ", err ? err : "(no libvlc error)");
        return false;
    }

    if (is_url)
    {
        // A live stream has no seekable start to buffer against, so give the
        // demuxer a jitter cushion before it starts handing over pictures.
        // Broadcast MPEG-TS off an HDHomeRun arrives in bursts; the default
        // (300 ms) underruns on the first GOP.
        libvlc_media_add_option(media, ":network-caching=1500");
    }

    libvlc_media_player_t *mp = libvlc_media_player_new_from_media(media);
    libvlc_media_release(media);
    if (!mp)
        return false;
    m_mp = mp;

    libvlc_video_set_callbacks(mp, cb_lock, cb_unlock, cb_display, this);
    libvlc_video_set_format_callbacks(mp, cb_format, cb_cleanup);

    // Route audio to Godot: decode to interleaved S16 stereo @48k into our ring
    // buffer; the owner drains it into an AudioStreamGenerator on a 3D player.
    libvlc_audio_set_format(mp, "S16N", m_audio_rate, m_audio_channels);
    libvlc_audio_set_callbacks(mp, cb_audio_play, nullptr, nullptr, cb_audio_flush, nullptr, this);

    // open() builds a NEW media player, which starts at 1.0 whatever the last one
    // was doing. A deck that set its speed before loading would otherwise have the
    // setting silently forgotten by the load.
    if (m_rate != 1.0f)
        libvlc_media_player_set_rate(mp, m_rate);

    attach_events();
    return true;
}

void VlcPlayer::attach_events()
{
    if (!m_mp)
        return;
    libvlc_event_manager_t *em = libvlc_media_player_event_manager(static_cast<libvlc_media_player_t *>(m_mp));
    // cb_event uses a VLC-free signature in the header; the pointer types are
    // ABI-compatible, so cast to libvlc_callback_t at the attach site.
    const libvlc_callback_t cb = reinterpret_cast<libvlc_callback_t>(&VlcPlayer::cb_event);
    // EndReached alone is enough for a file, which either opens or does not.
    // A network stream fails long after open() returned true -- an unreachable
    // host, a channel with no free tuner -- so the caller needs to hear about
    // the states too, or a dead stream is indistinguishable from a slow one.
    static const libvlc_event_e k_events[] = {
        libvlc_MediaPlayerEndReached,
        libvlc_MediaPlayerEncounteredError,
        libvlc_MediaPlayerBuffering,
        libvlc_MediaPlayerPlaying,
        libvlc_MediaPlayerStopped,
    };
    for (libvlc_event_e ev : k_events)
        libvlc_event_attach(em, ev, cb, this);
}

// ── transport ────────────────────────────────────────────────────────────────

void VlcPlayer::play()
{
    if (m_mp)
        libvlc_media_player_play(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::pause()
{
    if (m_mp)
        libvlc_media_player_set_pause(static_cast<libvlc_media_player_t *>(m_mp), 1);
}

void VlcPlayer::stop()
{
    if (m_mp)
        libvlc_media_player_stop(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::set_paused(bool paused)
{
    if (m_mp)
        libvlc_media_player_set_pause(static_cast<libvlc_media_player_t *>(m_mp), paused ? 1 : 0);
}

bool VlcPlayer::is_playing() const
{
    return m_mp && libvlc_media_player_is_playing(static_cast<libvlc_media_player_t *>(m_mp));
}

// ── video frame handoff ──────────────────────────────────────────────────────

void VlcPlayer::update_frame()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_size_dirty && m_width > 0 && m_height > 0)
    {
        m_image = Image::create_empty(m_width, m_height, false, Image::FORMAT_RGBA8);
        m_texture = ImageTexture::create_from_image(m_image);
        m_size_dirty = false;
        m_frame_dirty = false;
        return;
    }
    if (!m_frame_dirty || m_texture.is_null() || m_image.is_null())
        return;
    m_image->set_data(m_width, m_height, false, Image::FORMAT_RGBA8, m_shared);
    m_texture->update(m_image);
    m_frame_dirty = false;
}

Ref<Texture2D> VlcPlayer::get_texture() const
{
    return m_texture;
}

Vector2i VlcPlayer::get_video_size() const
{
    return Vector2i((int)m_width, (int)m_height);
}

int64_t VlcPlayer::get_frame_count() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_frame_count;
}

unsigned VlcPlayer::cb_format(void **opaque, char *chroma, unsigned *width,
                              unsigned *height, unsigned *pitches, unsigned *lines)
{
    VlcPlayer *self = static_cast<VlcPlayer *>(*opaque);
    unsigned w = *width;
    unsigned h = *height;
    std::memcpy(chroma, "RGBA", 4);
    *pitches = w * 4;
    *lines = h;
    {
        std::lock_guard<std::mutex> lock(self->m_mutex);
        self->m_width = w;
        self->m_height = h;
        self->m_decode.assign((size_t)w * h * 4, 0);
        self->m_shared.resize((int64_t)w * h * 4);
        self->m_size_dirty = true;
        self->m_frame_dirty = false;
    }
    return 1;
}

void VlcPlayer::cb_cleanup(void *opaque)
{
    VlcPlayer *self = static_cast<VlcPlayer *>(opaque);
    std::lock_guard<std::mutex> lock(self->m_mutex);
    self->m_decode.clear();
}

void *VlcPlayer::cb_lock(void *opaque, void **planes)
{
    VlcPlayer *self = static_cast<VlcPlayer *>(opaque);
    planes[0] = self->m_decode.empty() ? nullptr : self->m_decode.data();
    return nullptr;
}

void VlcPlayer::cb_unlock(void *opaque, void *picture, void *const *planes)
{
    (void)opaque;
    (void)picture;
    (void)planes;
}

void VlcPlayer::cb_display(void *opaque, void *picture)
{
    (void)picture;
    VlcPlayer *self = static_cast<VlcPlayer *>(opaque);
    std::lock_guard<std::mutex> lock(self->m_mutex);
    if (!self->m_decode.empty() && (size_t)self->m_shared.size() == self->m_decode.size())
    {
        std::memcpy(self->m_shared.ptrw(), self->m_decode.data(), self->m_decode.size());
        self->m_frame_dirty = true;
        ++self->m_frame_count;
    }
}

void VlcPlayer::cb_event(const void *event, void *data)
{
    const libvlc_event_t *ev = static_cast<const libvlc_event_t *>(event);
    VlcPlayer *self = static_cast<VlcPlayer *>(data);
    // Runs on a libVLC thread: never touch Godot objects here, only defer.
    switch (ev->type)
    {
    case libvlc_MediaPlayerEndReached:
        self->call_deferred("emit_signal", "finished");
        break;
    case libvlc_MediaPlayerEncounteredError:
        self->call_deferred("emit_signal", "error");
        break;
    case libvlc_MediaPlayerBuffering:
        self->call_deferred("emit_signal", "buffering",
                            ev->u.media_player_buffering.new_cache);
        break;
    case libvlc_MediaPlayerPlaying:
        self->call_deferred("emit_signal", "playing");
        break;
    case libvlc_MediaPlayerStopped:
        self->call_deferred("emit_signal", "stopped");
        break;
    default:
        break;
    }
}

// ── DVD navigation / chapters / titles ───────────────────────────────────────

void VlcPlayer::navigate(int mode)
{
    if (m_mp)
        libvlc_media_player_navigate(static_cast<libvlc_media_player_t *>(m_mp), (unsigned)mode);
}

void VlcPlayer::menu_up() { navigate(libvlc_navigate_up); }
void VlcPlayer::menu_down() { navigate(libvlc_navigate_down); }
void VlcPlayer::menu_left() { navigate(libvlc_navigate_left); }
void VlcPlayer::menu_right() { navigate(libvlc_navigate_right); }
void VlcPlayer::menu_activate() { navigate(libvlc_navigate_activate); }
void VlcPlayer::menu_popup() { navigate(libvlc_navigate_popup); }

void VlcPlayer::go_to_menu()
{
    if (!m_mp)
        return;
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    // Find the first title flagged as a menu and jump to it — that returns the
    // dvdnav VM to the disc menu from anywhere in playback. (navigate(popup)
    // only requests a popup overlay, which most discs ignore mid-title.)
    libvlc_title_description_t **titles = nullptr;
    int n = libvlc_media_player_get_full_title_descriptions(mp, &titles);
    int menu_title = -1;
    if (n > 0 && titles)
    {
        for (int i = 0; i < n; ++i)
        {
            if (titles[i] && (titles[i]->i_flags & libvlc_title_menu))
            {
                menu_title = i;
                break;
            }
        }
        libvlc_title_descriptions_release(titles, n);
    }
    if (menu_title >= 0)
        libvlc_media_player_set_title(mp, menu_title);
    else
        libvlc_media_player_navigate(mp, libvlc_navigate_popup);   // fallback
}

void VlcPlayer::next_chapter()
{
    if (m_mp)
        libvlc_media_player_next_chapter(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::prev_chapter()
{
    if (m_mp)
        libvlc_media_player_previous_chapter(static_cast<libvlc_media_player_t *>(m_mp));
}

void VlcPlayer::set_chapter(int chapter)
{
    if (m_mp)
        libvlc_media_player_set_chapter(static_cast<libvlc_media_player_t *>(m_mp), chapter);
}

int VlcPlayer::get_chapter() const
{
    return m_mp ? libvlc_media_player_get_chapter(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

int VlcPlayer::get_chapter_count() const
{
    return m_mp ? libvlc_media_player_get_chapter_count(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

void VlcPlayer::set_title(int title)
{
    if (m_mp)
        libvlc_media_player_set_title(static_cast<libvlc_media_player_t *>(m_mp), title);
}

int VlcPlayer::get_title() const
{
    return m_mp ? libvlc_media_player_get_title(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

int VlcPlayer::get_title_count() const
{
    return m_mp ? libvlc_media_player_get_title_count(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

bool VlcPlayer::is_in_menu() const
{
    if (!m_mp)
        return false;
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    int title = libvlc_media_player_get_title(mp);
    if (title < 0)
        return false;
    libvlc_title_description_t **titles = nullptr;
    int n = libvlc_media_player_get_full_title_descriptions(mp, &titles);
    bool menu = false;
    if (n > 0 && titles)
    {
        if (title < n && titles[title])
            menu = (titles[title]->i_flags & libvlc_title_menu) != 0;
        libvlc_title_descriptions_release(titles, n);
    }
    return menu;
}

// ── position / audio ─────────────────────────────────────────────────────────

double VlcPlayer::get_position() const
{
    return m_mp ? libvlc_media_player_get_position(static_cast<libvlc_media_player_t *>(m_mp)) : 0.0;
}

void VlcPlayer::set_position(double pos)
{
    if (m_mp)
        libvlc_media_player_set_position(static_cast<libvlc_media_player_t *>(m_mp), (float)pos);
}

int64_t VlcPlayer::get_length() const
{
    return m_mp ? libvlc_media_player_get_length(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

int64_t VlcPlayer::get_time() const
{
    return m_mp ? libvlc_media_player_get_time(static_cast<libvlc_media_player_t *>(m_mp)) : 0;
}

void VlcPlayer::set_volume(int volume)
{
    if (m_mp)
        libvlc_audio_set_volume(static_cast<libvlc_media_player_t *>(m_mp), volume);
}

/// Playback rate, 1.0 being the media's own speed. Remembered rather than only
/// pushed, because open() replaces the media player (see there).
///
/// libVLC refuses a rate a demux cannot serve and reports it; the stored value is
/// still what a later open() re-applies, so a refusal does not leave the object
/// disagreeing with the player about what it asked for.
void VlcPlayer::set_rate(float rate)
{
    if (rate <= 0.0f)
        return;
    m_rate = rate;
    if (m_mp)
        libvlc_media_player_set_rate(static_cast<libvlc_media_player_t *>(m_mp), rate);
}


/// What the PLAYER reports, not what was asked for -- the two differ when a demux
/// will not do the rate.
float VlcPlayer::get_rate() const
{
    if (!m_mp)
        return m_rate;
    return libvlc_media_player_get_rate(static_cast<libvlc_media_player_t *>(m_mp));
}

// ── Godot-routed audio ───────────────────────────────────────────────────────

int VlcPlayer::get_audio_rate() const { return m_audio_rate; }
int VlcPlayer::get_audio_channels() const { return m_audio_channels; }

// Depth the ring is capped at when a source stamps no usable play dates. Purely
// a ratchet stop: with no timestamps there is nothing to align against.
static constexpr int kFallbackLeadMs = 80;

void VlcPlayer::cb_audio_play(void *data, const void *samples, unsigned count, int64_t pts)
{
    VlcPlayer *self = static_cast<VlcPlayer *>(data);
    const int16_t *pcm = static_cast<const int16_t *>(samples);
    const int ch = self->m_audio_channels;
    size_t n = (size_t)count * (size_t)ch; // total int16 samples
    std::lock_guard<std::mutex> lock(self->m_audio_mutex);
    size_t cap = self->m_audio_ring.size();
    if (cap == 0)
        return;

    // pts is when these samples should be heard, on the clock the video output
    // schedules pictures against. Anchor it to the frame index the block starts
    // at -- everything already queued -- so read_audio can recover the play date
    // of whichever sample reaches the head later. Re-anchoring on every block
    // means a seek or a discontinuity is corrected by the next one and no
    // rounding accumulates.
    if (pts > 0)
    {
        self->m_anchor_index = self->m_frames_out + (int64_t)(self->m_audio_count / (size_t)ch);
        self->m_anchor_pts = pts;
        self->m_pts_anchored = true;
    }

    size_t overwritten = 0;
    for (size_t i = 0; i < n; i++)
    {
        self->m_audio_ring[self->m_audio_tail] = pcm[i];
        self->m_audio_tail = (self->m_audio_tail + 1) % cap;
        if (self->m_audio_count < cap)
            self->m_audio_count++;
        else
        {
            self->m_audio_head = (self->m_audio_head + 1) % cap; // overwrite oldest
            overwritten++;
        }
    }
    self->m_frames_out += (int64_t)(overwritten / (size_t)ch);
}

void VlcPlayer::cb_audio_flush(void *data, int64_t pts)
{
    (void)pts;
    VlcPlayer *self = static_cast<VlcPlayer *>(data);
    std::lock_guard<std::mutex> lock(self->m_audio_mutex);
    self->m_audio_head = 0;
    self->m_audio_tail = 0;
    self->m_audio_count = 0;
    // A seek or track change restarts the stream somewhere else on the clock, so
    // the anchor no longer describes anything. The next block re-establishes it.
    self->m_pts_anchored = false;
}

int VlcPlayer::get_audio_backlog_ms() const
{
    std::lock_guard<std::mutex> lock(m_audio_mutex);
    if (m_audio_channels < 1 || m_audio_rate < 1)
        return 0;
    return (int)((m_audio_count / (size_t)m_audio_channels) * 1000 / (size_t)m_audio_rate);
}

int VlcPlayer::get_audio_lead_ms() const
{
    std::lock_guard<std::mutex> lock(m_audio_mutex);
    if (!m_pts_anchored || m_audio_rate < 1)
        return 0;
    const int64_t head_pts =
        m_anchor_pts - (m_anchor_index - m_frames_out) * 1000000 / m_audio_rate;
    return (int)((head_pts - libvlc_clock()) / 1000);
}

int VlcPlayer::get_audio_lead_target_ms() const
{
    std::lock_guard<std::mutex> lock(m_audio_mutex);
    return m_audio_lead_ms;
}

void VlcPlayer::set_audio_lead_ms(int ms)
{
    std::lock_guard<std::mutex> lock(m_audio_mutex);
    m_audio_lead_ms = std::clamp(ms, -500, 1000);
}

PackedVector2Array VlcPlayer::read_audio(int max_frames)
{
    PackedVector2Array out;
    int ch = m_audio_channels;
    if (ch < 1 || max_frames <= 0)
        return out;
    std::lock_guard<std::mutex> lock(m_audio_mutex);
    size_t cap = m_audio_ring.size();
    if (cap == 0)
        return out;
    int frames_avail = (int)(m_audio_count / (size_t)ch);

    // Serve each sample at its play date, not at some chosen queue depth.
    //
    // libVLC stamps every block with the time it should be heard and schedules
    // pictures against that same clock, so a picture arriving at cb_display and
    // the sample belonging with it carry the same instant and can be compared
    // directly. What libVLC does not do is pace the audio. Routed through
    // callbacks there is no output module to push back, so the decoder runs as
    // far ahead as it is allowed -- measured at two seconds for a file and about
    // half a second for a disc -- and delivers that run-ahead in bursts. The
    // ring is therefore storage for the run-ahead, not a latency to be
    // minimised, and sync is a question of where in it we read from.
    //
    // Which is why no fixed depth can be right. Hold the ring at some number of
    // milliseconds and the sound comes out (run-ahead - depth) early: a setting
    // that suits a disc is over a second wrong on a plain file, and both are
    // wrong again after any hitch that moves the run-ahead. Steer the lead
    // instead -- keep the next sample's play date a constant interval ahead of
    // now, discarding when we have slipped behind it and waiting when we are in
    // front of it. The media's own buffering then cancels out of the answer.
    //
    // That interval is the one quantity that genuinely belongs to us: how much
    // sooner a sample must leave here than its picture leaves cb_display, to pay
    // for the queue and device latency after us against the upload and
    // compositor latency after the picture. Tens of milliseconds, a property of
    // this application rather than of the media, and what set_audio_lead_ms is
    // for.
    const int64_t lead_target = (int64_t)m_audio_lead_ms * 1000;
    const int64_t slack = 20000;   // 20 ms, far inside anything perceptible

    auto discard = [&](int n) {
        n = std::min(n, frames_avail);
        if (n <= 0)
            return;
        m_audio_head = (m_audio_head + (size_t)n * (size_t)ch) % cap;
        m_audio_count -= (size_t)n * (size_t)ch;
        m_frames_out += n;
        frames_avail -= n;
    };

    if (m_pts_anchored)
    {
        const int64_t head_pts =
            m_anchor_pts - (m_anchor_index - m_frames_out) * 1000000 / m_audio_rate;
        const int64_t lead = head_pts - libvlc_clock();
        if (lead > lead_target + slack)
            return out;   // ahead of the picture: let the clock come to us
        if (lead < lead_target - slack)
            discard((int)(((lead_target - lead) * m_audio_rate) / 1000000));
    }
    else if (frames_avail > (kFallbackLeadMs + 50) * m_audio_rate / 1000)
    {
        // Nothing to align against. Cap the queue so it at least cannot ratchet.
        discard(frames_avail - kFallbackLeadMs * m_audio_rate / 1000);
    }

    int frames = std::min(max_frames, frames_avail);
    if (frames <= 0)
        return out;
    out.resize(frames);
    Vector2 *w = out.ptrw();
    for (int f = 0; f < frames; f++)
    {
        int16_t l = m_audio_ring[m_audio_head];
        m_audio_head = (m_audio_head + 1) % cap;
        int16_t r = l;
        if (ch >= 2)
        {
            r = m_audio_ring[m_audio_head];
            m_audio_head = (m_audio_head + 1) % cap;
        }
        for (int c = 2; c < ch; c++) // discard extra channels (we request stereo)
            m_audio_head = (m_audio_head + 1) % cap;
        w[f] = Vector2((float)l / 32768.0f, (float)r / 32768.0f);
        m_audio_count -= (size_t)ch;
    }
    m_frames_out += frames;
    return out;
}

// ── Audio-track / subtitle selection ─────────────────────────────────────────

static Array vlc_desc_to_array(libvlc_track_description_t *t)
{
    Array a;
    while (t)
    {
        Dictionary d;
        d["id"] = t->i_id;
        d["name"] = String::utf8(t->psz_name ? t->psz_name : "");
        a.append(d);
        t = t->p_next;
    }
    return a;
}

Array VlcPlayer::get_audio_tracks() const
{
    if (!m_mp)
        return Array();
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    libvlc_track_description_t *t = libvlc_audio_get_track_description(mp);
    Array a = vlc_desc_to_array(t);
    if (t)
        libvlc_track_description_list_release(t);
    return a;
}

int VlcPlayer::get_audio_track() const
{
    return m_mp ? libvlc_audio_get_track(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

void VlcPlayer::set_audio_track(int id)
{
    if (m_mp)
        libvlc_audio_set_track(static_cast<libvlc_media_player_t *>(m_mp), id);
}

Array VlcPlayer::get_subtitle_tracks() const
{
    if (!m_mp)
        return Array();
    libvlc_media_player_t *mp = static_cast<libvlc_media_player_t *>(m_mp);
    libvlc_track_description_t *t = libvlc_video_get_spu_description(mp);
    Array a = vlc_desc_to_array(t);
    if (t)
        libvlc_track_description_list_release(t);
    return a;
}

int VlcPlayer::get_subtitle() const
{
    return m_mp ? libvlc_video_get_spu(static_cast<libvlc_media_player_t *>(m_mp)) : -1;
}

void VlcPlayer::set_subtitle(int id)
{
    if (m_mp)
        libvlc_video_set_spu(static_cast<libvlc_media_player_t *>(m_mp), id);
}

// ── bindings ─────────────────────────────────────────────────────────────────

void VlcPlayer::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("open", "path", "is_dvd"), &VlcPlayer::open, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("warm_up"), &VlcPlayer::warm_up);
    ClassDB::bind_method(D_METHOD("is_ready"), &VlcPlayer::is_ready);
    ClassDB::bind_method(D_METHOD("play"), &VlcPlayer::play);
    ClassDB::bind_method(D_METHOD("pause"), &VlcPlayer::pause);
    ClassDB::bind_method(D_METHOD("stop"), &VlcPlayer::stop);
    ClassDB::bind_method(D_METHOD("shutdown", "budget_ms"), &VlcPlayer::shutdown, DEFVAL(2000));
    ClassDB::bind_method(D_METHOD("set_paused", "paused"), &VlcPlayer::set_paused);
    ClassDB::bind_method(D_METHOD("set_rate", "rate"), &VlcPlayer::set_rate);
    ClassDB::bind_method(D_METHOD("get_rate"), &VlcPlayer::get_rate);
    ClassDB::bind_method(D_METHOD("is_playing"), &VlcPlayer::is_playing);
    ClassDB::bind_method(D_METHOD("get_frame_count"), &VlcPlayer::get_frame_count);

    ClassDB::bind_method(D_METHOD("update_frame"), &VlcPlayer::update_frame);
    ClassDB::bind_method(D_METHOD("get_texture"), &VlcPlayer::get_texture);
    ClassDB::bind_method(D_METHOD("get_video_size"), &VlcPlayer::get_video_size);

    ClassDB::bind_method(D_METHOD("navigate", "mode"), &VlcPlayer::navigate);
    ClassDB::bind_method(D_METHOD("menu_up"), &VlcPlayer::menu_up);
    ClassDB::bind_method(D_METHOD("menu_down"), &VlcPlayer::menu_down);
    ClassDB::bind_method(D_METHOD("menu_left"), &VlcPlayer::menu_left);
    ClassDB::bind_method(D_METHOD("menu_right"), &VlcPlayer::menu_right);
    ClassDB::bind_method(D_METHOD("menu_activate"), &VlcPlayer::menu_activate);
    ClassDB::bind_method(D_METHOD("menu_popup"), &VlcPlayer::menu_popup);
    ClassDB::bind_method(D_METHOD("go_to_menu"), &VlcPlayer::go_to_menu);

    ClassDB::bind_method(D_METHOD("next_chapter"), &VlcPlayer::next_chapter);
    ClassDB::bind_method(D_METHOD("prev_chapter"), &VlcPlayer::prev_chapter);
    ClassDB::bind_method(D_METHOD("set_chapter", "chapter"), &VlcPlayer::set_chapter);
    ClassDB::bind_method(D_METHOD("get_chapter"), &VlcPlayer::get_chapter);
    ClassDB::bind_method(D_METHOD("get_chapter_count"), &VlcPlayer::get_chapter_count);

    ClassDB::bind_method(D_METHOD("set_title", "title"), &VlcPlayer::set_title);
    ClassDB::bind_method(D_METHOD("get_title"), &VlcPlayer::get_title);
    ClassDB::bind_method(D_METHOD("get_title_count"), &VlcPlayer::get_title_count);
    ClassDB::bind_method(D_METHOD("is_in_menu"), &VlcPlayer::is_in_menu);

    ClassDB::bind_method(D_METHOD("get_position"), &VlcPlayer::get_position);
    ClassDB::bind_method(D_METHOD("set_position", "pos"), &VlcPlayer::set_position);
    ClassDB::bind_method(D_METHOD("get_length"), &VlcPlayer::get_length);
    ClassDB::bind_method(D_METHOD("get_time"), &VlcPlayer::get_time);
    ClassDB::bind_method(D_METHOD("set_volume", "volume"), &VlcPlayer::set_volume);

    ClassDB::bind_method(D_METHOD("get_audio_rate"), &VlcPlayer::get_audio_rate);
    ClassDB::bind_method(D_METHOD("get_audio_channels"), &VlcPlayer::get_audio_channels);
    ClassDB::bind_method(D_METHOD("read_audio", "max_frames"), &VlcPlayer::read_audio);
    ClassDB::bind_method(D_METHOD("get_audio_backlog_ms"), &VlcPlayer::get_audio_backlog_ms);
    ClassDB::bind_method(D_METHOD("get_audio_lead_ms"), &VlcPlayer::get_audio_lead_ms);
    ClassDB::bind_method(D_METHOD("get_audio_lead_target_ms"), &VlcPlayer::get_audio_lead_target_ms);
    ClassDB::bind_method(D_METHOD("set_audio_lead_ms", "ms"), &VlcPlayer::set_audio_lead_ms);

    ClassDB::bind_method(D_METHOD("get_audio_tracks"), &VlcPlayer::get_audio_tracks);
    ClassDB::bind_method(D_METHOD("get_audio_track"), &VlcPlayer::get_audio_track);
    ClassDB::bind_method(D_METHOD("set_audio_track", "id"), &VlcPlayer::set_audio_track);
    ClassDB::bind_method(D_METHOD("get_subtitle_tracks"), &VlcPlayer::get_subtitle_tracks);
    ClassDB::bind_method(D_METHOD("get_subtitle"), &VlcPlayer::get_subtitle);
    ClassDB::bind_method(D_METHOD("set_subtitle", "id"), &VlcPlayer::set_subtitle);

    ADD_SIGNAL(MethodInfo("finished"));
    ADD_SIGNAL(MethodInfo("error"));
    ADD_SIGNAL(MethodInfo("playing"));
    ADD_SIGNAL(MethodInfo("stopped"));
    ADD_SIGNAL(MethodInfo("buffering",
                          PropertyInfo(Variant::FLOAT, "percent")));
}

} // namespace Xenu
