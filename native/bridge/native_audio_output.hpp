#pragma once
// Owned research output transport. Never updates modeled voices, VM, GD/S, RNG or 30Hz.
#include "bb/game/sfx.h"
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <vector>
#include <cmath>
#include <memory>
#include <string>

struct TbNativeAudioTransport {
    bool enabled=false;
    uint64_t generation=0,sequence=0,asset_sequence=0,ticks_drained=0,commands_drained=0,commands_discarded=0;
    size_t queue_high_water=0,packet_PCM_high_water=0;
    static constexpr size_t max_commands=4096,max_packet_pcm=32*1024*1024,max_voice_keys=1280;
    std::unique_ptr<bb::XaStream> music;
    std::filesystem::path music_wanted,resolved_root,resolved_path;
    std::string music_error,resolved_error;
    int resolved_track=-1;
    uint64_t music_instance=0,music_decoded_frames=0,music_rewinds=0,music_starts=0;
    bool music_paused=false;
    std::vector<int16_t> scratch;
    static godot::Dictionary row(std::initializer_list<std::pair<const char*,godot::Variant>> values){
        godot::Dictionary r;for(const auto &[k,v]:values)r[godot::String(k)]=v;return r;
    }
    static godot::String gs(const std::string&s){return godot::String::utf8(s.c_str());}
    godot::Dictionary reset(const char *reason){
        ++generation;return row({{"kind","reset"},{"sequence",int64_t(++sequence)},{"generation",int64_t(generation)},
            {"reason",reason},{"enabled",enabled}});
    }
    static float ds_gain(int32_t v){return v<=-10000?0.0f:std::pow(10.0f,float(v)/2000.0f);}
    godot::Dictionary drain(bb::game::Sfx &sfx,const godot::String &resource,uint64_t world_generation,uint64_t tick,uint64_t session_tick){
        // Removing the vector first guarantees no retained history, even on a presentation decode error.
        std::vector<bb::SfxCmd> native;native.swap(sfx.cmds);++ticks_drained;commands_drained+=native.size();
        queue_high_water=std::max(queue_high_water,native.size());godot::Array commands,errors;size_t pcm_bytes=0;
        if(!enabled)commands_discarded+=native.size();
        else if(native.size()>max_commands)errors.append("SFX tick exceeds explicit command bound; entire packet discarded");
        else for(size_t ordinal=0;ordinal<native.size();++ordinal){const auto &c=native[ordinal];
            try{
                if(c.key>=max_voice_keys)throw std::runtime_error("SFX key outside native blob<128/copies10 domain");
                auto out=row({{"ordinal",int64_t(ordinal)},{"op",int(c.op)},{"key",int64_t(c.key)},
                    {"volume_hundredths_db",c.volume},{"gain_linear",double(ds_gain(c.volume))},{"pan",c.pan},{"rate",int64_t(c.rate)}});
                if(c.op==bb::SfxCmd::Play){
                    if(!c.sound||c.sound->pcm.empty()){out["empty_sound"]=true;commands.append(out);continue;}
                    const auto &s=*c.sound;const bool loop=s.loopEnd>0;const uint32_t frames=loop?s.loopEnd:s.frames();
                    if((s.channels!=1&&s.channels!=2)||!c.rate||frames>s.frames()||!frames||
                        (loop&&s.loopStart>=s.loopEnd))throw std::runtime_error("Invalid native PCM channels/rate/loop bounds");
                    const size_t required=size_t(frames)*(loop?12:4);if(required>max_packet_pcm-pcm_bytes)throw std::runtime_error("SFX PCM packet exceeds32MiB bound");
                    godot::PackedByteArray pcm;pcm.resize(int64_t(size_t(frames)*4));godot::PackedVector2Array loop_frames;
                    if(loop)loop_frames.resize(frames);
                    auto sides=[](int32_t p){return std::array{p>0?ds_gain(-p):1.0f,p<0?ds_gain(p):1.0f};};
                    const auto initial=sides(c.pan),repeat=sides(-c.pan);
                    for(uint32_t f=0;f<frames;++f){const auto &gain=loop&&f>=s.loopStart?repeat:initial;float pair[2];
                        for(size_t ch=0;ch<2;++ch){const int16_t sample=int16_t(std::lround(s.pcm[size_t(f)*s.channels+(s.channels==2?ch:0)]*gain[ch]));
                            const uint16_t raw=uint16_t(sample);const size_t offset=size_t(f)*4+ch*2;
                            pcm.set(int64_t(offset),uint8_t(raw));pcm.set(int64_t(offset+1),uint8_t(raw>>8));pair[ch]=float(sample)/32768.0f;}
                        if(loop)loop_frames.set(f,godot::Vector2(pair[0],pair[1]));}
                    pcm_bytes+=required;out["asset_id"]=int64_t(++asset_sequence);out["pcm_s16le"]=pcm;
                    out["channels"]=2;out["source_channels"]=int(s.channels);out["source_rate"]=int64_t(s.rate);out["frames"]=int64_t(frames);
                    out["loop_begin"]=int64_t(s.loopStart);out["loop_end"]=int64_t(s.loopEnd);out["loop"]=loop;
                    // Explicit generator cursor avoids assuming native WAV loop endpoint behavior.
                    if(loop)out["loop_pcm_frames"]=loop_frames;
                }
                commands.append(out);
            }catch(const std::exception&e){errors.append(row({{"ordinal",int64_t(ordinal)},{"error",gs(e.what())}}));}
        }
        packet_PCM_high_water=std::max(packet_PCM_high_water,pcm_bytes);
        return row({{"kind","tick"},{"sequence",int64_t(++sequence)},{"generation",int64_t(generation)},
            {"world_generation",int64_t(world_generation)},{"tick",int64_t(tick)},{"session_tick",int64_t(session_tick)},
            {"resource_sha256",resource},{"enabled",enabled},{"source_command_count",int64_t(native.size())},
            {"commands",commands},{"errors",errors},{"PCM_bytes",int64_t(pcm_bytes)},{"native_queue_after_drain",int64_t(sfx.cmds.size())}});
    }
    godot::Dictionary status()const{return row({{"enabled",enabled},{"generation",int64_t(generation)},{"sequence",int64_t(sequence)},
        {"completed_operations_drained",int64_t(ticks_drained)},{"commands_drained",int64_t(commands_drained)},
        {"commands_discarded",int64_t(commands_discarded)},{"queue_high_water",int64_t(queue_high_water)},
        {"packet_PCM_high_water",int64_t(packet_PCM_high_water)},{"retained_packet_history",0},
        {"max_voice_keys",int64_t(max_voice_keys)},{"music_instance",int64_t(music_instance)},
        {"music_path",godot::String(music_wanted.c_str())},{"music_open",bool(music)},{"music_error",gs(music_error)},
        {"music_decoded_frames",int64_t(music_decoded_frames)},{"music_rewinds",int64_t(music_rewinds)},{"music_starts",int64_t(music_starts)}});}
    godot::Dictionary set_music(const std::filesystem::path &path,bool paused,const std::string &resolution_error){
        music_paused=paused;if(path.empty())music_error=resolution_error;
        if(path!=music_wanted){music.reset();music_wanted=path;music_error=resolution_error;++music_instance;
            if(enabled&&!path.empty())try{music=std::make_unique<bb::XaStream>(path,bb::XaLayout::Stereo);
                if(!music->bytes())throw std::runtime_error("Empty original XA stream");++music_starts;
            }catch(const std::exception&e){music.reset();music_error=e.what();}}
        auto out=status();out["ok"]=music_error.empty();out["path"]=godot::String(music_wanted.c_str());out["instance"]=int64_t(music_instance);
        out["paused"]=music_paused;out["playing"]=bool(music);out["sample_rate"]=44100;out["channels"]=2;
        out["clip_offset_bytes"]=0;out["clip_size_bytes"]=0;out["loop"]=true;return out;
    }
    godot::Dictionary pull(int64_t requested){
        if(requested<1||requested>4096)return row({{"ok",false},{"error","Music pull bound is1..4096frames"}});
        godot::PackedVector2Array frames;
        if(music&&!music_paused&&enabled){try{scratch.clear();size_t n=music->read(size_t(requested),scratch);
            if(n<size_t(requested)&&music->bytes()){music->rewind();++music_rewinds;music->read(size_t(requested)-n,scratch);}
            frames.resize(int64_t(scratch.size()/2));for(int64_t i=0;i<frames.size();++i)frames.set(i,godot::Vector2(float(scratch[size_t(i)*2])/32768.0f,float(scratch[size_t(i)*2+1])/32768.0f));
            music_decoded_frames+=uint64_t(frames.size());
        }catch(const std::exception&e){music_error=e.what();music.reset();return row({{"ok",false},{"error",gs(music_error)}});}}
        return row({{"ok",true},{"instance",int64_t(music_instance)},{"frames",frames},{"paused",music_paused},{"decoded_total",int64_t(music_decoded_frames)}});
    }
};
