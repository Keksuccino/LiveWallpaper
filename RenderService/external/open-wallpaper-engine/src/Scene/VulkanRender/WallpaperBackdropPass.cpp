#include "WallpaperBackdropPass.hpp"

#include "Core/ArrayHelper.hpp"
#include "Presentation/WallpaperBackdrop.hpp"
#include "Utils/Logging.h"
#include "Vulkan/Shader.hpp"
#include "Vulkan/ShaderComp.hpp"

#include <algorithm>
#include <array>
#include <cstring>
#include <optional>
#include <string_view>

using namespace wallpaper::vulkan;

namespace
{

// The same arithmetic as the native backend's MSL in
// MetalWallpaperBackdrop.mm; a change to one is a change to both.
constexpr std::string_view kVertex = R"(#version 450
// A strip over the whole target: every stage works from the pixel it shades.
void main() {
    vec2 corner = vec2(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1));
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}
)";

// source.xy: source size; source.zw: source texels per small texel.
constexpr std::string_view kDownsample = R"(#version 450
layout(location = 0) out vec4 out_colour;
layout(binding = 0) uniform sampler2D u_source;
layout(push_constant) uniform Parameters {
    vec4  source;
    uvec4 taps;
} p;
void main() {
    vec2 origin  = floor(gl_FragCoord.xy) * p.source.zw;
    vec2 spacing = p.source.zw / vec2(p.taps.xy);
    vec4 sum     = vec4(0.0);
    for (uint y = 0u; y < p.taps.y; ++y) {
        for (uint x = 0u; x < p.taps.x; ++x) {
            vec2 at = origin + (vec2(float(x), float(y)) + 0.5) * spacing;
            sum += textureLod(u_source, at / p.source.xy, 0.0);
        }
    }
    out_colour = sum / float(p.taps.x * p.taps.y);
}
)";

// image.xy: image size; image.zw: direction. blur.x: sigma, blur.y: radius.
constexpr std::string_view kBlur = R"(#version 450
layout(location = 0) out vec4 out_colour;
layout(binding = 0) uniform sampler2D u_source;
layout(push_constant) uniform Parameters {
    vec4 image;
    vec4 blur;
} p;
void main() {
    vec2  centre = floor(gl_FragCoord.xy) + 0.5;
    float sigma  = p.blur.x;
    int   radius = int(p.blur.y);
    vec4  sum    = vec4(0.0);
    float total  = 0.0;
    for (int i = -radius; i <= radius; ++i) {
        float weight = exp(-float(i * i) / (2.0 * sigma * sigma));
        sum += weight * textureLod(u_source, (centre + p.image.zw * float(i)) / p.image.xy, 0.0);
        total += weight;
    }
    out_colour = sum / total;
}
)";

// rect: where the blurred image lies on the target, in pixels. image: its
// size, then the dimming and whether it is mirrored.
constexpr std::string_view kComposite = R"(#version 450
layout(location = 0) out vec4 out_colour;
layout(binding = 0) uniform sampler2D u_blurred;
layout(push_constant) uniform Parameters {
    vec4 rect;
    vec4 image;
} p;
void main() {
    vec2 uv = (gl_FragCoord.xy - p.rect.xy) / p.rect.zw;
    if (p.image.w != 0.0) uv.x = 1.0 - uv.x;
    // A cubic B-spline from four bilinear samples: the magnified image shows
    // no grid of its texels.
    vec2 size = p.image.xy;
    vec2 st   = uv * size - 0.5;
    vec2 i    = floor(st);
    vec2 f    = st - i;
    vec2 f2   = f * f;
    vec2 f3   = f2 * f;
    vec2 w0   = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    vec2 w1   = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    vec2 w2   = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    vec2 w3   = f3 / 6.0;
    vec2 g0   = w0 + w1;
    vec2 g1   = w2 + w3;
    vec2 h0   = (i - 0.5 + w1 / g0) / size;
    vec2 h1   = (i + 1.5 + w3 / g1) / size;
    vec4 colour =
        g0.y * (g0.x * textureLod(u_blurred, vec2(h0.x, h0.y), 0.0) +
                g1.x * textureLod(u_blurred, vec2(h1.x, h0.y), 0.0)) +
        g1.y * (g0.x * textureLod(u_blurred, vec2(h0.x, h1.y), 0.0) +
                g1.x * textureLod(u_blurred, vec2(h1.x, h1.y), 0.0));
    // Interleaved gradient noise, one 8-bit step: dark gradients do not band.
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    out_colour = vec4(colour.rgb * p.image.z + (noise - 0.5) / 255.0, 1.0);
}
)";

struct Parameters {
    float values[8];
};

constexpr VkFormat kImageFormat   = VK_FORMAT_R16G16B16A16_SFLOAT;
constexpr VkFormat kReducedFormat = VK_FORMAT_R8G8B8A8_UNORM;

std::optional<vvk::RenderPass> CreatePass(const vvk::Device& device, VkFormat format,
                                          VkAttachmentLoadOp load, VkImageLayout final_layout) {
    const VkAttachmentDescription attachment {
        .format         = format,
        .samples        = VK_SAMPLE_COUNT_1_BIT,
        .loadOp         = load,
        .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout    = final_layout,
    };
    const VkAttachmentReference reference {
        .attachment = 0,
        .layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const VkSubpassDescription subpass {
        .pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments    = &reference,
    };
    // The image was last read by a fragment shader (the previous step, or last
    // frame's composition), and the next step reads what this one writes.
    const std::array dependencies {
        VkSubpassDependency {
            .srcSubpass    = VK_SUBPASS_EXTERNAL,
            .dstSubpass    = 0,
            .srcStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT |
                            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        },
        VkSubpassDependency {
            .srcSubpass    = 0,
            .dstSubpass    = VK_SUBPASS_EXTERNAL,
            .srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
        },
    };
    const VkRenderPassCreateInfo info {
        .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments    = &attachment,
        .subpassCount    = 1,
        .pSubpasses      = &subpass,
        .dependencyCount = static_cast<uint32_t>(dependencies.size()),
        .pDependencies   = dependencies.data(),
    };
    vvk::RenderPass pass;
    if (device.CreateRenderPass(info, pass) != VK_SUCCESS) return std::nullopt;
    return pass;
}

bool CreatePipeline(const Device& device, std::string_view fragment, vvk::RenderPass pass,
                    PipelineParameters& out) {
    std::vector<Uni_ShaderSpv> spvs;
    ShaderCompOpt              opt;
    opt.client_ver             = glslang::EShTargetVulkan_1_1;
    opt.relaxed_errors_glsl    = true;
    opt.relaxed_rules_vulkan   = true;
    opt.suppress_warnings_glsl = true;
    const std::array units {
        ShaderCompUnit { .stage = EShLangVertex, .src = std::string(kVertex) },
        ShaderCompUnit { .stage = EShLangFragment, .src = std::string(fragment) },
    };
    if (! CompileAndLinkShaderUnits(units, opt, spvs)) return false;

    DescriptorSetInfo descriptors;
    descriptors.push_descriptor = true;
    descriptors.bindings.push_back(VkDescriptorSetLayoutBinding {
        .binding         = 0,
        .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    });
    GraphicsPipeline pipeline;
    pipeline.toDefault();
    pipeline.addDescriptorSetInfo(wallpaper::spanone { descriptors })
        .addPushConstantRange(VkPushConstantRange {
            .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset     = 0,
            .size       = sizeof(Parameters),
        })
        .setTopology(VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP);
    for (auto& spv : spvs) pipeline.addStage(std::move(spv));
    return pipeline.create(device, pass, out);
}

void Bind(vvk::CommandBuffer& cmd, const PipelineParameters& pipeline, VkSampler sampler,
          VkImageView view, const Parameters& parameters) {
    cmd.BindPipeline(VK_PIPELINE_BIND_POINT_GRAPHICS, *pipeline.handle);
    const VkDescriptorImageInfo image {
        .sampler     = sampler,
        .imageView   = view,
        .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const VkWriteDescriptorSet write {
        .sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstBinding      = 0,
        .descriptorCount = 1,
        .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo      = &image,
    };
    cmd.PushDescriptorSetKHR(VK_PIPELINE_BIND_POINT_GRAPHICS, *pipeline.layout, 0, write);
    cmd.PushConstants(*pipeline.layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(parameters),
                      &parameters);
}

} // namespace

bool WallpaperBackdropPass::prepare(const Device& device, VkFormat present_format) {
    if (present_format == VK_FORMAT_UNDEFINED) return false;
    if (m_present_format == present_format && m_reduce.handle && m_downsample.handle &&
        m_blur.handle && m_composite.handle && m_sampler)
        return true;
    m_present_format = VK_FORMAT_UNDEFINED;
    const auto image_pass = [&device](VkFormat format = kImageFormat) {
        return CreatePass(device.handle(), format, VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                          VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    };
    // Only for building a pipeline the composition's render passes are
    // compatible with: the same single attachment of the present format.
    auto reduce_pass     = image_pass(kReducedFormat);
    auto downsample_pass = image_pass();
    auto blur_pass       = image_pass();
    auto composite_pass  = CreatePass(device.handle(), present_format, VK_ATTACHMENT_LOAD_OP_CLEAR,
                                      VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
    if (! reduce_pass || ! downsample_pass || ! blur_pass || ! composite_pass ||
        ! CreatePipeline(device, kDownsample, std::move(*reduce_pass), m_reduce) ||
        ! CreatePipeline(device, kDownsample, std::move(*downsample_pass), m_downsample) ||
        ! CreatePipeline(device, kBlur, std::move(*blur_pass), m_blur) ||
        ! CreatePipeline(device, kComposite, std::move(*composite_pass), m_composite)) {
        LOG_ERROR("the blurred fill's pipelines could not be built");
        return false;
    }
    if (! m_sampler) {
        const VkSamplerCreateInfo sampler {
            .sType        = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter    = VK_FILTER_LINEAR,
            .minFilter    = VK_FILTER_LINEAR,
            .mipmapMode   = VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .maxLod       = 0.0f,
        };
        if (device.handle().CreateSampler(sampler, m_sampler) != VK_SUCCESS) return false;
    }
    m_present_format = present_format;
    return true;
}

bool WallpaperBackdropPass::createTarget(const Device& device, VkFormat format, uint32_t width,
                                         uint32_t height, VkRenderPass pass, Target& target) {
    target.image.extent = VkExtent3D { width, height, 1 };
    const VkImageCreateInfo image {
        .sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType     = VK_IMAGE_TYPE_2D,
        .format        = format,
        .extent        = target.image.extent,
        .mipLevels     = 1,
        .arrayLayers   = 1,
        .samples       = VK_SAMPLE_COUNT_1_BIT,
        .tiling        = VK_IMAGE_TILING_OPTIMAL,
        .usage         = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode   = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    const VmaAllocationCreateInfo allocation { .usage = VMA_MEMORY_USAGE_GPU_ONLY };
    if (vvk::CreateImage(device.vma_allocator(), image, allocation, target.image.handle) !=
        VK_SUCCESS)
        return false;
    VmaAllocationInfo allocated {};
    vmaGetAllocationInfo(device.vma_allocator(), target.image.handle.Allocation(), &allocated);
    m_bytes += allocated.size;
    const VkImageViewCreateInfo view {
        .sType            = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image            = *target.image.handle,
        .viewType         = VK_IMAGE_VIEW_TYPE_2D,
        .format           = format,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    if (device.handle().CreateImageView(view, target.image.view) != VK_SUCCESS) return false;
    const VkImageView attachment = *target.image.view;
    const VkFramebufferCreateInfo framebuffer {
        .sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass      = pass,
        .attachmentCount = 1,
        .pAttachments    = &attachment,
        .width           = width,
        .height          = height,
        .layers          = 1,
    };
    return device.handle().CreateFramebuffer(framebuffer, target.framebuffer) == VK_SUCCESS;
}

bool WallpaperBackdropPass::ensureImages(const Device& device,
                                         const wallpaper::WallpaperBackdropPlan& plan) {
    const bool reduced_fits =
        plan.two_steps ? m_reduced.image.handle && m_reduced.image.extent.width == plan.reduced.width &&
                             m_reduced.image.extent.height == plan.reduced.height
                       : ! m_reduced.image.handle;
    if (m_blurred.image.handle && m_blurred.image.extent.width == plan.extent.width &&
        m_blurred.image.extent.height == plan.extent.height && reduced_fits)
        return true;
    release();
    const bool created =
        createTarget(device, kImageFormat, plan.extent.width, plan.extent.height, *m_blur.pass,
                     m_blurred) &&
        createTarget(device, kImageFormat, plan.extent.width, plan.extent.height, *m_blur.pass,
                     m_scratch) &&
        (! plan.two_steps || createTarget(device, kReducedFormat, plan.reduced.width,
                                          plan.reduced.height, *m_reduce.pass, m_reduced));
    if (! created) {
        release();
        return false;
    }
    LOG_INFO("blurred fill images: %ux%u%s, %llu bytes", plan.extent.width, plan.extent.height,
             plan.two_steps ? (" after " + std::to_string(plan.reduced.width) + "x" +
                               std::to_string(plan.reduced.height)).c_str()
                            : "",
             static_cast<unsigned long long>(m_bytes));
    return true;
}

VkResult WallpaperBackdropPass::recordBlur(const Device& device, vvk::CommandBuffer& cmd,
                                           const ImageParameters& source) {
    if (m_present_format == VK_FORMAT_UNDEFINED || source.view == VK_NULL_HANDLE)
        return VK_ERROR_INITIALIZATION_FAILED;
    const auto plan = wallpaper::ComputeWallpaperBackdropPlan(source.extent.width,
                                                              source.extent.height);
    const auto extent = plan.extent;
    if (! ensureImages(device, plan)) return VK_ERROR_OUT_OF_DEVICE_MEMORY;

    const auto pass = [&](const Target& target, const PipelineParameters& pipeline,
                          VkImageView input, const Parameters& parameters) {
        const uint32_t width  = target.image.extent.width;
        const uint32_t height = target.image.extent.height;
        const VkRenderPassBeginInfo begin {
            .sType       = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass  = *pipeline.pass,
            .framebuffer = *target.framebuffer,
            .renderArea  = { { 0, 0 }, { width, height } },
        };
        cmd.BeginRenderPass(begin, VK_SUBPASS_CONTENTS_INLINE);
        Bind(cmd, pipeline, *m_sampler, input, parameters);
        VkViewport viewport {
            0.0f, 0.0f, static_cast<float>(width), static_cast<float>(height), 0.0f, 1.0f,
        };
        VkRect2D scissor { { 0, 0 }, { width, height } };
        cmd.SetViewport(0, viewport);
        cmd.SetScissor(0, scissor);
        cmd.Draw(4, 1, 0, 0);
        cmd.EndRenderPass();
    };

    const auto parameters = [](uint32_t width, uint32_t height,
                               const wallpaper::WallpaperBackdropDownsample& taps) {
        Parameters reduce {};
        const float sizes[4] = { static_cast<float>(width), static_cast<float>(height),
                                 taps.block_x, taps.block_y };
        std::copy(std::begin(sizes), std::end(sizes), reduce.values);
        // The tap counts are read as unsigned integers, so they go in as their bits.
        const uint32_t tap_counts[4] = { taps.taps_x, taps.taps_y, 0, 0 };
        std::memcpy(&reduce.values[4], tap_counts, sizeof(tap_counts));
        return reduce;
    };
    const float width  = static_cast<float>(extent.width);
    const float height = static_cast<float>(extent.height);
    const Parameters across { { width, height, 1.0f, 0.0f, wallpaper::kWallpaperBackdropSigma,
                                static_cast<float>(wallpaper::kWallpaperBackdropRadius), 0.0f,
                                0.0f } };
    const Parameters down { { width, height, 0.0f, 1.0f, wallpaper::kWallpaperBackdropSigma,
                              static_cast<float>(wallpaper::kWallpaperBackdropRadius), 0.0f,
                              0.0f } };
    VkImageView input        = source.view;
    uint32_t    input_width  = source.extent.width;
    uint32_t    input_height = source.extent.height;
    if (plan.two_steps) {
        pass(m_reduced, m_reduce, input, parameters(input_width, input_height, plan.first));
        input        = *m_reduced.image.view;
        input_width  = plan.reduced.width;
        input_height = plan.reduced.height;
    }
    pass(m_blurred, m_downsample, input, parameters(input_width, input_height, plan.second));
    pass(m_scratch, m_blur, *m_blurred.image.view, across);
    pass(m_blurred, m_blur, *m_scratch.image.view, down);
    return VK_SUCCESS;
}

void WallpaperBackdropPass::drawBands(vvk::CommandBuffer& cmd, const RenderingResources& rr,
                                      VkExtent2D extent) const {
    if (! rr.wallpaper_backdrop || ! m_composite.handle || ! m_blurred.image.view) return;
    const auto& rect = rr.wallpaper_backdrop_rect;
    const Parameters parameters { {
        static_cast<float>(rect.offset.x),
        static_cast<float>(rect.offset.y),
        static_cast<float>(std::max(1u, rect.extent.width)),
        static_cast<float>(std::max(1u, rect.extent.height)),
        static_cast<float>(m_blurred.image.extent.width),
        static_cast<float>(m_blurred.image.extent.height),
        wallpaper::kWallpaperBackdropDim,
        rr.wallpaper_horizontal_flip ? 1.0f : 0.0f,
    } };
    Bind(cmd, m_composite, *m_sampler, *m_blurred.image.view, parameters);
    VkViewport viewport {
        0.0f, 0.0f, static_cast<float>(extent.width), static_cast<float>(extent.height), 0.0f,
        1.0f,
    };
    cmd.SetViewport(0, viewport);
    for (uint32_t i = 0; i < rr.wallpaper_backdrop_band_count; ++i) {
        const auto& band = rr.wallpaper_backdrop_bands[i];
        // A band is inside the layout's window; the target can be smaller.
        const int64_t x0 = std::clamp<int64_t>(band.offset.x, 0, extent.width);
        const int64_t y0 = std::clamp<int64_t>(band.offset.y, 0, extent.height);
        const int64_t x1 = std::clamp<int64_t>(int64_t(band.offset.x) + band.extent.width, 0,
                                               extent.width);
        const int64_t y1 = std::clamp<int64_t>(int64_t(band.offset.y) + band.extent.height, 0,
                                               extent.height);
        if (x1 <= x0 || y1 <= y0) continue;
        VkRect2D scissor { { static_cast<int32_t>(x0), static_cast<int32_t>(y0) },
                           { static_cast<uint32_t>(x1 - x0), static_cast<uint32_t>(y1 - y0) } };
        cmd.SetScissor(0, scissor);
        cmd.Draw(4, 1, 0, 0);
    }
}

void WallpaperBackdropPass::release() {
    // Asked on every composition without room: nothing to do in the usual case.
    if (! m_reduced.image.handle && ! m_blurred.image.handle && ! m_scratch.image.handle) return;
    m_reduced = {};
    m_blurred = {};
    m_scratch = {};
    m_bytes   = 0;
}

void WallpaperBackdropPass::destroy() {
    release();
    ResetPipelineParameters(m_reduce);
    ResetPipelineParameters(m_downsample);
    ResetPipelineParameters(m_blur);
    ResetPipelineParameters(m_composite);
    m_sampler        = {};
    m_present_format = VK_FORMAT_UNDEFINED;
}

uint64_t WallpaperBackdropPass::allocatedBytes() const { return m_bytes; }
