#pragma once

#include "Presentation/WallpaperScaling.hpp"

#include <array>
#include <cstdint>

namespace wallpaper
{

// The blurred fill behind a FIT_BLURRED wallpaper, shared by both backends so
// they draw the same thing.
//
// The scene's finished picture is box-filtered down to a small image whose
// longer side is `kWallpaperBackdropLongSide` texels. A large picture is
// reduced in two steps, first to an eighth of its size in an 8-bit image,
// because one pass that averaged a whole block of a 4K picture per pixel would
// read hundreds of texels in a row per pixel and keep the GPU busy for
// milliseconds. Each step reads bilinear taps (two texels a side) spaced at
// most `kWallpaperBackdropTapSpacing` texels apart, so at least a quarter of
// the texels count, spread evenly over the block. Reading all of them would
// cost a 6880-wide raster about three times as much GPU time, and what is
// skipped should not show: the copy is then blurred over about 160 of those
// texels, so by estimate a one-pixel line that moves in and out of the taps
// changes it by less than one 8-bit step (not measured). The small image is
// blurred by a separable Gaussian of `kWallpaperBackdropSigma` texels (taps
// out to `kWallpaperBackdropRadius`, edges clamped) and drawn over the
// display's room around the picture: stretched over `backdrop_px` (the picture
// as Fill would place it, centred), sampled through a cubic B-spline so the
// magnification shows no texel grid, scaled by `kWallpaperBackdropDim`, and
// dithered by one 8-bit step so the dark gradients do not band. The picture
// itself is drawn exactly as Fit draws it.
inline constexpr uint32_t kWallpaperBackdropLongSide = 128;
inline constexpr uint32_t kWallpaperBackdropFirstStep = 8;
inline constexpr uint32_t kWallpaperBackdropTapSpacing = 4;
inline constexpr float    kWallpaperBackdropSigma    = 3.0f;
inline constexpr int      kWallpaperBackdropRadius   = 9;
inline constexpr float    kWallpaperBackdropDim      = 0.7f;

struct WallpaperBackdropExtent {
    uint32_t width { 1 };
    uint32_t height { 1 };
};

// The small image a `source_width` x `source_height` picture is reduced to:
// the source's aspect, its longer side `kWallpaperBackdropLongSide` (never
// larger than the source), and never below one texel.
WallpaperBackdropExtent ComputeWallpaperBackdropExtent(uint32_t source_width,
                                                       uint32_t source_height);

// How the box filter covers one small texel: `taps_x` by `taps_y` bilinear
// samples spread evenly over the source block `block_x` by `block_y` texels
// wide, at most `kWallpaperBackdropTapSpacing` texels apart.
struct WallpaperBackdropDownsample {
    float    block_x { 1.0f };
    float    block_y { 1.0f };
    uint32_t taps_x { 1 };
    uint32_t taps_y { 1 };
};

WallpaperBackdropDownsample ComputeWallpaperBackdropDownsample(uint32_t source_width,
                                                               uint32_t source_height,
                                                               WallpaperBackdropExtent extent);

// The reduction of a `source_width` x `source_height` picture: straight to
// `extent`, or, when that would cover blocks wider than eight texels, first
// to `reduced` (an eighth of the source, rounded up) and then to `extent`.
// For a picture up to 8192 texels long, no pixel of either step reads more
// than four bilinear taps.
struct WallpaperBackdropPlan {
    bool                        two_steps { false };
    WallpaperBackdropExtent     reduced {};
    WallpaperBackdropDownsample first {};
    WallpaperBackdropExtent     extent {};
    WallpaperBackdropDownsample second {};
};

WallpaperBackdropPlan ComputeWallpaperBackdropPlan(uint32_t source_width, uint32_t source_height);

// The parts of the display the picture leaves uncovered, in device pixels:
// a band above and below it the display's full width, and one either side of
// it between those. Empty unless `layout.backdrop`.
struct WallpaperBackdropBands {
    std::array<PixelRect, 4> rects {};
    uint32_t                 count { 0 };
};

WallpaperBackdropBands ComputeWallpaperBackdropBands(const WallpaperScalingLayout& layout);

} // namespace wallpaper
