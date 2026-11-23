#pragma once
// Source preparation: activate only after the current-baseline contact regression and review.
// Generic decoded-script block clone + exact operand replacement. Original bytes stay untouched.
#include "bb/tb_level.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstddef>
#include <deque>
#include <span>
#include <string_view>
#include <vector>

namespace tb_compat {
struct DecodedBlockClone {
    std::string_view section_sha256;
    uint32_t destination_chunk, source_chunk, source_block_offset, call_offset, edit_offset;
    uint16_t destination_id, destination_parent, source_block, local_block;
    std::span<const uint8_t> expected_call, replacement_call, expected_edit, replacement_edit;
};
inline constexpr std::array<uint8_t, 9> kHealthApplyCall{
    0x5d, 0x40, 0x00, 0x32, 0x27, 0x0c, 0x00, 0x00, 0x00};
inline constexpr std::array<uint8_t, 17> kHealthBugsWrite{
    0x56, 0x00, 0x08, 0x00, 0x80, 0xfe, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00};
// Content manifest bytes, separate from the generic cloning algorithm.
inline constexpr std::array<uint8_t, 9> kHealthApplyCallLocal{
    0x5d, 0x40, 0x00, 0x0f, 0x27, 0x0c, 0x00, 0x00, 0x00};
inline constexpr std::array<uint8_t, 17> kHealthBugsWriteFrom511{
    0x56, 0x00, 0x08, 0x00, 0x80, 0xff, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00};
inline constexpr std::array kHealthBlockClones{
    DecodedBlockClone{"d61fb6512c390232e852f1fb0584ab5177709caf31d9730ebfde70eb441de292",
        38002, 43521, 44039, 38354, 44051, 244, 63, 10034, 9999,
        kHealthApplyCall, kHealthApplyCallLocal, kHealthBugsWrite, kHealthBugsWriteFrom511},
    DecodedBlockClone{"3e63904e2c7d0a08660fc7797feaf6623910180a41723593c9e072a13240d9e8",
        73708, 23778, 24296, 74109, 24308, 238, 63, 10034, 9999,
        kHealthApplyCall, kHealthApplyCallLocal, kHealthBugsWrite, kHealthBugsWriteFrom511},
};
// Must outlive TbWorld::load's entire parse/model/logic/template construction.
// std::deque keeps payload storage stable when another cloned tag is appended.
struct DecodedOverrideStorage { std::deque<std::vector<uint8_t>> payloads; };
inline uint16_t decoded_u16(std::span<const uint8_t> d) {
    if (d.size() < 2) throw bb::FormatError("decoded override: short u16");
    return uint16_t(d[0] | uint16_t(d[1]) << 8);
}
inline bool exact_tag(const bb::TbTag& tag, std::span<const uint8_t> encoded) {
    return !encoded.empty() && tag.id == encoded[0] && tag.data.size() == encoded.size()-1 &&
        std::equal(tag.data.begin(), tag.data.end(), encoded.begin()+1);
}
inline std::span<const uint8_t> own_payload(DecodedOverrideStorage& storage, std::span<const uint8_t> p) {
    auto& owned = storage.payloads.emplace_back(p.begin(), p.end());
    return {owned.data(), owned.size()};
}
inline void apply_decoded_block_clones(bb::TbScript& script, std::string_view section_sha256,
                                      std::span<const DecodedBlockClone> patches,
                                      DecodedOverrideStorage& storage) {
    for (const auto& patch : patches) {
        if (patch.section_sha256 != section_sha256) continue;
        if (patch.expected_call.size()!=patch.replacement_call.size() ||
            patch.expected_edit.size()!=patch.replacement_edit.size() ||
            patch.replacement_call.size()!=9 || patch.expected_call[0]!=0x5d || patch.replacement_call[0]!=0x5d ||
            decoded_u16(patch.replacement_call.subspan(3))!=patch.local_block ||
            patch.expected_edit.empty() || patch.expected_edit[0]!=patch.replacement_edit[0])
            throw bb::FormatError("decoded override: invalid manifest windows");
        if (patch.local_block >= 10000) throw bb::FormatError("decoded override: local block required");
        bb::TbChunk *destination=nullptr, *source=nullptr;
        std::size_t source_definitions=0;
        for (auto& chunk : script.chunks) {
            if (chunk.offset == patch.destination_chunk) destination=&chunk;
            if (chunk.offset == patch.source_chunk) source=&chunk;
            for (const auto& tag : chunk.tags) {
                if (tag.id==0x4d && decoded_u16(tag.data)==patch.source_block) ++source_definitions;
                if (tag.id==0x4d && decoded_u16(tag.data)==patch.local_block)
                    throw bb::FormatError("decoded override: reserved block ID collision");
            }
        }
        if (source_definitions!=1) throw bb::FormatError("decoded override: ambiguous effective global block");
        if (!destination || !source || destination->type!=0x08 || source->type!=0x08)
            throw bb::FormatError("decoded override: expected templates absent");
        const auto id=destination->tag(0x27), parent=source->tag(0x27);
        if (id.size()!=4 || decoded_u16(id)!=patch.destination_id ||
            decoded_u16(id.subspan(2))!=patch.destination_parent || parent.size()!=4 ||
            decoded_u16(parent)!=patch.destination_parent)
            throw bb::FormatError("decoded override: template ancestry differs");
        auto call=std::find_if(destination->tags.begin(),destination->tags.end(),
            [&](const auto& tag){return tag.offset==patch.call_offset;});
        if (call==destination->tags.end() || !exact_tag(*call,patch.expected_call))
            throw bb::FormatError("decoded override: caller differs");
        auto block=std::find_if(source->tags.begin(),source->tags.end(),
            [&](const auto& tag){return tag.offset==patch.source_block_offset;});
        if (block==source->tags.end() || block->id!=0x4d || decoded_u16(block->data)!=patch.source_block)
            throw bb::FormatError("decoded override: source block differs");
        std::vector<bb::TbTag> cloned;
        for (auto it=block; it!=source->tags.end(); ++it) {
            if (it!=block && it->id==0x4d) break;
            if (it!=block && (it->id<0x4e || it->id>0x60))
                throw bb::FormatError("decoded override: malformed source block boundary");
            cloned.push_back(*it);
        }
        auto edit=std::find_if(cloned.begin(),cloned.end(),
            [&](const auto& tag){return tag.offset==patch.edit_offset;});
        if (edit==cloned.end() || !exact_tag(*edit,patch.expected_edit))
            throw bb::FormatError("decoded override: write operand signature differs");
        // Prepare all new payloads before changing the parsed script.
        for (auto& tag : cloned) tag.data=own_payload(storage,tag.data);
        auto& local_id=storage.payloads[storage.payloads.size()-cloned.size()];
        local_id[0]=uint8_t(patch.local_block); local_id[1]=uint8_t(patch.local_block>>8);
        const auto edited_index=std::size_t(edit-cloned.begin());
        // Full replacement windows belong to content data, never hard-coded operand semantics.
        cloned[edited_index].data=own_payload(storage,patch.replacement_edit.subspan(1));
        call->data=own_payload(storage,patch.replacement_call.subspan(1));
        destination->tags.insert(destination->tags.end(),cloned.begin(),cloned.end());
    }
}
} // namespace tb_compat
