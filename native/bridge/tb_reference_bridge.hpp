#pragma once
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <filesystem>
#include <memory>

class TbReferenceBridge : public godot::RefCounted {
    GDCLASS(TbReferenceBridge, godot::RefCounted)
    struct State;
    struct Session;
    struct AudioOutput;
    std::unique_ptr<State> state;
    std::unique_ptr<Session> session;
    std::unique_ptr<AudioOutput> audio_output;
    godot::String last_error;
    godot::Dictionary scene_cache, frame_cache;
    void capture_frame(const godot::Array &events);
    std::unique_ptr<State> prepare_level(const std::filesystem::path &data_root, const godot::String &level,
        const godot::String &language, const godot::PackedByteArray *carried, const godot::String &expected_sha, int32_t load_look_h);
    void advance_session(godot::Array &events, godot::Array &audio_packets);
    godot::Dictionary session_payload() const;
    godot::Dictionary hud_payload() const;
    godot::Dictionary visual_payload() const;
    void refresh_session_cache();
protected:
    static void _bind_methods();
public:
    TbReferenceBridge();
    ~TbReferenceBridge();
    void set_key_prompt_names(const godot::PackedStringArray &p1,
        const godot::PackedStringArray &p2);
    godot::Dictionary load_level(const godot::String &data_root, const godot::String &level, const godot::String &language);
    godot::Dictionary load_saved_level(const godot::String &data_root, const godot::String &level,
        const godot::String &language, const godot::PackedByteArray &gd, const godot::String &expected_sha);
    godot::Dictionary set_session_enabled(bool enabled);
    godot::Dictionary request_reload();
    godot::Dictionary request_transition(const godot::String &level);
    godot::Dictionary get_session_status() const;
    godot::Dictionary ack_save_request(bool success);
    godot::Dictionary get_scene() const;
    godot::Dictionary get_frame() const;
    godot::Dictionary step(int64_t p1_buttons, int64_t p2_buttons=0);
    godot::Dictionary skip_speech();
    godot::Dictionary set_coop(bool enabled);
    godot::Dictionary get_status() const;
    godot::Dictionary set_audio_output_enabled(bool enabled);
    godot::Dictionary get_audio_output_status() const;
    godot::Dictionary reconcile_music_output();
    godot::Dictionary pull_music_frames(int64_t max_frames);
};
