#pragma once

#include "Resource.hpp"

#include "Presentation/WallpaperBackdrop.hpp"

#include "Vulkan/Device.hpp"
#include "Vulkan/GraphicsPipeline.hpp"

#include <cstdint>

namespace wallpaper
{
namespace vulkan
{

/// The Compatibility backend's blurred fill for a FIT_BLURRED layout, drawn the
/// way `Presentation/WallpaperBackdrop.hpp` describes and with the same
/// arithmetic as the native backend's `MetalWallpaperBackdrop`. Nothing is
/// built until the mode is chosen (`prepare`), nothing is allocated until a
/// composition needs it, and the small images go again as soon as a
/// composition does not.
class WallpaperBackdropPass : NoCopy, NoMove {
public:
    WallpaperBackdropPass()  = default;
    ~WallpaperBackdropPass() = default;

    /// Compiles the pipelines for a composition in `present_format`, outside
    /// any frame.
    bool prepare(const Device&, VkFormat present_format);
    /// Reduces and blurs `source`, which is laid out for shader reads, into
    /// this pass's own image. Recorded outside any render pass, before the
    /// composition whose render pass of `present_format` `drawBands` draws in.
    VkResult recordBlur(const Device&, vvk::CommandBuffer&, const ImageParameters& source);
    /// Inside the composition's render pass on an `extent` target: fills the
    /// room around the picture that `rr` describes from the image the last
    /// `recordBlur` drew. Binds its own pipeline and leaves the viewport and
    /// scissor for the caller to set.
    void drawBands(vvk::CommandBuffer&, const RenderingResources& rr, VkExtent2D extent) const;
    /// Drops the small images. The pipelines stay, for the next time.
    void release();
    /// Drops everything, before the device goes.
    void destroy();
    /// Bytes the small images hold now; 0 while none is allocated.
    [[nodiscard]] uint64_t allocatedBytes() const;

private:
    struct Target {
        VmaImageParameters image;
        vvk::Framebuffer   framebuffer;
    };

    bool ensureImages(const Device&, const WallpaperBackdropPlan& plan);
    bool createTarget(const Device&, VkFormat, uint32_t width, uint32_t height,
                      VkRenderPass pass, Target& target);

    VkFormat           m_present_format { VK_FORMAT_UNDEFINED };
    PipelineParameters m_reduce;
    PipelineParameters m_downsample;
    PipelineParameters m_blur;
    PipelineParameters m_composite;
    vvk::Sampler       m_sampler;
    Target             m_reduced;
    Target             m_blurred;
    Target             m_scratch;
    uint64_t           m_bytes { 0 };
};

} // namespace vulkan
} // namespace wallpaper
