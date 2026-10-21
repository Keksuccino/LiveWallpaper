#pragma once

#import <Metal/Metal.h>

#include "Presentation/WallpaperBackdrop.hpp"

#include <cstdint>
#include <map>
#include <string>

namespace wallpaper::metal
{

/// The blurred copy a FIT_BLURRED layout shows around the picture, drawn the
/// way `WallpaperBackdrop.hpp` describes. Nothing is compiled until the mode is
/// chosen (`prepare`) and nothing is allocated until a composition needs it;
/// the small images go again as soon as a composition does not.
class MetalWallpaperBackdrop {
public:
    MetalWallpaperBackdrop()                                         = default;
    MetalWallpaperBackdrop(const MetalWallpaperBackdrop&)            = delete;
    MetalWallpaperBackdrop& operator=(const MetalWallpaperBackdrop&) = delete;

    /// Compiles the pipelines for a target of `format`, outside any frame: a
    /// pipeline built inside one would hold the frame on the shader compiler.
    bool prepare(id<MTLDevice> device, MTLPixelFormat format);
    /// Reduces and blurs `source` into this object's own image, encoded into
    /// `command` ahead of the composition that `drawBands` draws into.
    bool encodeBlur(id<MTLDevice> device, id<MTLCommandBuffer> command, id<MTLTexture> source,
                    id<MTLSamplerState> linear);
    /// Fills the room `layout` leaves around the picture in `encoder`, whose
    /// target is `width` x `height` pixels of `format`, from the image the
    /// last `encodeBlur` drew. Leaves the encoder's scissor on the whole target.
    bool drawBands(id<MTLDevice> device, id<MTLRenderCommandEncoder> encoder,
                   MTLPixelFormat format, uint32_t width, uint32_t height,
                   const WallpaperScalingLayout& layout, bool horizontal_flip,
                   id<MTLSamplerState> linear);
    /// Drops the small images. The compiled pipelines stay, for the next time.
    void release();
    /// Bytes the small images hold now; 0 while none is allocated.
    [[nodiscard]] uint64_t allocatedBytes() const;
    [[nodiscard]] const std::string& lastError() const { return last_error_; }

private:
    bool ensureLibrary(id<MTLDevice> device);
    id<MTLRenderPipelineState> pipeline(id<MTLDevice> device, NSString* fragment,
                                        MTLPixelFormat format);
    bool ensureImages(id<MTLDevice> device, const WallpaperBackdropPlan& plan);
    bool fail(std::string message);

    id<MTLLibrary>                                  library_ { nil };
    std::map<std::string, id<MTLRenderPipelineState>> pipelines_;
    id<MTLTexture>                                  reduced_ { nil };
    id<MTLTexture>                                  blurred_ { nil };
    id<MTLTexture>                                  scratch_ { nil };
    std::string                                     last_error_;
};

} // namespace wallpaper::metal
