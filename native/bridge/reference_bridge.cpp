// Own local research adapter. External reconstruction algorithms remain in
// ignored pinned archives, separate from the independent distributable port.
#include "tb_reference_bridge.hpp"
#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include "bb/bze.h"
#include "bb/tb_actor.h"
#include "bb/tb_level.h"
#include "bb/audio.h"
#include "bb/game/tb_dialog_metrics.h"
#include "bb/game/tb_world.h"
#include "compat_script_patches.h"
#include "compat_decoded_script_patches.h"
#include "native_audio_output.hpp"
#include <windows.h>
#include <bcrypt.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
using namespace godot;
namespace fs=std::filesystem;
constexpr float SCALE=0.001f;
constexpr const char *BACKEND="bbtime-465afda7976c1ff1c50a40e7560b0a0ccec14c03-local-research-r09-global-skip-link-after-template-closure-v1-r16-state-derived-hang-v1-r20-preserve-stomp-through-hurt-vm-v1-r22-live-mutable-surfaces-v1-r25-recorded-camera-actor-paths-v1-r26-native-level-view-entry-v1-r27-zero-scaled-cylinder-v1";
static Dictionary dict(std::initializer_list<std::pair<const char *,Variant>> fields) {
    Dictionary out;for(const auto &[key,value]:fields)out[String(key)]=value;return out;
}
static String str(const std::string &s){return String::utf8(s.c_str());}
static std::string text(const String &s){return s.utf8().get_data();}
static fs::path native_path(const String &s){
    const auto wide=s.wide_string();
    return fs::path(wide.get_data());
}
static std::string path_utf8(const fs::path &path){
    const auto utf8=path.u8string();
    return std::string(reinterpret_cast<const char *>(utf8.data()),utf8.size());
}
static std::string lower(std::string s){std::transform(s.begin(),s.end(),s.begin(),[](unsigned char c){return char(std::tolower(c));});return s;}
static fs::path find_ci(const fs::path &base,const std::string &name) {
    if(!fs::is_directory(base))throw std::runtime_error("Directory missing: "+path_utf8(base));
    fs::path result;
    for(const auto &entry:fs::directory_iterator(base))if(lower(path_utf8(entry.path().filename()))==lower(name)){
        if(!result.empty())throw std::runtime_error("Ambiguous resource name: "+name);result=entry.path();
    }
    if(result.empty())throw std::runtime_error("Resource missing: "+path_utf8(base/name));return result;
}
static Vector3 ps1(const bb::game::V3 &p){return Vector3(p.x*SCALE,-p.y*SCALE,-p.z*SCALE);}
static PackedInt32Array raw(const bb::game::V3 &p){PackedInt32Array a;a.append(p.x);a.append(p.y);a.append(p.z);return a;}
static PackedByteArray bytes(std::span<const uint8_t> data){
    PackedByteArray out;out.resize(int64_t(data.size()));if(!data.empty())std::memcpy(out.ptrw(),data.data(),data.size());return out;
}
static String sha256(std::span<const uint8_t> data){
    BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw std::runtime_error("Cannot open SHA256 provider");
    ULONG length=0,returned=0;auto status=BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&length),sizeof(length),&returned,0);
    std::vector<uint8_t> object(length),output(32);
    if(status>=0)status=BCryptCreateHash(algorithm,&hash,object.data(),length,nullptr,0,0);
    if(status>=0)status=BCryptHashData(hash,const_cast<PUCHAR>(data.data()),ULONG(data.size()),0);
    if(status>=0)status=BCryptFinishHash(hash,output.data(),ULONG(output.size()),0);
    if(hash)BCryptDestroyHash(hash);BCryptCloseAlgorithmProvider(algorithm,0);
    if(status<0)throw std::runtime_error("SHA256 provider failed");
    std::ostringstream hex;hex<<std::hex<<std::setfill('0');for(auto v:output)hex<<std::setw(2)<<unsigned(v);return str(hex.str());
}
static constexpr float PC_VERTEX_MODULATION = 1.0f;
static Dictionary mesh_data(const bb::Mesh &mesh,float color_scale){
    int texture_variant = -1;
    if ((mesh.texture >= 0 || mesh.textureAnim >= 0) && !mesh.vertices.empty()) {
        if (mesh.blend == bb::Blend::Alpha) texture_variant = 0;
        if (mesh.blend == bb::Blend::Subtract) texture_variant = 2;
        if (mesh.blend == bb::Blend::Additive)
            texture_variant = mesh.vertices.at(mesh.indices.front()).rgba[3] == 64 ? 3 : 1;
    }
    PackedVector3Array positions;PackedVector2Array uvs;PackedColorArray colors;PackedInt32Array indices;
    positions.resize(int64_t(mesh.vertices.size()));uvs.resize(int64_t(mesh.vertices.size()));colors.resize(int64_t(mesh.vertices.size()));
    for(size_t i=0;i<mesh.vertices.size();++i){const auto &v=mesh.vertices[i];
        positions.set(int64_t(i),Vector3(v.pos[0]*SCALE,v.pos[1]*SCALE,v.pos[2]*SCALE));
        uvs.set(int64_t(i),Vector2(v.uv[0],v.uv[1]));
        colors.set(int64_t(i),Color(v.rgba[0]*color_scale/255.0f,v.rgba[1]*color_scale/255.0f,v.rgba[2]*color_scale/255.0f,texture_variant >= 0 ? 1.0f : v.rgba[3]/255.0f));}
    if(mesh.indices.size()%3)throw std::runtime_error("Non-triangle source mesh");indices.resize(int64_t(mesh.indices.size()));
    for(size_t i=0;i<mesh.indices.size();i+=3){for(int k=0;k<3;++k)if(mesh.indices[i+k]>=mesh.vertices.size())throw std::runtime_error("Mesh index exceeds vertices");
        indices.set(int64_t(i),int32_t(mesh.indices[i]));indices.set(int64_t(i+1),int32_t(mesh.indices[i+2]));indices.set(int64_t(i+2),int32_t(mesh.indices[i+1]));}
    return dict({{"name",str(mesh.name)},{"texture",mesh.texture},{"blend",int(mesh.blend)},{"two_sided",mesh.twoSided},
        {"vertices",positions},{"uvs",uvs},{"colors",colors},{"indices",indices},{"pc_texture_variant",texture_variant},{"texture_anim",mesh.textureAnim},{"zone",mesh.zone},
        {"background",mesh.background},{"far_clip",mesh.farClip*SCALE},{"winding","clockwise"},{"worldspace",true}});
}
static void append_mesh_payload(Array &destination, const bb::Mesh &mesh,
                                std::optional<uint32_t> source_chunk = {}) {
    if (mesh.vertices.empty() || mesh.indices.empty()) return;
    const auto append = [&](const bb::Mesh &batch) {
        Dictionary payload = mesh_data(batch, PC_VERTEX_MODULATION);
        if (source_chunk) payload["source_chunk"] = int64_t(*source_chunk);
        destination.append(payload);
    };

    // The decoded mesh groups combine ABR 1 and 3 under Additive. Each source
    // primitive still carries its mode in its uniform vertex alpha.
    if (mesh.blend == bb::Blend::Additive && (mesh.texture >= 0 || mesh.textureAnim >= 0)) {
        const uint8_t alpha = mesh.vertices.at(mesh.indices.front()).rgba[3];
        const bool mixed = std::ranges::any_of(mesh.vertices, [&](const bb::Vertex &v) {
            return v.rgba[3] != alpha;
        });
        if (mixed) {
            if (mesh.indices.size() % 3) throw std::runtime_error("Non-triangle source mesh");
            std::array<std::vector<uint32_t>, 2> groups;
            for (size_t i = 0; i < mesh.indices.size(); i += 3) {
                const bool quarter = mesh.vertices.at(mesh.indices[i]).rgba[3] == 64;
                auto &indices = groups[quarter];
                indices.insert(indices.end(), mesh.indices.begin() + i, mesh.indices.begin() + i + 3);
            }
            bb::Mesh batch = mesh;
            for (auto &indices : groups) {
                if (indices.empty()) continue;
                batch.indices = std::move(indices);
                append(batch);
            }
            return;
        }
    }
    append(mesh);
}


static Vector3 effect_position(const bb::game::V3 &p) {
    return Vector3(float(p.x), -float(p.y), -float(p.z));
}

static bb::Vertex effect_vertex(const Vector3 &p, std::array<float, 2> uv,
                                std::array<uint8_t, 4> rgba) {
    return {.pos = {float(p.x), float(p.y), float(p.z)}, .uv = {uv[0], uv[1]},
            .rgba = {rgba[0], rgba[1], rgba[2], rgba[3]}};
}

static void append_effect(Array &result, const bb::Mesh &mesh, const char *kind,
                          int source_asset, int source_frame, int64_t source_actor_uid = -1) {
    const int64_t first = result.size();
    append_mesh_payload(result, mesh);
    for (int64_t i = first; i < result.size(); ++i) {
        Dictionary data = result[i];
        data["effect_kind"] = String(kind);
        data["source_asset"] = source_asset;
        data["source_frame"] = source_frame;
        data["source_actor_uid"] = source_actor_uid;
        result[i] = data;
    }
}

static Array effect_payload(const bb::Scene &scene, const bb::game::TbWorld &world) {
    Array result;
    using Kind = bb::game::TbWorld::FxDraw::Kind;
    const Vector3 eye = effect_position(world.cam.eye);
    const Vector3 fwd = (effect_position(world.cam.look) - eye).normalized();
    if (fwd.length_squared() < 0.5f) return result;
    const Vector3 view_right = fwd.cross(Vector3(0, 1, 0));
    const Vector3 right = view_right.length_squared() > 1e-8f ? view_right.normalized() : Vector3(1, 0, 0);
    const Vector3 down = fwd.cross(right);
    const float line_pixel = float(2.0 * world.viewTanY / 480.0);
    constexpr std::array<std::array<float, 2>, 4> uv{{{0, 0}, {1, 0}, {0, 1}, {1, 1}}};

    bb::Mesh lines;
    lines.name = "NativeEffectLines";
    lines.twoSided = true;
    for (const auto &draw : world.fx) {
        if (draw.kind == Kind::Line) {
            const Vector3 a = effect_position(draw.pos);
            Vector3 b = effect_position(draw.to);
            const float zb = std::max(1.0f, float((b - eye).dot(fwd)));
            // Screen offsets use the original 400/250 projection scales (0x451370 and 0x453350).
            b += right * (float(draw.dx) * zb / 400.0f) + down * (float(draw.dy) * zb / 250.0f);
            const Vector3 cross = (b - a).cross(a - eye);
            const Vector3 side = cross.length_squared() > 1e-12f ? cross.normalized() : right;
            const Vector3 wa = side * (0.5f * line_pixel * std::max(1.0f, float((a - eye).dot(fwd))));
            const Vector3 wb = side * (0.5f * line_pixel * zb);
            const std::array<uint8_t, 4> c0{draw.c0[0], draw.c0[1], draw.c0[2], 255};
            const std::array<uint8_t, 4> c1{draw.c1[0], draw.c1[1], draw.c1[2], 255};
            const auto base = uint32_t(lines.vertices.size());
            lines.vertices.push_back(effect_vertex(a - wa, {0, 0}, c0));
            lines.vertices.push_back(effect_vertex(a + wa, {0, 0}, c0));
            lines.vertices.push_back(effect_vertex(b - wb, {0, 0}, c1));
            lines.vertices.push_back(effect_vertex(b + wb, {0, 0}, c1));
            lines.indices.insert(lines.indices.end(), {base, base + 1, base + 2, base + 1, base + 3, base + 2});
            continue;
        }
        const auto sequence = scene.sprites.find(draw.asset);
        if (sequence == scene.sprites.end() || draw.frame >= sequence->second.size()) continue;
        const bb::SpriteFrame &frame = sequence->second[draw.frame];
        if (frame.texture < 0 || size_t(frame.texture) >= scene.textures.size()) continue;

        const bool ground = draw.kind == Kind::Ground;
        std::array<Vector3, 4> corners;
        if (ground) {
            for (size_t i = 0; i < corners.size(); ++i) corners[i] = effect_position(draw.quad[i]);
        } else {
            const float angle = float(draw.angle) * 6.2831853f / 4096.0f;
            const float cs = std::cos(angle), sn = std::sin(angle), size = float(draw.size);
            const Vector3 center = effect_position(draw.pos);
            // The original 0x453350 view offsets use y in 0.625-scaled units.
            const std::array<std::array<float, 2>, 4> offsets{{
                {0.625f * cs, 1.6f * sn}, {-sn, cs}, {sn, -cs}, {-0.625f * cs, -1.6f * sn}}};
            for (size_t i = 0; i < corners.size(); ++i)
                corners[i] = center + right * (size * offsets[i][0]) + down * (size * offsets[i][1]);
        }

        bb::Mesh mesh;
        mesh.name = ground ? "NativeEffectGround" : "NativeEffectSprite";
        mesh.texture = frame.texture;
        mesh.blend = frame.pcBlend;
        mesh.twoSided = !ground;
        mesh.indices = ground ? std::vector<uint32_t>{0, 2, 1, 1, 2, 3}
                              : std::vector<uint32_t>{0, 1, 2, 1, 3, 2};
        for (size_t i = 0; i < corners.size(); ++i)
            mesh.vertices.push_back(effect_vertex(corners[i], uv[i], {255, 255, 255, frame.pcAlpha}));
        append_effect(result, mesh, ground ? "ground" : "sprite", int(draw.asset), int(draw.frame));
    }
    append_effect(result, lines, "line", -1, -1);

    // 0x464480 shifts the composed shadow 5 units down and 9 away from the eye.
    const Vector3 bias = down * 5.0f + fwd * 9.0f;
    bb::AnimState identity;
    identity.parts.push_back({.flags = 4, .object = 0, .parent = -1});
    for (const auto &shadow : world.shadows) {
        if (!shadow.model) continue;
        const int16_t size = int16_t(shadow.scale);
        std::vector<bb::Mesh> meshes;
        bb::poseActor(*shadow.model, identity, {shadow.pos.x, shadow.pos.y, shadow.pos.z},
                      shadow.rot, {size, 0x1000, size}, meshes);
        for (auto &mesh : meshes) {
            for (auto &vertex : mesh.vertices) {
                vertex.pos[0] += float(bias.x);
                vertex.pos[1] += float(bias.y);
                vertex.pos[2] += float(bias.z);
            }
            append_effect(result, mesh, "shadow", int(shadow.model->modelAsset), -1, int64_t(shadow.uid));
        }
    }
    return result;
}

static Array static_mesh_payload(const bb::Scene &scene, bb::game::TbWorld &world,
                                 const std::vector<bb::TbPropMeshRange> &prop_meshes) {
    // The constructor's complete entity list owns drawable placements even if their first
    // native tick hides them using save data. View-list or frame visibility is transient.
    std::set<uint32_t> owned_chunks;
    for (const bb::game::TbActor *actor : world.list()) {
        if (actor->chunk && actor->model && !actor->model->meshes.empty())
            owned_chunks.insert(actor->chunk);
    }

    Array meshes;
    size_t range_index = 0;
    for (size_t index = 0; index < scene.meshes.size(); ++index) {
        while (range_index < prop_meshes.size() && prop_meshes[range_index].endMesh <= index)
            ++range_index;
        std::optional<uint32_t> source_chunk;
        if (range_index < prop_meshes.size() && prop_meshes[range_index].firstMesh <= index)
            source_chunk = prop_meshes[range_index].sourceChunk;
        if (source_chunk && owned_chunks.contains(*source_chunk))
            continue;

        append_mesh_payload(meshes, scene.meshes[index], source_chunk);
    }
    return meshes;
}

struct TbReferenceBridge::State {
    fs::path data_root,path;String level,language,source_hash;bb::BzeFile container;bb::Scene scene;
    Dictionary scene_payload,native_entry;int level_index=-1;
    std::unique_ptr<bb::game::TbWorld> world;uint64_t event_sequence=0;bool pending_skip=false;
    int speech_clip=-1;uint64_t speech_started=0,speech_duration=0;String speech_path;PackedByteArray speech_pcm;
    std::map<int,std::pair<PackedByteArray,uint64_t>> pcm_cache;
};
struct TbReferenceBridge::AudioOutput : TbNativeAudioTransport {};
struct TbReferenceBridge::Session {
    std::array<PackedStringArray, 2> key_prompt_names;
    bool enabled=false,entered=false,requested=false,fading_out=false,blocked=false;
    uint64_t generation=0,ticks=0;String target,origin,error;
    void clear_transition(){requested=fading_out=blocked=false;target=origin=error="";}
};
static int level_index(const String &name){
    for(int i=0;!bb::game::TbWorld::levelName(i).empty();++i)
        if(lower(std::string(bb::game::TbWorld::levelName(i)))==lower(text(name)))return i;
    return -1;
}
TbReferenceBridge::TbReferenceBridge():session(std::make_unique<Session>()),audio_output(std::make_unique<AudioOutput>()){}
TbReferenceBridge::~TbReferenceBridge()=default;
void TbReferenceBridge::_bind_methods(){
    ClassDB::bind_method(D_METHOD("set_key_prompt_names", "p1", "p2"),
        &TbReferenceBridge::set_key_prompt_names);
    ClassDB::bind_method(D_METHOD("load_level","data_root","level","language"),&TbReferenceBridge::load_level);
    ClassDB::bind_method(D_METHOD("load_saved_level","data_root","level","language","gd","expected_sha"),&TbReferenceBridge::load_saved_level);
    ClassDB::bind_method(D_METHOD("set_session_enabled","enabled"),&TbReferenceBridge::set_session_enabled);
    ClassDB::bind_method(D_METHOD("request_reload"),&TbReferenceBridge::request_reload);
    ClassDB::bind_method(D_METHOD("request_transition","level"),&TbReferenceBridge::request_transition);
    ClassDB::bind_method(D_METHOD("get_session_status"),&TbReferenceBridge::get_session_status);
    ClassDB::bind_method(D_METHOD("ack_save_request","success"),&TbReferenceBridge::ack_save_request);
    ClassDB::bind_method(D_METHOD("get_scene"),&TbReferenceBridge::get_scene);
    ClassDB::bind_method(D_METHOD("get_frame"),&TbReferenceBridge::get_frame);
    ClassDB::bind_method(D_METHOD("step","p1_buttons","p2_buttons"),&TbReferenceBridge::step,DEFVAL(0));
    ClassDB::bind_method(D_METHOD("skip_speech"),&TbReferenceBridge::skip_speech);
    ClassDB::bind_method(D_METHOD("set_coop","enabled"),&TbReferenceBridge::set_coop);
    ClassDB::bind_method(D_METHOD("get_status"),&TbReferenceBridge::get_status);
    ClassDB::bind_method(D_METHOD("set_audio_output_enabled","enabled"),&TbReferenceBridge::set_audio_output_enabled);
    ClassDB::bind_method(D_METHOD("get_audio_output_status"),&TbReferenceBridge::get_audio_output_status);
    ClassDB::bind_method(D_METHOD("reconcile_music_output"),&TbReferenceBridge::reconcile_music_output);
    ClassDB::bind_method(D_METHOD("pull_music_frames","max_frames"),&TbReferenceBridge::pull_music_frames);
}
void TbReferenceBridge::set_key_prompt_names(const PackedStringArray &p1,
        const PackedStringArray &p2) {
    session->key_prompt_names = {p1, p2};
}

std::unique_ptr<TbReferenceBridge::State> TbReferenceBridge::prepare_level(const fs::path &root,const String &level,const String &language,
        const PackedByteArray *carried,const String &expected_sha,int32_t load_look_h){
        const std::string name=text(level),lang=text(language);
        if(name.empty()||name.size()>32||!std::all_of(name.begin(),name.end(),[](unsigned char c){return std::isalnum(c)||c=='_';}))throw std::runtime_error("Level must be an original resource stem without path separators");
        if(lang!="RU"&&lang!="EN")throw std::runtime_error("Language profile must be RU or EN");
        auto next=std::make_unique<State>();next->data_root=root;next->level=level;next->language=language;
        next->path=find_ci(find_ci(next->data_root,"BZE"),name+(lang=="RU"?".bzr":".bze"));
        next->container=bb::loadBze(next->path);next->source_hash=sha256(next->container.bytes);
        if(!expected_sha.is_empty()){
            const std::string expected=text(expected_sha);
            if(expected.size()!=64||!std::all_of(expected.begin(),expected.end(),[](unsigned char c){return std::isxdigit(c);}))
                throw std::runtime_error("Expected source SHA256 must contain 64 hexadecimal characters");
            if(lower(expected)!=text(next->source_hash))throw std::runtime_error("Saved level source SHA256 does not match the selected resource/profile");}
        if(next->container.variant!=bb::BzeVariant::TimeBusters)throw std::runtime_error("A Time Busters container is required");
        const int script_section = next->container.find(1);
        if (script_section < 0) throw bb::FormatError("Missing original script section");
        const auto original_script = next->container.payload(size_t(script_section));
        const auto original_script_sha = text(sha256(original_script));
        tb_compat::apply_script_patches(next->container,
            [](std::span<const uint8_t> script) { return text(sha256(script)); });
        std::vector<bb::TbPropMeshRange> prop_meshes;
        std::vector<std::vector<uint8_t>> raw_textures;
        next->scene=bb::buildTbScene(next->container,name,1.0,prop_meshes,&raw_textures);
        bb::addTbActors(next->scene,next->container);
        if(next->scene.placeholder||next->scene.meshes.empty())throw std::runtime_error("Original scene required; placeholder/empty scene refused");
        std::array<uint8_t,0x300> gd;
        if(carried){if(carried->size()!=int64_t(gd.size()))throw std::runtime_error("Persistent GAME_DATA must contain exactly 768 bytes");
            std::memcpy(gd.data(),carried->ptr(),gd.size());}
        tb_compat::DecodedOverrideStorage decoded_storage;
        next->world=std::make_unique<bb::game::TbWorld>(bb::game::TbWorld::load(
            next->container,next->scene,carried?&gd:nullptr,0,
            [&](bb::TbScript& script) {
                tb_compat::apply_decoded_block_clones(script,original_script_sha,
                    tb_compat::kHealthBlockClones,decoded_storage);
            }));
        // Override display labels only. An empty slot keeps the native fallback.
        auto &key_names = next->world->keyNames;
        for (size_t player = 0; player < key_names.size(); ++player) {
            const auto &names = session->key_prompt_names[player];
            if (names.size() != int64_t(key_names[player].size())) continue;
            for (int64_t slot = 0; slot < names.size(); ++slot) {
                const String label = names[slot];
                if (!label.is_empty()) key_names[player][size_t(slot)] = text(label);
            }
        }
        PackedInt32Array changed;
        if(carried)for(int64_t i=0;i<carried->size();++i)if((*carried)[i]!=next->world->GD[size_t(i)])changed.append(int32_t(i));
        next->native_entry=dict({{"policy","original-4395d0-level-entry-v1"},{"stage","constructor_complete_before_first_vm_tick"},
            {"source_kind",carried?"sealed_persistent_game_data":"new_game"},{"payload_game_data",carried?*carried:PackedByteArray()},
            {"payload_sha256",carried?sha256(std::span<const uint8_t>(carried->ptr(),size_t(carried->size()))):String()},
            {"constructor_game_data",bytes(next->world->GD)},{"constructor_sha256",sha256(next->world->GD)},
            {"changed_gd_offsets",changed},{"camera_script_flags",int64_t(next->world->camScript.flags)},
            {"external_payload_modified",false},{"original_call","436a67->4395d0;GD9f@43960f;flags40@4395f4"}});
        if(next->world->actors[0].id!=2||next->world->actors[1].id!=3||next->world->col.polys.empty())throw std::runtime_error("Both original players and original collision are required");
        next->level_index=level_index(level);
        if(next->level_index>=0)next->world->GD[0]=uint8_t(next->level_index);
        next->world->loadLookH=load_look_h;
        // The app performs this public native load initialization after TbWorld::load.
        next->world->fadeIn(1,200);
        Array textures,sky;PackedInt32Array overlay_font,hud_sheet;
        Array meshes = static_mesh_payload(next->scene, *next->world, prop_meshes);
        for(const int32_t index:next->scene.overlayFont)overlay_font.append(index);
        for(const int32_t index:next->scene.hudSheet)hud_sheet.append(index);
        for(size_t i=0;i<next->scene.textures.size();++i){const auto &t=next->scene.textures[i];
            if(t.rgba.size()!=size_t(t.width)*t.height*4)throw std::runtime_error("Texture dimensions do not match RGBA bytes");
            Dictionary texture = dict({{"id",int64_t(i)},{"name",str(t.name)},{"width",int64_t(t.width)},
                {"height",int64_t(t.height)},{"rgba",bytes(t.rgba)},{"has_alpha",t.hasAlpha}});
            if (i < raw_textures.size() && !raw_textures[i].empty()) texture["pc_raw_rgba"] = bytes(raw_textures[i]);
            textures.append(texture);
        }
        for (const auto &mesh : next->scene.skyMeshes) append_mesh_payload(sky, mesh);
        next->scene_payload=dict({{"ok",true},{"schema_version",1},{"level",level},{"language",language},{"source_path",String(next->path.c_str())},
            {"source_sha256",next->source_hash},{"original_data_loaded",true},{"placeholder",false},{"coordinate_scale",SCALE},
            {"coordinate_space","GodotYUp"},{"winding","clockwise"},{"color_scale_applied",PC_VERTEX_MODULATION},{"world_far_clip",next->scene.tbFarClip*SCALE},
            {"pc_tex_gamma",next->scene.pcTexGamma},{"textures",textures},{"overlay_font",overlay_font},{"hud_sheet",hud_sheet},{"static_meshes",meshes},{"sky_meshes",sky},
            {"collision_polygons",int64_t(next->world->col.polys.size())},{"backend",BACKEND}});
        return next;
}
Dictionary TbReferenceBridge::load_level(const String &root,const String &level,const String &language){
    Array output;
    if(state&&!state->world->sfx.cmds.empty())output.append(audio_output->drain(state->world->sfx,state->source_hash,session->generation,state->world->ticks,session->ticks));
    output.append(audio_output->reset("direct_load"));
    state.reset();scene_cache.clear();frame_cache.clear();last_error="";session->clear_transition();
    try{auto next=prepare_level(native_path(root),level,language,nullptr,"",session->enabled&&session->entered?300:0);
        state=std::move(next);scene_cache=state->scene_payload;++session->generation;if(session->enabled)session->entered=true;
        capture_frame({});auto result=get_status();result["audio_output"]=output;return result;
    }catch(const std::exception &error){state.reset();scene_cache.clear();frame_cache.clear();last_error=str(error.what());audio_output->set_music({},false,"");
        return dict({{"ok",false},{"error",last_error},{"loaded",false},{"backend",BACKEND},{"audio_output",output}});}
}
Dictionary TbReferenceBridge::load_saved_level(const String &root,const String &level,const String &language,const PackedByteArray &gd,const String &expected_sha){
    try{if(gd.size()!=768)throw std::runtime_error("Persistent GAME_DATA must contain exactly 768 bytes");
        if(expected_sha.is_empty())throw std::runtime_error("Saved level requires its expected source SHA256");
        auto next=prepare_level(native_path(root),level,language,&gd,expected_sha,session->enabled&&session->entered?300:0);
        Array output;
        if(state&&!state->world->sfx.cmds.empty())output.append(audio_output->drain(state->world->sfx,state->source_hash,session->generation,state->world->ticks,session->ticks));
        output.append(audio_output->reset("saved_level_load"));
        state=std::move(next);scene_cache=state->scene_payload;last_error="";session->clear_transition();++session->generation;
        if(session->enabled)session->entered=true;capture_frame({});auto result=get_status();result["audio_output"]=output;return result;
    }catch(const std::exception &error){if(!state)last_error=str(error.what());
        return dict({{"ok",false},{"error",str(error.what())},{"loaded",bool(state)},{"preserved_current_world",bool(state)},{"backend",BACKEND}});}
}

Dictionary TbReferenceBridge::hud_payload()const{
    if(!state)return {};const auto &w=*state->world;
    auto u16=[&](size_t i){return int(w.GD[i])|(int(w.GD[i+1])<<8);};
    PackedInt32Array health;for(size_t role=0;role<2;++role)health.append(w.player(role).hp);
    const size_t level_offset=0x58u+size_t(w.GD[0xa9]);const int level_count=u16(level_offset);
    return dict({{"lives",int(int8_t(w.GD[0xa0]))},{"health",health},{"carrots",u16(0x58)},{"coins",u16(0x5a)},
        {"completion_percent",u16(0x84)*100/6010},{"completion_raw",u16(0x84)},{"level_gears",level_count},{"level_collectibles",level_count},{"level_counter_selector",int(w.GD[0xa9])},{"level_counter_offset",int64_t(level_offset)},{"completion_domain","native_hud_GD84_not_save_slot_percent"}});
}
Dictionary TbReferenceBridge::visual_payload()const{
    if(!state)return {};const auto &w=*state->world;const auto overlay=w.fadeOverlay();
    return dict({{"bars",int(w.bars)},{"fade",dict({{"mode",w.fade.mode},{"speed",w.fade.speed},{"level",w.fade.level},{"dark",w.fade.dark},
        {"rgb",bytes(w.fade.rgb)},{"overlay_rgba8",bytes(overlay)},{"blend","multiply"}})}});
}
Dictionary TbReferenceBridge::session_payload()const{
    const auto &s=*session;const String phase=!state?"idle":(s.blocked?"blocked":(state->world->quitToMenu?"quit":(s.fading_out?"fading_out":"running")));
    return dict({{"session_api_version",1},{"generation",int64_t(s.generation)},{"session_tick",int64_t(s.ticks)},{"enabled",s.enabled},
        {"loaded",bool(state)},{"phase",phase},{"transition_pending",s.requested||s.fading_out||s.blocked},
        {"transition_error",s.error},{"target_level",s.target},{"transition_origin",s.origin},
        {"quit_requested",state&&state->world->quitToMenu},{"save_requested",state?int(state->world->S[0x29]):0}});
}
Dictionary TbReferenceBridge::get_session_status()const{
    auto out=session_payload();out["ok"]=true;out["hud"]=hud_payload();out["visual"]=visual_payload();
    if(state){out["level"]=state->level;out["language"]=state->language;out["source_sha256"]=state->source_hash;out["world_tick"]=int64_t(state->world->ticks);}
    return out;
}
void TbReferenceBridge::refresh_session_cache(){if(state){frame_cache["session"]=session_payload();frame_cache["hud"]=hud_payload();frame_cache["visual"]=visual_payload();}}
Dictionary TbReferenceBridge::set_session_enabled(bool enabled){session->enabled=enabled;if(enabled&&state)session->entered=true;refresh_session_cache();return get_session_status();}
Dictionary TbReferenceBridge::request_reload(){
    if(!state||!session->enabled)return dict({{"ok",false},{"error","A loaded, enabled session is required"}});
    if((session->requested||session->fading_out)&&!session->blocked)return dict({{"ok",false},{"error","A level transition is already in progress"}});
    session->clear_transition();session->requested=true;session->target=state->level;session->origin="manual_reload";
    refresh_session_cache();return get_session_status();
}
Dictionary TbReferenceBridge::request_transition(const String &level){
    if(!state||!session->enabled)return dict({{"ok",false},{"error","A loaded, enabled session is required"}});
    if((session->requested||session->fading_out)&&!session->blocked)return dict({{"ok",false},{"error","A level transition is already in progress"}});
    const int index=level_index(level);if(index<0)return dict({{"ok",false},{"error","Requested transition is not in the original level table"}});
    session->clear_transition();session->requested=true;session->target=str(std::string(bb::game::TbWorld::levelName(index)));session->origin="manual_transition";
    refresh_session_cache();return get_session_status();
}
Dictionary TbReferenceBridge::ack_save_request(bool success){
    if(!state||!session->enabled)return dict({{"ok",false},{"error","A loaded, enabled session is required"}});
    const uint8_t request=state->world->S[0x29];if(!request)return dict({{"ok",false},{"error","No native save request is pending"}});
    state->world->S[0x29]=0;if(request==6)state->world->S[0x27]=success?0x0e:0x0f;
    capture_frame({});auto out=get_session_status();out["acknowledged_request"]=request;out["native_savegame_written"]=false;return out;
}
void TbReferenceBridge::advance_session(Array &events,Array &audio_packets){
    if(!session->enabled||!state->world->restart)return;
    auto emit=[&](const char *type){events.append(dict({{"type",type},{"tick",int64_t(state->world->ticks)},
        {"event_id",int64_t(++state->event_sequence)},{"generation",int64_t(session->generation)},{"session_tick",int64_t(session->ticks)},
        {"origin",session->origin},{"target_level",session->target},{"error",session->error}}));};
    if(!session->fading_out){
        if(!session->requested){session->origin=state->world->nextLevel>=0?"native_transition":"native_reload";
            session->target=state->world->nextLevel>=0?str(std::string(bb::game::TbWorld::levelName(state->world->nextLevel))):state->level;}
        session->requested=false;session->fading_out=true;state->world->reloadStart();emit("session_reload_started");}
    if(state->world->fade.level>0)return;
    try{if(session->target.is_empty())throw std::runtime_error("Native transition target has no entry in the original level table");
        const PackedByteArray carried=bytes(state->world->GD);const bool coop=state->world->twoPlayer();
        const auto invuln=state->world->invuln;const auto cheats=state->world->cheats;const uint64_t event_sequence=state->event_sequence;
        auto next=prepare_level(state->data_root,session->target,state->language,&carried,"",session->entered?300:0);
        next->world->setTwoPlayer(coop);next->world->invuln=invuln;next->world->cheats=cheats;next->event_sequence=event_sequence;
        if(!state->world->sfx.cmds.empty())audio_packets.append(audio_output->drain(state->world->sfx,state->source_hash,session->generation,state->world->ticks,session->ticks));
        audio_packets.append(audio_output->reset("native_world_replacement"));
        state=std::move(next);scene_cache=state->scene_payload;++session->generation;session->entered=true;
        emit("session_level_loaded");session->clear_transition();last_error="";
    }catch(const std::exception &error){session->blocked=true;session->error=str(error.what());emit("session_transition_blocked");}
}
static void pose_world_actor(const bb::game::TbWorld &world, const bb::game::TbActor &actor,
                             const bb::ActorModel &model, const bb::AnimState &animation,
                             std::vector<bb::Mesh> &out) {
    bb::game::Mat root;
    if (world.presentationHungRoot(actor, root)) {
        std::array<float, 9> basis;
        for (size_t i = 0; i < basis.size(); ++i) basis[i] = root.m[i] / 4096.0f;
        // The native hung record already contains the parent basis and local yaw.
        bb::poseActor(model, animation, {root.t.x, root.t.y, root.t.z}, {},
                      {4096, 4096, 4096}, out, {}, &basis);
        return;
    }
    bb::poseActor(model, animation, {actor.pos.x, actor.pos.y, actor.pos.z},
                  {actor.pitch, actor.yaw, actor.roll}, {actor.scale[0], actor.scale[1], actor.scale[2]}, out);
}

void TbReferenceBridge::capture_frame(const Array &events){
    if(!state)return;const auto &s=*state;const auto &world=*s.world;Array actors;
    const auto append_actor=[&](const bb::game::TbActor &a,bool player){Array posed;const auto *record=a.rec();
        const bool visible=a.drawn()&&!(a.f24&4)&&(player||a.active);bool animated=false;
        if(visible&&a.model){std::vector<bb::Mesh> out;const auto &model=a.mesh?*a.mesh:*a.model;bb::AnimState rigid;
            rigid.parts.push_back({.flags=4,.object=0,.parent=-1});
            // A class-5 block moves via the native mover without advancing an animation.
            const bool rigid_block = a.behaviour == 5 && model.objects.size() == 1;
            const bool still = a.anim.parts.empty() && (a.behaviour == 0 || rigid_block);
            if(still||!a.anim.parts.empty()){pose_world_actor(world,a,model,still?rigid:a.anim,out);
                // 0x465130: shade actor RGB after posing, before selecting PC texture variants.
                if (a.shade) {
                    const int factor = 32 - a.shade;
                    for (auto &mesh : out)
                        for (auto &vertex : mesh.vertices)
                            for (size_t channel = 0; channel < 3; ++channel)
                                vertex.rgba[channel] = uint8_t((vertex.rgba[channel] * factor + 16) / 32);
                }
                for (const auto &mesh : out) append_mesh_payload(posed, mesh);
                animated = !still && !a.anim.parts.empty();}}
        actors.append(dict({{"uid",int64_t(a.uid)},{"source_id",a.id},{"source_chunk",int64_t(a.chunk)},{"player",player},
            {"position",ps1(a.pos)},{"raw_position",raw(a.pos)},{"state",record?int(record->id):-1},{"anim",a.anim.anim},
            {"anim_frame",a.anim.frame},{"pose_parts",int64_t(a.anim.parts.size())},{"attach_part",a.anim.attachPart},
            {"research_debug",dict({{"hp",int(a.hp)},{"state_ticks",int(a.stateTicks)},{"hit_transition",int(a.hitTr)},{"contact",int(a.contact)},{"damage_in",int(a.dmgIn)},{"own_hurt",int(record?record->ownHurt:0)},{"f20",int64_t(a.f20)},{"f24",int64_t(a.f24)},{"f28",int64_t(a.f28)},{"parent",a.parent},{"ride_record",a.rideRec},{"ground_poly",a.groundPoly},{"velocity",raw({a.vel[0],a.vel[1],a.vel[2]})},{"state_flags_a",int64_t(record?record->flagsA:0)},{"state_flags_b",int64_t(record?record->flagsB:0)},{"state_flags_c",int64_t(record?record->flagsC:0)},{"yaw",a.yaw},{"pitch",a.pitch},{"roll",a.roll},{"path_node_index",a.path.node},{"path_point_index",a.path.index},{"path_fraction",a.path.fraction}})},{"visible",visible},{"animated",animated},{"meshes_worldspace",true},{"meshes",posed}}));};
    const auto &bugs=world.player(0), &taz=world.player(1);
    append_actor(bugs,true);
    append_actor(taz,true);
    for(const auto &a:world.actors)if(&a!=&bugs && &a!=&taz)append_actor(a,false);
    for(const auto &a:world.entities)if(&a!=&bugs && &a!=&taz)append_actor(a,false);
    PackedStringArray unsupported;for(const auto &u:world.unsupported)unsupported.append(str(u));
    Array recorded_paths;
    for (const auto& node : world.pathNodes()) {
        PackedInt32Array points;
        for (const auto& p : node.points) { points.append(p.x); points.append(p.y); points.append(p.z); }
        recorded_paths.append(dict({{"id",node.id},{"count",int64_t(node.points.size())},{"raw_points",points}}));
    }
    auto path_debug=dict({{"nodes",recorded_paths},{"node_index",world.camPath.node},{"point_index",world.camPath.index},
        {"modes",world.camPath.modes},{"path_id",world.cam.pathId},{"distance",world.camPath.distance},{"height",world.camPath.height},
        {"camera_script_flags",world.camScript.flags},{"camera_flags",world.cam.flags}});
    PackedInt32Array world_draw_zones;
    // The first native entry is the active camera territory. Without one,
    // preserve the full scene while the world initializes or has no portals.
    if (world.ticks && world.visZones.front().zone > 0) {
        for (const auto &entry : world.visZones)
            if (entry.zone > 0) world_draw_zones.append(entry.zone);
    }
    auto camera=dict({{"eye",ps1(world.cam.eye)},{"look",ps1(world.cam.look)},{"raw_eye",raw(world.cam.eye)},{"raw_look",raw(world.cam.look)},{"up",Vector3(0,1,0)},{"native_flags",int64_t(world.camScript.flags)},{"research_paths",path_debug}});
    auto speech=dict({{"clip",world.speechClip},{"state",world.S[0x22]},{"playing",world.speechPlaying()},{"source_path",s.speech_path},
        {"pcm_s16le",s.speech_pcm},{"sample_rate",44100},{"channels",1},{"duration_ticks",int64_t(s.speech_duration)},
        {"native_completion_callback",world.speechAudio},{"language_index",world.GD[0x93]}});
    Array glyphs,text_boxes,hud_sprites;
    for(size_t i=0;i<world.hudSprites.size();++i){const auto &sp=world.hudSprites[i];hud_sprites.append(dict({{"index",int64_t(i)},{"frame",int(sp.frame)},{"shown",sp.shown},{"x",int(sp.x)},{"y",int(sp.y)},{"u",int(sp.u)},{"v",int(sp.v)},{"w",int(sp.w)},{"h",int(sp.h)}}));}
    for(const auto &g:world.glyphs)glyphs.append(dict({{"ch",int(g.ch)},{"glyph",int(g.glyph)},{"x",int(g.x)},{"y",int(g.y)},{"pal",int(g.pal)}}));
    for(const auto &box:world.textBoxes){PackedInt32Array rect;for(const int16_t value:box)rect.append(value);text_boxes.append(rect);}
    const auto overlay=dict({{"schema_version",1},{"coordinate_space","TBOverlay512x240Centered"},{"glyphs",glyphs},{"text_boxes",text_boxes},{"hud_sprites",hud_sprites}});
    PackedInt32Array texture_links;
    for (const auto &animation : s.scene.textureAnims) {
        if (animation.frames.empty()) {
            texture_links.append(-1);
            continue;
        }
        size_t frame = animation.startFrame % animation.frames.size();
        if (!animation.timingInferred && animation.holdTicks > 0 &&
            animation.holdTicks != UINT32_MAX)
            frame = (frame + world.ticks / animation.holdTicks) % animation.frames.size();

        int32_t texture = animation.frames[frame];
        const auto alias = world.textureLinks.find(uint16_t(animation.linkId));
        if (alias != world.textureLinks.end() && !animation.records.empty()) {
            const int32_t resolved = animation.records[alias->second % animation.records.size()];
            if (resolved >= 0) texture = resolved;
        }
        texture_links.append(texture);
    }
    frame_cache=dict({{"ok",true},{"schema_version",1},{"tick",int64_t(world.ticks)},{"level",s.level},{"language",s.language},
        {"coordinate_scale",SCALE},{"coordinate_space","GodotYUp"},{"camera",camera},{"world_draw_zones",world_draw_zones},{"texture_links",texture_links},{"effects_meshes",effect_payload(s.scene, world)},{"actors",actors},{"events",events},{"speech",speech},
        {"focus",world.focus()},{"coop",world.twoPlayer()},{"restart",world.restart},{"next_level",world.nextLevel},{"unsupported",unsupported},
        {"native_entry",s.native_entry},{"game_data",bytes(world.GD)},{"script_state",bytes(world.S)},{"overlay",overlay},{"bars",world.bars},{"fade_dark",world.fade.dark},{"music_track",world.musicTrack},{"music_paused",world.musicPaused},{"backend",BACKEND}});
    refresh_session_cache();
}
Dictionary TbReferenceBridge::step(int64_t p1,int64_t p2){
    if(!state)return dict({{"ok",false},{"error",last_error.is_empty()?String("No level loaded"):last_error}});
    if(p1<0||p1>65535||p2<0||p2>65535)return dict({{"ok",false},{"error","Pad mask outside 0..65535"}});
    if(session->enabled&&session->blocked)return dict({{"ok",false},{"loaded",true},{"blocked",true},{"error",session->error},{"session",session_payload()}});
    if(session->enabled&&state->world->quitToMenu)return dict({{"ok",false},{"loaded",true},{"quit_requested",true},{"error","Native session requested return to the front end"},{"session",session_payload()}});
    Array audio_packets;
    try{auto &s=*state;auto &world=*s.world;Array events;
        const int64_t event_tick=int64_t(world.ticks)+1;
        const uint64_t event_session_tick=session->ticks+1;
        auto emit=[&](const char *type,Dictionary payload=Dictionary()){payload["type"]=type;payload["tick"]=event_tick;payload["event_id"]=int64_t(++s.event_sequence);
            if(session->enabled){payload["session_tick"]=int64_t(event_session_tick);payload["generation"]=int64_t(session->generation);}events.append(payload);};
        const int old_speech=world.S[0x22],old_focus=world.focus(),old_next=world.nextLevel;const bool old_restart=world.restart;
        const auto player_state=[](const bb::game::TbActor &a){return a.rec()?int(a.rec()->id):-1;};
        const std::array<int,2> old_states={player_state(world.player(0)),player_state(world.player(1))};
        const std::array<uint32_t,2> old_uids={world.player(0).uid,world.player(1).uid};
        if(session->enabled&&session->requested&&!session->fading_out){world.restart=true;
            world.nextLevel=session->origin=="manual_transition"?level_index(session->target):-1;}
        if(world.S[0x22]==2){try{std::ostringstream folder;folder<<std::setw(2)<<std::setfill('0')<<unsigned(world.GD[0x93]);
                auto speech=find_ci(find_ci(find_ci(s.data_root,"SPEECH"),folder.str()),"Speech"+std::to_string(world.speechClip)+".xa");const int clip=world.speechClip;
                if(!s.pcm_cache.contains(clip)){bb::XaStream stream(speech,bb::XaLayout::Mono);std::vector<int16_t> samples;
                    if(stream.frames()>44100*600)throw std::runtime_error("Speech exceeds research decode bound");while(stream.read(65536,samples)){}
                    auto pcm=bytes(std::span(reinterpret_cast<const uint8_t*>(samples.data()),samples.size()*2));
                    s.pcm_cache.emplace(clip,std::make_pair(pcm,(stream.frames()*30+stream.rate()-1)/stream.rate()));}
                s.speech_pcm=s.pcm_cache.at(clip).first;s.speech_duration=s.pcm_cache.at(clip).second;s.speech_path=String(speech.c_str());
                s.speech_started=world.ticks;s.speech_clip=clip;world.speechAudio=true;
            }catch(const std::exception &error){world.speechAudio=false;s.speech_pcm.clear();s.speech_duration=0;s.speech_path="";emit("speech_audio_unavailable",dict({{"error",str(error.what())}}));}}
        if(world.speechPlaying()&&(s.pending_skip||(s.speech_duration&&world.ticks-s.speech_started>=s.speech_duration))){world.speechEnded=true;
            emit(s.pending_skip?"speech_skip_completion_requested":"speech_duration_completed");s.pending_skip=false;}
        bb::game::PadInput pad1,pad2;pad1.buttons=uint16_t(p1);pad2.buttons=uint16_t(p2);
        {
            const bb::game::TbDialogMetricsScope dialogue(s.language == "RU");
            world.tick(pad1,pad2);
        }
        ++session->ticks;
        audio_packets.append(audio_output->drain(world.sfx,s.source_hash,session->generation,world.ticks,session->ticks));
        if(old_speech==2 && world.S[0x22]==4 && world.speechAudio)s.speech_started=world.ticks;
        emit("input_applied",dict({{"p1_buttons",p1},{"p2_buttons",p2}}));
        for(size_t role=0;role<2;++role){
            const auto &a=world.player(role);
            const int now=player_state(a);
            if(now!=old_states[role]||a.uid!=old_uids[role])
                emit("state_changed",dict({{"uid",int64_t(a.uid)},{"source_id",a.id},{"before",old_states[role]},{"after",now}}));
        }
        if(world.focus()!=old_focus)emit("focus_changed",dict({{"focus",world.focus()}}));
        if(world.S[0x22]!=old_speech)emit("speech_state_changed",dict({{"before",old_speech},{"after",world.S[0x22]},{"clip",world.speechClip}}));
        if(world.nextLevel!=old_next||world.restart!=old_restart)emit("transition_requested",dict({{"next_level",world.nextLevel},{"restart",world.restart}}));
        if(world.lastCallFriend)emit("call_friend_result",dict({{"result",world.lastCallFriend}}));
        advance_session(events,audio_packets);capture_frame(events);auto result=get_frame();result["audio_output"]=audio_packets;return result;
    }catch(const std::exception &error){last_error=str(error.what());const int64_t tick=state->world->ticks;
        if(state)state->world->sfx.cmds.clear();audio_packets.append(audio_output->reset("simulation_error"));audio_output->set_music({},false,"");
        state.reset();scene_cache.clear();frame_cache.clear();return dict({{"ok",false},{"loaded",false},{"error",last_error},{"tick",tick},{"audio_output",audio_packets}});}
}
Dictionary TbReferenceBridge::get_scene()const{if(!state)return dict({{"ok",false},{"error",last_error.is_empty()?String("No level loaded"):last_error}});return scene_cache.duplicate(true);}
Dictionary TbReferenceBridge::get_frame()const{if(!state)return dict({{"ok",false},{"error",last_error.is_empty()?String("No level loaded"):last_error}});return frame_cache.duplicate(true);}
Dictionary TbReferenceBridge::skip_speech(){if(!state)return dict({{"ok",false},{"error","No level loaded"}});
    if(!state->world->speechPlaying())return dict({{"ok",false},{"error","No callback-managed speech is active"}});
    state->pending_skip=true;return dict({{"ok",true},{"mode","native_speechEnded_callback_next_step"}});}
Dictionary TbReferenceBridge::set_coop(bool enabled){if(!state)return dict({{"ok",false},{"error","No level loaded"}});state->world->setTwoPlayer(enabled);capture_frame({});return get_status();}
Dictionary TbReferenceBridge::get_status()const{auto out=dict({{"ok",bool(state)},{"loaded",bool(state)},{"schema_version",1},{"tick_hz",30},
        {"backend",BACKEND},{"research_only",true},{"independent_core",false},{"package_allowed",false},{"coordinate_scale",SCALE},
        {"coordinate_space","GodotYUp"},{"actor_meshes_worldspace",true},{"godot_api","4.7.2"},
        {"godot_cpp_revision","e103d348c4b2d8df7b819126d855e19381cb9a87"},{"error",last_error},{"session_api_version",1}});
    if(state){out["level"]=state->level;out["language"]=state->language;out["source_path"]=String(state->path.c_str());out["source_sha256"]=state->source_hash;out["tick"]=int64_t(state->world->ticks);out["coop"]=state->world->twoPlayer();}return out;}
Dictionary TbReferenceBridge::set_audio_output_enabled(bool enabled){
    Array packets;if(audio_output->enabled!=enabled){audio_output->enabled=enabled;
        packets.append(audio_output->reset(enabled?"output_enabled":"output_discard"));
        // Output reset is not a modeled-voice operation and cannot request completion.
        audio_output->music.reset();audio_output->music_wanted.clear();audio_output->music_error.clear();}
    auto out=audio_output->status();out["ok"]=true;out["audio_output"]=packets;return out;
}
Dictionary TbReferenceBridge::get_audio_output_status()const{auto out=audio_output->status();
    out["native_queue_size"]=state?int64_t(state->world->sfx.cmds.size()):0;out["adapter_id"]="r29-native-audio-output-v1";return out;}
Dictionary TbReferenceBridge::reconcile_music_output(){
    fs::path desired;std::string error;bool paused=false;
    if(state&&audio_output->enabled){const auto &w=*state->world;paused=w.musicPaused;
        if(w.S[0x22]==0&&w.musicTrack>1){
            const fs::path &root=state->data_root;
            if(root!=audio_output->resolved_root||w.musicTrack!=audio_output->resolved_track){
                audio_output->resolved_root=root;audio_output->resolved_track=w.musicTrack;
                audio_output->resolved_path.clear();audio_output->resolved_error.clear();
                try{auto tracks=find_ci(state->data_root,"TRACK");fs::path file;
                    try{file=find_ci(tracks,"Track"+std::to_string(w.musicTrack-1)+".xa");}
                    catch(const std::exception&){file=find_ci(tracks,"Track14.xa");}
                    audio_output->resolved_path=file;
                }catch(const std::exception&e){audio_output->resolved_error=e.what();}}
            desired=audio_output->resolved_path;error=audio_output->resolved_error;
        }}
    auto out=audio_output->set_music(desired,paused,error);out["resolution_error"]=str(error);return out;
}
Dictionary TbReferenceBridge::pull_music_frames(int64_t frames){return audio_output->pull(frames);}
static void initialize_reference(ModuleInitializationLevel level){if(level==MODULE_INITIALIZATION_LEVEL_SCENE)GDREGISTER_CLASS(TbReferenceBridge);}
static void uninitialize_reference(ModuleInitializationLevel){}
extern "C" GDExtensionBool GDE_EXPORT tb_reference_library_init(GDExtensionInterfaceGetProcAddress get_proc,GDExtensionClassLibraryPtr library,GDExtensionInitialization *initialization){
    GDExtensionBinding::InitObject init(get_proc,library,initialization);init.register_initializer(initialize_reference);init.register_terminator(uninitialize_reference);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);return init.init();}
