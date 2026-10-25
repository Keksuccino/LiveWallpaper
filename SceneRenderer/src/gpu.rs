//! Thin Metal helpers: device, textures, samplers, pipelines, render-target pool.

use std::collections::HashMap;
use std::ffi::c_void;
use std::ptr::NonNull;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_foundation::NSString;
use objc2_metal::*;

use crate::particles::VertexLayout;
use crate::scene::Blend;
use crate::shader::{Program, VERTEX_BUFFER_SLOT};
use crate::tex::{Format, Tex};
use crate::Error;

pub type Device = ProtocolObject<dyn MTLDevice>;
pub type Texture = ProtocolObject<dyn MTLTexture>;
pub type Queue = ProtocolObject<dyn MTLCommandQueue>;
pub type Pipeline = ProtocolObject<dyn MTLRenderPipelineState>;
pub type Sampler = ProtocolObject<dyn MTLSamplerState>;
pub type Encoder = ProtocolObject<dyn MTLRenderCommandEncoder>;
pub type CommandBuffer = ProtocolObject<dyn MTLCommandBuffer>;
pub type DepthState = ProtocolObject<dyn MTLDepthStencilState>;

/// Render targets and intermediate effect buffers. Colour math happens in gamma space, like the
/// original engine, so nothing is sRGB-tagged.
pub const TARGET_FORMAT: MTLPixelFormat = MTLPixelFormat::BGRA8Unorm;
/// Same as the target so pipelines are shared between direct and intermediate draws.
pub const FBO_FORMAT: MTLPixelFormat = TARGET_FORMAT;

/// Interleaved vertex: position xyz, texcoord uv.
pub const VERTEX_STRIDE: usize = 20;

/// Puppet vertex: position xy, texcoord uv, straight colour rgba.
pub const PUPPET_STRIDE: usize = 32;

/// The depth buffer of the passes that draw models.
pub const DEPTH_FORMAT: MTLPixelFormat = MTLPixelFormat::Depth32Float;

/// Where a mesh pipeline reads the vertex inputs a mesh has no data for (see
/// `model::CONSTANT_ATTRIBUTES`): one value for every vertex.
pub const CONSTANT_BUFFER_SLOT: usize = VERTEX_BUFFER_SLOT as usize + 1;

/// A vertex input of a mesh pipeline: its location, format, byte offset and whether it reads the
/// constant buffer instead of the vertex.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MeshInput {
    pub location: u32,
    pub format: MTLVertexFormat,
    pub offset: usize,
    pub constant: bool,
}

/// Textured, coloured triangles whose vertices are computed on the CPU (skinned puppet meshes).
const PUPPET_MSL: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct VIn { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; float4 col [[attribute(2)]]; };
struct VOut { float4 pos [[position]]; float2 uv; float4 col; };
struct U { float4x4 mvp; };
vertex VOut wm_puppet_vs(VIn v [[stage_in]], constant U& u [[buffer(0)]]) {
    VOut o;
    o.pos = u.mvp * float4(v.pos, 0.0, 1.0);
    o.uv = v.uv;
    o.col = v.col;
    return o;
}
fragment float4 wm_puppet_fs(VOut i [[stage_in]], texture2d<float> t [[texture(0)]],
                           sampler s [[sampler(0)]]) {
    float4 c = t.sample(s, i.uv);
    return float4(c.rgb * i.col.rgb, c.a * i.col.a);
}
"#;

const COMPOSITE_MSL: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct VIn { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float4x4 mvp; float4 color; };
vertex VOut wm_composite_vs(VIn v [[stage_in]], constant U& u [[buffer(0)]]) {
    VOut o; o.pos = u.mvp * float4(v.pos, 1.0); o.uv = v.uv; return o;
}
fragment float4 wm_composite_fs(VOut i [[stage_in]], constant U& u [[buffer(0)]],
                                texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, i.uv) * u.color;
}
// Wallpaper Engine's colour options and image filter, applied as the scene reaches the target
// (the same steps as its `ccsimple` pass): contrast around mid grey, then value, saturation and
// hue in HSV, then a colour lookup table mixed in by its strength.
// `params`: value scale, contrast, saturation scale, hue shift (in turns).
// `grade`: x = 1 with the colour options on, y = filter strength (0 = no filter).
struct G { float4x4 mvp; float4 color; float4 params; float4 grade; };
float3 wm_rgb2hsv(float3 c) {
    float4 p = c.g < c.b ? float4(c.bg, -1.0, 2.0 / 3.0) : float4(c.gb, 0.0, -1.0 / 3.0);
    float4 q = c.r < p.x ? float4(p.xyw, c.r) : float4(c.r, p.yzx);
    float chroma = q.x - min(q.w, q.y);
    float hue = abs((q.w - q.y) / (6.0 * chroma + 1e-10) + q.z);
    return float3(hue, chroma / (q.x + 1e-10), q.x);
}
float3 wm_hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), saturate(p - 1.0), c.y);
}
fragment float4 wm_grade_fs(VOut i [[stage_in]], constant G& u [[buffer(0)]],
                            texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                            texture3d<float> lut [[texture(1)]], sampler ls [[sampler(1)]]) {
    float4 c = t.sample(s, i.uv);
    if (u.grade.x > 0.5) {
        c.rgb = mix(float3(0.5), c.rgb, u.params.y);
        float3 hsv = wm_rgb2hsv(c.rgb);
        hsv.z *= u.params.x;
        hsv.y *= u.params.z;
        hsv.x += u.params.w;
        c.rgb = wm_hsv2rgb(hsv);
    }
    if (u.grade.y > 0.0) {
        c.rgb = mix(c.rgb, lut.sample(ls, c.rgb).rgb, u.grade.y);
    }
    return c * u.color;
}
"#;

/// Blur for the background of the blurred-fit mode. Five taps along one axis, using the
/// hardware's bilinear filtering to reach twice as far.
const BLUR_MSL: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct VIn { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VOut { float4 pos [[position]]; float2 uv; };
struct U { float4x4 mvp; float4 rect; float2 dir; float2 tp; };
vertex VOut wm_blur_vs(VIn v [[stage_in]], constant U& u [[buffer(0)]]) {
    VOut o; o.pos = u.mvp * float4(v.pos, 1.0); o.uv = v.uv; return o;
}
fragment float4 wm_blur_fs(VOut i [[stage_in]], constant U& u [[buffer(0)]],
                           texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 c = u.rect.xy + i.uv * u.rect.zw;
    float3 sum = t.sample(s, c).rgb * 0.2270270270;
    sum += t.sample(s, c + u.dir * 1.3846153846).rgb * 0.3162162162;
    sum += t.sample(s, c - u.dir * 1.3846153846).rgb * 0.3162162162;
    sum += t.sample(s, c + u.dir * 3.2307692308).rgb * 0.0702702703;
    sum += t.sample(s, c - u.dir * 3.2307692308).rgb * 0.0702702703;
    return float4(sum, 1.0);
}
// Bloom source: a four-tap box average (for downsampling) keeping only what is brighter than
// the threshold `tp.x`, scaled by `tp.y`.
fragment float4 wm_bright_fs(VOut i [[stage_in]], constant U& u [[buffer(0)]],
                             texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    float2 c = u.rect.xy + i.uv * u.rect.zw;
    float3 x = (t.sample(s, c + u.dir).rgb + t.sample(s, c - u.dir).rgb
              + t.sample(s, c + float2(u.dir.x, -u.dir.y)).rgb
              + t.sample(s, c + float2(-u.dir.x, u.dir.y)).rgb) * 0.25;
    float b = max(max(x.r, x.g), x.b);
    return float4(x * (max(b - u.tp.x, 0.0) / max(b, 1e-4)) * u.tp.y, 1.0);
}
"#;

#[derive(Debug)]
pub struct Gpu {
    pub device: Retained<Device>,
    pub queue: Retained<Queue>,
    /// [linear clamp, linear repeat, nearest clamp, nearest repeat]
    pub samplers: [Retained<Sampler>; 4],
    composite: HashMap<(Blend, MTLPixelFormat, usize), Retained<Pipeline>>,
    grade: HashMap<(Blend, MTLPixelFormat), Retained<Pipeline>>,
    composite_lib: Retained<ProtocolObject<dyn MTLLibrary>>,
    blur: HashMap<(&'static str, usize), Retained<Pipeline>>,
    blur_lib: Retained<ProtocolObject<dyn MTLLibrary>>,
    puppet: HashMap<(Blend, MTLPixelFormat, usize), Retained<Pipeline>>,
    puppet_lib: Retained<ProtocolObject<dyn MTLLibrary>>,
    /// Pipelines of particle materials, by program address, blend, format, samples and vertex
    /// layout address.
    particle_programs: HashMap<(usize, Blend, MTLPixelFormat, usize, usize), Retained<Pipeline>>,
    /// By (depth test, depth write).
    depth_states: HashMap<(bool, bool), Retained<DepthState>>,
}

impl Gpu {
    pub fn new() -> Result<Self, Error> {
        let device =
            MTLCreateSystemDefaultDevice().ok_or_else(|| Error::Metal("no Metal device".into()))?;
        let queue = device
            .newCommandQueue()
            .ok_or_else(|| Error::Metal("no command queue".into()))?;
        let sampler = |linear: bool, repeat: bool| {
            let d = MTLSamplerDescriptor::new();
            let filter = if linear {
                MTLSamplerMinMagFilter::Linear
            } else {
                MTLSamplerMinMagFilter::Nearest
            };
            let mode = if repeat {
                MTLSamplerAddressMode::Repeat
            } else {
                MTLSamplerAddressMode::ClampToEdge
            };
            d.setMinFilter(filter);
            d.setMagFilter(filter);
            d.setMipFilter(MTLSamplerMipFilter::Linear);
            d.setSAddressMode(mode);
            d.setTAddressMode(mode);
            device
                .newSamplerStateWithDescriptor(&d)
                .ok_or_else(|| Error::Metal("sampler".into()))
        };
        let samplers = [
            sampler(true, false)?,
            sampler(true, true)?,
            sampler(false, false)?,
            sampler(false, true)?,
        ];
        let composite_lib = library(&device, COMPOSITE_MSL)?;
        let blur_lib = library(&device, BLUR_MSL)?;
        let puppet_lib = library(&device, PUPPET_MSL)?;
        Ok(Self {
            device,
            queue,
            samplers,
            composite: HashMap::new(),
            grade: HashMap::new(),
            composite_lib,
            blur: HashMap::new(),
            blur_lib,
            puppet: HashMap::new(),
            puppet_lib,
            particle_programs: HashMap::new(),
            depth_states: HashMap::new(),
        })
    }

    /// Uploads one image of `tex`. With `color`, a one- or two-channel texture reads as grey
    /// (and alpha): that is what such a file holds when it is drawn as a picture, such as a
    /// particle sprite. Masks and flow maps keep their raw channels.
    pub fn upload(&self, tex: &Tex, image: usize, color: bool) -> Result<Retained<Texture>, Error> {
        let mips = tex
            .images
            .get(image)
            .ok_or_else(|| Error::Format("texture image index".into()))?;
        let first = mips
            .first()
            .ok_or_else(|| Error::Format("texture has no mips".into()))?;
        let format = match tex.format {
            Format::Rgba8 => MTLPixelFormat::RGBA8Unorm,
            Format::Rg8 => MTLPixelFormat::RG8Unorm,
            Format::R8 => MTLPixelFormat::R8Unorm,
            Format::Bc1 => MTLPixelFormat::BC1_RGBA,
            Format::Bc2 => MTLPixelFormat::BC2_RGBA,
            Format::Bc3 => MTLPixelFormat::BC3_RGBA,
        };
        // SAFETY: plain descriptor construction with in-range sizes.
        let desc = unsafe {
            MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                format,
                first.width.max(1),
                first.height.max(1),
                false,
            )
        };
        // Stop at the first mip whose size does not halve properly (some files carry odd chains).
        let levels = mips
            .iter()
            .enumerate()
            .take_while(|(i, m)| {
                m.width == (first.width >> i).max(1) && m.height == (first.height >> i).max(1)
            })
            .count();
        // SAFETY: `levels` is at least 1 and matches the chain we upload below.
        unsafe { desc.setMipmapLevelCount(levels) };
        desc.setUsage(MTLTextureUsage::ShaderRead);
        let gray = |alpha| MTLTextureSwizzleChannels {
            red: MTLTextureSwizzle::Red,
            green: MTLTextureSwizzle::Red,
            blue: MTLTextureSwizzle::Red,
            alpha,
        };
        match tex.format {
            Format::R8 if color => desc.setSwizzle(gray(MTLTextureSwizzle::One)),
            Format::Rg8 if color => desc.setSwizzle(gray(MTLTextureSwizzle::Green)),
            _ => {}
        }
        let texture = self
            .device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("texture alloc".into()))?;
        for (level, mip) in mips.iter().take(levels).enumerate() {
            let region = MTLRegion {
                origin: MTLOrigin { x: 0, y: 0, z: 0 },
                size: MTLSize {
                    width: mip.width.max(1),
                    height: mip.height.max(1),
                    depth: 1,
                },
            };
            let ptr = NonNull::new(mip.data.as_ptr() as *mut c_void)
                .ok_or_else(|| Error::Format("empty mip".into()))?;
            // SAFETY: decode() checked that `data` holds at least `bytes(width, height)` bytes.
            unsafe {
                texture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(
                    region,
                    level,
                    ptr,
                    tex.format.row_bytes(mip.width.max(1)),
                )
            };
        }
        Ok(texture)
    }

    /// 1x1 texture of one colour, for shader defaults such as `util/white`.
    pub fn solid(&self, rgba: [u8; 4]) -> Result<Retained<Texture>, Error> {
        let tex = Tex {
            texture_width: 1,
            texture_height: 1,
            image_width: 1,
            image_height: 1,
            format: Format::Rgba8,
            clamp: false,
            nearest: false,
            images: vec![vec![crate::tex::Mip {
                width: 1,
                height: 1,
                data: rgba.to_vec(),
            }]],
            frames: Vec::new(),
        };
        self.upload(&tex, 0, false)
    }

    pub fn render_target(
        &self,
        w: usize,
        h: usize,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Texture>, Error> {
        // SAFETY: plain descriptor construction.
        let desc = unsafe {
            MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                format,
                w.max(1),
                h.max(1),
                false,
            )
        };
        desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
        desc.setStorageMode(MTLStorageMode::Private);
        if samples > 1 {
            desc.setTextureType(MTLTextureType::Type2DMultisample);
            // SAFETY: sample counts are 2 or 4, both supported on every Mac GPU.
            unsafe { desc.setSampleCount(samples) };
            desc.setUsage(MTLTextureUsage::RenderTarget);
        }
        self.device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("render target alloc".into()))
    }

    pub fn pipeline(
        &self,
        program: &Program,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        let vs_lib = library(&self.device, &program.vertex.msl)?;
        let fs_lib = library(&self.device, &program.fragment.msl)?;
        let vs = function(&vs_lib, &program.vertex.entry)?;
        let fs = function(&fs_lib, &program.fragment.entry)?;
        let vd = MTLVertexDescriptor::new();
        for (name, loc) in &program.attributes {
            // Position-like attributes read xyz, everything else uv; vec4 inputs get w = 1.
            let (format, offset) = if name.starts_with("a_Position") {
                (MTLVertexFormat::Float3, 0)
            } else {
                (MTLVertexFormat::Float2, 12)
            };
            // SAFETY: attribute indices come from our own location assignment (< 31).
            let attr = unsafe { vd.attributes().objectAtIndexedSubscript(*loc as usize) };
            attr.setFormat(format);
            // SAFETY: offsets lie inside the 20-byte vertex.
            unsafe {
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        self.finish_pipeline(&vs, &fs, &vd, blend, format, samples, VERTEX_STRIDE)
    }

    /// A pipeline drawing a model mesh (`model::VERTEX_STRIDE` vertices) into a pass with a depth
    /// buffer (see `begin_depth`).
    pub fn mesh_pipeline(
        &self,
        program: &Program,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        inputs: &[MeshInput],
    ) -> Result<Retained<Pipeline>, Error> {
        let vs_lib = library(&self.device, &program.vertex.msl)?;
        let fs_lib = library(&self.device, &program.fragment.msl)?;
        let vs = function(&vs_lib, &program.vertex.entry)?;
        let fs = function(&fs_lib, &program.fragment.entry)?;
        let vd = MTLVertexDescriptor::new();
        for input in inputs {
            let slot = if input.constant { CONSTANT_BUFFER_SLOT } else { VERTEX_BUFFER_SLOT as usize };
            // SAFETY: locations come from our own assignment (< 31), offsets lie in the vertex or
            // the constant buffer.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(input.location as usize);
                attr.setFormat(input.format);
                attr.setOffset(input.offset);
                attr.setBufferIndex(slot);
            }
        }
        // Metal rejects a layout no attribute reads from.
        if inputs.iter().any(|i| i.constant) {
            // SAFETY: a fixed slot inside the 31 buffer slots; a constant step reads one value for
            // every vertex and needs a step rate of 0.
            unsafe {
                let constant = vd.layouts().objectAtIndexedSubscript(CONSTANT_BUFFER_SLOT);
                constant.setStepFunction(MTLVertexStepFunction::Constant);
                constant.setStepRate(0);
                constant.setStride(16);
            }
        }
        let desc = self.pipeline_descriptor(&vs, &fs, &vd, blend, format, samples, crate::model::VERTEX_STRIDE);
        desc.setDepthAttachmentPixelFormat(DEPTH_FORMAT);
        self.device
            .newRenderPipelineStateWithDescriptor_error(&desc)
            .map_err(|e| Error::Metal(format!("pipeline: {}", e.localizedDescription())))
    }

    /// Depth comparison for model draws: nearer or equal wins, as the cleared depth is 1.
    pub fn depth_state(&mut self, test: bool, write: bool) -> Result<Retained<DepthState>, Error> {
        if let Some(s) = self.depth_states.get(&(test, write)) {
            return Ok(s.clone());
        }
        let d = MTLDepthStencilDescriptor::new();
        d.setDepthCompareFunction(if test { MTLCompareFunction::LessEqual } else { MTLCompareFunction::Always });
        d.setDepthWriteEnabled(write);
        let state = self
            .device
            .newDepthStencilStateWithDescriptor(&d)
            .ok_or_else(|| Error::Metal("depth state".into()))?;
        let _ = self.depth_states.insert((test, write), state.clone());
        Ok(state)
    }

    /// A depth buffer for the model passes. `transient`: it lives within one pass, so on Apple
    /// GPUs it can stay in tile memory and take no memory at all.
    pub fn depth_target(&self, w: usize, h: usize, samples: usize, transient: bool) -> Result<Retained<Texture>, Error> {
        // SAFETY: plain descriptor construction.
        let desc = unsafe {
            MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
                DEPTH_FORMAT,
                w.max(1),
                h.max(1),
                false,
            )
        };
        desc.setUsage(MTLTextureUsage::RenderTarget);
        let memoryless = transient && self.device.supportsFamily(MTLGPUFamily::Apple1);
        desc.setStorageMode(if memoryless { MTLStorageMode::Memoryless } else { MTLStorageMode::Private });
        if samples > 1 {
            desc.setTextureType(MTLTextureType::Type2DMultisample);
            // SAFETY: sample counts are 2 or 4, both supported on every Mac GPU.
            unsafe { desc.setSampleCount(samples) };
        }
        self.device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("depth target alloc".into()))
    }

    pub fn composite(
        &mut self,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        if let Some(p) = self.composite.get(&(blend, format, samples)) {
            return Ok(p.clone());
        }
        let p = self.composite_library_pipeline("wm_composite_fs", blend, format, samples)?;
        let _ = self.composite.insert((blend, format, samples), p.clone());
        Ok(p)
    }

    /// The composite with Wallpaper Engine's colour options and image filter (`wm_grade_fs`).
    pub fn grade(&mut self, blend: Blend, format: MTLPixelFormat) -> Result<Retained<Pipeline>, Error> {
        if let Some(p) = self.grade.get(&(blend, format)) {
            return Ok(p.clone());
        }
        let p = self.composite_library_pipeline("wm_grade_fs", blend, format, 1)?;
        let _ = self.grade.insert((blend, format), p.clone());
        Ok(p)
    }

    /// A pipeline of `wm_composite_vs` and a fragment function of the composite library.
    fn composite_library_pipeline(
        &self,
        fragment: &str,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        let vs = function(&self.composite_lib, "wm_composite_vs")?;
        let fs = function(&self.composite_lib, fragment)?;
        let vd = MTLVertexDescriptor::new();
        for (i, (format, offset)) in [(MTLVertexFormat::Float3, 0), (MTLVertexFormat::Float2, 12)]
            .into_iter()
            .enumerate()
        {
            // SAFETY: fixed indices and offsets inside the vertex.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(i);
                attr.setFormat(format);
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        self.finish_pipeline(&vs, &fs, &vd, blend, format, samples, VERTEX_STRIDE)
    }

    /// A cubic RGBA8 texture of `size`³ texels from `rgba`, its slices stacked top to bottom
    /// (`size` columns, `size * size` rows): a colour lookup table.
    pub fn upload_volume(&self, rgba: &[u8], size: usize) -> Result<Retained<Texture>, Error> {
        let row = size * 4;
        if size == 0 || rgba.len() < row * size * size {
            return Err(Error::Format("lookup table is smaller than its size".into()));
        }
        let desc = MTLTextureDescriptor::new();
        desc.setTextureType(MTLTextureType::Type3D);
        desc.setPixelFormat(MTLPixelFormat::RGBA8Unorm);
        // SAFETY: plain descriptor setters with in-range sizes.
        unsafe {
            desc.setWidth(size);
            desc.setHeight(size);
            desc.setDepth(size);
        }
        desc.setUsage(MTLTextureUsage::ShaderRead);
        let texture = self
            .device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("lookup table alloc".into()))?;
        let region = MTLRegion {
            origin: MTLOrigin { x: 0, y: 0, z: 0 },
            size: MTLSize { width: size, height: size, depth: size },
        };
        let ptr = NonNull::new(rgba.as_ptr() as *mut c_void)
            .ok_or_else(|| Error::Format("empty lookup table".into()))?;
        // SAFETY: `rgba` holds at least size³ texels of 4 bytes, checked above.
        unsafe {
            texture.replaceRegion_mipmapLevel_slice_withBytes_bytesPerRow_bytesPerImage(
                region,
                0,
                0,
                ptr,
                row,
                row * size,
            )
        };
        Ok(texture)
    }

    /// Pipeline for a blur-library pass (`wm_blur_fs` or `wm_bright_fs`), without blending.
    pub fn blur_pipeline(&mut self, fragment: &'static str, samples: usize) -> Result<Retained<Pipeline>, Error> {
        if let Some(p) = self.blur.get(&(fragment, samples)) {
            return Ok(p.clone());
        }
        let vs = function(&self.blur_lib, "wm_blur_vs")?;
        let fs = function(&self.blur_lib, fragment)?;
        let vd = MTLVertexDescriptor::new();
        for (i, (format, offset)) in [(MTLVertexFormat::Float3, 0), (MTLVertexFormat::Float2, 12)]
            .into_iter()
            .enumerate()
        {
            // SAFETY: fixed indices and offsets inside the vertex.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(i);
                attr.setFormat(format);
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        let p = self.finish_pipeline(&vs, &fs, &vd, Blend::Normal, FBO_FORMAT, samples, VERTEX_STRIDE)?;
        let _ = self.blur.insert((fragment, samples), p.clone());
        Ok(p)
    }

    /// Pipeline for CPU-built textured, coloured triangles (skinned puppet meshes).
    pub fn puppet_pipeline(
        &mut self,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        let key = (blend, format, samples);
        if let Some(p) = self.puppet.get(&key) {
            return Ok(p.clone());
        }
        let vs = function(&self.puppet_lib, "wm_puppet_vs")?;
        let fs = function(&self.puppet_lib, "wm_puppet_fs")?;
        let vd = MTLVertexDescriptor::new();
        for (i, (format, offset)) in [
            (MTLVertexFormat::Float2, 0),
            (MTLVertexFormat::Float2, 8),
            (MTLVertexFormat::Float4, 16),
        ]
        .into_iter()
        .enumerate()
        {
            // SAFETY: fixed indices and offsets inside the 32-byte vertex.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(i);
                attr.setFormat(format);
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        let p = self.finish_pipeline(&vs, &fs, &vd, blend, format, samples, PUPPET_STRIDE)?;
        let _ = self.puppet.insert(key, p.clone());
        Ok(p)
    }

    /// Pipeline for a particle material's program with the vertex layout its renderer fills.
    /// Programs live as long as the engine, so their address identifies them.
    pub fn particle_program_pipeline(
        &mut self,
        program: &Program,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        layout: &'static VertexLayout,
    ) -> Result<Retained<Pipeline>, Error> {
        let key = (
            program as *const Program as usize,
            blend,
            format,
            samples,
            layout as *const VertexLayout as usize,
        );
        if let Some(p) = self.particle_programs.get(&key) {
            return Ok(p.clone());
        }
        let vs_lib = library(&self.device, &program.vertex.msl)?;
        let fs_lib = library(&self.device, &program.fragment.msl)?;
        let vs = function(&vs_lib, &program.vertex.entry)?;
        let fs = function(&fs_lib, &program.fragment.entry)?;
        let vd = MTLVertexDescriptor::new();
        for (name, loc) in &program.attributes {
            // An attribute the layout does not fill (a custom shader's own) reads the vertex's
            // first floats.
            let (floats, offset) = layout
                .attributes
                .iter()
                .find(|a| a.0 == name)
                .map_or((2, 0), |a| (a.1, a.2));
            let format = match floats {
                1 => MTLVertexFormat::Float,
                2 => MTLVertexFormat::Float2,
                3 => MTLVertexFormat::Float3,
                _ => MTLVertexFormat::Float4,
            };
            // SAFETY: attribute indices come from our own location assignment (< 31); offsets
            // lie inside the layout's stride.
            unsafe {
                let attr = vd.attributes().objectAtIndexedSubscript(*loc as usize);
                attr.setFormat(format);
                attr.setOffset(offset);
                attr.setBufferIndex(VERTEX_BUFFER_SLOT as usize);
            }
        }
        let p = self.finish_pipeline(&vs, &fs, &vd, blend, format, samples, layout.stride)?;
        let _ = self.particle_programs.insert(key, p.clone());
        Ok(p)
    }

    #[allow(clippy::too_many_arguments)]
    fn finish_pipeline(
        &self,
        vs: &ProtocolObject<dyn MTLFunction>,
        fs: &ProtocolObject<dyn MTLFunction>,
        vd: &MTLVertexDescriptor,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        stride: usize,
    ) -> Result<Retained<Pipeline>, Error> {
        let desc = self.pipeline_descriptor(vs, fs, vd, blend, format, samples, stride);
        self.device
            .newRenderPipelineStateWithDescriptor_error(&desc)
            .map_err(|e| Error::Metal(format!("pipeline: {}", e.localizedDescription())))
    }

    /// The pipeline description `finish_pipeline` builds: the functions, the vertex layout with
    /// its stride, the colour attachment and the blend.
    #[allow(clippy::too_many_arguments)]
    fn pipeline_descriptor(
        &self,
        vs: &ProtocolObject<dyn MTLFunction>,
        fs: &ProtocolObject<dyn MTLFunction>,
        vd: &MTLVertexDescriptor,
        blend: Blend,
        format: MTLPixelFormat,
        samples: usize,
        stride: usize,
    ) -> Retained<MTLRenderPipelineDescriptor> {
        // SAFETY: fixed slot index inside the 31 buffer slots.
        unsafe {
            vd.layouts()
                .objectAtIndexedSubscript(VERTEX_BUFFER_SLOT as usize)
                .setStride(stride)
        };
        let desc = MTLRenderPipelineDescriptor::new();
        desc.setVertexFunction(Some(vs));
        desc.setFragmentFunction(Some(fs));
        desc.setVertexDescriptor(Some(vd));
        desc.setRasterSampleCount(samples.max(1));
        // SAFETY: attachment 0 always exists.
        let color = unsafe { desc.colorAttachments().objectAtIndexedSubscript(0) };
        color.setPixelFormat(format);
        let (src, dst) = match blend {
            Blend::Normal | Blend::Disabled => (None, None),
            Blend::Translucent => (
                Some(MTLBlendFactor::SourceAlpha),
                Some(MTLBlendFactor::OneMinusSourceAlpha),
            ),
            Blend::Additive => (Some(MTLBlendFactor::SourceAlpha), Some(MTLBlendFactor::One)),
        };
        if let (Some(src), Some(dst)) = (src, dst) {
            color.setBlendingEnabled(true);
            color.setSourceRGBBlendFactor(src);
            color.setDestinationRGBBlendFactor(dst);
            color.setSourceAlphaBlendFactor(MTLBlendFactor::One);
            color.setDestinationAlphaBlendFactor(MTLBlendFactor::OneMinusSourceAlpha);
        }
        desc
    }
}

fn library(device: &Device, src: &str) -> Result<Retained<ProtocolObject<dyn MTLLibrary>>, Error> {
    let opts = MTLCompileOptions::new();
    // Release-mode math like the original engine's driver compilers.
    opts.setMathMode(MTLMathMode::Fast);
    device
        .newLibraryWithSource_options_error(&NSString::from_str(src), Some(&opts))
        .map_err(|e| Error::Metal(format!("MSL compile: {}", e.localizedDescription())))
}

fn function(
    lib: &ProtocolObject<dyn MTLLibrary>,
    name: &str,
) -> Result<Retained<ProtocolObject<dyn MTLFunction>>, Error> {
    lib.newFunctionWithName(&NSString::from_str(name))
        .ok_or_else(|| Error::Metal(format!("missing function {name}")))
}

/// Intermediate render targets. They live in one Metal heap: a buffer handed back mid-frame is
/// marked aliasable, so the next layer's buffers reuse its memory. The heap is sized to the
/// largest set of buffers alive at the same time, not the sum over layers, and grows only when a
/// frame needs more.
#[derive(Debug, Default)]
pub struct Pool {
    heap: Option<Retained<ProtocolObject<dyn MTLHeap>>>,
    heap_size: usize,
    live: usize,
    peak: usize,
}

impl Pool {
    pub fn take(&mut self, gpu: &Gpu, w: usize, h: usize) -> Result<Retained<Texture>, Error> {
        let desc = texture_descriptor(w, h);
        let need = gpu.device.heapTextureSizeAndAlignWithDescriptor(&desc);
        self.live += need.size;
        self.peak = self.peak.max(self.live);
        if let Some(heap) = &self.heap {
            if heap.maxAvailableSizeWithAlignment(need.align) >= need.size {
                if let Some(t) = heap.newTextureWithDescriptor(&desc) {
                    return Ok(t);
                }
            }
        }
        // Heap too small this frame: allocate standalone; `end_frame` grows the heap.
        gpu.device
            .newTextureWithDescriptor(&desc)
            .ok_or_else(|| Error::Metal("render target alloc".into()))
    }

    pub fn give(&mut self, t: Retained<Texture>) {
        let need = t
            .device()
            .heapTextureSizeAndAlignWithDescriptor(&texture_descriptor(t.width(), t.height()));
        self.live = self.live.saturating_sub(need.size);
        if t.heap().is_some() {
            // SAFETY: the texture is not used by any command encoded after this point.
            unsafe { t.makeAliasable() };
        }
    }

    pub fn end_frame(&mut self, gpu: &Gpu) {
        if self.peak > self.heap_size {
            let size = self.peak.next_multiple_of(1 << 20);
            let desc = MTLHeapDescriptor::new();
            desc.setSize(size);
            desc.setStorageMode(MTLStorageMode::Private);
            desc.setHazardTrackingMode(MTLHazardTrackingMode::Tracked);
            self.heap = gpu.device.newHeapWithDescriptor(&desc);
            self.heap_size = if self.heap.is_some() { size } else { 0 };
        }
        self.live = 0;
        self.peak = 0;
    }

    pub fn clear(&mut self) {
        *self = Self::default();
    }
}

fn texture_descriptor(w: usize, h: usize) -> Retained<MTLTextureDescriptor> {
    // SAFETY: plain descriptor construction.
    let desc = unsafe {
        MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
            FBO_FORMAT,
            w.max(1),
            h.max(1),
            false,
        )
    };
    desc.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
    desc.setStorageMode(MTLStorageMode::Private);
    desc
}

/// Begins a render pass on `target`, cleared to `clear` or loaded when `None`.
pub fn begin(
    cb: &CommandBuffer,
    target: &Texture,
    msaa: Option<&Texture>,
    clear: Option<[f64; 4]>,
) -> Result<Retained<Encoder>, Error> {
    let rp = color_pass(target, msaa, clear);
    cb.renderCommandEncoderWithDescriptor(&rp)
        .ok_or_else(|| Error::Metal("render encoder".into()))
}

/// Like `begin`, with the depth buffer of the model passes: cleared to 1 when `clear_depth`, kept
/// for a later pass when `keep_depth`.
pub fn begin_depth(
    cb: &CommandBuffer,
    target: &Texture,
    msaa: Option<&Texture>,
    clear: Option<[f64; 4]>,
    depth: &Texture,
    clear_depth: bool,
    keep_depth: bool,
) -> Result<Retained<Encoder>, Error> {
    let rp = color_pass(target, msaa, clear);
    let att = rp.depthAttachment();
    att.setTexture(Some(depth));
    att.setLoadAction(if clear_depth { MTLLoadAction::Clear } else { MTLLoadAction::Load });
    att.setClearDepth(1.0);
    att.setStoreAction(if keep_depth { MTLStoreAction::Store } else { MTLStoreAction::DontCare });
    cb.renderCommandEncoderWithDescriptor(&rp)
        .ok_or_else(|| Error::Metal("render encoder".into()))
}

/// A pass description with one colour attachment on `target` (through `msaa` when set).
fn color_pass(target: &Texture, msaa: Option<&Texture>, clear: Option<[f64; 4]>) -> Retained<MTLRenderPassDescriptor> {
    let rp = MTLRenderPassDescriptor::new();
    // SAFETY: attachment 0 always exists.
    let att = unsafe { rp.colorAttachments().objectAtIndexedSubscript(0) };
    match msaa {
        Some(ms) => {
            att.setTexture(Some(ms));
            att.setResolveTexture(Some(target));
            // Kept (not memoryless) because layers with effects split the scene into several passes.
            att.setStoreAction(MTLStoreAction::StoreAndMultisampleResolve);
        }
        None => {
            att.setTexture(Some(target));
            att.setStoreAction(MTLStoreAction::Store);
        }
    }
    match clear {
        Some([r, g, b, a]) => {
            att.setLoadAction(MTLLoadAction::Clear);
            att.setClearColor(MTLClearColor {
                red: r,
                green: g,
                blue: b,
                alpha: a,
            });
        }
        None => att.setLoadAction(MTLLoadAction::Load),
    }
    rp
}

/// Pushes small per-draw data (uniforms, the 4-vertex quad) without allocating buffers.
pub fn set_bytes(enc: &Encoder, vertex: bool, data: &[u8], slot: usize) {
    if data.is_empty() {
        return;
    }
    let Some(ptr) = NonNull::new(data.as_ptr() as *mut c_void) else {
        return;
    };
    // SAFETY: Metal copies `data.len()` bytes immediately; set*Bytes accepts up to 4 KB, and our
    // uniform blocks stay well below that (callers fall back to a buffer above it).
    unsafe {
        if vertex {
            enc.setVertexBytes_length_atIndex(ptr, data.len(), slot);
        } else {
            enc.setFragmentBytes_length_atIndex(ptr, data.len(), slot);
        }
    }
}

pub fn set_buffer_or_bytes(gpu: &Gpu, enc: &Encoder, vertex: bool, data: &[u8], slot: usize) {
    if data.len() <= 4096 {
        set_bytes(enc, vertex, data, slot);
        return;
    }
    let Some(ptr) = NonNull::new(data.as_ptr() as *mut c_void) else {
        return;
    };
    // SAFETY: the buffer copies `data`.
    let buffer = unsafe {
        gpu.device.newBufferWithBytes_length_options(
            ptr,
            data.len(),
            MTLResourceOptions::StorageModeShared,
        )
    };
    if let Some(buffer) = buffer {
        // SAFETY: offset 0 in a buffer we own.
        unsafe {
            if vertex {
                enc.setVertexBuffer_offset_atIndex(Some(&buffer), 0, slot);
            } else {
                enc.setFragmentBuffer_offset_atIndex(Some(&buffer), 0, slot);
            }
        }
    }
}
