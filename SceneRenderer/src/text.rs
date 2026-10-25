//! Text layers: a string drawn with CoreText into a texture-sized RGBA bitmap.
//!
//! The renderer does not draw text every frame. A [`TextRenderer`] caches finished bitmaps by
//! everything that changes their pixels (font, size, string, colour, alignment, line spacing,
//! padding, opacity and pixel scale), so a clock only rasterises when its string actually changes.
//! The returned [`TextBitmap`] carries the premultiplied RGBA pixels plus the rectangle, in layer
//! design units, where the engine should draw them.

use std::collections::HashMap;
use std::ffi::c_void;
use std::ptr;
use std::rc::Rc;

use objc2_core_foundation::{
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks, CFAttributedString, CFData,
    CFDictionary, CFRetained, CFString, CGAffineTransform, CGFloat,
};
use objc2_core_graphics::{
    kCGColorSpaceSRGB, CGBitmapContextCreate, CGBitmapContextGetBytesPerRow,
    CGBitmapContextGetData, CGColor, CGColorSpace, CGContext, CGDataProvider, CGFont,
    CGImageAlphaInfo,
};
use objc2_core_text::{kCTFontAttributeName, kCTForegroundColorAttributeName, CTFont, CTLine};

use crate::vfs::Vfs;
use crate::Error;

/// The largest bitmap edge we will allocate, in pixels. A 32 pt line at 300 % is far below this.
const MAX_EDGE: usize = 16_384;
/// Keep a handful of recent strings: clocks tick once a second at most.
const MAX_CACHE: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HAlign {
    Left,
    Center,
    Right,
}

impl HAlign {
    pub fn from_scene(s: Option<&str>) -> Self {
        match s.unwrap_or("left") {
            "center" => Self::Center,
            "right" => Self::Right,
            _ => Self::Left,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VAlign {
    Top,
    Center,
    Bottom,
}

impl VAlign {
    pub fn from_scene(s: Option<&str>) -> Self {
        match s.unwrap_or("top") {
            "center" => Self::Center,
            "bottom" => Self::Bottom,
            _ => Self::Top,
        }
    }
}

/// Where a font comes from: bytes shipped inside the scene package, or a system family name.
#[derive(Debug, Clone)]
pub enum FontSource {
    Bytes { name: String, data: Vec<u8> },
    Family(String),
}

impl FontSource {
    pub fn from_bytes(name: impl Into<String>, data: Vec<u8>) -> Self {
        Self::Bytes {
            name: name.into(),
            data,
        }
    }

    pub fn family(name: impl Into<String>) -> Self {
        Self::Family(name.into())
    }

    /// A package font path (`fonts/...otf`) when the package has it, else a system family name.
    pub fn from_scene(vfs: &Vfs, name: &str) -> Self {
        match vfs.read(name) {
            Some(data) if looks_like_font(name) => Self::from_bytes(name, data),
            _ => Self::family(name),
        }
    }

    pub fn key(&self) -> &str {
        match self {
            Self::Bytes { name, .. } => name,
            Self::Family(name) => name,
        }
    }
}

fn looks_like_font(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [".otf", ".ttf", ".ttc", ".otc"]
        .iter()
        .any(|ext| lower.ends_with(ext))
}

/// A CoreText font at one point size. `CFRetained` releases both references with `CFRelease`
/// when the struct is dropped.
pub struct Font {
    key: String,
    size: f32,
    font: CFRetained<CTFont>,
    // CoreText keeps whatever it needs, but holding the graphics font as well makes the lifetime
    // explicit and costs only one retained reference.
    _graphics: Option<CFRetained<CGFont>>,
}

impl std::fmt::Debug for Font {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Font")
            .field("key", &self.key)
            .field("size", &self.size)
            .finish_non_exhaustive()
    }
}

impl Font {
    /// A package or system font. Invalid package bytes fall back to the file name as a family
    /// name, so a bad font costs the glyph style but not the whole text layer.
    pub fn load(source: &FontSource, size: f32) -> Result<Self, Error> {
        if !(size.is_finite() && size > 0.0) {
            return Err(Error::Unsupported(format!("text font size {size}")));
        }
        if let FontSource::Bytes { name, data } = source {
            match Self::from_bytes(name, data, size) {
                Ok(font) => return Ok(font),
                Err(_) => {
                    let stem = std::path::Path::new(name)
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or(name);
                    return Ok(Self::from_name(stem, size));
                }
            }
        }
        Ok(Self::from_name(source.key(), size))
    }

    /// A font from an OpenType/TrueType file, without registering it on the system.
    pub fn from_bytes(name: &str, data: &[u8], size: f32) -> Result<Self, Error> {
        if !(size.is_finite() && size > 0.0) {
            return Err(Error::Unsupported(format!("text font size {size}")));
        }
        let data = CFData::from_bytes(data);
        let provider = CGDataProvider::with_cf_data(Some(&data))
            .ok_or_else(|| Error::Unsupported(format!("text font {name}: no data provider")))?;
        let graphics = CGFont::with_data_provider(&provider)
            .ok_or_else(|| Error::Unsupported(format!("text font {name}: not a usable font")))?;
        // SAFETY: the graphics font is valid for the call, and a null matrix asks for identity.
        let font =
            unsafe { CTFont::with_graphics_font(&graphics, size as CGFloat, ptr::null(), None) };
        Ok(Self {
            key: name.to_string(),
            size,
            font,
            _graphics: Some(graphics),
        })
    }

    /// A system font by family or full name. CoreText substitutes a default if the name is unknown.
    pub fn from_name(name: &str, size: f32) -> Self {
        let family = CFString::from_str(name);
        // SAFETY: a null matrix asks CoreText for the identity matrix.
        let font = unsafe { CTFont::with_name(&family, size as CGFloat, ptr::null()) };
        Self {
            key: name.to_string(),
            size,
            font,
            _graphics: None,
        }
    }

    pub fn key(&self) -> &str {
        &self.key
    }

    pub fn size(&self) -> f32 {
        self.size
    }

    /// Font ascent, descent and leading at this size, in design points.
    pub fn metrics(&self) -> (f32, f32, f32) {
        // SAFETY: `self.font` is a live CTFont; the metric getters only read it.
        unsafe {
            (
                self.font.ascent() as f32,
                self.font.descent() as f32,
                self.font.leading() as f32,
            )
        }
    }
}

/// How one text layer is rasterised.
#[derive(Debug, Clone)]
pub struct TextSpec {
    pub text: String,
    /// Straight sRGB colour; the fourth component is alpha and is multiplied by `opacity`.
    pub color: [f32; 4],
    pub h_align: HAlign,
    pub v_align: VAlign,
    /// Multiplier on CoreText's natural line height (1.0 keeps the font's spacing).
    pub line_spacing: f32,
    /// Transparent margin around the glyphs, in design points.
    pub padding: f32,
    /// Multiplied into the colour alpha.
    pub opacity: f32,
    /// On-screen pixels per design point. Rasterise at the scale the layer is drawn at.
    pub pixels_per_point: f32,
    /// The layer's box in design units. `None` makes a tight bitmap and places it at (0, 0).
    pub box_size: Option<[f32; 2]>,
}

impl Default for TextSpec {
    fn default() -> Self {
        Self {
            text: String::new(),
            color: [1.0, 1.0, 1.0, 1.0],
            h_align: HAlign::Left,
            v_align: VAlign::Top,
            line_spacing: 1.0,
            padding: 0.0,
            opacity: 1.0,
            pixels_per_point: 1.0,
            box_size: None,
        }
    }
}

/// A finished raster. `pixels` is RGBA8, premultiplied, sRGB, rows top to bottom.
#[derive(Debug, Clone, PartialEq)]
pub struct TextBitmap {
    pub pixels: Vec<u8>,
    pub width: u32,
    pub height: u32,
    /// `x, y, width, height` inside the layer box, in design units, origin top-left, y down.
    pub rect: [f32; 4],
}

impl TextBitmap {
    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0 || self.pixels.is_empty()
    }

    /// True when at least one pixel has both alpha and visible colour (used by tests and for
    /// deciding whether an upload is worth doing).
    pub fn has_colored_pixels(&self) -> bool {
        self.pixels
            .as_chunks::<4>()
            .0
            .iter()
            .any(|p| p[3] != 0 && (p[0] != 0 || p[1] != 0 || p[2] != 0))
    }

    fn empty() -> Self {
        Self {
            pixels: Vec::new(),
            width: 0,
            height: 0,
            rect: [0.0; 4],
        }
    }
}

/// Everything that changes the pixels or their placement.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct CacheKey {
    font: String,
    font_size: u32,
    text: String,
    color: [u32; 4],
    h_align: HAlign,
    v_align: VAlign,
    line_spacing: u32,
    padding: u32,
    opacity: u32,
    scale: u32,
    box_size: Option<[u32; 2]>,
}

impl CacheKey {
    fn new(font: &Font, spec: &TextSpec) -> Self {
        Self {
            font: font.key.to_string(),
            font_size: font.size.to_bits(),
            text: spec.text.clone(),
            color: spec.color.map(f32::to_bits),
            h_align: spec.h_align,
            v_align: spec.v_align,
            line_spacing: spec.line_spacing.to_bits(),
            padding: spec.padding.to_bits(),
            opacity: spec.opacity.to_bits(),
            scale: spec.pixels_per_point.to_bits(),
            box_size: spec.box_size.map(|[w, h]| [w.to_bits(), h.to_bits()]),
        }
    }
}

/// Caches finished text bitmaps. Keep one per engine (or per text layer) on the render thread.
#[derive(Debug, Default)]
pub struct TextRenderer {
    cache: HashMap<CacheKey, Rc<TextBitmap>>,
}

impl TextRenderer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cache_len(&self) -> usize {
        self.cache.len()
    }

    pub fn clear(&mut self) {
        self.cache.clear();
    }

    /// Returns the cached bitmap when nothing that affects it changed, otherwise rasterises it.
    pub fn render(&mut self, font: &Font, spec: &TextSpec) -> Result<Rc<TextBitmap>, Error> {
        let key = CacheKey::new(font, spec);
        if let Some(bitmap) = self.cache.get(&key) {
            return Ok(bitmap.clone());
        }
        let bitmap = Rc::new(self.rasterize(font, spec)?);
        if self.cache.len() >= MAX_CACHE {
            self.cache.clear();
        }
        let _ = self.cache.insert(key, bitmap.clone());
        Ok(bitmap)
    }

    fn rasterize(&self, font: &Font, spec: &TextSpec) -> Result<TextBitmap, Error> {
        let scale = spec.pixels_per_point;
        if !(scale.is_finite() && scale > 0.0) {
            return Err(Error::Unsupported(format!("text pixel scale {scale}")));
        }
        if spec.text.is_empty() {
            return Ok(TextBitmap::empty());
        }

        let pad = spec.padding.max(0.0);
        let spacing = if spec.line_spacing.is_finite() {
            spec.line_spacing.max(0.01)
        } else {
            1.0
        };
        let color = with_opacity(spec.color, spec.opacity);

        let color = CGColor::new_srgb(
            color[0] as CGFloat,
            color[1] as CGFloat,
            color[2] as CGFloat,
            color[3] as CGFloat,
        );
        let attrs = attribute_dictionary(&font.font, &color)?;

        // One CTLine per logical line. Empty lines still take vertical space.
        let mut lines = Vec::new();
        let mut line_widths = Vec::new();
        let mut line_ascents = Vec::new();
        let mut line_heights = Vec::new();
        for text in spec.text.split('\n') {
            let string = CFString::from_str(text);
            // SAFETY: both CF objects are alive for the duration of the call; the dictionary
            // copies the attribute values and the string is retained by the attributed string.
            let attributed = unsafe { CFAttributedString::new(None, Some(&string), Some(&attrs)) }
                .ok_or_else(|| Error::Format("text: could not make attributed string".into()))?;
            // SAFETY: the attributed string outlives the line and is never mutated.
            let line = unsafe { CTLine::with_attributed_string(&attributed) };
            let mut ascent: CGFloat = 0.0;
            let mut descent: CGFloat = 0.0;
            let mut leading: CGFloat = 0.0;
            // SAFETY: the three pointers point at local, initialised values.
            let width =
                unsafe { line.typographic_bounds(&mut ascent, &mut descent, &mut leading) } as f32;
            lines.push(line);
            line_widths.push(width.max(0.0));
            line_ascents.push(ascent as f32);
            line_heights.push((ascent as f32 + descent as f32 + leading as f32).max(0.0) * spacing);
        }

        let content_w = line_widths.iter().copied().fold(0.0f32, f32::max);
        let content_h: f32 = line_heights.iter().sum();
        let points_w = content_w + 2.0 * pad;
        let points_h = content_h + 2.0 * pad;
        let pixel_w = (points_w * scale).ceil().max(1.0) as usize;
        let pixel_h = (points_h * scale).ceil().max(1.0) as usize;
        if pixel_w > MAX_EDGE || pixel_h > MAX_EDGE {
            return Err(Error::Unsupported(format!(
                "text bitmap {pixel_w}x{pixel_h} exceeds {MAX_EDGE} px"
            )));
        }

        // The bitmap is a little larger than the layout because of the ceil above; use its real
        // size so the engine maps one texture pixel to one device pixel.
        let rect_w = pixel_w as f32 / scale;
        let rect_h = pixel_h as f32 / scale;
        let (x, y) = placement(rect_w, rect_h, spec.box_size, spec.h_align, spec.v_align);
        // Snap the quad to the raster grid. Without this a half-pixel offset blurs the text.
        let x = (x * scale).round() / scale;
        let y = (y * scale).round() / scale;

        // SAFETY: `kCGColorSpaceSRGB` is a framework static that lives for the whole process.
        let srgb = unsafe { kCGColorSpaceSRGB };
        let space = CGColorSpace::with_name(Some(srgb))
            .ok_or_else(|| Error::Unsupported("text: no sRGB colour space".into()))?;
        // SAFETY: a null data pointer lets Core Graphics allocate `pixel_h` rows of `pixel_w`
        // RGBA8 pixels; the context owns that buffer until it is dropped below.
        let context = unsafe {
            CGBitmapContextCreate(
                ptr::null_mut(),
                pixel_w,
                pixel_h,
                8,
                pixel_w * 4,
                Some(&space),
                CGImageAlphaInfo::PremultipliedLast.0,
            )
        }
        .ok_or_else(|| Error::Format("text: could not create bitmap context".into()))?;

        draw(
            &context,
            &lines,
            &line_widths,
            &line_ascents,
            &line_heights,
            content_w,
            rect_h,
            pad,
            scale,
            spec.h_align,
        );

        let bpr = CGBitmapContextGetBytesPerRow(Some(&context));
        let data = CGBitmapContextGetData(Some(&context)) as *const u8;
        if data.is_null() {
            return Err(Error::Format("text: bitmap context has no storage".into()));
        }
        let mut pixels = vec![0u8; pixel_w * pixel_h * 4];
        for row in 0..pixel_h {
            // SAFETY: the context allocated `bpr * pixel_h` bytes and row is in range; the
            // destination has exactly `pixel_w * 4` bytes for this row.
            unsafe {
                ptr::copy_nonoverlapping(
                    data.add(row * bpr),
                    pixels.as_mut_ptr().add(row * pixel_w * 4),
                    pixel_w * 4,
                );
            }
        }

        Ok(TextBitmap {
            pixels,
            width: pixel_w as u32,
            height: pixel_h as u32,
            rect: [x, y, rect_w, rect_h],
        })
    }
}

fn with_opacity(mut color: [f32; 4], opacity: f32) -> [f32; 4] {
    let opacity = if opacity.is_finite() {
        opacity.clamp(0.0, 1.0)
    } else {
        1.0
    };
    for c in &mut color {
        *c = c.clamp(0.0, 1.0);
    }
    color[3] *= opacity;
    color
}

fn attribute_dictionary(font: &CTFont, color: &CGColor) -> Result<CFRetained<CFDictionary>, Error> {
    let font_ptr = font as *const CTFont as *const c_void;
    let color_ptr = color as *const CGColor as *const c_void;
    // SAFETY: both attribute names are framework statics valid for the process lifetime.
    let mut keys = unsafe {
        [
            kCTFontAttributeName as *const CFString as *const c_void,
            kCTForegroundColorAttributeName as *const CFString as *const c_void,
        ]
    };
    let mut values = [font_ptr, color_ptr];
    // SAFETY: two matching keys and values, both backed by live CF objects; the type callbacks
    // retain them for the dictionary's lifetime.
    unsafe {
        CFDictionary::new(
            None,
            keys.as_mut_ptr(),
            values.as_mut_ptr(),
            2,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        )
    }
    .ok_or_else(|| Error::Format("text: could not make attribute dictionary".into()))
}

#[allow(clippy::too_many_arguments)]
fn draw(
    context: &CGContext,
    lines: &[CFRetained<CTLine>],
    widths: &[f32],
    ascents: &[f32],
    heights: &[f32],
    content_w: f32,
    bitmap_h: f32,
    pad: f32,
    scale: f32,
    h_align: HAlign,
) {
    // Work in design points and let Core Graphics rasterise at the device scale.
    CGContext::scale_ctm(Some(context), scale as CGFloat, scale as CGFloat);
    // Identity text matrix: y grows upwards in the bitmap context, and CTLine draws from the
    // baseline. Rows still come out top-to-bottom in memory.
    let identity = CGAffineTransform {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
        tx: 0.0,
        ty: 0.0,
    };
    CGContext::set_text_matrix(Some(context), identity);

    let mut top = pad;
    for (((line, width), ascent), height) in lines.iter().zip(widths).zip(ascents).zip(heights) {
        // Baseline from the top of the bitmap.
        let baseline_from_top = top + *ascent;
        let x = pad + line_offset(content_w, *width, h_align);
        let y = bitmap_h - baseline_from_top;
        CGContext::set_text_position(Some(context), x as CGFloat, y as CGFloat);
        // SAFETY: the bitmap context is live and allocated for this draw; the line outlives it.
        unsafe { line.draw(context) };
        top += *height;
    }
}

/// Where a line starts inside the content width.
fn line_offset(content_w: f32, line_w: f32, h_align: HAlign) -> f32 {
    match h_align {
        HAlign::Left => 0.0,
        HAlign::Center => ((content_w - line_w) / 2.0).max(0.0),
        HAlign::Right => (content_w - line_w).max(0.0),
    }
}

/// Top-left of the bitmap inside the layer box, snapped later to the raster grid.
fn placement(
    w: f32,
    h: f32,
    box_size: Option<[f32; 2]>,
    h_align: HAlign,
    v_align: VAlign,
) -> (f32, f32) {
    let Some([bw, bh]) = box_size else {
        return (0.0, 0.0);
    };
    let x = match h_align {
        HAlign::Left => 0.0,
        HAlign::Center => (bw - w) / 2.0,
        HAlign::Right => bw - w,
    };
    let y = match v_align {
        VAlign::Top => 0.0,
        VAlign::Center => (bh - h) / 2.0,
        VAlign::Bottom => bh - h,
    };
    (x, y)
}

/// `1 0.5 0` / `1, 0.5, 0` / `#ff8000` / `#ff8000ff` to straight sRGB plus alpha.
pub fn parse_color(value: &str) -> [f32; 4] {
    let value = value.trim();
    if let Some(hex) = value.strip_prefix('#') {
        if let Some(c) = parse_hex_color(hex) {
            return c;
        }
    }
    let mut parts = Vec::new();
    for part in value.split(|c: char| c.is_whitespace() || c == ',') {
        if let Ok(v) = part.parse::<f32>() {
            parts.push(v);
        }
    }
    let get = |i: usize, d: f32| parts.get(i).copied().unwrap_or(d);
    [get(0, 1.0), get(1, 1.0), get(2, 1.0), get(3, 1.0)]
}

fn parse_hex_color(hex: &str) -> Option<[f32; 4]> {
    let expand = |s: &str| u8::from_str_radix(s, 16).ok();
    let c = match hex.len() {
        3 => {
            let r = expand(&hex[0..1])?;
            let g = expand(&hex[1..2])?;
            let b = expand(&hex[2..3])?;
            [r * 17, g * 17, b * 17, 255]
        }
        4 => {
            let r = expand(&hex[0..1])?;
            let g = expand(&hex[1..2])?;
            let b = expand(&hex[2..3])?;
            let a = expand(&hex[3..4])?;
            [r * 17, g * 17, b * 17, a * 17]
        }
        6 => [
            expand(&hex[0..2])?,
            expand(&hex[2..4])?,
            expand(&hex[4..6])?,
            255,
        ],
        8 => [
            expand(&hex[0..2])?,
            expand(&hex[2..4])?,
            expand(&hex[4..6])?,
            expand(&hex[6..8])?,
        ],
        _ => return None,
    };
    Some([
        c[0] as f32 / 255.0,
        c[1] as f32 / 255.0,
        c[2] as f32 / 255.0,
        c[3] as f32 / 255.0,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(text: &str) -> TextSpec {
        TextSpec {
            text: text.to_string(),
            ..TextSpec::default()
        }
    }

    #[test]
    fn color_parsing() {
        assert_eq!(parse_color("1 1 1"), [1.0, 1.0, 1.0, 1.0]);
        assert_eq!(parse_color("1, 0.5, 0.25"), [1.0, 0.5, 0.25, 1.0]);
        assert_eq!(parse_color("0.2 0.4 0.6 0.8"), [0.2, 0.4, 0.6, 0.8]);
        assert_eq!(parse_color("#ff8000"), [1.0, 128.0 / 255.0, 0.0, 1.0]);
        assert_eq!(parse_color("#f80"), [1.0, 136.0 / 255.0, 0.0, 1.0]);
        assert_eq!(parse_color("#ff800080")[3], 128.0 / 255.0);
        assert_eq!(parse_color("garbage"), [1.0, 1.0, 1.0, 1.0]);
    }

    #[test]
    fn alignment_offset_in_box() {
        assert_eq!(
            placement(20.0, 10.0, Some([100.0, 50.0]), HAlign::Left, VAlign::Top),
            (0.0, 0.0)
        );
        assert_eq!(
            placement(
                20.0,
                10.0,
                Some([100.0, 50.0]),
                HAlign::Center,
                VAlign::Center
            ),
            (40.0, 20.0)
        );
        assert_eq!(
            placement(
                20.0,
                10.0,
                Some([100.0, 50.0]),
                HAlign::Right,
                VAlign::Bottom
            ),
            (80.0, 40.0)
        );
        assert_eq!(
            placement(20.0, 10.0, None, HAlign::Center, VAlign::Center),
            (0.0, 0.0)
        );
    }

    #[test]
    fn alignment_offsets_a_short_line() {
        assert_eq!(line_offset(100.0, 20.0, HAlign::Left), 0.0);
        assert_eq!(line_offset(100.0, 20.0, HAlign::Center), 40.0);
        assert_eq!(line_offset(100.0, 20.0, HAlign::Right), 80.0);
        assert_eq!(line_offset(20.0, 100.0, HAlign::Center), 0.0);
    }

    #[test]
    fn opacity_and_color_are_clamped() {
        assert_eq!(
            with_opacity([2.0, -1.0, 0.5, 0.5], 0.5),
            [1.0, 0.0, 0.5, 0.25]
        );
        assert_eq!(with_opacity([1.0, 1.0, 1.0, 1.0], f32::NAN)[3], 1.0);
    }

    #[test]
    fn cache_key_changes_only_when_pixels_do() {
        let font = Font::from_name("Helvetica", 32.0);
        let mut s = spec("12:34");
        let a = CacheKey::new(&font, &s);
        let b = CacheKey::new(&font, &s.clone());
        assert_eq!(a, b);

        s.text = "12:35".into();
        assert_ne!(a, CacheKey::new(&font, &s));
        s.text = "12:34".into();
        s.color = [1.0, 0.0, 0.0, 1.0];
        assert_ne!(a, CacheKey::new(&font, &s));
        s.color = [1.0, 1.0, 1.0, 1.0];
        s.pixels_per_point = 2.0;
        assert_ne!(a, CacheKey::new(&font, &s));

        let bigger = Font::from_name("Helvetica", 48.0);
        assert_ne!(a, CacheKey::new(&bigger, &spec("12:34")));
    }

    #[test]
    fn bitmap_rows_are_top_down() {
        // A "T" has its bar at the top: the first rows in memory must hold more ink.
        let font = Font::from_name("Helvetica", 64.0);
        let b = TextRenderer::new().render(&font, &spec("T")).unwrap();
        let (w, h) = (b.width as usize, b.height as usize);
        let ink = |rows: std::ops::Range<usize>| -> u32 {
            rows.flat_map(|y| (0..w).map(move |x| (y * w + x) * 4 + 3))
                .map(|i| b.pixels[i] as u32)
                .sum()
        };
        let top = ink(0..h / 2);
        let bottom = ink(h / 2..h);
        assert!(top > bottom, "top {top} bottom {bottom}");
    }

    #[test]
    fn scene_alignment_names() {
        assert_eq!(HAlign::from_scene(Some("center")), HAlign::Center);
        assert_eq!(HAlign::from_scene(Some("right")), HAlign::Right);
        assert_eq!(HAlign::from_scene(None), HAlign::Left);
        assert_eq!(VAlign::from_scene(Some("bottom")), VAlign::Bottom);
        assert_eq!(VAlign::from_scene(Some("nonsense")), VAlign::Top);
    }

    #[test]
    fn empty_string_makes_an_empty_bitmap() {
        let font = Font::from_name("Helvetica", 32.0);
        let mut renderer = TextRenderer::new();
        let bitmap = renderer.render(&font, &spec("")).unwrap();
        assert!(bitmap.is_empty());
        assert!(bitmap.rect.iter().all(|v| *v == 0.0));
    }

    #[test]
    fn second_render_uses_the_cache() {
        let font = Font::from_name("Helvetica", 32.0);
        let mut renderer = TextRenderer::new();
        let s = spec("cache me");
        let a = renderer.render(&font, &s).unwrap();
        let b = renderer.render(&font, &s).unwrap();
        assert!(Rc::ptr_eq(&a, &b));
        assert_eq!(renderer.cache_len(), 1);
        let mut changed = s.clone();
        changed.text = "cache you".into();
        let _ = renderer.render(&font, &changed).unwrap();
        assert_eq!(renderer.cache_len(), 2);
    }

    #[test]
    fn bad_font_bytes_fall_back_to_a_system_font() {
        let source = FontSource::from_bytes("Nope", b"not a font".to_vec());
        let font = Font::load(&source, 24.0).unwrap();
        assert!(font.metrics().0 > 0.0);
    }

    #[test]
    #[ignore = "needs the local scene library"]
    fn renders_hello_with_the_nier_font() {
        let home = std::env::var("HOME").expect("HOME");
        let path = std::path::Path::new(&home)
            .join("Library/Application Support/WallpaperMage/Library/3008153534/scene.pkg");
        let pkg = crate::vfs::Pkg::open(&path).expect("open Nier scene package");
        let data = pkg
            .get("fonts/Nexa Light.otf")
            .expect("Nier font in package");
        let font = Font::from_bytes("Nexa Light.otf", &data, 48.0).expect("load Nier font");

        let mut renderer = TextRenderer::new();
        let spec = TextSpec {
            text: "Hello".into(),
            color: [0.9, 0.15, 0.1, 1.0],
            pixels_per_point: 2.0,
            padding: 4.0,
            box_size: Some([300.0, 80.0]),
            h_align: HAlign::Center,
            v_align: VAlign::Center,
            ..TextSpec::default()
        };
        let bitmap = renderer.render(&font, &spec).expect("render text");
        assert!(bitmap.width > 0 && bitmap.height > 0);
        assert_eq!(
            bitmap.pixels.len(),
            bitmap.width as usize * bitmap.height as usize * 4
        );
        assert!(
            bitmap.has_colored_pixels(),
            "the glyphs should produce visible pixels"
        );
        assert!(
            bitmap
                .pixels
                .as_chunks::<4>()
                .0
                .iter()
                .any(|p| p[3] > 0 && p[0] > p[1] && p[0] > p[2]),
            "the red text colour should survive premultiplication"
        );
        assert!(bitmap.rect[2] > 0.0 && bitmap.rect[3] > 0.0);
    }
}
