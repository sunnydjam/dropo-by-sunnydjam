#ifndef RUNNER_WINDOW_GEOMETRY_H_
#define RUNNER_WINDOW_GEOMETRY_H_

#include <algorithm>
#include <cstdint>

// Pure geometry helpers are also exercised by compile-time regression tests.
// Positions are signed physical screen coordinates; client sizes are logical
// pixels, so moving between monitors does not change the user's chosen scale.
namespace dropo::window_geometry {

struct Rect {
  int left;
  int top;
  int right;
  int bottom;
};

struct SavedPlacement {
  uint32_t version;
  Rect normal_bounds;
  int client_width;
  int client_height;
};

constexpr uint32_t kPlacementVersion = 1;

constexpr int ScaleForDpi(int value, unsigned int dpi) {
  const int64_t scaled = static_cast<int64_t>(value) * dpi;
  return static_cast<int>((scaled + (scaled < 0 ? -48 : 48)) / 96);
}

constexpr int LogicalPixels(int value, unsigned int dpi) {
  return dpi == 0 ? value : static_cast<int>(
      (static_cast<int64_t>(value) * 96 + dpi / 2) / dpi);
}

constexpr bool ValidPlacement(const SavedPlacement& saved) {
  const auto bounds = saved.normal_bounds;
  // Reject corrupt/stale records before passing values to the Win32 APIs.
  // Negative coordinates are expected on monitors left/above the primary one.
  return saved.version == kPlacementVersion &&
         saved.client_width >= 120 && saved.client_width <= 16384 &&
         saved.client_height >= 80 && saved.client_height <= 16384 &&
         bounds.left >= -1000000 && bounds.top >= -1000000 &&
         bounds.right <= 1000000 && bounds.bottom <= 1000000 &&
         bounds.right > bounds.left && bounds.bottom > bounds.top;
}

constexpr Rect ClampToWorkArea(Rect bounds, Rect work) {
  if (work.right <= work.left || work.bottom <= work.top) {
    return bounds;
  }
  const int width = std::clamp(bounds.right - bounds.left, 1,
                               work.right - work.left);
  const int height = std::clamp(bounds.bottom - bounds.top, 1,
                                work.bottom - work.top);
  const int left = std::clamp(bounds.left, work.left, work.right - width);
  const int top = std::clamp(bounds.top, work.top, work.bottom - height);
  return {left, top, left + width, top + height};
}

}  // namespace dropo::window_geometry

#endif  // RUNNER_WINDOW_GEOMETRY_H_
