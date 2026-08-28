#include "MetaXRAudioStream.hpp"
#include "MetaXRAudioServer.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>

using namespace godot;

namespace Xenu
{

int32_t MetaXRAudioPlayback::_mix(AudioFrame* p_buffer, float /*p_rate_scale*/, int32_t p_frames)
{
    if (p_buffer == nullptr || p_frames <= 0)
        return 0;

    MetaXRAudioServer* server = MetaXRAudioServer::GetSingleton();
    // IsShuttingDown comes first and is atomic: Shutdown() destroys the Meta
    // context a few lines after it sets the flag, and this runs on the audio
    // thread, so mixing into a context that is being torn down has to stop before
    // the teardown starts rather than after it finishes.
    if (server == nullptr || server->IsShuttingDown() || !server->IsRunning())
    {
        std::memset(p_buffer, 0, sizeof(AudioFrame) * static_cast<size_t>(p_frames));
        return p_frames;
    }

    // AudioFrame is { float left; float right; }, so an interleaved float buffer
    // and an AudioFrame array have the same layout — mix straight into it.
    static_assert(sizeof(AudioFrame) == 2 * sizeof(float), "AudioFrame is expected to be two floats");

    server->MixInto(reinterpret_cast<float*>(p_buffer), p_frames);
    return p_frames;
}

void MetaXRAudioPlayback::_start(double /*p_from_pos*/) { m_playing = true; }
void MetaXRAudioPlayback::_stop() { m_playing = false; }
bool MetaXRAudioPlayback::_is_playing() const { return m_playing; }

Ref<AudioStreamPlayback> MetaXRAudioStream::_instantiate_playback() const
{
    Ref<MetaXRAudioPlayback> playback;
    playback.instantiate();
    return playback;
}

String MetaXRAudioStream::_get_stream_name() const { return "MetaXRAudioMix"; }

// Endless: this is a live mix, not a clip.
double MetaXRAudioStream::_get_length() const { return 0.0; }

bool MetaXRAudioStream::_is_monophonic() const { return false; }

void MetaXRAudioMixer::_process(double /*p_delta*/)
{
    MetaXRAudioServer* server = MetaXRAudioServer::GetSingleton();
    if (server != nullptr && server->GetActiveVoiceCount() == 0)
        server->ReleaseMixer();
}

// Retiring when the room falls silent is not enough on its own: quitting with
// voices still playing leaves the playback alive into engine teardown, where
// releasing it faults. The close request is the last notification that still has
// a frame behind it, so it is where the release has to be forced.
void MetaXRAudioMixer::_notification(int p_what)
{
    if (p_what != NOTIFICATION_WM_CLOSE_REQUEST)
        return;

    if (MetaXRAudioServer* server = MetaXRAudioServer::GetSingleton())
        server->PrepareForQuit();
}

} // namespace Xenu
