#include "Presentation/WallpaperScaling.hpp"
#include "Presentation/WallpaperBackdrop.hpp"

#include <algorithm>
#include <cmath>

namespace wallpaper
{

namespace
{

int32_t round_px(double value)
{
    return static_cast<int32_t>(std::lround(value));
}

double normalize_scale_factor(double factor)
{
    if (!std::isfinite(factor) || factor <= 0.0) return 1.0;
    return factor;
}

} // namespace

WallpaperScalingLayout ComputeWallpaperScalingLayout(
    WallpaperScalingMode mode,
    uint32_t scene_width,
    uint32_t scene_height,
    uint32_t display_logical_width,
    uint32_t display_logical_height,
    double display_scale_factor,
    double wallpaper_scale_factor,
    double pan_x,
    double pan_y)
{
    WallpaperScalingLayout layout {};
    layout.scene_width = std::max<uint32_t>(1, scene_width);
    layout.scene_height = std::max<uint32_t>(1, scene_height);
    layout.display_logical_width = std::max<uint32_t>(1, display_logical_width);
    layout.display_logical_height = std::max<uint32_t>(1, display_logical_height);

    const double sx = layout.display_logical_width / layout.scene_width;
    const double sy = layout.display_logical_height / layout.scene_height;

    switch (mode) {
    case WallpaperScalingMode::NONE:
        layout.scale_x = 1.0;
        layout.scale_y = 1.0;
        break;
    case WallpaperScalingMode::STRETCH:
        layout.scale_x = sx;
        layout.scale_y = sy;
        break;
    case WallpaperScalingMode::FIT:
    case WallpaperScalingMode::FIT_BLURRED: {
        const double scale = std::min(sx, sy);
        layout.scale_x = scale;
        layout.scale_y = scale;
        break;
    }
    case WallpaperScalingMode::FILL: {
        const double scale = std::max(sx, sy);
        layout.scale_x = scale;
        layout.scale_y = scale;
        break;
    }
    }

    const double user_factor = normalize_scale_factor(wallpaper_scale_factor);
    layout.scale_x *= user_factor;
    layout.scale_y *= user_factor;

    const double logical_width = layout.scene_width * layout.scale_x;
    const double logical_height = layout.scene_height * layout.scale_y;
    // The slack is what the display has left after the wallpaper, negative when
    // the wallpaper overflows it, so one expression places both a letterboxed
    // and a cropped wallpaper. `viewport_px.y` is measured from the window top,
    // so a pan of 0 puts the wallpaper's top edge on the display's top. A
    // mirrored wallpaper is flipped inside this rectangle by the backends, so
    // the position places the rectangle, not the mirrored picture.
    const WallpaperFraming framing = NormalizeWallpaperFraming({ pan_x, pan_y });
    const double logical_x = (layout.display_logical_width - logical_width) * framing.pan_x;
    const double logical_y = (layout.display_logical_height - logical_height) * framing.pan_y;

    layout.viewport_px = PixelRect {
        round_px(logical_x * display_scale_factor),
        round_px(logical_y * display_scale_factor),
        round_px(logical_width * display_scale_factor),
        round_px(logical_height * display_scale_factor),
    };
    layout.scissor_px = PixelRect {
        0,
        0,
        round_px(layout.display_logical_width * display_scale_factor),
        round_px(layout.display_logical_height * display_scale_factor),
    };
    if (mode == WallpaperScalingMode::FIT_BLURRED) {
        const double fill   = std::max(sx, sy);
        const double width  = layout.scene_width * fill;
        const double height = layout.scene_height * fill;
        layout.backdrop_px  = PixelRect {
            round_px((layout.display_logical_width - width) * 0.5 * display_scale_factor),
            round_px((layout.display_logical_height - height) * 0.5 * display_scale_factor),
            round_px(width * display_scale_factor),
            round_px(height * display_scale_factor),
        };
        const auto& picture = layout.viewport_px;
        const auto& window  = layout.scissor_px;
        layout.backdrop     = picture.x > window.x + 1 || picture.y > window.y + 1 ||
                          picture.x + picture.width < window.x + window.width - 1 ||
                          picture.y + picture.height < window.y + window.height - 1;
    }
    return layout;
}

WallpaperBackdropExtent ComputeWallpaperBackdropExtent(uint32_t source_width,
                                                       uint32_t source_height)
{
    const uint32_t width   = std::max<uint32_t>(1, source_width);
    const uint32_t height  = std::max<uint32_t>(1, source_height);
    const uint32_t longest = std::max(width, height);
    if (longest <= kWallpaperBackdropLongSide) return { width, height };
    const double shrink = static_cast<double>(kWallpaperBackdropLongSide) / longest;
    return {
        static_cast<uint32_t>(std::max(1L, std::lround(width * shrink))),
        static_cast<uint32_t>(std::max(1L, std::lround(height * shrink))),
    };
}

WallpaperBackdropDownsample ComputeWallpaperBackdropDownsample(uint32_t source_width,
                                                               uint32_t source_height,
                                                               WallpaperBackdropExtent extent)
{
    WallpaperBackdropDownsample downsample;
    downsample.block_x = static_cast<float>(std::max<uint32_t>(1, source_width)) /
                         static_cast<float>(std::max<uint32_t>(1, extent.width));
    downsample.block_y = static_cast<float>(std::max<uint32_t>(1, source_height)) /
                         static_cast<float>(std::max<uint32_t>(1, extent.height));
    // A bilinear tap averages two texels a side; taps at most four texels
    // apart read at least every other pair on each axis. See
    // kWallpaperBackdropTapSpacing.
    const float spacing = static_cast<float>(kWallpaperBackdropTapSpacing);
    downsample.taps_x =
        static_cast<uint32_t>(std::max(1.0f, std::ceil(downsample.block_x / spacing)));
    downsample.taps_y =
        static_cast<uint32_t>(std::max(1.0f, std::ceil(downsample.block_y / spacing)));
    return downsample;
}

WallpaperBackdropPlan ComputeWallpaperBackdropPlan(uint32_t source_width, uint32_t source_height)
{
    WallpaperBackdropPlan plan;
    const uint32_t width  = std::max<uint32_t>(1, source_width);
    const uint32_t height = std::max<uint32_t>(1, source_height);
    plan.extent = ComputeWallpaperBackdropExtent(width, height);
    const auto eighth = [](uint32_t size) {
        return (size + kWallpaperBackdropFirstStep - 1) / kWallpaperBackdropFirstStep;
    };
    plan.reduced = { std::max(plan.extent.width, eighth(width)),
                     std::max(plan.extent.height, eighth(height)) };
    plan.two_steps = width > plan.extent.width * kWallpaperBackdropFirstStep ||
                     height > plan.extent.height * kWallpaperBackdropFirstStep;
    if (! plan.two_steps) {
        plan.reduced = plan.extent;
        plan.second  = ComputeWallpaperBackdropDownsample(width, height, plan.extent);
        return plan;
    }
    plan.first  = ComputeWallpaperBackdropDownsample(width, height, plan.reduced);
    plan.second = ComputeWallpaperBackdropDownsample(plan.reduced.width, plan.reduced.height,
                                                     plan.extent);
    return plan;
}

WallpaperBackdropBands ComputeWallpaperBackdropBands(const WallpaperScalingLayout& layout)
{
    WallpaperBackdropBands bands;
    if (! layout.backdrop) return bands;
    const auto& window = layout.scissor_px;
    const auto& vp     = layout.viewport_px;
    const int32_t left   = std::clamp(vp.x, window.x, window.x + window.width);
    const int32_t right  = std::clamp(vp.x + vp.width, window.x, window.x + window.width);
    const int32_t top    = std::clamp(vp.y, window.y, window.y + window.height);
    const int32_t bottom = std::clamp(vp.y + vp.height, window.y, window.y + window.height);
    const auto add = [&bands](int32_t x, int32_t y, int32_t width, int32_t height) {
        if (width > 0 && height > 0) bands.rects[bands.count++] = PixelRect { x, y, width, height };
    };
    add(window.x, window.y, window.width, top - window.y);
    add(window.x, bottom, window.width, window.y + window.height - bottom);
    add(window.x, top, left - window.x, bottom - top);
    add(right, top, window.x + window.width - right, bottom - top);
    return bands;
}

WallpaperCursorMapping ComputeWallpaperCursorMapping(const WallpaperScalingLayout& layout,
                                                     double camera_center_x, double camera_center_y,
                                                     double camera_width, double camera_height) {
    const double viewport_width  = layout.viewport_px.width;
    const double viewport_height = layout.viewport_px.height;
    const double window_width    = layout.scissor_px.width;
    const double window_height   = layout.scissor_px.height;
    if (viewport_width <= 0.0 || viewport_height <= 0.0 || window_width <= 0.0 ||
        window_height <= 0.0 || ! std::isfinite(camera_width) || ! std::isfinite(camera_height) ||
        camera_width <= 0.0 || camera_height <= 0.0 || ! std::isfinite(camera_center_x) ||
        ! std::isfinite(camera_center_y)) {
        return {};
    }

    // Window pixel -> presented-image fraction -> camera world coordinate.
    const auto world_x = [&](double pixel) {
        return camera_center_x +
               ((pixel - layout.viewport_px.x) / viewport_width - 0.5) * camera_width;
    };
    const auto world_y = [&](double pixel) {
        return camera_center_y +
               (0.5 - (pixel - layout.viewport_px.y) / viewport_height) * camera_height;
    };

    const double left   = world_x(0.0);
    const double bottom = world_y(window_height);
    return WallpaperCursorMapping {
        .origin_x = left,
        .origin_y = bottom,
        .size_x   = world_x(window_width) - left,
        .size_y   = world_y(0.0) - bottom,
        // The drawn image is exactly the camera rectangle, however the viewport
        // is cropped or letterboxed against the window.
        .content_origin_x = camera_center_x - 0.5 * camera_width,
        .content_origin_y = camera_center_y - 0.5 * camera_height,
        .content_size_x   = camera_width,
        .content_size_y   = camera_height,
        .valid            = true,
    };
}

VkViewport MakeWallpaperViewport(const WallpaperScalingLayout& layout)
{
    const int32_t viewport_width = std::max(1, layout.viewport_px.width);
    const int32_t viewport_height = std::max(1, layout.viewport_px.height);

    return VkViewport {
        .x = static_cast<float>(layout.viewport_px.x),
        .y = static_cast<float>(layout.viewport_px.y + viewport_height),
        .width = static_cast<float>(viewport_width),
        .height = -static_cast<float>(viewport_height),
        .minDepth = 0.0f,
        .maxDepth = 1.0f,
    };
}

VkRect2D MakeWallpaperScissor(const WallpaperScalingLayout& layout)
{
    return VkRect2D {
        .offset = { layout.scissor_px.x, layout.scissor_px.y },
        .extent = {
            static_cast<uint32_t>(std::max(1, layout.scissor_px.width)),
            static_cast<uint32_t>(std::max(1, layout.scissor_px.height)),
        },
    };
}

} // namespace wallpaper
