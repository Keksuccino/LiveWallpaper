#pragma once

#include "Presentation/WallpaperFraming.hpp"

#include <cstdint>
#include <vulkan/vulkan.h>

namespace wallpaper
{

enum class WallpaperScalingMode : std::uint8_t
{
    NONE = 0,
    STRETCH = 1,
    FIT = 2,
    FILL = 3,
    // FIT's picture, with the room around it filled by a blurred, darkened copy
    // of the same picture as FILL would place it (see WallpaperBackdrop.hpp).
    FIT_BLURRED = 4,
};

// Whether a raw property value names a scaling mode.
constexpr bool IsWallpaperScalingMode(int32_t value) {
    return value >= 0 && value <= static_cast<int32_t>(WallpaperScalingMode::FIT_BLURRED);
}

struct PixelRect {
    int32_t x { 0 };
    int32_t y { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
};

struct WallpaperScalingLayout {
    double scene_width { 0.0 };
    double scene_height { 0.0 };
    double display_logical_width { 0.0 };
    double display_logical_height { 0.0 };
    double scale_x { 1.0 };
    double scale_y { 1.0 };
    PixelRect viewport_px {};
    PixelRect scissor_px {};
    // FIT_BLURRED only: whether the picture leaves room on the display for the
    // blurred copy, which is drawn over `backdrop_px` -- the picture as FILL at
    // a scale factor of 1 places it, centred whatever the position -- and only
    // where `viewport_px` does not cover. A gap of one pixel, the most rounding
    // leaves on a side when the shapes match, is no room.
    bool      backdrop { false };
    PixelRect backdrop_px {};
};

// `pan_x` and `pan_y` are `WallpaperFraming` fractions and are clamped the same
// way. The defaults centre the wallpaper exactly as the layout always has.
WallpaperScalingLayout ComputeWallpaperScalingLayout(
    WallpaperScalingMode mode,
    uint32_t scene_width,
    uint32_t scene_height,
    uint32_t display_logical_width,
    uint32_t display_logical_height,
    double display_scale_factor,
    double wallpaper_scale_factor,
    double pan_x = 0.5,
    double pan_y = 0.5);

// World rectangle the window covers, expressed for a cursor given in
// window-normalized coordinates: world = origin + (x, 1 - y) * size. The
// content rectangle is the part of it the wallpaper actually draws, which is
// smaller than the window whenever the presentation letterboxes.
struct WallpaperCursorMapping {
    double origin_x { 0.0 };
    double origin_y { 0.0 };
    double size_x { 0.0 };
    double size_y { 0.0 };
    double content_origin_x { 0.0 };
    double content_origin_y { 0.0 };
    double content_size_x { 0.0 };
    double content_size_y { 0.0 };
    bool   valid { false };
};

// The presented image is the camera rectangle scaled into layout.viewport_px,
// which FILL deliberately pushes outside the window. Cursor coordinates must
// follow that mapping, or hit testing drifts from what the display shows.
WallpaperCursorMapping ComputeWallpaperCursorMapping(const WallpaperScalingLayout& layout,
                                                     double camera_center_x, double camera_center_y,
                                                     double camera_width, double camera_height);

VkViewport MakeWallpaperViewport(const WallpaperScalingLayout& layout);
VkRect2D   MakeWallpaperScissor(const WallpaperScalingLayout& layout);

} // namespace wallpaper
