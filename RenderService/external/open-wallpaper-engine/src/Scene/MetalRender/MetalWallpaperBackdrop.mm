#include "MetalWallpaperBackdrop.hpp"

#include "Presentation/WallpaperBackdrop.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <string_view>

namespace wallpaper::metal
{

namespace
{

// The same arithmetic as the Compatibility backend's GLSL in
// WallpaperBackdropPass.cpp; a change to one is a change to both.
constexpr std::string_view kBackdropShaderSource = R"(
#include <metal_stdlib>
using namespace metal;

struct BackdropVarying {
    float4 position [[position]];
};

// A strip over the whole target: every stage works from the pixel it shades.
vertex BackdropVarying owe_backdrop_vertex(uint vertex_id [[vertex_id]]) {
    const float2 corner = float2(float(vertex_id & 1u), float(vertex_id >> 1u));
    BackdropVarying out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// x, y: source size; z, w: source texels per small texel. taps: per axis.
struct BackdropDownsample {
    float4 source;
    uint4  taps;
};

fragment float4 owe_backdrop_downsample(BackdropVarying in [[stage_in]],
                                        texture2d<float> source [[texture(0)]],
                                        sampler bilinear [[sampler(0)]],
                                        constant BackdropDownsample& p [[buffer(0)]]) {
    const float2 origin = floor(in.position.xy) * p.source.zw;
    const float2 spacing = p.source.zw / float2(p.taps.xy);
    float4 sum = float4(0.0);
    for (uint y = 0; y < p.taps.y; ++y) {
        for (uint x = 0; x < p.taps.x; ++x) {
            const float2 at = origin + (float2(float(x), float(y)) + 0.5) * spacing;
            sum += source.sample(bilinear, at / p.source.xy, level(0.0));
        }
    }
    return sum / float(p.taps.x * p.taps.y);
}

// x, y: image size; z, w: direction. sigma and radius in texels.
struct BackdropBlur {
    float4 image;
    float4 blur;
};

fragment float4 owe_backdrop_blur(BackdropVarying in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  sampler bilinear [[sampler(0)]],
                                  constant BackdropBlur& p [[buffer(0)]]) {
    const float2 centre = floor(in.position.xy) + 0.5;
    const float  sigma = p.blur.x;
    const int    radius = int(p.blur.y);
    float4 sum = float4(0.0);
    float  total = 0.0;
    for (int i = -radius; i <= radius; ++i) {
        const float weight = exp(-float(i * i) / (2.0 * sigma * sigma));
        sum += weight * source.sample(bilinear, (centre + p.image.zw * float(i)) / p.image.xy,
                                      level(0.0));
        total += weight;
    }
    return sum / total;
}

// rect: where the blurred image lies on the target, in pixels. image: its
// size, then the dimming and whether it is mirrored.
struct BackdropComposite {
    float4 rect;
    float4 image;
};

fragment float4 owe_backdrop_composite(BackdropVarying in [[stage_in]],
                                       texture2d<float> blurred [[texture(0)]],
                                       sampler bilinear [[sampler(0)]],
                                       constant BackdropComposite& p [[buffer(0)]]) {
    float2 uv = (in.position.xy - p.rect.xy) / p.rect.zw;
    if (p.image.w != 0.0) uv.x = 1.0 - uv.x;
    // A cubic B-spline from four bilinear samples: the magnified image shows
    // no grid of its texels.
    const float2 size = p.image.xy;
    const float2 st = uv * size - 0.5;
    const float2 i = floor(st);
    const float2 f = st - i;
    const float2 f2 = f * f;
    const float2 f3 = f2 * f;
    const float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    const float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    const float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    const float2 w3 = f3 / 6.0;
    const float2 g0 = w0 + w1;
    const float2 g1 = w2 + w3;
    const float2 h0 = (i - 0.5 + w1 / g0) / size;
    const float2 h1 = (i + 1.5 + w3 / g1) / size;
    const float4 colour =
        g0.y * (g0.x * blurred.sample(bilinear, float2(h0.x, h0.y), level(0.0)) +
                g1.x * blurred.sample(bilinear, float2(h1.x, h0.y), level(0.0))) +
        g1.y * (g0.x * blurred.sample(bilinear, float2(h0.x, h1.y), level(0.0)) +
                g1.x * blurred.sample(bilinear, float2(h1.x, h1.y), level(0.0)));
    // Interleaved gradient noise, one 8-bit step: dark gradients do not band.
    const float noise =
        fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
    return float4(colour.rgb * p.image.z + (noise - 0.5) / 255.0, 1.0);
}
)";

struct DownsampleParameters {
    float    source[4];
    uint32_t taps[4];
};

struct BlurParameters {
    float image[4];
    float blur[4];
};

struct CompositeParameters {
    float rect[4];
    float image[4];
};

constexpr MTLPixelFormat kImageFormat   = MTLPixelFormatRGBA16Float;
constexpr MTLPixelFormat kReducedFormat = MTLPixelFormatRGBA8Unorm;

} // namespace

bool MetalWallpaperBackdrop::fail(std::string message)
{
    last_error_ = std::move(message);
    return false;
}

bool MetalWallpaperBackdrop::ensureLibrary(id<MTLDevice> device)
{
    if (library_ != nil) return true;
    NSString* source = [[NSString alloc] initWithBytes:kBackdropShaderSource.data()
                                                length:kBackdropShaderSource.size()
                                              encoding:NSUTF8StringEncoding];
    NSError* error = nil;
    library_ = [device newLibraryWithSource:source options:[MTLCompileOptions new] error:&error];
    if (library_ == nil) {
        return fail(std::string("the blurred fill's shaders failed to compile: ") +
                    (error != nil ? error.localizedDescription.UTF8String : "unknown error"));
    }
    return true;
}

id<MTLRenderPipelineState> MetalWallpaperBackdrop::pipeline(id<MTLDevice> device,
                                                            NSString* fragment,
                                                            MTLPixelFormat format)
{
    const std::string key = std::string(fragment.UTF8String) + "/" + std::to_string(format);
    if (const auto found = pipelines_.find(key); found != pipelines_.end()) return found->second;
    if (! ensureLibrary(device)) return nil;
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction   = [library_ newFunctionWithName:@"owe_backdrop_vertex"];
    descriptor.fragmentFunction = [library_ newFunctionWithName:fragment];
    descriptor.colorAttachments[0].pixelFormat = format;
    NSError* error = nil;
    id<MTLRenderPipelineState> state =
        [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (state == nil) {
        fail(std::string("the blurred fill's pipeline failed to build: ") +
             (error != nil ? error.localizedDescription.UTF8String : "unknown error"));
        return nil;
    }
    pipelines_.emplace(key, state);
    return state;
}

bool MetalWallpaperBackdrop::prepare(id<MTLDevice> device, MTLPixelFormat format)
{
    if (device == nil) return false;
    return pipeline(device, @"owe_backdrop_downsample", kReducedFormat) != nil &&
           pipeline(device, @"owe_backdrop_downsample", kImageFormat) != nil &&
           pipeline(device, @"owe_backdrop_blur", kImageFormat) != nil &&
           pipeline(device, @"owe_backdrop_composite", format) != nil;
}

bool MetalWallpaperBackdrop::ensureImages(id<MTLDevice> device,
                                          const WallpaperBackdropPlan& plan)
{
    const bool reduced_fits =
        plan.two_steps ? reduced_ != nil && reduced_.width == plan.reduced.width &&
                             reduced_.height == plan.reduced.height
                       : reduced_ == nil;
    if (blurred_ != nil && blurred_.width == plan.extent.width &&
        blurred_.height == plan.extent.height && reduced_fits)
        return true;
    release();
    const auto make = [&](MTLPixelFormat format, WallpaperBackdropExtent extent, NSString* label) {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                               width:extent.width
                                                              height:extent.height
                                                           mipmapped:NO];
        descriptor.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        texture.label          = label;
        return texture;
    };
    blurred_ = make(kImageFormat, plan.extent, @"wallpaper backdrop");
    scratch_ = make(kImageFormat, plan.extent, @"wallpaper backdrop scratch");
    if (plan.two_steps) reduced_ = make(kReducedFormat, plan.reduced, @"wallpaper backdrop reduced");
    if (blurred_ == nil || scratch_ == nil || (plan.two_steps && reduced_ == nil)) {
        release();
        return fail("the blurred fill's images could not be allocated");
    }
    LOG_INFO("blurred fill images: %ux%u%s, %llu bytes", plan.extent.width, plan.extent.height,
             plan.two_steps ? (" after " + std::to_string(plan.reduced.width) + "x" +
                               std::to_string(plan.reduced.height)).c_str()
                            : "",
             static_cast<unsigned long long>(allocatedBytes()));
    return true;
}

bool MetalWallpaperBackdrop::encodeBlur(id<MTLDevice> device, id<MTLCommandBuffer> command,
                                        id<MTLTexture> source, id<MTLSamplerState> linear)
{
    if (device == nil || command == nil || source == nil || linear == nil) return false;
    const auto plan = ComputeWallpaperBackdropPlan((uint32_t)source.width, (uint32_t)source.height);
    const auto extent = plan.extent;
    if (! ensureImages(device, plan)) return false;
    id<MTLRenderPipelineState> reduce_step =
        pipeline(device, @"owe_backdrop_downsample", kReducedFormat);
    id<MTLRenderPipelineState> downsample =
        pipeline(device, @"owe_backdrop_downsample", kImageFormat);
    id<MTLRenderPipelineState> blur = pipeline(device, @"owe_backdrop_blur", kImageFormat);
    if (reduce_step == nil || downsample == nil || blur == nil) return false;

    const auto pass = [&](NSString* label, id<MTLTexture> target,
                          id<MTLRenderPipelineState> state, id<MTLTexture> input,
                          const void* parameters, size_t length) {
        MTLRenderPassDescriptor* descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        descriptor.colorAttachments[0].texture = target;
        // Every texel is drawn, so nothing needs keeping or clearing.
        descriptor.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
        descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:descriptor];
        if (encoder == nil) return false;
        encoder.label = label;
        [encoder setRenderPipelineState:state];
        [encoder setFragmentTexture:input atIndex:0];
        [encoder setFragmentSamplerState:linear atIndex:0];
        [encoder setFragmentBytes:parameters length:length atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];
        return true;
    };

    const auto parameters = [](uint32_t width, uint32_t height,
                               const WallpaperBackdropDownsample& taps) {
        return DownsampleParameters {
            .source = { (float)width, (float)height, taps.block_x, taps.block_y },
            .taps   = { taps.taps_x, taps.taps_y, 0, 0 },
        };
    };
    id<MTLTexture> input = source;
    if (plan.two_steps) {
        const auto first =
            parameters((uint32_t)source.width, (uint32_t)source.height, plan.first);
        if (! pass(@"wallpaper backdrop: reduce", reduced_, reduce_step, source, &first,
                   sizeof(first)))
            return false;
        input = reduced_;
    }
    const auto reduce = parameters((uint32_t)input.width, (uint32_t)input.height, plan.second);
    const float size[2] = { (float)extent.width, (float)extent.height };
    const BlurParameters across {
        .image  = { size[0], size[1], 1.0f, 0.0f },
        .blur   = { kWallpaperBackdropSigma, (float)kWallpaperBackdropRadius, 0.0f, 0.0f },
    };
    const BlurParameters down {
        .image  = { size[0], size[1], 0.0f, 1.0f },
        .blur   = { kWallpaperBackdropSigma, (float)kWallpaperBackdropRadius, 0.0f, 0.0f },
    };
    return pass(@"wallpaper backdrop: downsample", blurred_, downsample, input, &reduce,
                sizeof(reduce)) &&
           pass(@"wallpaper backdrop: blur across", scratch_, blur, blurred_, &across,
                sizeof(across)) &&
           pass(@"wallpaper backdrop: blur down", blurred_, blur, scratch_, &down, sizeof(down));
}

bool MetalWallpaperBackdrop::drawBands(id<MTLDevice> device, id<MTLRenderCommandEncoder> encoder,
                                       MTLPixelFormat format, uint32_t width, uint32_t height,
                                       const WallpaperScalingLayout& layout, bool horizontal_flip,
                                       id<MTLSamplerState> linear)
{
    if (device == nil || encoder == nil || blurred_ == nil || linear == nil) return false;
    id<MTLRenderPipelineState> composite = pipeline(device, @"owe_backdrop_composite", format);
    if (composite == nil) return false;
    const auto bands = ComputeWallpaperBackdropBands(layout);
    const CompositeParameters parameters {
        .rect  = { (float)layout.backdrop_px.x, (float)layout.backdrop_px.y,
                   (float)std::max(1, layout.backdrop_px.width),
                   (float)std::max(1, layout.backdrop_px.height) },
        .image = { (float)blurred_.width, (float)blurred_.height, kWallpaperBackdropDim,
                   horizontal_flip ? 1.0f : 0.0f },
    };
    [encoder setViewport:(MTLViewport) { 0.0, 0.0, (double)width, (double)height, 0.0, 1.0 }];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setRenderPipelineState:composite];
    [encoder setFragmentTexture:blurred_ atIndex:0];
    [encoder setFragmentSamplerState:linear atIndex:0];
    [encoder setFragmentBytes:&parameters length:sizeof(parameters) atIndex:0];
    for (uint32_t i = 0; i < bands.count; ++i) {
        const auto& band = bands.rects[i];
        // A band is inside the layout's window; the target can be smaller.
        const auto x0 = (NSUInteger)std::clamp<int64_t>(band.x, 0, width);
        const auto y0 = (NSUInteger)std::clamp<int64_t>(band.y, 0, height);
        const auto x1 = (NSUInteger)std::clamp<int64_t>((int64_t)band.x + band.width, 0, width);
        const auto y1 = (NSUInteger)std::clamp<int64_t>((int64_t)band.y + band.height, 0, height);
        if (x1 <= x0 || y1 <= y0) continue;
        [encoder setScissorRect:(MTLScissorRect) { x0, y0, x1 - x0, y1 - y0 }];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder setScissorRect:(MTLScissorRect) { 0, 0, width, height }];
    return true;
}

void MetalWallpaperBackdrop::release()
{
    reduced_ = nil;
    blurred_ = nil;
    scratch_ = nil;
}

uint64_t MetalWallpaperBackdrop::allocatedBytes() const
{
    uint64_t bytes = 0;
    if (reduced_ != nil) bytes += reduced_.allocatedSize;
    if (blurred_ != nil) bytes += blurred_.allocatedSize;
    if (scratch_ != nil) bytes += scratch_.allocatedSize;
    return bytes;
}

} // namespace wallpaper::metal
