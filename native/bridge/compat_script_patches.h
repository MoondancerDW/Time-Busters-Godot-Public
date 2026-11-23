#pragma once

#include "bb/bze.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace tb_compat {

struct ScriptPatch {
    std::string_view section_sha256;
    std::size_t offset;
    std::span<const std::uint8_t> original;
    std::span<const std::uint8_t> replacement;
};

// TRCASG01 actor 308, M394: run the reset after even an immediate result confirmation.
// The Russian and English containers share this exact instruction section.
inline constexpr std::array<std::uint8_t, 9> kRugbyResetOriginal{
    0x52, 0x08, 0x00, 0x10, 0x00, 0x14, 0x00, 0x00, 0x00,
};
inline constexpr std::array<std::uint8_t, 9> kRugbyResetReplacement{
    0x52, 0x08, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
};

inline constexpr std::array kScriptPatches{
    ScriptPatch{
        "1d2dd3066fe43c91cdfda1357abab40555ce92a2896f32d618fb339bb034d15d",
        154343,
        kRugbyResetOriginal,
        kRugbyResetReplacement,
    },
};

template <typename Hash>
void apply_script_patches(bb::BzeFile &container, const Hash &hash) {
    if (container.compressed) return;
    const int section_index = container.find(1);
    if (section_index < 0) return;

    const auto &section = container.sections[std::size_t(section_index)];
    auto bytes = std::span(container.bytes);
    if (section.offset > bytes.size() || section.actualSize > bytes.size() - section.offset) {
        throw bb::FormatError("Time Busters script section is outside its container");
    }
    auto script = bytes.subspan(section.offset, section.actualSize);
    const auto source_sha256 = hash(std::span<const std::uint8_t>(script));

    for (const auto &patch : kScriptPatches) {
        if (patch.section_sha256 != source_sha256) continue;
        if (patch.original.size() != patch.replacement.size() ||
            patch.offset > script.size() || patch.original.size() > script.size() - patch.offset) {
            throw bb::FormatError("Time Busters script patch has an invalid window");
        }
        const auto instruction = script.subspan(patch.offset, patch.original.size());
        if (!std::equal(patch.original.begin(), patch.original.end(), instruction.begin())) {
            throw bb::FormatError("Time Busters script patch does not match the source instruction");
        }
        std::copy(patch.replacement.begin(), patch.replacement.end(), instruction.begin());
    }
}

} // namespace tb_compat
