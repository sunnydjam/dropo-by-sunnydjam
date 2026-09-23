#include "../window_geometry.h"

// These assertions run on every Windows runner build, including the release
// gate, without launching a window or touching the user's saved placement.
namespace {
using dropo::window_geometry::ClampToWorkArea;
using dropo::window_geometry::kPlacementVersion;
using dropo::window_geometry::LogicalPixels;
using dropo::window_geometry::Rect;
using dropo::window_geometry::SavedPlacement;
using dropo::window_geometry::ScaleForDpi;
using dropo::window_geometry::ValidPlacement;

constexpr bool Equal(Rect a, Rect b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

static_assert(ScaleForDpi(820, 96) == 820);
static_assert(ScaleForDpi(820, 120) == 1025);
static_assert(ScaleForDpi(560, 144) == 840);
static_assert(ScaleForDpi(560, 192) == 1120);
static_assert(ScaleForDpi(-10, 96) == -10);
static_assert(ScaleForDpi(-820, 120) == -1025);
static_assert(LogicalPixels(1025, 120) == 820);
static_assert(LogicalPixels(840, 144) == 560);
static_assert(LogicalPixels(1120, 192) == 560);
static_assert(LogicalPixels(560, 0) == 560);

constexpr Rect kWork{0, 0, 1920, 1040};
static_assert(Equal(ClampToWorkArea({100, 100, 936, 699}, kWork),
                    {100, 100, 936, 699}));
// A disconnected secondary display must not leave the window offscreen.
static_assert(Equal(ClampToWorkArea({2400, 200, 3236, 799}, kWork),
                    {1084, 200, 1920, 799}));
// Respect taskbars at the top and left, including negative monitor origins.
static_assert(Equal(ClampToWorkArea({-2000, -20, -1164, 579},
                                  {-1880, 40, 0, 1080}),
                    {-1880, 40, -1044, 639}));
// A small work area still contains every edge (Flutter may scroll within it).
static_assert(Equal(ClampToWorkArea({10, 10, 1682, 1208},
                                  {0, 0, 1280, 680}),
                    {0, 0, 1280, 680}));
static_assert(Equal(ClampToWorkArea({100, 100, 900, 700},
                                  {0, 0, 0, 0}),
                    {100, 100, 900, 700}));

static_assert(ValidPlacement({kPlacementVersion, {-1800, 80, -964, 679},
                             820, 560}));
static_assert(!ValidPlacement({0, {10, 10, 846, 609}, 820, 560}));
static_assert(!ValidPlacement({kPlacementVersion, {10, 10, 846, 609},
                              0, 560}));
static_assert(!ValidPlacement({kPlacementVersion, {10, 10, 846, 609},
                              820, 20000}));
static_assert(!ValidPlacement({kPlacementVersion,
                              {-32000, -32000, -32000, -32000}, 820, 560}));
static_assert(!ValidPlacement({kPlacementVersion,
                              {2000000, 10, 2000836, 609}, 820, 560}));
}  // namespace
