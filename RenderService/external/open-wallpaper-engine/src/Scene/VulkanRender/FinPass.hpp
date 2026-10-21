#pragma once
#include "VulkanPass.hpp"
#include "PassCommon.hpp"
#include "WallpaperBackdropPass.hpp"
#include <string>

#include "Vulkan/Device.hpp"
#include "Vulkan/StagingBuffer.hpp"
#include "Vulkan/GraphicsPipeline.hpp"

#include "Scene/Scene.h"
#include "SpecTexs.hpp"

#include <vector>

namespace wallpaper
{
namespace vulkan
{

class FinPass : public VulkanPass {
public:
    struct Desc {
        // in
        const std::string_view result { SpecTex_Default };
        VkFormat               present_format;
        VkImageLayout          present_layout;
        uint32_t               present_queue_index;

        // prepared
        ImageParameters vk_result;
        ImageParameters vk_present;
        VkImageLayout   render_layout;
        VkClearValue    clear_value;

        StagingBufferRef   vertex_buf;
        StagingBufferRef   flipped_vertex_buf;
        PipelineParameters pipeline;
    };

    FinPass(const Desc&);
    virtual ~FinPass();

    void setPresent(ImageParameters);
    void setPresentLayout(VkImageLayout);
    void setPresentFormat(VkFormat);
    void setPresentQueueIndex(uint32_t);
    /// Whether the layout may ask for FIT_BLURRED's fill: its pipelines are
    /// built now, or with the next prepare.
    void setBackdropWanted(bool);
    /// The blurred fill, which a direct presentation draws with too.
    [[nodiscard]] WallpaperBackdropPass& backdrop() { return m_backdrop; }
    /// Bytes the blurred fill's images hold now.
    [[nodiscard]] uint64_t backdropBytes() const { return m_backdrop.allocatedBytes(); }

    void prepare(Scene&, const Device&, RenderingResources&) override;
    bool updateFrame(const Device&, RenderingResources&) override;
    VkResult execute(const Device&, RenderingResources&) override;
    void destory(const Device&, RenderingResources&) override;
    /// The scene output image this pass samples when it composes the frame.
    [[nodiscard]] const ImageParameters& sourceImage() const { return m_desc.vk_result; }
    /// A render pass compatible with this pass's pipeline that leaves its
    /// target ready to be copied from, for composing a poster.
    [[nodiscard]] VkRenderPass copySourcePass() const { return *m_copy_source_pass; }
    /// The composition `execute` records -- same source, vertices, viewport,
    /// scissor and blurred fill -- through `render_pass` into an
    /// `extent`-sized `framebuffer` of the present format.
    VkResult recordComposition(RenderingResources&, VkRenderPass render_pass,
                               VkFramebuffer framebuffer, VkExtent2D extent);

#ifdef WESCENE_BUILD_TESTS
    PipelineParameters& pipelineForTests() { return m_desc.pipeline; }
    void                destroyForTests(RenderingResources& rr) { resetPreparedState(rr); }
#endif

private:
    void resetPreparedState(RenderingResources&);

    Desc                                m_desc {};
    const Scene*                        m_scene { nullptr };
    std::vector<CachedColorFramebuffer> m_framebuffers;
    vvk::RenderPass                     m_copy_source_pass;
    const Device*                       m_device { nullptr };
    WallpaperBackdropPass               m_backdrop;
    bool                                m_backdrop_wanted { false };
};

} // namespace vulkan
} // namespace wallpaper
