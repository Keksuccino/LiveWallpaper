//! Video textures: an MP4 file that a `.tex` file carries instead of pixels (Wallpaper Engine's
//! animated GIFs become these), decoded with AVFoundation and looping with scene time.
//!
//! AVFoundation reads from a file, so the clip is written to a file in the temporary folder named
//! after its contents: renderers of the same scene share it, a later run reuses it, and there is
//! never more than one per clip (the system clears the folder). Frames are decoded in order, on the hardware decoder, as the scene time passes
//! their presentation times; a time before the frame shown (the loop wrapped, the scene
//! restarted) starts the reader over.

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_av_foundation::{
    AVAssetReader, AVAssetReaderStatus, AVAssetReaderTrackOutput, AVAssetTrack, AVMediaTypeVideo, AVURLAsset,
};
use objc2_core_foundation::CFString;
use objc2_core_media::CMSampleBuffer;
use objc2_core_video::{
    kCVPixelBufferPixelFormatTypeKey, kCVPixelFormatType_32BGRA, CVPixelBufferGetBaseAddress,
    CVPixelBufferGetBytesPerRow, CVPixelBufferGetHeight, CVPixelBufferGetWidth, CVPixelBufferLockBaseAddress,
    CVPixelBufferLockFlags, CVPixelBufferUnlockBaseAddress,
};
use objc2_foundation::{NSDictionary, NSNumber, NSString, NSURL};

use crate::Error;

/// One decoded frame: BGRA rows, `width * 4` bytes each.
pub struct Picture<'a> {
    pub width: usize,
    pub height: usize,
    pub pixels: &'a [u8],
}

pub struct Video {
    track: Retained<AVAssetTrack>,
    asset: Retained<AVURLAsset>,
    reader: Option<(Retained<AVAssetReader>, Retained<AVAssetReaderTrackOutput>)>,
    duration: f64,
    /// Presentation time of the frame shown, and the next frame decoded but not yet due.
    shown: Option<f64>,
    next: Option<(f64, Retained<CMSampleBuffer>)>,
    pixels: Vec<u8>,
    size: [usize; 2],
}

impl Video {
    /// Opens the MP4 `data`. `name` is for messages.
    pub fn open(data: &[u8], name: &str) -> Result<Self, Error> {
        // FNV-1a of the contents.
        let hash = data.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, &b| (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3));
        let file = std::env::temp_dir().join(format!("wallpapermage-video-{hash:016x}-{}.mp4", data.len()));
        if std::fs::metadata(&file).map_or(true, |m| m.len() != data.len() as u64) {
            // Written aside and renamed, so a reader never sees half a file.
            let part = file.with_extension(format!("{}.part", std::process::id()));
            std::fs::write(&part, data)
                .and_then(|()| std::fs::rename(&part, &file))
                .map_err(|e| Error::Io(format!("{}: {e}", file.display())))?;
        }
        let url = NSURL::fileURLWithPath(&NSString::from_str(&file.to_string_lossy()));
        // SAFETY: plain AVFoundation object creation; the asset is read synchronously below.
        let (asset, track, duration) = unsafe {
            let asset = AVURLAsset::URLAssetWithURL_options(&url, None);
            let video = AVMediaTypeVideo.ok_or_else(|| Error::Unsupported("no AVFoundation video type".into()))?;
            #[allow(deprecated)]
            let track = asset.tracksWithMediaType(video).firstObject();
            let duration = asset.duration().seconds();
            (asset, track, duration)
        };
        let Some(track) = track else {
            return Err(Error::Format(format!("video texture {name} has no video track")));
        };
        Ok(Self {
            track,
            asset,
            reader: None,
            duration: if duration.is_finite() { duration } else { 0.0 },
            shown: None,
            next: None,
            pixels: Vec::new(),
            size: [0; 2],
        })
    }

    /// The frame due at scene time `time` (looping), when it differs from the one shown.
    pub fn seek(&mut self, time: f32) -> Option<Picture<'_>> {
        let t = if self.duration > 0.0 { f64::from(time).rem_euclid(self.duration) } else { 0.0 };
        if self.reader.is_none() || self.shown.is_some_and(|s| t < s) {
            self.restart();
        }
        // The last frame due; after a restart at least the first one.
        let mut due: Option<(f64, Retained<CMSampleBuffer>)> = None;
        loop {
            if self.next.is_none() {
                self.next = self.read();
            }
            let take = match &self.next {
                Some((pts, _)) => *pts <= t || (self.shown.is_none() && due.is_none()),
                None => false,
            };
            if !take {
                break;
            }
            due = self.next.take();
        }
        let (pts, sample) = due?;
        self.shown = Some(pts);
        self.copy(&sample).then(|| Picture { width: self.size[0], height: self.size[1], pixels: &self.pixels })
    }

    fn restart(&mut self) {
        self.shown = None;
        self.next = None;
        let key: &NSString = {
            let k: &CFString = unsafe { kCVPixelBufferPixelFormatTypeKey };
            // SAFETY: CFString and NSString are toll-free bridged.
            unsafe { &*(k as *const CFString).cast::<NSString>() }
        };
        let format = NSNumber::numberWithUnsignedInt(kCVPixelFormatType_32BGRA);
        let settings = NSDictionary::<NSString, AnyObject>::from_slices(&[key], &[&**format as &AnyObject]);
        // SAFETY: the reader reads the asset's own track with valid settings.
        self.reader = unsafe {
            let Ok(reader) = AVAssetReader::assetReaderWithAsset_error(&self.asset) else { return };
            let output = AVAssetReaderTrackOutput::assetReaderTrackOutputWithTrack_outputSettings(&self.track, Some(&settings));
            output.setAlwaysCopiesSampleData(false);
            if !reader.canAddOutput(&output) {
                return;
            }
            reader.addOutput(&output);
            if !reader.startReading() {
                return;
            }
            Some((reader, output))
        };
    }

    /// The next decoded frame and its presentation time.
    fn read(&mut self) -> Option<(f64, Retained<CMSampleBuffer>)> {
        let (reader, output) = self.reader.as_ref()?;
        // SAFETY: the reader was started; a finished reader returns nothing.
        unsafe {
            if reader.status() != AVAssetReaderStatus::Reading {
                return None;
            }
            let sample = output.copyNextSampleBuffer()?;
            Some((sample.presentation_time_stamp().seconds(), sample))
        }
    }

    /// Copies a frame's pixels into `pixels`, tightly packed.
    fn copy(&mut self, sample: &CMSampleBuffer) -> bool {
        // SAFETY: the base address is valid while locked; rows are read within the buffer.
        unsafe {
            let Some(image) = sample.image_buffer() else { return false };
            if CVPixelBufferLockBaseAddress(&image, CVPixelBufferLockFlags::ReadOnly) != 0 {
                return false;
            }
            let (w, h, stride) = (CVPixelBufferGetWidth(&image), CVPixelBufferGetHeight(&image), CVPixelBufferGetBytesPerRow(&image));
            let base = CVPixelBufferGetBaseAddress(&image) as *const u8;
            if !base.is_null() {
                self.pixels.resize(w * h * 4, 0);
                for y in 0..h {
                    let row = std::slice::from_raw_parts(base.add(y * stride), w * 4);
                    self.pixels[y * w * 4..(y + 1) * w * 4].copy_from_slice(row);
                }
                self.size = [w, h];
            }
            CVPixelBufferUnlockBaseAddress(&image, CVPixelBufferLockFlags::ReadOnly);
            !base.is_null()
        }
    }
}
