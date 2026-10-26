use almost_enough::SyncStopper;
use enough::{Stop, Unstoppable};
use fast_ssim2::{
    compute_ssimulacra2_with_config, PixelDescriptor, PixelSlice, Ssimulacra2Config,
    Ssimulacra2Error, Ssimulacra2Reference,
};
use rustler::{Atom, Binary, ResourceArc};

/// Rows per cancellation-check boundary at scale 0. 256 is upstream's
/// documented memory sweet spot (~bounded peak working set at 40 MP) and
/// gives ~150 ms cancellation latency at scale 0 on a 36 MP image.
const STRIP_HEIGHT: usize = 256;

#[derive(rustler::NifTaggedEnum)]
enum CompareError {
    Cancelled,
    Failed(String),
}

fn to_compare_error(e: Ssimulacra2Error) -> CompareError {
    match e {
        Ssimulacra2Error::Cancelled(_) => CompareError::Cancelled,
        other => CompareError::Failed(other.to_string()),
    }
}

mod atoms {
    rustler::atoms! {
        ok,
        rgb888,
        rgb16,
        linear_rgb,
        gray8,
        linear_gray,
    }
}

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

struct StopResource {
    stopper: SyncStopper,
}

#[rustler::resource_impl]
impl rustler::Resource for StopResource {}

/// Create a fresh, live cancellation token. Regular (non-dirty) NIF.
#[rustler::nif]
fn token_new() -> ResourceArc<StopResource> {
    ResourceArc::new(StopResource {
        stopper: SyncStopper::new(),
    })
}

/// Trip a cancellation token. Regular NIF — runs instantly on a normal
/// scheduler, so it can cancel a token while a dirty `compare` blocks.
#[rustler::nif]
fn token_cancel(token: ResourceArc<StopResource>) -> Atom {
    token.stopper.cancel();
    atoms::ok()
}

enum Format {
    Rgb888,
    Rgb16,
    LinearRgb,
    Gray8,
    LinearGray,
}

impl Format {
    fn from_atom(a: Atom) -> Result<Self, String> {
        if a == atoms::rgb888() {
            Ok(Format::Rgb888)
        } else if a == atoms::rgb16() {
            Ok(Format::Rgb16)
        } else if a == atoms::linear_rgb() {
            Ok(Format::LinearRgb)
        } else if a == atoms::gray8() {
            Ok(Format::Gray8)
        } else if a == atoms::linear_gray() {
            Ok(Format::LinearGray)
        } else {
            Err("unknown format".to_string())
        }
    }
}

impl Format {
    fn descriptor(&self) -> PixelDescriptor {
        match self {
            Format::Rgb888 => PixelDescriptor::RGB8_SRGB,
            Format::Rgb16 => PixelDescriptor::RGB16_SRGB,
            Format::LinearRgb => PixelDescriptor::RGBF32_LINEAR,
            Format::Gray8 => PixelDescriptor::GRAY8_SRGB,
            Format::LinearGray => PixelDescriptor::GRAYF32_LINEAR,
        }
    }

    fn bytes_per_pixel(&self) -> usize {
        match self {
            Format::Rgb888 => 3,
            Format::Rgb16 => 6,
            Format::LinearRgb => 12,
            Format::Gray8 => 1,
            Format::LinearGray => 4,
        }
    }
}

// Pixel bytes as fast-ssim2 can read them. PixelSlice requires the data to be
// aligned for the sample type, but BEAM (sub-)binaries are not guaranteed to be
// 2-/4-byte aligned. Aligned binaries (the common case) are borrowed as-is; a
// misaligned one is copied into a u32-backed buffer, which is aligned for every
// sample type we accept.
enum Pixels<'a> {
    Borrowed(&'a [u8]),
    Copied(Vec<u32>, usize),
}

impl<'a> Pixels<'a> {
    fn new(b: &'a [u8], format: &Format) -> Self {
        let align = match format {
            Format::Rgb888 | Format::Gray8 => 1,
            Format::Rgb16 => 2,
            Format::LinearRgb | Format::LinearGray => 4,
        };
        if (b.as_ptr() as usize).is_multiple_of(align) {
            Pixels::Borrowed(b)
        } else {
            let mut buf = vec![0u32; b.len().div_ceil(4)];
            bytemuck::cast_slice_mut::<u32, u8>(&mut buf)[..b.len()].copy_from_slice(b);
            Pixels::Copied(buf, b.len())
        }
    }

    fn bytes(&self) -> &[u8] {
        match self {
            Pixels::Borrowed(b) => b,
            Pixels::Copied(buf, len) => &bytemuck::cast_slice(buf)[..*len],
        }
    }

    fn slice(&self, w: usize, h: usize, format: &Format) -> Result<PixelSlice<'_>, String> {
        let stride = w * format.bytes_per_pixel();
        PixelSlice::new(
            self.bytes(),
            w as u32,
            h as u32,
            stride,
            format.descriptor(),
        )
        .map_err(|e| e.to_string())
    }
}

// Every size takes the strip path (tight per-strip cancellation latency +
// bounded peak memory); fast-ssim2 reflect-pads sub-8px inputs there itself.
fn strip_config(stop: &dyn Stop) -> Ssimulacra2Config<'_> {
    Ssimulacra2Config::strips(STRIP_HEIGHT).with_stop(stop)
}

fn stop_of(cancel: &Option<ResourceArc<StopResource>>) -> &dyn Stop {
    match cancel {
        Some(res) => &res.stopper,
        None => &Unstoppable,
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compare(
    reference: Binary,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
    cancel: Option<ResourceArc<StopResource>>,
) -> Result<f64, CompareError> {
    let format = Format::from_atom(format).map_err(CompareError::Failed)?;
    let (r, d) = (
        Pixels::new(reference.as_slice(), &format),
        Pixels::new(distorted.as_slice(), &format),
    );
    let r = r
        .slice(width, height, &format)
        .map_err(CompareError::Failed)?;
    let d = d
        .slice(width, height, &format)
        .map_err(CompareError::Failed)?;
    compute_ssimulacra2_with_config(&r, &d, &strip_config(stop_of(&cancel)))
        .map_err(to_compare_error)
}

struct ReferenceResource {
    inner: Ssimulacra2Reference,
}

#[rustler::resource_impl]
impl rustler::Resource for ReferenceResource {}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_new(
    source: Binary,
    width: usize,
    height: usize,
    format: Atom,
) -> Result<ResourceArc<ReferenceResource>, String> {
    let format = Format::from_atom(format)?;
    let s = Pixels::new(source.as_slice(), &format);
    let inner =
        Ssimulacra2Reference::new(&s.slice(width, height, &format)?).map_err(|e| e.to_string())?;
    Ok(ResourceArc::new(ReferenceResource { inner }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_compare(
    reference: ResourceArc<ReferenceResource>,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
    cancel: Option<ResourceArc<StopResource>>,
) -> Result<f64, CompareError> {
    let format = Format::from_atom(format).map_err(CompareError::Failed)?;
    let d = Pixels::new(distorted.as_slice(), &format);
    let d = d
        .slice(width, height, &format)
        .map_err(CompareError::Failed)?;
    reference
        .inner
        .compare_with_config(&d, &strip_config(stop_of(&cancel)))
        .map_err(to_compare_error)
}

rustler::init!("Elixir.Ssimulacra2.Native");
