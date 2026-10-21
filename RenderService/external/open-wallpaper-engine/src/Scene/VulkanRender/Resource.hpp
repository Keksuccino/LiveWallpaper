#pragma once
#include <array>
#include "Core/NoCopyMove.hpp"
#include "Vulkan/StagingBuffer.hpp"
#include <memory>

namespace wallpaper
{
namespace vulkan
{
class TexturePrefetch;
class WallpaperBackdropPass;

struct RenderingResources {
    vvk::CommandBuffer command;

    vvk::Semaphore sem_swap_wait_image;
    vvk::Semaphore sem_swap_finish;
    // Exportable (SYNC_FD) semaphore signaled on every offscreen frame
    // submit. The host exports it via vkGetSemaphoreFdKHR and ships the
    // resulting dma_fence sync_file to the waywallen daemon on
    // FrameReady events.
    vvk::Semaphore sem_export;
    vvk::Fence     fence_frame;

    StagingBuffer* vertex_buf { nullptr };
    StagingBuffer* dyn_buf { nullptr };
    /// Set only while passes are being prepared: images decoded ahead of the
    /// pass that binds them. Null means every pass parses its own.
    TexturePrefetch* texture_prefetch { nullptr };

    VkViewport wallpaper_viewport {};
    VkRect2D   wallpaper_scissor {};
    bool       wallpaper_horizontal_flip { false };
    /// FIT_BLURRED's fill: whether the room around the picture is filled, the
    /// rectangle the blurred copy is stretched over (FILL's, so it can begin
    /// off the target) and the room's parts, all in target pixels from the top.
    bool                    wallpaper_backdrop { false };
    /// Draws that fill: the final composition's own, which a plain video's
    /// direct presentation borrows. Null while there is no composition.
    WallpaperBackdropPass*  wallpaper_backdrop_pass { nullptr };
    VkRect2D                wallpaper_backdrop_rect {};
    std::array<VkRect2D, 4> wallpaper_backdrop_bands {};
    uint32_t                wallpaper_backdrop_band_count { 0 };
};
} // namespace vulkan
} // namespace wallpaper
