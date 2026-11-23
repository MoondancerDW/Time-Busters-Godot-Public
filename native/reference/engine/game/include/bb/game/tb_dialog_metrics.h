#pragma once

namespace bb::game {

// The display profile applies to this native tick only, even when several worlds
// with different assets share a thread. No saved or gameplay state is involved.
class TbDialogMetricsScope final {
public:
    explicit TbDialogMetricsScope(bool russian) noexcept;
    ~TbDialogMetricsScope() noexcept;
    TbDialogMetricsScope(const TbDialogMetricsScope&) = delete;
    TbDialogMetricsScope& operator=(const TbDialogMetricsScope&) = delete;

private:
    bool previous_;
};

}  // namespace bb::game
